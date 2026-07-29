/// Ops shell — sidebar + body inside the vibe_studio chrome. Chrome
/// (titlebar / statusbar / tab) lives in `StandardStudioShell`; this
/// widget owns the route state for Ops's per-section pages.
///
/// Phase C scaffold — surfaces the sidebar layout + placeholder
/// bodies for every route so the chrome routing path is exercised
/// end-to-end. Each route's real page is ported in follow-up rounds
/// from `apps/Ops/dart/lib/ui/<page>/`.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/base/settings/settings_dialog.dart'
    show promptForNewProject;
import 'package:appplayer_studio/src/base/settings/vibe_settings.dart'
    show VibeSettings;
import 'package:appplayer_studio/src/apps/ops/util/log.dart' show OpsLog;
import 'package:appplayer_studio/src/apps/ops/debug/ui_debug_bridge.dart'
    show UiDebugAttacher, UiDebugBridge;
import 'package:appplayer_studio/src/apps/ops/debug/ui_dialog_listener.dart'
    show UiDialogListener;
import 'package:appplayer_studio/src/apps/ops/state/providers.dart';
import 'ops_builtin.dart' show OpsBootResult, OpsBuiltInApp;
import 'package:appplayer_studio/src/apps/ops/registries/member_registry.dart'
    show AgentMember;
import 'package:appplayer_studio/src/apps/ops/ui/about/about_page.dart';
import 'package:appplayer_studio/src/apps/ops/ui/audit/audit_placeholder_page.dart';
import 'package:appplayer_studio/src/apps/ops/ui/bundle/bundles_page.dart';
import 'package:appplayer_studio/src/apps/ops/ui/home/workspace_home_page.dart';
import 'package:appplayer_studio/src/apps/ops/ui/inbox/inbox_page.dart';
import 'package:appplayer_studio/src/apps/ops/ui/knowledge/knowledge_page.dart';
import 'package:appplayer_studio/src/apps/ops/ui/member/member_page.dart';
import 'package:appplayer_studio/src/apps/ops/ui/observability/activity_feed_page.dart';
import 'package:appplayer_studio/src/apps/ops/ui/organization/org_chart_page.dart';
import 'package:appplayer_studio/src/apps/ops/ui/channels/channels_page.dart';
import 'package:appplayer_studio/src/apps/ops/ui/philosophy/philosophies_page.dart';
import 'package:appplayer_studio/src/apps/ops/ui/process/process_page.dart';
import 'package:appplayer_studio/src/apps/ops/ui/profile/profiles_page.dart';
import 'package:appplayer_studio/src/apps/ops/ui/files/files_page.dart';
import 'package:appplayer_studio/src/apps/ops/ui/resources/resources_page.dart';
import 'package:appplayer_studio/src/apps/ops/ui/settings/settings_page.dart';
import 'package:appplayer_studio/src/apps/ops/ui/skill/skills_page.dart';
import 'package:appplayer_studio/src/apps/ops/ui/task/task_page.dart';
import 'package:appplayer_studio/src/apps/ops/ui/workspace/workspace_list_pane.dart';
import 'package:appplayer_studio/base.dart'
    show
        AgentHost,
        BuiltInApp,
        BuiltInAppContext,
        BuiltInAppRegistry,
        BuiltinToolRegistry,
        ChromeBridge,
        DomainLifecycleState,
        DomainSettingsPanel,
        LifecycleHandler,
        LifecycleSlots,
        SettingsSection,
        ManifestFieldList,
        bakeInheritedFields,
        effectiveWorkspaceDir,
        StudioBackbone,
        StudioWelcomePanel,
        WorkspaceTabActiveScope,
        inspectTag;
import 'infra/project_seed.dart' show applyOpsProjectSeed, isOpsProjectDir;
import 'package:appplayer_studio/ui.dart' as ui;

/// Sidebar route — mirrors the order of `apps/Ops/dart/lib/widgets/
/// ops_sidebar.dart`. Each value maps to a body widget in [OpsShell].
/// Sidebar groups — the essence-based information architecture.
/// The flat menu is replaced by
/// four essence areas + a System bin.
enum OpsGroup {
  overview('OVERVIEW'),
  experts('PEOPLE'),
  knowledge('KNOWLEDGE'),
  work('WORK'),
  system('SYSTEM');

  const OpsGroup(this.label);
  final String label;
}

enum OpsRoute {
  // Overview — workspace at a glance (status · work · evolution timeline).
  home('home', 'Home', Icons.home_outlined, OpsGroup.overview),
  observability(
    'observability',
    'Activity',
    Icons.timeline_outlined,
    OpsGroup.overview,
  ),
  // Organization — workspaces + their agents/knowledge as a graphical chart.
  organization(
    'organization',
    'Organization',
    Icons.hub_outlined,
    OpsGroup.overview,
  ),
  // Experts — agents as growing specialists (4-axis owned + transfer).
  members('members', 'Experts', Icons.group_outlined, OpsGroup.experts),
  // Knowledge — the 4 axes (pool seed + every agent's evolving owned) + facts.
  knowledge(
    'knowledge',
    'Knowledge',
    Icons.menu_book_outlined,
    OpsGroup.knowledge,
  ),
  skills('skills', 'Skills', Icons.handyman_outlined, OpsGroup.knowledge),
  profiles('profiles', 'Profiles', Icons.badge_outlined, OpsGroup.knowledge),
  philosophies(
    'philosophies',
    'Philosophies',
    Icons.psychology_outlined,
    OpsGroup.knowledge,
  ),
  // Work — tasks & processes the experts collaborate on.
  inbox('inbox', 'Inbox', Icons.inbox_outlined, OpsGroup.work),
  tasks('tasks', 'Tasks', Icons.task_outlined, OpsGroup.work),
  processes(
    'processes',
    'Processes',
    Icons.account_tree_outlined,
    OpsGroup.work,
  ),
  // System — operator tools.
  workspaces(
    'workspaces',
    'Workspaces',
    Icons.folder_outlined,
    OpsGroup.system,
  ),
  bundles('bundles', 'Bundles', Icons.inventory_2_outlined, OpsGroup.system),
  resources('resources', 'Resources', Icons.lan_outlined, OpsGroup.system),
  // Channels — external messaging accounts (KakaoTalk / email / Slack / …) the
  // workspace uses to notify + receive; credentials in the secure vault.
  channels('channels', 'Channels', Icons.forum_outlined, OpsGroup.system),
  files('files', 'Files', Icons.folder_open_outlined, OpsGroup.system),
  audit('audit', 'Audit', Icons.fact_check_outlined, OpsGroup.system),
  about('about', 'About', Icons.info_outline, OpsGroup.system);
  // Chat / Settings retired — host chrome owns both surfaces:
  //   - Chat: host chat panel routed via `chromeBridge.activeChatAgentId`
  //     (Ops's defaultChatAgentId = 'ops.manager').
  //   - Settings: host Studio Settings dialog reads
  //     `BuiltInAppContext.domainSettingsProvider` and renders Ops's
  //     section alongside the host sections.

  const OpsRoute(this.id, this.label, this.icon, this.group);
  final String id;
  final String label;
  final IconData icon;
  final OpsGroup group;
}

class OpsShell extends StatefulWidget {
  const OpsShell({
    super.key,
    required this.bundlePath,
    required this.chromeBridge,
    required this.tabKey,
    required this.backbone,
    required this.app,
    required this.server,
    this.inheritedSettings = const <String, Object?>{},
    this.overridesFile = '',
  });

  final String bundlePath;
  final ChromeBridge chromeBridge;
  final String tabKey;
  final StudioBackbone backbone;
  final BuiltInApp app;

  /// Host tool registry, threaded from `mount` so UI actions can reach
  /// Ops's MCP tools via [opsToolServerProvider] / [opsCallTool].
  final BuiltinToolRegistry server;
  final Map<String, Object?> inheritedSettings;
  final String overridesFile;

  @override
  State<OpsShell> createState() => _OpsShellState();
}

class _OpsShellState extends State<OpsShell> {
  Future<OpsBootResult>? _bootFuture;

  /// Currently-bound project root for this Ops tab. Null until the
  /// host's chrome lifecycle (`newProjectInActive` / `openProjectInActive`)
  /// hands a directory over. Standard wiring — mirrors App Builder /
  /// Scene Builder: data lives inside the project, not in a global
  /// seed root.
  String? _currentProject;

  // Single per-PROJECT chat coordinator — the manager is scoped by the ops
  // project path alone (`ops.manager.<opsProject>`) and the chat routes to it
  // via `chatManagerOverride`, exactly like App Builder / Scene Builder. The
  // coordinator is the Studio-level command channel for the whole project — the
  // one human interface — NOT a member of any workspace's org chart and NOT
  // per-workspace. Workspaces are data-isolation lenses that all run
  // concurrently (the kernel agent runtime is workspace-complete via
  // `loadAll`), so the active workspace still changes through the workspace
  // registry (driven by `workspace_switch` / `workspace_create`, decoupled from
  // this widget) — we subscribe to its `changes` stream — but a switch only
  // refreshes the chat roster (the now-viewed department's agents); it never
  // re-scopes the coordinator or re-keys its single conversation. Department
  // isolation stays at the data layer (facts / members / skills per workspace).
  // `_scopedManagerId` is cached so tab re-activation re-applies it without
  // re-deriving from the volatile `activeChatAgentId`.
  StreamSubscription<void>? _wsChangesSub;
  StreamSubscription<void>? _memberChangesSub;
  String? _scopedManagerId;

  /// Ops's base chat manager id — the seed ships `ops.manager` as the Ops
  /// project manager (standard `.manager` naming, parity with App Builder /
  /// Scene Builder / Studio managers). Used as the base for the per-project
  /// coordinator clone. Referenced directly (not read from the volatile
  /// `activeChatAgentId`, the host's deferred-synced display value) so the
  /// scoped clone inherits `ops.manager`'s persona / tool scope.
  static const String _opsManagerId = 'ops.manager';

  // The chrome lifecycle slots (`newProjectInActive` /
  // `openProjectInActive` / `closeProjectInActive`) belong to whichever
  // built-in tab is currently active — they are wired in
  // [didChangeDependencies] when `WorkspaceTabActiveScope.isActiveOf`
  // flips true and released only-if-mine when it flips false. Wiring
  // in `initState` (the way an earlier draft did it) would let every
  // built-in's mount race for the slot and the last mount would win
  // regardless of which tab the user is actually viewing — the
  // IndexedStack mounts every tab eagerly to keep state alive.

  /// Per the built-in contract — built-in publishes its 4-axis hooks
  /// to the registry so host wiring (`_syncHeaderActions` reading
  /// `lifecycleState` through `lifecycleStateProvider`) reaches the
  /// same providers regardless of mount file location.
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
          ..domainSettingsProvider = _provideDomainSettings;
    BuiltInAppRegistry.instance.mount(widget.bundlePath, widget.app, _ctx);
    // Push the initial lifecycle snapshot immediately so the chrome's
    // ProjectHeader reads `projectName: 'No project open'` from the
    // start instead of falling back to the (potentially stale)
    // `bundleName` derived from the host tab's `currentProject`.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _publishLifecycleState();
        // Restore the bound project on (re)mount so closing a tab and
        // reopening returns to the last project instead of the welcome panel.
        _restoreLastProject();
      }
    });
  }

  /// On (re)mount, restore the bound project — App Builder / Scene Builder
  /// parity:
  ///   1. `bundlePath` is itself an Ops project (host tab restore) → bind it.
  ///   2. else reopen the sidecar `lastProjectPath` when it is still a valid
  ///      Ops project on disk (manual tab close + reopen).
  ///   3. else leave the welcome panel.
  /// Without this, a freshly mounted [OpsShell] always starts unbound (Ops
  /// only bound via the welcome buttons / MCP), so reopening a tab dropped the
  /// previously open project. Ops's last-project pointer is stored in the
  /// per-host host config store as a value (see [_hostSettingsPath] +
  /// `VibeSettings.domainLastProject`), so debug and release never share a
  /// binding and nothing is hardcoded to a `makemind_ops` folder.
  /// The **per-host host config store** (`~/.config/<hostToolId>/settings.json`).
  /// Ops's last-opened project is kept HERE as a VALUE — not in a hardcoded
  /// `makemind_ops` folder. The host config dir is already separated per host
  /// (`vibe_studio_debug` vs `vibe_studio`), so the two instances keep
  /// independent project bindings; the project path is configurable data in
  /// the store, keyed by the built-in's own id ([VibeSettings.domainLastProject]).
  String get _hostSettingsPath =>
      VibeSettings.defaultPath(widget.backbone.toolId);

  Future<void> _restoreLastProject() async {
    if (!mounted || _currentProject != null) return;
    if (isOpsProjectDir(widget.bundlePath)) {
      unawaited(_bindProject(widget.bundlePath));
      return;
    }
    try {
      final s = await VibeSettings.load(_hostSettingsPath);
      final last = s.domainLastProject[widget.app.id];
      // Deliberately NO fallback to the pre-per-host shared config
      // (`~/.config/<appId>/settings.json` → `lastProjectPath`): that file is
      // host-agnostic and, for `makemind_ops`, points at the LIVE ops project.
      // Reading it here would let the DEBUG host reopen live — the exact
      // cross-host contamination the per-host `domainLastProject` store exists
      // to prevent. Upgrading hosts re-open their project once (which writes
      // the per-host key via [_bindProject]); we never auto-inherit the shared
      // legacy binding.
      // Re-check `_currentProject`: an MCP `project.open` / `project.new` may
      // have bound a project while the async load was in flight.
      if (mounted &&
          _currentProject == null &&
          last != null &&
          last.isNotEmpty &&
          isOpsProjectDir(last)) {
        OpsLog.info('restore', 'reopening last project $last');
        unawaited(_bindProject(last));
      }
    } catch (e) {
      OpsLog.warn('restore', 'failed: $e');
    }
  }

  /// `domainSettingsProvider` — feeds the host Studio
  /// Settings dialog (gear icon on the chrome) so Ops's configuration
  /// lives in the same place as App Builder / Scene Builder settings.
  /// The body is `SettingsPage` (Ops's existing form) wrapped in a
  /// `ProviderScope` that re-injects the booted KnowledgeInit /
  /// OpsConfig overrides — the form reads `knowledgeInitProvider` and
  /// `opsThemeModeProvider`, so it can't render in the host dialog's
  /// scope without these overrides.
  DomainSettingsPanel? _provideDomainSettings() {
    final boot = _bootFuture;
    if (boot == null) return null;
    return DomainSettingsPanel(
      name: 'Ops',
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
                    'Parent directory where new Ops projects land. '
                    'Inherits from Studio Settings; a per-domain override '
                    'may be set here.',
              },
            ], widget.inheritedSettings),
            overridesFile: widget.overridesFile,
          ),
        ),
        SettingsSection(
          label: 'Configuration',
          body: FutureBuilder<OpsBootResult>(
            future: boot,
            builder: (ctx, snap) {
              if (!snap.hasData) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              }
              final result = snap.data!;
              return ProviderScope(
                overrides: <Override>[
                  opsConfigProvider.overrideWith((ref) => result.cfg),
                  opsThemeModeProvider.overrideWith(
                    (ref) => _toThemeMode(result.cfg.themeMode),
                  ),
                  knowledgeInitProvider.overrideWithValue(result.init),
                  opsToolServerProvider.overrideWithValue(widget.server),
                  if (result.init.observability != null)
                    observabilityProvider.overrideWithValue(
                      result.init.observability!,
                    ),
                ],
                child: const SettingsPage(),
              );
            },
          ),
        ),
      ],
    );
  }

  /// `lifecycleBindingsProvider` — maps the chrome
  /// `ProjectHeader` system buttons (X / New / Open / …) and any
  /// `dispatchLifecycleSlot` call onto Ops handlers. Slots Ops does
  /// not own (save / saveAs / revert / build / undo / etc.) stay
  /// unbound — the chrome paints them disabled, matching the
  /// auto-save semantics of Ops registries (every write through
  /// member_/task_/etc. tools is immediate, no Save concept).
  Map<String, LifecycleHandler>? _provideLifecycleBindings() {
    return <String, LifecycleHandler>{
      LifecycleSlots.projectNew: (ctx) => _executeNew(ctx),
      LifecycleSlots.projectOpen: (ctx) => _executeOpen(ctx),
      LifecycleSlots.projectClose: (_) async {
        _closeProject();
      },
    };
  }

  /// App Builder pattern (`_onNewProject` in `feat/shell_layout.dart`)
  /// — built-in opens the shared `promptForNewProject` dialog itself,
  /// reads the user's `(name, parent)`, then scaffolds directly. The
  /// dialog widget lives in base (`base/settings/settings_dialog.dart`);
  /// the built-in is just the caller. No round-trip through host
  /// `chromeBridge.newProjectDialog` slot (host owns the chrome
  /// surface; the built-in owns the project lifecycle).
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
    final initial = _readWorkspaceDir();
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Open Ops project folder',
      initialDirectory: initial,
    );
    if (picked == null) return;
    await _openProject(picked);
  }

  /// Host's `workspaceDir` setting forwarded via `inheritedSettings`
  /// — used as the `New project` dialog's default parent.
  String? _readWorkspaceDir() {
    // Domain override (Ops Domain Settings → Workspace folder) wins over
    // the inherited studio-wide value — per-domain project locations.
    return effectiveWorkspaceDir(
      inherited: widget.inheritedSettings,
      overridesFile: widget.overridesFile,
    );
  }

  /// Read by host `_syncHeaderActions` and pushed into
  /// `chromeBridge.lifecycleState` so the chrome's ProjectHeader reads
  /// `life.projectName`. Matches App Builder's no-project label
  /// (`VibeShell._projectName` → "No project open") so the chrome
  /// surface stays consistent across built-ins.
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
      widget.chromeBridge.newProjectInActive = _newProject;
      widget.chromeBridge.openProjectInActive = _openProject;
      widget.chromeBridge.closeProjectInActive = _closeProject;
      // Re-apply the cached per-workspace override on tab re-activation;
      // release-if-mine happens in the inactive branch.
      if (_scopedManagerId != null) {
        widget.chromeBridge.chatManagerOverride.value = _scopedManagerId;
      }
      // Republish this tab's agent roster on re-activation (a sibling tab may
      // have cleared it).
      _publishChatRoster();
      // Push the lifecycle snapshot when this tab becomes active so the
      // chrome's ProjectHeader picks up the current `projectName` (or
      // "No project open") without waiting for a `_bindProject` /
      // `_closeProject` to fire. Needed because the host's
      // `lifecycleStateProvider` walk only re-runs when the active
      // built-in flips — without this republish a re-launch into a
      // sibling tab can show a stale projectName.
      //
      // Deferred to post-frame: didChangeDependencies can run while the
      // parent (WorkspaceTabActiveScope) is still building, and publishing
      // synchronously sets a ValueNotifier whose ValueListenableBuilder
      // would then markNeedsBuild mid-build (setState-during-build assert).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _publishLifecycleState();
      });
    } else {
      _releaseSlotsIfMine();
    }
  }

  @override
  void dispose() {
    BuiltInAppRegistry.instance.unmount(widget.bundlePath);
    // ignore: unawaited_futures
    _wsChangesSub?.cancel();
    // ignore: unawaited_futures
    _memberChangesSub?.cancel();
    _releaseSlotsIfMine();
    // Tab CLOSE = full backend shutdown (design contract:
    // "tab close = unregisterAll +
    // registry.remove"). This State disposes ONLY on tab removal — the
    // host renders tab bodies in a keyed IndexedStack, so a tab SWITCH
    // keeps the mount alive and the backend keeps running in the
    // background ("background active = all"). resetBootCache
    // disposes the live KnowledgeInit → every workspace
    // BundleActivation.unregisterAll. Guard on this tab owning the live
    // boot so closing a stale Ops tab (its project isn't the booted one,
    // or the project was already closed via the header button) never
    // tears down another tab's — or an already-disposed — backend.
    final teardown = OpsBuiltInApp.shouldTeardownOnClose(_currentProject);
    OpsLog.info(
      'lifecycle',
      'ops tab dispose: currentProject=$_currentProject '
          'bootedProject=${OpsBuiltInApp.bootedProject} teardown=$teardown',
    );
    if (teardown) {
      OpsBuiltInApp.resetBootCache();
    }
    super.dispose();
  }

  /// True when this Ops mount is the currently-active built-in tab.
  /// IndexedStack keeps every tab body alive, so postFrame callbacks
  /// from sibling Ops mounts (or this one before it becomes active)
  /// would otherwise clobber the active tab's lifecycle snapshot.
  bool get _isActiveTab =>
      BuiltInAppRegistry.instance.activeContext?.bundlePath ==
      widget.bundlePath;

  /// Push a fresh lifecycle snapshot into the chrome bridge. Called
  /// from `_bindProject` / `_closeProject` after `_currentProject`
  /// flips so the host's ProjectHeader picks up the new `projectName`
  /// without waiting for a tab-activation re-sync. Skipped when this
  /// mount isn't the active tab — `_setActiveContext` (host) repaints
  /// the bridge via the resolver when we become active again.
  void _publishLifecycleState() {
    if (!_isActiveTab) return;
    widget.chromeBridge.lifecycleState.value = _provideLifecycleState();
  }

  /// Clear each lifecycle slot only when this state's own handler is
  /// still installed — a sibling built-in mount may have taken the
  /// slot since we wired it, and we don't want to strand that tab.
  void _releaseSlotsIfMine() {
    if (widget.chromeBridge.newProjectInActive == _newProject) {
      widget.chromeBridge.newProjectInActive = null;
    }
    if (widget.chromeBridge.openProjectInActive == _openProject) {
      widget.chromeBridge.openProjectInActive = null;
    }
    if (widget.chromeBridge.closeProjectInActive == _closeProject) {
      widget.chromeBridge.closeProjectInActive = null;
    }
    // Release the shared chat override only when it's still ours — a sibling
    // tab's active override must not be clobbered.
    if (_scopedManagerId != null &&
        widget.chromeBridge.chatManagerOverride.value == _scopedManagerId) {
      widget.chromeBridge.chatManagerOverride.value = null;
    }
    // Drop the agent roster so a sibling tab's chat chip doesn't surface this
    // Ops project's agents. The next active built-in republishes its own.
    widget.chromeBridge.chatAgentRoster.value =
        const <({String id, String displayName, String? modelId})>[];
  }

  Future<Map<String, dynamic>> _newProject({
    required String name,
    required String parent,
  }) async {
    final dir = p.join(parent, name);
    final d = Directory(dir);
    if (await d.exists()) {
      return <String, dynamic>{
        'ok': false,
        'error': 'A project already exists at $dir',
      };
    }
    try {
      await d.create(recursive: true);
      // App Builder pattern — write the project skeleton (marker +
      // empty sub-dirs) before binding so the first `openProjectInActive`
      // / re-open call recognises the directory as an Ops project.
      await applyOpsProjectSeed(dir, name);
    } catch (e) {
      return <String, dynamic>{'ok': false, 'error': '$e'};
    }
    return _bindProject(dir);
  }

  Future<Map<String, dynamic>> _openProject(String path) async {
    if (path.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': 'path required'};
    }
    if (!await Directory(path).exists()) {
      return <String, dynamic>{
        'ok': false,
        'error': 'directory does not exist: $path',
      };
    }
    // Require the Ops marker — refuses to bind an arbitrary directory
    // that wasn't created through `_newProject` (or migrated by hand).
    // The user gets a clear error instead of a half-booted Ops state.
    if (!isOpsProjectDir(path)) {
      return <String, dynamic>{
        'ok': false,
        'error':
            'Not an Ops project (missing project.opsproj marker): '
            '$path',
      };
    }
    return _bindProject(path);
  }

  Map<String, dynamic> _closeProject() {
    if (!mounted) return <String, dynamic>{'ok': true, 'closed': false};
    setState(() {
      _currentProject = null;
      _bootFuture = null;
    });
    // Drop the static boot cache too so the next bind (same path or
    // different) re-runs KnowledgeInit + BundleActivation against the
    // current on-disk manifest.
    OpsBuiltInApp.resetBootCache();
    _publishLifecycleState();
    // Drop the scoped coordinator override + roster: the project is gone, so a
    // late coordinator wake must NOT still resolve `chatManagerOverride` to this
    // closed project's `ops.manager.<project>` (which would route the report to
    // the now-bare welcome-state chat key). `_releaseSlotsIfMine` does this on
    // tab deactivate; project close (staying on the same tab) needs it too.
    if (_scopedManagerId != null &&
        widget.chromeBridge.chatManagerOverride.value == _scopedManagerId) {
      widget.chromeBridge.chatManagerOverride.value = null;
    }
    _scopedManagerId = null;
    widget.chromeBridge.chatAgentRoster.value =
        const <({String id, String displayName, String? modelId})>[];
    // Return the host tab + chat to the no-project (tab-level) state.
    widget.chromeBridge.setActiveTabProject?.call(null);
    return <String, dynamic>{'ok': true, 'closed': true};
  }

  Future<Map<String, dynamic>> _bindProject(String dir) async {
    // ensureBoot runs unconditionally — even when the shell widget is
    // currently unmounted between the MCP `project/new` request and
    // this closure firing — so downstream MCP tools resolving through
    // `OpsBuiltInApp.currentBoot` see the live project root instead
    // of the stale null-project init.
    final future = OpsBuiltInApp.ensureBoot(
      backbone: widget.backbone,
      currentProject: dir,
    );
    if (mounted) {
      setState(() {
        _currentProject = dir;
        _bootFuture = future;
      });
      _publishLifecycleState();
    }
    // Remember this project in Ops's sidecar settings so a tab close + reopen
    // restores it ([_restoreLastProject]). App Builder / Scene Builder parity.
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
    // Sync the host tab model + re-key the chat to this project (the host's
    // manifest-domain open flow does this for free; built-ins that own their
    // own bind must call it explicitly, else the previous project's chat
    // lingers).
    widget.chromeBridge.setActiveTabProject?.call(dir);
    // Subscribe to the booted project's workspace registry so the chat
    // manager override tracks the active workspace (the operational unit).
    // ignore: unawaited_futures
    future.then((result) {
      if (!mounted) return;
      // Subscribe to the CANONICAL bound registry the workspace tools mutate
      // (`OpsBuiltInApp.liveInit`, downgrade-guarded — same instance the
      // `init` getter resolves), NOT this future's `result.init`: a later
      // no-project `ensureBoot` (mount / registerHostTools) can resolve a
      // DIFFERENT, unbound instance, so subscribing to `result.init` would
      // miss every tool-driven `workspace_switch` (the active workspace would
      // appear to never change → chat stuck on the first workspace + leak).
      final reg = (OpsBuiltInApp.liveInit ?? result.init).registries.workspace;
      _wsChangesSub?.cancel();
      _wsChangesSub = reg.changes.listen((_) {
        // Workspace switch = data-lens change only. The coordinator + its
        // single per-project conversation stay put; just refresh the roster so
        // the chat chip lists the now-viewed department's agents.
        if (mounted) _publishChatRoster();
      });
      // Refresh the chat agent roster whenever this project's members change
      // (agent create / update / delete) so a freshly created agent becomes
      // chattable without a workspace re-switch. Same canonical bound registry
      // rationale as `_wsChangesSub`.
      final memberReg =
          (OpsBuiltInApp.liveInit ?? result.init).registries.member;
      _memberChangesSub?.cancel();
      _memberChangesSub = memberReg.changes.listen((_) {
        if (mounted) _publishChatRoster();
      });
      _applyOpsScopedManager();
    });
    // Await the boot before returning "ok". `ensureBoot` publishes the
    // project-bound `_liveInit` only when `_doBoot` COMPLETES; returning
    // early (the old sync bind) let an immediately-following ops tool
    // (`workspace_create`, `member_*`, `task_run`, …) resolve the STALE
    // `_liveInit` and bind to the PREVIOUS project — a race reproduced live:
    // `project.info` (tab currentProject) flipped instantly while the
    // workspace registry lagged one bind behind. Blocking here makes
    // `studio.project.new` / `studio.project.open` return only once the new
    // project is actually the bound one.
    try {
      await future;
    } catch (_) {
      /* boot failure surfaces through the tools that resolve `_liveInit`;
         the bind still returns ok so the tab reflects the attempted open */
    }
    return <String, dynamic>{
      'ok': true,
      'projectPath': dir,
      'projectName': p.basename(dir),
    };
  }

  /// Ensure the single per-PROJECT coordinator manager
  /// (`ops.manager.<opsProject>`) exists and route the chat to it via
  /// `chatManagerOverride` — exactly like App Builder / Scene Builder
  /// (`_applyScopedManager`, scoped by project path). The coordinator is the
  /// Studio-level command channel for the WHOLE ops project — the single human
  /// interface for all work instructions — NOT a member of any workspace's org
  /// chart and NOT per-workspace. Workspaces are data-isolation lenses that all
  /// run concurrently (the kernel agent runtime is workspace-complete via
  /// `loadAll`), so switching one changes the VIEW, not the coordinator or its
  /// single conversation. The chat + `fs.*` anchor stays the ops project (set
  /// once at bind — [_bindProject]'s `setActiveTabProject(dir)`), so there is
  /// ONE coordinator conversation per project. Caches the qualified id for tab
  /// re-activation ([didChangeDependencies]); only writes the shared bridge
  /// override while this is the active tab. Best-effort.
  Future<void> _applyOpsScopedManager() async {
    final opsProject = _currentProject;
    if (opsProject == null || opsProject.isEmpty) return;
    try {
      // Scope by the ops PROJECT path (same-name-≠-same-thing → full path).
      final qualified = await AgentHost.shared?.ensureScopedManager(
        _opsManagerId,
        opsProject,
      );
      if (qualified == null || !mounted) return;
      _scopedManagerId = qualified;
      if (_isActiveTab) {
        widget.chromeBridge.chatManagerOverride.value = qualified;
        // The active workspace's agents are still listed on the chat chip for
        // direct conversation (the coordinator stays the default selection).
        _publishChatRoster();
      }
    } catch (_) {
      /* best-effort */
    }
  }

  /// Push the active workspace's operational agents to the chat panel roster
  /// (`chromeBridge.chatAgentRoster`) so the chat chip lists them and the user
  /// can converse directly — not only with the manager. Entry `id` =
  /// `member.agentId` (project + workspace scoped) so the per-agent send routes
  /// to the right agent and its conversation stays per-unit. Best-effort; only
  /// writes while this is the active tab. Cleared on deactivate.
  void _publishChatRoster() {
    if (!_isActiveTab) return;
    final init = OpsBuiltInApp.liveInit;
    final wsId = init?.registries.workspace.activeId;
    if (init == null || wsId == null || wsId.isEmpty) {
      widget.chromeBridge.chatAgentRoster.value =
          const <({String id, String displayName, String? modelId})>[];
      return;
    }
    init.registries.member
        .listForWorkspace(wsId)
        .then((members) {
          if (!mounted || !_isActiveTab) return;
          widget
              .chromeBridge
              .chatAgentRoster
              .value = <({String id, String displayName, String? modelId})>[
            for (final m in members)
              if (m is AgentMember)
                (
                  id: m.agentId,
                  displayName: m.displayName,
                  modelId: m.model?.model,
                ),
          ];
        })
        .catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final c = ui.VbuTokens.colorOf(context);
    // No project bound — render the shared StudioWelcomePanel
    // full-width (no sidebar). Members / Tasks / Skills / Settings /
    // ... are project-scoped surfaces; showing them before a project
    // is bound would suggest data exists when it doesn't. Same pattern
    // App Builder / Scene Builder follow on their first run.
    if (_currentProject == null || _bootFuture == null) {
      return Container(
        color: c.bg,
        child: StudioWelcomePanel(
          title: 'AppPlayer Ops',
          recents: const <String>[],
          // Welcome buttons fire the built-in's own lifecycle handlers so
          // `_newProject` / `_openProject` run the seed (manifest +
          // knowledge sub-dirs) and re-bind. The host's generic
          // `newProjectDialog` slot only creates the directory and would
          // skip the seed, leaving the folder unrecognisable on reopen.
          onNew: () => _executeNew(context),
          onOpen: () => _executeOpen(context),
          onPickRecent: (_) {
            /* no recents yet */
          },
        ),
      );
    }
    return Container(color: c.bg, child: _renderBody());
  }

  Widget _renderBody() {
    // No-project case handled in [build] (full-width welcome, no
    // sidebar); this body is only reached when a project is bound.
    return FutureBuilder<OpsBootResult>(
      future: _bootFuture,
      builder: (ctx, snap) {
        if (snap.hasError) {
          return _OpsConfigError(error: snap.error!);
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        final result = snap.data!;
        return ProviderScope(
          overrides: <Override>[
            opsConfigProvider.overrideWith((ref) => result.cfg),
            opsThemeModeProvider.overrideWith(
              (ref) => _toThemeMode(result.cfg.themeMode),
            ),
            knowledgeInitProvider.overrideWithValue(result.init),
            opsToolServerProvider.overrideWithValue(widget.server),
            if (result.init.observability != null)
              observabilityProvider.overrideWithValue(
                result.init.observability!,
              ),
          ],
          // `UiDebugAttacher` captures the scope's `ref` for the
          // out-of-tree `UiDebugBridge` so the `ui_*` MCP tools
          // (ui_capture / ui_navigate / ui_state / ui_page_state /
          // ui_open_agent_dialog) can read & write provider state.
          // `UiDialogListener` watches `dialogRequestProvider` (set by
          // ui_open_agent_dialog) and opens the agent detail dialog from
          // inside the booted scope — without it the tool only sets state
          // and no dialog surfaces.
          child: const UiDebugAttacher(
            child: UiDialogListener(child: _OpsShellBody()),
          ),
        );
      },
    );
  }

  String _routeName(OpsRoute r) {
    switch (r) {
      case OpsRoute.about:
        return 'about';
      case OpsRoute.home:
        return 'home';
      case OpsRoute.workspaces:
        return 'workspaces';
      case OpsRoute.members:
        return 'members';
      case OpsRoute.skills:
        return 'skills';
      case OpsRoute.profiles:
        return 'profiles';
      case OpsRoute.philosophies:
        return 'philosophies';
      case OpsRoute.bundles:
        return 'bundles';
      case OpsRoute.resources:
        return 'resources';
      case OpsRoute.files:
        return 'files';
      case OpsRoute.inbox:
        return 'inbox';
      case OpsRoute.tasks:
        return 'tasks';
      case OpsRoute.processes:
        return 'processes';
      case OpsRoute.knowledge:
        return 'knowledge';
      case OpsRoute.observability:
        return 'observability';
      case OpsRoute.organization:
        return 'organization';
      case OpsRoute.channels:
        return 'channels';
      case OpsRoute.audit:
        return 'audit';
    }
  }

  OpsRoute _routeFromName(String name) {
    switch (name) {
      case 'about':
        return OpsRoute.about;
      case 'workspaces':
        return OpsRoute.workspaces;
      case 'members':
        return OpsRoute.members;
      case 'skills':
        return OpsRoute.skills;
      case 'profiles':
        return OpsRoute.profiles;
      case 'philosophies':
        return OpsRoute.philosophies;
      case 'bundles':
        return OpsRoute.bundles;
      case 'tasks':
        return OpsRoute.tasks;
      case 'processes':
        return OpsRoute.processes;
      case 'knowledge':
        return OpsRoute.knowledge;
      case 'observability':
        return OpsRoute.observability;
      case 'audit':
        return OpsRoute.audit;
      case 'home':
      default:
        return OpsRoute.home;
    }
  }

  ThemeMode _toThemeMode(String raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}

class _OpsConfigError extends StatelessWidget {
  const _OpsConfigError({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    final c = ui.VbuTokens.colorOf(context);
    return Container(
      color: c.bg,
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'OpsConfig load failed:\n$error',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: ui.VbuTokens.fontMono,
            fontSize: 11,
            color: c.coral,
          ),
        ),
      ),
    );
  }
}

/// Body rendered once a project is bound — sidebar + active page.
/// Lives inside the per-project `ProviderScope` so both the sidebar's
/// `shellRouteProvider` watch and the page widgets see the project
/// overrides (opsConfig / knowledgeInit / etc.).
class _OpsShellBody extends ConsumerWidget {
  const _OpsShellBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ui.VbuTokens.colorOf(context);
    final routeName = ref.watch(shellRouteProvider);
    final active = _routeFromName(routeName);
    // `UiDebugBridge.captureKey` anchors the `ui_capture` MCP tool's
    // RepaintBoundary. Wrapping the Ops shell here gives external
    // LLMs / diora's self-verification path a working screenshot
    // surface for every Ops page (Members / Tasks / Skills / …)
    // without modifying the host's MaterialApp.builder.
    return RepaintBoundary(
      key: UiDebugBridge.captureKey,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _OpsSidebar(
            active: active,
            onSelect:
                (r) =>
                    ref.read(shellRouteProvider.notifier).state = _routeName(r),
          ),
          Container(width: 1, color: c.borderSubtle),
          Expanded(child: _routeBodyFor(routeName)),
        ],
      ),
    );
  }

  Widget _routeBodyFor(String name) {
    switch (name) {
      case 'about':
        return const AboutPage();
      case 'workspaces':
        return const WorkspaceListPane();
      case 'members':
        return const MemberPage();
      case 'skills':
        return const SkillsPage();
      case 'profiles':
        return const ProfilesPage();
      case 'philosophies':
        return const PhilosophiesPage();
      case 'bundles':
        return const BundlesPage();
      case 'resources':
        return const ResourcesPage();
      case 'files':
        return const FilesPage();
      case 'inbox':
        return const InboxPage();
      case 'tasks':
        return const TaskPage();
      case 'processes':
        return const ProcessPage();
      case 'knowledge':
        return const KnowledgePage();
      case 'observability':
        return const ActivityFeedPage();
      case 'organization':
        return const OrgChartPage();
      case 'channels':
        return const ChannelsPage();
      case 'audit':
        return const AuditPlaceholderPage();
      case 'home':
      default:
        return const WorkspaceHomePage();
    }
  }

  String _routeName(OpsRoute r) => r.name;

  OpsRoute _routeFromName(String name) {
    for (final r in OpsRoute.values) {
      if (r.name == name) return r;
    }
    return OpsRoute.home;
  }
}

class _OpsSidebar extends StatelessWidget {
  const _OpsSidebar({required this.active, required this.onSelect});
  final OpsRoute active;
  final ValueChanged<OpsRoute> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = ui.VbuTokens.colorOf(context);
    return SizedBox(
      width: 200,
      child: Container(
        color: c.surface,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: ui.VbuTokens.space2),
          children: <Widget>[
            for (final group in OpsGroup.values) ...<Widget>[
              _OpsSidebarGroupHeader(label: group.label),
              for (final r in OpsRoute.values.where((r) => r.group == group))
                inspectTag(
                  type: 'ops_sidebar_item',
                  id: r.id,
                  label: r.label,
                  child: _OpsSidebarTile(
                    route: r,
                    selected: r == active,
                    onTap: () => onSelect(r),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OpsSidebarGroupHeader extends StatelessWidget {
  const _OpsSidebarGroupHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = ui.VbuTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ui.VbuTokens.space4,
        ui.VbuTokens.space3,
        ui.VbuTokens.space4,
        ui.VbuTokens.space1,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
          color: c.textMuted,
        ),
      ),
    );
  }
}

class _OpsSidebarTile extends StatefulWidget {
  const _OpsSidebarTile({
    required this.route,
    required this.selected,
    required this.onTap,
  });
  final OpsRoute route;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_OpsSidebarTile> createState() => _OpsSidebarTileState();
}

class _OpsSidebarTileState extends State<_OpsSidebarTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = ui.VbuTokens.colorOf(context);
    final fg =
        widget.selected ? c.mint : (_hovered ? c.textPrimary : c.textSecondary);
    final bg =
        widget.selected
            ? c.surface3
            : (_hovered ? c.surface2 : Colors.transparent);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          color: bg,
          padding: const EdgeInsets.symmetric(
            horizontal: ui.VbuTokens.space3,
            vertical: ui.VbuTokens.space2,
          ),
          child: Row(
            children: <Widget>[
              Icon(widget.route.icon, size: 16, color: fg),
              const SizedBox(width: ui.VbuTokens.space2),
              Text(
                widget.route.label,
                style: TextStyle(
                  fontFamily: ui.VbuTokens.fontSans,
                  fontSize: 12,
                  fontWeight:
                      widget.selected ? FontWeight.w600 : FontWeight.w500,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
