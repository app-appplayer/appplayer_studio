import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart'
    show
        AgentHost,
        BuiltInAppContext,
        BuiltInAppRegistry,
        BuiltinToolRegistry,
        ChromeBridge,
        DomainLifecycleState,
        DomainSettingsPanel,
        LifecycleHandler,
        LifecycleSlots,
        ManifestFieldList,
        SettingsSection,
        StudioBackbone,
        StudioWelcomePanel,
        VibeSettings,
        WorkspaceTabActiveScope,
        bakeInheritedFields,
        effectiveWorkspaceDir;
import 'package:appplayer_studio/src/base/settings/settings_dialog.dart'
    show promptForNewProject;

import '../form_builder_builtin.dart';
import '../infra/project_seed.dart';
import '../init/form_init.dart';
import 'approvals_page.dart';
import 'compose_page.dart';
import 'registry_page.dart';
import 'templates_page.dart';

/// Sidebar routes — Templates (create/manage) · Compose (fill/validate) ·
/// Issues (published snapshots + corrections) · About.
enum FormRoute {
  templates('Templates', Icons.grid_view_outlined),
  compose('Compose', Icons.edit_note_outlined),
  approvals('Approvals', Icons.approval_outlined),
  issues('Registry', Icons.library_books_outlined),
  about('About', Icons.info_outline);

  const FormRoute(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Top-level body the host mounts inside the Form Builder tab. Owns the
/// project lifecycle (welcome → bind → routes), the chrome
/// hooks, and the active-tab gate — App Builder / Scene Builder / Ops
/// pattern, nothing bespoke.
class FormShell extends StatefulWidget {
  const FormShell({
    super.key,
    required this.app,
    required this.bundlePath,
    required this.chromeBridge,
    required this.server,
    required this.backbone,
    this.inheritedSettings = const <String, Object?>{},
    this.overridesFile = '',
  });

  final FormBuilderBuiltInApp app;
  final String bundlePath;
  final ChromeBridge chromeBridge;
  final BuiltinToolRegistry server;
  final StudioBackbone backbone;
  final Map<String, Object?> inheritedSettings;
  final String overridesFile;

  @override
  State<FormShell> createState() => _FormShellState();
}

class _FormShellState extends State<FormShell> {
  FormRoute _route = FormRoute.templates;
  String? _currentProject;
  Future<FormInit>? _bootFuture;

  /// Issues → Compose correction handoff: the issue whose content pre-fills
  /// the editor (`supersedes` pre-set). Keyed into ComposePage so each
  /// handoff recreates the editor state.
  Map<String, dynamic>? _correction;

  /// Deep-link landing (`studio.app.open` → [_navigate]): the entity the
  /// target page should focus once it builds — an issueId on Issues, a
  /// documentId on Approvals, a templateId on Templates. Cleared on the
  /// next manual route change (one-shot, same spirit as [_correction]).
  String? _landingEntity;

  /// Per-project chat coordinator clone id (`form_builder.manager.<proj>_<h>`)
  /// — cached so tab re-activation re-applies it without re-deriving from the
  /// volatile `activeChatAgentId`. Single coordinator per project (Ops
  /// 2026-07-03 model).
  String? _scopedManagerId;

  static const String _managerId = 'form_builder.manager';

  late final BuiltInAppContext _ctx;

  @override
  void initState() {
    super.initState();
    _ctx =
        BuiltInAppContext(
            bundlePath: widget.bundlePath,
            chromeBridge: widget.chromeBridge,
            inheritedSettings: widget.inheritedSettings,
            overridesFile: widget.overridesFile,
          )
          ..lifecycleStateProvider = _provideLifecycleState
          ..lifecycleBindingsProvider = _provideLifecycleBindings
          ..domainSettingsProvider = _provideDomainSettings
          ..navigateProvider = _navigate;
    BuiltInAppRegistry.instance.mount(widget.bundlePath, widget.app, _ctx);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _publishLifecycleState();
        _restoreLastProject();
      }
    });
  }

  /// Deep-link landing. Route names =
  /// the rail's lower-case labels; unknown route/entity returns false so
  /// `studio.app.open` reports it instead of landing somewhere wrong.
  Future<bool> _navigate(String route, {String? entityId}) async {
    final target = switch (route) {
      'dashboard' || 'templates' => FormRoute.templates,
      'compose' => FormRoute.compose,
      'approvals' => FormRoute.approvals,
      'issues' || 'registry' => FormRoute.issues,
      'about' => FormRoute.about,
      _ => null,
    };
    if (target == null || !mounted) return false;
    setState(() {
      _route = target;
      _landingEntity = entityId;
    });
    return true;
  }

  // --- project lifecycle --------------------------------------------------

  String get _hostSettingsPath =>
      VibeSettings.defaultPath(widget.backbone.toolId);

  Future<void> _restoreLastProject() async {
    if (!mounted || _currentProject != null) return;
    if (isFormProjectDir(widget.bundlePath)) {
      _bindProject(widget.bundlePath);
      return;
    }
    try {
      final s = await VibeSettings.load(_hostSettingsPath);
      final last = s.domainLastProject[widget.app.id];
      if (last != null && isFormProjectDir(last)) {
        if (mounted) _bindProject(last);
      }
    } catch (_) {
      /* welcome panel stays */
    }
  }

  Future<Map<String, dynamic>> _newProject({
    required String name,
    required String parent,
  }) async {
    final dir = p.join(parent, name);
    await Directory(dir).create(recursive: true);
    await applyFormProjectSeed(dir, name);
    return _bindProject(dir);
  }

  Future<Map<String, dynamic>> _openProject(String path) async {
    if (!isFormProjectDir(path)) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text(
              'Not a Form Builder project (project.formproj missing)',
            ),
          ),
        );
      }
      return <String, dynamic>{
        'ok': false,
        'error': 'Not a Form Builder project (project.formproj missing)',
      };
    }
    return _bindProject(path);
  }

  Map<String, dynamic> _bindProject(String dir) {
    // ensureBoot runs unconditionally (even if this widget is between
    // mounts) so tool handlers resolving through
    // `FormBuilderBuiltInApp.liveInit` see the live project.
    final future = FormBuilderBuiltInApp.ensureBoot(dir);
    if (mounted) {
      setState(() {
        _currentProject = dir;
        _bootFuture = future;
      });
      _publishLifecycleState();
    }
    // Sidecar last-project pointer (tab close + reopen restore) — per-host
    // config store value, App Builder / Scene Builder / Ops parity.
    // ignore: unawaited_futures
    () async {
      try {
        final path = _hostSettingsPath;
        final s = await VibeSettings.load(path);
        s.domainLastProject[widget.app.id] = dir;
        await s.save(path);
      } catch (_) {
        /* best-effort persistence */
      }
    }();
    // One chat / fs anchor per project (single coordinator model).
    widget.chromeBridge.setActiveTabProject?.call(dir);
    // ignore: unawaited_futures
    _applyScopedManager(dir);
    return <String, dynamic>{'ok': true, 'projectRoot': dir};
  }

  Map<String, dynamic> _closeProject() {
    // ignore: unawaited_futures
    FormBuilderBuiltInApp.closeProject();
    if (!mounted) return <String, dynamic>{'ok': true, 'closed': false};
    setState(() {
      _currentProject = null;
      _bootFuture = null;
    });
    if (_scopedManagerId != null &&
        widget.chromeBridge.chatManagerOverride.value == _scopedManagerId) {
      widget.chromeBridge.chatManagerOverride.value = null;
    }
    _scopedManagerId = null;
    _publishLifecycleState();
    return <String, dynamic>{'ok': true, 'closed': true};
  }

  /// Single per-PROJECT coordinator (`form_builder.manager.<proj>_<hash>`) —
  /// App Builder / Scene Builder / Ops(2026-07-03) same shape. Best-effort: without
  /// the seed manager / agent host the chat stays on the base resolver.
  Future<void> _applyScopedManager(String projectDir) async {
    try {
      final qualified = await AgentHost.shared?.ensureScopedManager(
        _managerId,
        projectDir,
      );
      if (qualified == null || !mounted) return;
      _scopedManagerId = qualified;
      if (_isActiveTab) {
        widget.chromeBridge.chatManagerOverride.value = qualified;
      }
    } catch (_) {
      /* base manager routing stays */
    }
  }

  // --- chrome hooks -------------------------------------------------------

  Map<String, LifecycleHandler>? _provideLifecycleBindings() {
    return <String, LifecycleHandler>{
      LifecycleSlots.projectNew: (ctx) => _executeNew(ctx),
      LifecycleSlots.projectOpen: (ctx) => _executeOpen(ctx),
      LifecycleSlots.projectClose: (_) async {
        _closeProject();
      },
    };
  }

  Future<void> _executeNew(BuildContext ctx) async {
    final defaultParent =
        _readWorkspaceDir() ??
        p.join(Platform.environment['HOME'] ?? '/tmp', 'AppPlayerProjects');
    if (!ctx.mounted) return;
    final input = await promptForNewProject(ctx, defaultParent: defaultParent);
    if (input == null) return;
    await _newProject(name: input.name, parent: input.parent);
  }

  Future<void> _executeOpen(BuildContext ctx) async {
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Open Form Builder project folder',
      initialDirectory: _readWorkspaceDir(),
    );
    if (picked == null) return;
    await _openProject(picked);
  }

  String? _readWorkspaceDir() {
    // Domain override (Form Builder Domain Settings → Workspace folder)
    // wins over the inherited studio-wide value.
    return effectiveWorkspaceDir(
      inherited: widget.inheritedSettings,
      overridesFile: widget.overridesFile,
    );
  }

  DomainSettingsPanel? _provideDomainSettings() {
    return DomainSettingsPanel(
      name: 'Form Builder',
      sections: <SettingsSection>[
        SettingsSection(
          label: 'Workspace',
          body: ManifestFieldList(
            fields: bakeInheritedFields(const <Map<String, dynamic>>[
              <String, dynamic>{
                'key': 'workspaceDir',
                'label': 'Workspace folder',
                'type': 'folder',
                'description':
                    'Parent directory where new Form Builder projects '
                    'land. Inherits from Studio Settings; a per-domain '
                    'override may be set here.',
              },
            ], widget.inheritedSettings),
            overridesFile: widget.overridesFile,
          ),
        ),
      ],
    );
  }

  DomainLifecycleState _provideLifecycleState() {
    final cp = _currentProject;
    return DomainLifecycleState(
      hasProject: cp != null,
      dirty: false,
      canUndo: false,
      canRedo: false,
      canCompareChannels: false,
      projectName: cp == null ? 'No project open' : p.basename(cp),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isActive = WorkspaceTabActiveScope.isActiveOf(context);
    if (isActive) {
      widget.chromeBridge.newProjectInActive = _newProjectSlot;
      widget.chromeBridge.openProjectInActive = _openProjectSlot;
      widget.chromeBridge.closeProjectInActive = _closeProjectSlot;
      if (_scopedManagerId != null) {
        widget.chromeBridge.chatManagerOverride.value = _scopedManagerId;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _publishLifecycleState();
      });
    } else {
      _releaseSlotsIfMine();
    }
  }

  // Stable tear-off targets so `_releaseSlotsIfMine` identity checks hold.
  late final Future<Map<String, dynamic>> Function({
    required String name,
    required String parent,
  })
  _newProjectSlot = _newProject;
  late final Future<Map<String, dynamic>> Function(String) _openProjectSlot =
      _openProject;
  late final Map<String, dynamic> Function() _closeProjectSlot = _closeProject;

  void _releaseSlotsIfMine() {
    if (widget.chromeBridge.newProjectInActive == _newProjectSlot) {
      widget.chromeBridge.newProjectInActive = null;
    }
    if (widget.chromeBridge.openProjectInActive == _openProjectSlot) {
      widget.chromeBridge.openProjectInActive = null;
    }
    if (widget.chromeBridge.closeProjectInActive == _closeProjectSlot) {
      widget.chromeBridge.closeProjectInActive = null;
    }
    if (_scopedManagerId != null &&
        widget.chromeBridge.chatManagerOverride.value == _scopedManagerId) {
      widget.chromeBridge.chatManagerOverride.value = null;
    }
  }

  bool get _isActiveTab =>
      BuiltInAppRegistry.instance.activeContext?.bundlePath ==
      widget.bundlePath;

  void _publishLifecycleState() {
    if (!_isActiveTab) return;
    widget.chromeBridge.lifecycleState.value = _provideLifecycleState();
  }

  @override
  void dispose() {
    BuiltInAppRegistry.instance.unmount(widget.bundlePath);
    _releaseSlotsIfMine();
    // Tab CLOSE = unbind the Form Builder core (design contract
    // tab-close only). This State disposes ONLY on tab
    // removal — the host renders tab bodies in a keyed IndexedStack, so a
    // tab SWITCH keeps the mount alive and the core stays bound in the
    // background. Guard on this tab owning the live boot so closing a
    // stale Form tab (or one whose project was already closed via the
    // header button) never unbinds another tab's core. Ops parity.
    if (FormBuilderBuiltInApp.shouldTeardownOnClose(_currentProject)) {
      // ignore: unawaited_futures
      FormBuilderBuiltInApp.closeProject();
    }
    super.dispose();
  }

  // --- body -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_currentProject == null || _bootFuture == null) {
      return StudioWelcomePanel(
        title: 'Form Builder',
        recents: const <String>[],
        onNew: () => _executeNew(context),
        onOpen: () => _executeOpen(context),
        onPickRecent: (_) {
          /* no recents yet */
        },
      );
    }
    return FutureBuilder<FormInit>(
      future: _bootFuture,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Form Builder boot failed: ${snap.error}'));
        }
        final init = snap.data;
        if (init == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NavigationRail(
              selectedIndex: _route.index,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected:
                  (i) => setState(() {
                    _route = FormRoute.values[i];
                    _landingEntity = null; // one-shot deep-link focus
                  }),
              destinations: [
                for (final r in FormRoute.values)
                  NavigationRailDestination(
                    icon: Icon(r.icon),
                    label: Text(r.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
              // Pages are keyed by the PROJECT ROOT: a rebind (restore →
              // project.new/open, or a switch between projects) must recreate
              // the page state — without the key the old State (and its
              // initState-loaded lists) survives the rebuild and shows the
              // PREVIOUS project's templates/drafts/issues (stale-page bug,
              // live-caught 2026-07-03 usage test).
              child: switch (_route) {
                FormRoute.templates => TemplatesPage(
                  key: ValueKey('fb-templates::${init.projectRoot}'),
                  server: widget.server,
                  projectRoot: init.projectRoot,
                ),
                FormRoute.compose => ComposePage(
                  key: ValueKey(
                    'fb-compose::${init.projectRoot}'
                    '::${_correction?['issueId'] ?? ''}',
                  ),
                  server: widget.server,
                  init: init,
                  correction: _correction,
                ),
                FormRoute.approvals => ApprovalsPage(
                  key: ValueKey(
                    'fb-approvals::${init.projectRoot}'
                    '::${_landingEntity ?? ''}',
                  ),
                  server: widget.server,
                  init: init,
                  landingDocumentId: _landingEntity,
                ),
                FormRoute.issues => RegistryPage(
                  key: ValueKey(
                    'fb-registry::${init.projectRoot}'
                    '::${_landingEntity ?? ''}',
                  ),
                  init: init,
                  landingIssueId: _landingEntity,
                  onCorrect:
                      (issue) => setState(() {
                        _correction = issue;
                        _route = FormRoute.compose;
                      }),
                ),
                FormRoute.about => _AboutPage(projectRoot: init.projectRoot),
              },
            ),
          ],
        );
      },
    );
  }
}

class _AboutPage extends StatelessWidget {
  const _AboutPage({required this.projectRoot});
  final String projectRoot;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Form Builder', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text('Project: $projectRoot', style: style),
          const SizedBox(height: 8),
          Text(
            'Templates persist as project facts through the host form.* '
            'capability; drafts and issued snapshots are form_builder.* '
            'facts. Issued documents are immutable — corrections issue a '
            'new snapshot with a supersedes link.',
            style: style,
          ),
        ],
      ),
    );
  }
}
