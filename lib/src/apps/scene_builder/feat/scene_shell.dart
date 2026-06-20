import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart'
    show
        BuiltInAppContext,
        BuiltInAppRegistry,
        ChromeBridge,
        DomainLifecycleState,
        HeaderAction,
        VibeChatController,
        WorkspaceTabActiveScope,
        materialIconByName;
import 'package:appplayer_studio/ui.dart';

import '../../../base/capture/scene_project/scene_project_tools.dart'
    show SceneProjectScope, createSceneProjectAt;
import '../scene_builder_builtin.dart';
import 'branding_view.dart';
import 'edit_view.dart';
import 'editor_view.dart';
import 'recordings_view.dart';
import 'scenarios_view.dart';

/// Authoring modes the Scene Builder exposes. `edit` = scenario step
/// editor; `video` = trim/join editor for existing video clips.
enum SceneMode { scenarios, edit, recordings, video, branding }

/// Top-level body widget the host mounts inside the Scene Builder tab.
/// Owns the mode switch + body routing + chrome action publish.
class SceneShell extends StatefulWidget {
  const SceneShell({
    super.key,
    required this.bundlePath,
    required this.chromeBridge,
    required this.chat,
  });

  final String bundlePath;
  final ChromeBridge chromeBridge;
  final VibeChatController chat;

  @override
  State<SceneShell> createState() => _SceneShellState();
}

class _SceneShellState extends State<SceneShell> {
  SceneMode _mode = SceneMode.scenarios;
  String? _selectedScenarioId;
  // Minimal project lifecycle — the active scene project folder. Adopted via
  // the chrome `openProjectInActive` slot (which `studio.scene.project.open` /
  // `.new` call) and reported via `activeProjectInfo` so scenarios/recordings
  // scope to `<project>/`. Without this the scene project tools failed
  // ("openProjectInActive bridge slot not wired") and stayed global-only.
  String? _currentProject;
  // Scope-qualified chat manager id for the active scene project
  // (`<sceneManager>.<projectId>`), cached from the bridge override the
  // scene-project tool sets on open (`_adoptProject`). Re-applied verbatim on
  // tab re-activation so the per-project chat isolation survives the host's
  // two-phase active-tab publish — mirrors App Builder #23. Re-deriving it here
  // from the volatile `activeChatAgentId` races the host's deferred sync.
  String? _scopedManagerId;
  late final BuiltInAppContext _ctx;

  @override
  void initState() {
    super.initState();
    _ctx =
        BuiltInAppContext(
            bundlePath: widget.bundlePath,
            chromeBridge: widget.chromeBridge,
          )
          ..headerActionsProvider = _provideHeaderActions
          ..lifecycleStateProvider = _provideLifecycleState;
    BuiltInAppRegistry.instance.mount(
      widget.bundlePath,
      const SceneBuilderBuiltInApp(),
      _ctx,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshHeaderActions();
    });
  }

  @override
  void dispose() {
    // Release the project lifecycle slots if we still own them.
    if (identical(widget.chromeBridge.openProjectInActive, _adoptProject)) {
      widget.chromeBridge.openProjectInActive = null;
    }
    if (identical(widget.chromeBridge.activeProjectInfo, _reportProjectInfo)) {
      widget.chromeBridge.activeProjectInfo = null;
    }
    if (identical(widget.chromeBridge.newProjectInActive, _newSceneProject)) {
      widget.chromeBridge.newProjectInActive = null;
    }
    // Release the shared chat override if it's still ours — dispose-while-active
    // (tab closed while focused) doesn't go through the deactivate clear, so
    // without this the next tab's chat routes to this dead scene manager.
    if (_scopedManagerId != null &&
        widget.chromeBridge.chatManagerOverride.value == _scopedManagerId) {
      widget.chromeBridge.chatManagerOverride.value = null;
    }
    BuiltInAppRegistry.instance.unmount(widget.bundlePath);
    // Detach from DomainServerManager so a domainSpawned boot (when
    // inheritFromSystem=false) tears down when this is the last domain
    // attached. Mirror to App Builder's dispose — MOD-INFRA-010 §10.7
    // gap G-3.
    widget.chromeBridge.domainServerManager?.detach(widget.bundlePath);
    super.dispose();
  }

  /// The chrome bridge is process-wide; writing while a different tab
  /// is active would clobber that tab's actions. Inactive mounts
  /// (IndexedStack keeps every tab body live, so this fires from sibling
  /// scene builders on boot too) just bail — `_setActiveContext`
  /// repopulates the bridge through the resolver when we become active.
  bool get _isActiveTab =>
      BuiltInAppRegistry.instance.activeContext?.bundlePath ==
      widget.bundlePath;

  void _refreshHeaderActions() {
    if (!_isActiveTab) return;
    final actions = _provideHeaderActions();
    if (actions != null) {
      widget.chromeBridge.headerActions.value = actions;
    }
    widget.chromeBridge.lifecycleState.value = _provideLifecycleState();
  }

  /// Own the project lifecycle slots while active so `studio.scene.project.*`
  /// and scenario/recorder dir-scoping resolve this tab's scene project.
  /// Wired/released from [didChangeDependencies] keyed on
  /// `WorkspaceTabActiveScope` — the same activation hook App Builder / Ops
  /// use (the InheritedWidget flips when the host's IndexedStack changes the
  /// active tab; a provider pull does NOT fire on `select_tab`).
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isActive = WorkspaceTabActiveScope.isActiveOf(context);
    if (isActive) {
      widget.chromeBridge.openProjectInActive = _adoptProject;
      widget.chromeBridge.activeProjectInfo = _reportProjectInfo;
      // Generic `studio.project.new` on a Scene tab → scaffold a real scene
      // project (scene.json + subdirs) instead of the host's empty-dir
      // `_doNewProject`. Mirrors App Builder/Ops wiring this slot.
      widget.chromeBridge.newProjectInActive = _newSceneProject;
      // Keep the process-global scope tracking the ACTIVE scene tab (it's the
      // source of truth the scene tools / recorder read). Otherwise, with
      // multiple scene tabs open, last-opened wins instead of the active tab.
      final cp = _currentProject;
      if (cp != null && cp.isNotEmpty) SceneProjectScope.activePath = cp;
    } else {
      if (identical(widget.chromeBridge.openProjectInActive, _adoptProject)) {
        widget.chromeBridge.openProjectInActive = null;
      }
      if (identical(
        widget.chromeBridge.activeProjectInfo,
        _reportProjectInfo,
      )) {
        widget.chromeBridge.activeProjectInfo = null;
      }
      if (identical(widget.chromeBridge.newProjectInActive, _newSceneProject)) {
        widget.chromeBridge.newProjectInActive = null;
      }
    }
    // Per-scene-project chat manager override lifecycle — mirror App Builder
    // #23. Re-apply this tab's CACHED scoped manager id while active, clear
    // when inactive so a sibling tab's chat isn't routed to it. Cached (not
    // re-derived) because the host's `_notifyContext` two-phase publish briefly
    // flips this tab inactive (clearing the override) then re-active while the
    // host's deferred `_syncChatAgent` has left `activeChatAgentId` momentarily
    // empty — re-deriving there would leave the override null (the scoB leak).
    final override = widget.chromeBridge.chatManagerOverride;
    if (isActive) {
      override.value = _scopedManagerId;
    } else if (_scopedManagerId != null && override.value == _scopedManagerId) {
      // Release only OUR override — the bridge field is shared and every
      // builtin shell writes it on rebuild; clearing unconditionally would
      // clobber a sibling tab's active override (the A->B->A leak).
      override.value = null;
    }
  }

  /// Host chrome `newProjectInActive` slot — generic `studio.project.new` on
  /// the active Scene tab. Delegates to the shared scene scaffolder so it
  /// builds the scene-shaped layout (not the host's empty dir).
  Future<Map<String, dynamic>> _newSceneProject({
    required String name,
    required String parent,
  }) => createSceneProjectAt(
    bridge: widget.chromeBridge,
    name: name,
    parent: parent,
  );

  /// Adopt [path] as the active scene project (chrome `openProjectInActive`
  /// slot — invoked by `studio.scene.project.open` / `.new`).
  Future<Map<String, dynamic>> _adoptProject(String path) async {
    if (!mounted) return <String, dynamic>{'ok': false, 'error': 'unmounted'};
    // Cache the scope-qualified manager id the scene-project tool just set on
    // the bridge (`_applySceneScopedManager` runs immediately before this
    // adopt) so [didChangeDependencies] can re-apply it verbatim on
    // re-activation without re-deriving from the volatile `activeChatAgentId`.
    _scopedManagerId = widget.chromeBridge.chatManagerOverride.value;
    setState(() => _currentProject = path);
    _refreshHeaderActions();
    return <String, dynamic>{
      'ok': true,
      'projectPath': path,
      'projectName': p.basename(path),
    };
  }

  /// Report the active scene project (chrome `activeProjectInfo` slot). Empty
  /// when none open, or when this tab isn't active (so a sibling tab's reads
  /// don't pick up a stale scene project).
  Map<String, dynamic> _reportProjectInfo() {
    final cp = _currentProject;
    if (cp == null || !_isActiveTab) return const <String, dynamic>{};
    return <String, dynamic>{'projectPath': cp, 'projectName': p.basename(cp)};
  }

  /// Active scene project path — owned minimally by this shell.
  String? _activeSceneProject() => _currentProject;

  DomainLifecycleState _provideLifecycleState() {
    final cp = _activeSceneProject();
    return DomainLifecycleState(
      hasProject: cp != null,
      dirty: false,
      canUndo: false,
      canRedo: false,
      canCompareChannels: false,
      projectName: cp == null ? 'No scene open' : p.basename(cp),
    );
  }

  List<HeaderAction>? _provideHeaderActions() {
    Future<Map<String, dynamic>> call(
      String tool,
      Map<String, dynamic> params,
    ) async {
      final fn = widget.chromeBridge.callHostTool;
      if (fn == null) {
        return <String, dynamic>{'ok': false, 'error': 'bridge not wired'};
      }
      return fn(tool, params);
    }

    return <HeaderAction>[
      HeaderAction(
        tooltip: 'New scenario',
        icon: Icons.add,
        elementId: 'scene_new',
        onTap: () {
          setState(() {
            _selectedScenarioId = null;
            _mode = SceneMode.edit;
          });
        },
      ),
      HeaderAction(
        tooltip: 'Start recording',
        icon: Icons.fiber_manual_record,
        elementId: 'scene_record_start',
        onTap: () async {
          final result = await call(
            'studio.recorder.start',
            const <String, dynamic>{'fps': 24, 'area': 'window'},
          );
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result['ok'] == false
                    ? 'Start failed · ${result['error'] ?? 'unknown'}'
                    : 'Recording…',
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        },
      ),
      HeaderAction(
        tooltip: 'Stop recording',
        icon: Icons.stop,
        elementId: 'scene_record_stop',
        onTap: () async {
          final result = await call(
            'studio.recorder.stop',
            const <String, dynamic>{},
          );
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result['ok'] == false
                    ? 'Stop failed · ${result['error'] ?? 'unknown'}'
                    : 'Stopped',
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        },
      ),
      HeaderAction(
        tooltip: 'Refresh',
        icon: materialIconByName('refresh'),
        elementId: 'scene_refresh',
        divider: true,
        onTap: () {
          // Re-mount the active view by toggling mode.
          final m = _mode;
          setState(() => _mode = SceneMode.scenarios);
          if (m != SceneMode.scenarios) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _mode = m);
            });
          }
        },
      ),
    ];
  }

  void _switchMode(SceneMode m) {
    setState(() => _mode = m);
    _refreshHeaderActions();
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Container(
      color: c.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _ModeStrip(active: _mode, onSelect: _switchMode),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    switch (_mode) {
      case SceneMode.scenarios:
        return ScenariosView(
          bundlePath: widget.bundlePath,
          chromeBridge: widget.chromeBridge,
          onEdit:
              (id) => setState(() {
                _selectedScenarioId = id;
                _mode = SceneMode.edit;
              }),
          onNewScenario:
              () => setState(() {
                _selectedScenarioId = null;
                _mode = SceneMode.edit;
              }),
        );
      case SceneMode.edit:
        return EditView(
          bundlePath: widget.bundlePath,
          chromeBridge: widget.chromeBridge,
          scenarioId: _selectedScenarioId,
        );
      case SceneMode.recordings:
        return RecordingsView(
          bundlePath: widget.bundlePath,
          chromeBridge: widget.chromeBridge,
        );
      case SceneMode.video:
        return EditorView(chromeBridge: widget.chromeBridge);
      case SceneMode.branding:
        return BrandingView(
          bundlePath: widget.bundlePath,
          chromeBridge: widget.chromeBridge,
        );
    }
  }
}

class _ModeStrip extends StatelessWidget {
  const _ModeStrip({required this.active, required this.onSelect});

  final SceneMode active;
  final void Function(SceneMode) onSelect;

  static const List<SceneMode> _order = <SceneMode>[
    SceneMode.scenarios,
    SceneMode.edit,
    SceneMode.recordings,
    SceneMode.video,
    SceneMode.branding,
  ];

  static const Map<SceneMode, ({String label, IconData icon})> _meta =
      <SceneMode, ({String label, IconData icon})>{
        SceneMode.scenarios: (label: 'Scenarios', icon: Icons.list_alt),
        SceneMode.edit: (label: 'Edit', icon: Icons.edit_outlined),
        SceneMode.recordings: (
          label: 'Recordings',
          icon: Icons.videocam_outlined,
        ),
        SceneMode.video: (label: 'Video', icon: Icons.content_cut),
        SceneMode.branding: (label: 'Branding', icon: Icons.palette_outlined),
      };

  @override
  Widget build(BuildContext context) {
    return VbuTabStrip(
      tabs: <VbuTab>[
        for (final m in _order)
          VbuTab(label: _meta[m]!.label, icon: _meta[m]!.icon, closable: false),
      ],
      activeIndex: _order.indexOf(active),
      onSelect: (i) => onSelect(_order[i]),
      showActiveTopAccent: false,
    );
  }
}
