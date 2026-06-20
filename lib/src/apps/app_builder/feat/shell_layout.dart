import 'dart:async';
import 'dart:math' as math;
import 'package:logging/logging.dart';
import 'package:appplayer_studio/base.dart'
    show
        AgentHost,
        promptForNewProject,
        promptForWorkspacePath,
        VibeChatController,
        BundleAgentsView,
        BundleKnowledgeView,
        BundleManifestView,
        BundleToolsKind,
        BundleToolsView,
        ChromeBridge,
        WorkspaceTabActiveScope,
        inspectTag,
        packageOverridesFile;
import 'dart:convert' show JsonEncoder, jsonDecode, jsonEncode, utf8;
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:crypto/crypto.dart' show sha256;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/rendering.dart'
    show
        RenderBox,
        RenderDecoratedBox,
        RenderMetaData,
        RenderObject,
        RenderPadding,
        RenderParagraph,
        RenderRepaintBoundary;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mcp_bundle/mcp_bundle.dart'
    hide ValidationIssue, ValidationSeverity;
import 'package:path/path.dart' as p;

import '../theme/tokens.dart';
import '../conv/dart_converter.dart';
import '../conv/self_ui_converter.dart';
import '../core/layer_projection.dart';
import '../core/patch_pipeline.dart';
import '../core/spec_validator.dart';
import '../core/types.dart';
import '../theme/app_theme.dart';
import '../core/vibe_project.dart';
import 'widget_tree.dart';
import '../core/workspace_canonical.dart';
import '../infra/project_seed.dart' show applyProjectSeed;
import '../infra/vibe_project_prefs.dart' show BuildConfig;
import '../infra/vibe_server_bridge.dart';
import '../infra/vibe_settings.dart';
import '../infra/workspace_fs_port.dart';
import 'build_dialog.dart';
import 'build_tools.dart';
import 'file_tools.dart';
import 'asset_gallery.dart';
import 'assets_dialog.dart';
import 'channel_diff_dialog.dart';
import 'clean_dialog.dart';
import 'history_dialog.dart';
import 'export_dialog.dart';
import 'import_dialog.dart';
import 'inspector_panel.dart';
import 'inspector_session.dart';
import 'spec_catalog.dart' as sc;
import 'instance_strip.dart';
import 'overview_strip.dart';
import 'preview_panel.dart';
import 'properties_panel.dart';
import 'widget_schema_catalog.dart';
import 'vibe_llm.dart';

/// Top-level shell. Per `handoff/HANDOFF.md`:
///
///   ┌ Titlebar (28) ──────────────────────────────────────┐
///   │ Chat (280) │ [Strip + Preview]  │ Properties (320) │
///   └ Statusbar (24) ─────────────────────────────────────┘
class VibeShell extends StatefulWidget {
  const VibeShell({
    super.key,
    required this.projection,
    required this.canonical,
    required this.pipeline,
    required this.chat,
    required this.settings,
    this.project,
    this.llm,
    this.bridge,
    this.transport = 'http',
    this.mcpPort,
    this.specVersion = sc.specVersion,
    this.selfUiFramework = SelfUiFramework.none,
    this.selfUiSimDir,
    this.studioChromeBridge,
    this.hostTabKey,
  });

  /// Chrome tab path that hosts this shell — propagated down to the
  /// preview's [DslWorkspaceView] as its `gateTabKey` so the embedded
  /// DSL runtime only calls `buildUI()` when this tab is the chrome's
  /// active tab. Without it, two `application` shells alive at the
  /// same time both grab the process-singleton navigatorKey and the
  /// previously-mounted shell's content lingers.
  final String? hostTabKey;

  /// Host base `ChromeBridge` (when running inside Studio's shell as a
  /// built-in app). Bundle-mode cards (Tools, Agents) plumb this into
  /// host base authoring views — null when running standalone, in
  /// which case those cards render in read-only mode.
  final dynamic studioChromeBridge;

  final LayerProjection projection;
  final WorkspaceCanonical canonical;
  final PatchPipeline pipeline;
  final VibeChatController chat;

  /// The single VibeSettings instance the parent (built-in mount or
  /// standalone main) owns. The shell uses this for every
  /// settings.workspaceDir lookup so the picker / VibeProject paths
  /// see exactly the value the parent overrode (built-in mount sets
  /// inheritedSettings.workspaceDir here). Removed the previous
  /// in-shell `VibeSettings.load(VibeSettings.defaultPath('app_builder_vibe'))` so there's a single source of truth.
  final VibeSettings settings;

  /// The opened `.apbproj` project. Drives the project header (New /
  /// Open / Save / Save As / Revert / Import / Export). Tests that
  /// drive only the bundle UI may omit it.
  final VibeProject? project;

  /// Optional LLM adapter — when provided, the shell pushes any saved
  /// Settings update into it so a freshly-typed API key takes effect on
  /// the next chat send without restarting the app. Tests pass null.
  final VibeLlmAdapter? llm;

  /// MCP-side bridge. The shell registers every getter / callback in
  /// initState so MCP tool handlers can drive shell-owned state
  /// (project lifecycle, channel switch, focus / selection, settings)
  /// and read it back via `vibe_shell_state` / `vibe://*`. Tests omit
  /// it; production wires the same instance the [ServerBootstrap]
  /// reads from.
  final VibeServerBridge? bridge;
  final String transport;

  /// MCP server port — surfaced as a click-to-copy URL pill in the
  /// titlebar so the user can wire vibe into AppPlayer / Claude
  /// Desktop. Null hides the pill (test paths usually skip it).
  final int? mcpPort;

  final String specVersion;
  final SelfUiFramework selfUiFramework;
  final String? selfUiSimDir;

  @override
  State<VibeShell> createState() => VibeShellState();
}

class VibeShellState extends State<VibeShell> {
  // ---------------------------------------------------------------
  // Public hooks for host chrome
  // ---------------------------------------------------------------
  //
  // The shell no longer paints its own titlebar / project header /
  // statusbar — the surrounding host chrome (vibe_studio's
  // ProjectHeader trailing actions, ActivityBar, statusbar) owns
  // those slots. A built-in app wrapper grabs a `GlobalKey<VibeShellState>`
  // and registers `HeaderAction`s that delegate to the `execute*`
  // methods below so the same actions reach the same internal state
  // machine the standalone shell used to drive.
  //
  // `executeUndo / executeRedo / executeSave / ...` mirror the
  // standalone shell's chrome buttons one-to-one. State getters
  // (`canUndo`, `dirty`, `recentProjects`, ...) let the host paint
  // the equivalent disabled / emphasised states.
  Future<void> executeNew(BuildContext context) => _onNewProject(context);
  Future<void> executeOpen(BuildContext context) => _onOpenProject(context);
  Future<void> executeOpenRecent(String path) async => _onOpenRecent(path);
  Future<void> executeSave(BuildContext context) => _onSave(context);
  Future<void> executeSaveAs(BuildContext context) => _onSaveAs(context);
  Future<void> executeRevert(BuildContext context) => _onRevert(context);
  void executeUndo() => _onUndo();
  void executeRedo() => _onRedo();
  Future<void> executeRename(BuildContext context) => _onRename(context);
  void executeCloseProject() => _onCloseProject();
  Future<void> executeImportBundle(BuildContext context) =>
      _onImportBundle(context);
  Future<void> executeExportBundle(BuildContext context) =>
      _onExportBundle(context);
  Future<void> executeManageAssets(BuildContext context) =>
      _onManageAssets(context);
  Future<void> executeCompareChannels(BuildContext context) =>
      _onCompareChannels(context);
  Future<void> executeBuild(BuildContext context) => _onBuild(context);
  Future<void> executeCleanBuild(BuildContext context) =>
      _onCleanBuild(context);
  Future<void> executeBuildSettings(BuildContext context) =>
      _onBuildSettings(context);
  Future<void> executeHistory(BuildContext context) => _onHistory(context);
  Future<void> executeSettings(BuildContext context) => _onSettings(context);

  bool get canUndo => _canUndo;
  bool get canRedo => _canRedo;
  bool get dirty => _dirty;
  bool get hasProject => _project != null;
  String get projectName => _projectName;
  int get enabledChannelCount => _enabledChannelCount();
  List<String> get recentProjects =>
      List<String>.unmodifiable(_settings.recentProjects);
  bool get canCompareChannels => _enabledChannelCount() >= 2;

  /// Notifier the host listens to so it can refresh its
  /// `chromeBridge.headerActions` whenever shell-internal state that
  /// affects emphasis / enablement changes (dirty bit, undo / redo
  /// availability, recent projects, project open/close, channel count).
  /// Bumped by [_maybeEmitChromeStateChanged] after every build when a
  /// tracked value actually changes, so the host listens with a single
  /// `ValueListenableBuilder` and doesn't have to touch every internal
  /// `setState` call site.
  final ValueNotifier<int> chromeStateRevision = ValueNotifier<int>(0);

  bool? _lastCanUndo;
  bool? _lastCanRedo;
  bool? _lastDirty;
  String? _lastProjectName;
  bool? _lastHasProject;
  int? _lastEnabledChannels;
  int? _lastRecentLen;

  void _maybeEmitChromeStateChanged() {
    final hasProject = _project != null;
    final enabledCh = _enabledChannelCount();
    final recentLen = _settings.recentProjects.length;
    if (_lastCanUndo == _canUndo &&
        _lastCanRedo == _canRedo &&
        _lastDirty == _dirty &&
        _lastProjectName == _projectName &&
        _lastHasProject == hasProject &&
        _lastEnabledChannels == enabledCh &&
        _lastRecentLen == recentLen) {
      return;
    }
    _lastCanUndo = _canUndo;
    _lastCanRedo = _canRedo;
    _lastDirty = _dirty;
    _lastProjectName = _projectName;
    _lastHasProject = hasProject;
    _lastEnabledChannels = enabledCh;
    _lastRecentLen = recentLen;
    // Bump the revision in a post-frame callback so listeners that
    // call `setState` don't fire inside the current build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      chromeStateRevision.value = chromeStateRevision.value + 1;
    });
  }

  // ---------------------------------------------------------------
  // Internal state
  // ---------------------------------------------------------------
  /// Focused overview layer keyed by `(activeChannel, _centerMode)`.
  /// Each coordinate keeps its own focused card so toggling modes or
  /// switching channels does not bleed selection across.
  /// Missing coordinate → first-run defaults: UI = appStructure,
  /// Bundle = manifest, Debug = appStructure (debug strip is empty).
  Map<String, Map<CenterMode, LayerId>> _focusedByChannelMode =
      <String, Map<CenterMode, LayerId>>{};

  String get _focusKey => _project?.activeChannel ?? '';

  static LayerId _defaultFocusFor(CenterMode mode) =>
      mode == CenterMode.bundle ? LayerId.manifest : LayerId.appStructure;

  LayerId get _focused =>
      _focusedByChannelMode[_focusKey]?[_centerMode] ??
      _defaultFocusFor(_centerMode);

  set _focused(LayerId layer) {
    (_focusedByChannelMode[_focusKey] ??=
            <CenterMode, LayerId>{})[_centerMode] =
        layer;
  }

  static Map<String, Map<CenterMode, LayerId>> _cloneFocusMap(
    Map<String, Map<CenterMode, LayerId>> src,
  ) => <String, Map<CenterMode, LayerId>>{
    for (final entry in src.entries)
      entry.key: Map<CenterMode, LayerId>.from(entry.value),
  };

  int _previewEpoch = 0;
  CenterMode _centerMode = CenterMode.ui;
  late LayerProjection _projection;
  // Inspector session lifecycle is owned at the shell level so that
  // toggling editor↔debug doesn't tear down active connections /
  // the wire log every time. The InspectorPanel binds to this and
  // skips dispose; cleanup happens when the whole shell unmounts.
  final InspectorSessionManager _inspectorSessions = InspectorSessionManager();

  /// Project-scoped chat manager id (`<baseManager>.<projectId>`) for the
  /// currently open project — drives `studioChromeBridge.chatManagerOverride`
  /// so the manager conversation is isolated per project (FlowBrain keys
  /// `conv/<agentId>/turns` by id). Null until a project + base manager
  /// resolve. Set in [_applyScopedManager], re-applied / cleared by the
  /// active-tab lifecycle in [_bindStudioProjectSlotIfActive].
  String? _scopedManagerId;
  // RepaintBoundary key for the live preview surface. Owned by the
  // shell so the bridge handler for `vibe_preview_capture` can grab
  // a `RenderRepaintBoundary` without reaching into PreviewPanel's
  // private state.
  final GlobalKey _previewCaptureKey = GlobalKey();
  // Counterpart key for the Inspector's rendered surface — used by
  // `vibe_layout_snapshot` when the user is in debug mode so the
  // walker can pick up the connected app's UI tree instead of the
  // editor's. The MetaData wrapping is enabled in InspectorRender so
  // the same `RenderMetaData` walker handles either surface.
  final GlobalKey _inspectorCaptureKey = GlobalKey();
  String? _selectedPageId;
  String? _selectedComponentId;
  // Selection within the focused page or component's widget tree.
  // Reset when the page / component focus changes so stale paths from
  // one widget don't leak into another.
  WidgetPath? _selectedWidgetPath;
  VibeProject? _project;
  late VibeSettings _settings = widget.settings;
  bool _dirty = false;

  /// One-shot guard so the MCP bridge project slots are wired exactly once
  /// from the first `didChangeDependencies` (see that method).
  bool _bridgeWired = false;
  bool _canUndo = false;
  bool _canRedo = false;
  // Live spec validation pass — recomputed on every canonical change
  // so the statusbar lint badge reflects the current bundle.
  late final SpecValidator _validator = SpecValidatorImpl(
    specVersion: widget.specVersion,
  );
  List<ValidationIssue> _lint = const <ValidationIssue>[];

  /// Latest health summary (status / counts). Refreshed off the
  /// canonical change stream with a small debounce so the chat-side
  /// health bar can render a live status pill without burning CPU
  /// on every keystroke.
  Map<String, dynamic>? _health;
  Timer? _healthDebounce;

  /// Previous blocking count — used to detect transitions and emit a
  /// chat-side note when the bundle regresses (more issues than last
  /// snapshot) or fully clears. Skips noise from advisory drift.
  int? _prevBlocking;

  /// Bounded ring buffers backing the debug-surface MCP tools.
  /// Append-on-emit, drop-from-front when over [_kRingCap]. Newest
  /// entry is at the end of each list. Bridge getters reverse on
  /// read so callers see newest-first without mutating the buffer.
  static const int _kRingCap = 500;
  final List<Map<String, dynamic>> _runtimeErrors = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> _logRing = <Map<String, dynamic>>[];
  StreamSubscription<dynamic>? _logSub;
  // Live panel widths. Bounded between [_minPanelWidth] and a sane upper
  // limit so neither panel can swallow the canvas. Persisted to settings
  // on drag end.
  double _chatWidth = VibeTokens.chatPanelWidth;
  double _propsWidth = VibeTokens.propsPanelWidth;
  // Per-channel dirty cache. Updated on every canonical.dirtyChanges
  // event for the active channel; channels we haven't visited stay
  // out of the map (no badge until first activation).
  final Map<String, bool> _channelDirty = <String, bool>{};

  /// Per-channel filesystem watchers. Fire when an external editor /
  /// process writes inside `<bundle>.mbd/` (the .draft/ sibling is
  /// already covered by the canonical's own pipeline). The handler
  /// debounces multi-event bursts (atomic saves emit a flurry) into
  /// a single `_refreshChannelDirtyFromDisk()` pass.
  final Map<String, StreamSubscription<FileSystemEvent>> _channelWatchers =
      <String, StreamSubscription<FileSystemEvent>>{};
  Timer? _watcherDebounce;
  static const double _minPanelWidth = 240.0;
  static const double _maxPanelWidth = 640.0;

  @override
  void initState() {
    super.initState();
    _projection = widget.projection;
    _project = widget.project;
    _dirty = widget.canonical.isDirty;
    // Auto-rebind chat for already-open project (host hands us
    // VibeShell with project != null after _AppBuilderMount loads
    // lastProjectPath). The standalone main.dart did this implicitly
    // via Project init order; in built-in mode the shell mounts
    // after the bootstrap, so trigger _rebindChat once here.
    if (widget.project != null) {
      // ignore: unawaited_futures
      _rebindChat(widget.project!);
    }
    _restorePrefs();
    _resyncSelection();
    _wireDebugSurface();
    // Studio chrome MCP entry — `studio.ui.set_center_mode` routes here
    // so external callers (chat / external LLM / scenario replay) can
    // flip the 3-way mode without a synthetic pointer event.
    _wireStudioChromeBridge();
  }

  void _wireStudioChromeBridge() {
    final bridge = widget.studioChromeBridge;
    if (bridge == null) return;
    try {
      bridge.setCenterMode = (String mode) {
        CenterMode? next;
        switch (mode) {
          case 'ui':
            next = CenterMode.ui;
            break;
          case 'bundle':
            next = CenterMode.bundle;
            break;
          case 'debug':
            next = CenterMode.debug;
            break;
        }
        if (next == null) return false;
        if (!mounted) return false;
        setState(() => _centerMode = next!);
        return true;
      };
    } catch (_) {
      /* bridge field missing — older host */
    }
  }

  /// Active-aware bind target for `studioChromeBridge.newProjectInActive`.
  /// `_wireBridge` populates this with App Builder's `scaffoldNewProject`
  /// closure on first mount; `_bindStudioProjectSlotIfActive` then
  /// installs or releases it based on `WorkspaceTabActiveScope.isActiveOf`.
  Future<Map<String, dynamic>> Function({
    required String name,
    required String parent,
  })?
  _studioNewProjectHandler;

  /// Active-aware bind target for `studioChromeBridge.openProjectInActive`
  /// (the host slot `studio.project.open` calls). Without this, MCP-driven
  /// open fell through to the host's generic `_doOpenProject`, which sets the
  /// tab path but never loads the `VibeProject` or runs `_rebindChat` — so the
  /// per-project chat manager override stayed pinned to the previously open
  /// project. Wired / released in `_bindStudioProjectSlotIfActive` exactly
  /// like `_studioNewProjectHandler`, so MCP open mirrors the UI Open button.
  Future<Map<String, dynamic>> Function(String path)? _studioOpenProjectHandler;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // First pass after mount: wire the MCP server's project slots
    // (getProject / getRecents / …). Built-in mode mounts the shell
    // already holding the boot project, so there's no null→project
    // `didUpdateWidget` to do it — and `initState` can't, because
    // `_wireBridge` reaches an InheritedWidget (the active-scope check).
    // `didChangeDependencies` runs once right after initState and is the
    // earliest place inherited widgets may be read. Without this,
    // `project.info` and every project-scoped tool report "no project"
    // even though the UI has the boot project open.
    if (!_bridgeWired) {
      _bridgeWired = true;
      _wireBridge();
    }
    // `WorkspaceTabActiveScope` flips when the host's IndexedStack
    // switches which tab is on-screen — rebind the host's chrome
    // lifecycle slot so the active built-in always owns it.
    _bindStudioProjectSlotIfActive();
  }

  /// Wire / release `studioChromeBridge.newProjectInActive` against the
  /// current scope state. Idempotent — safe to call from
  /// `didChangeDependencies` (active flip) and from `_wireBridge`
  /// (first time the handler is registered). The release path is
  /// only-if-mine so a later mount's handler is never stranded.
  void _bindStudioProjectSlotIfActive() {
    if (!mounted) return;
    final isActive = WorkspaceTabActiveScope.isActiveOf(context);
    final bridge = widget.studioChromeBridge;
    // Per-project chat manager override lifecycle (independent of the
    // project slots below): apply this tab's scoped manager while active,
    // release when inactive — but ONLY if the override is still ours. The
    // bridge field is shared and every builtin shell writes it on rebuild;
    // clearing unconditionally would clobber a sibling tab's active override
    // (the Scene A->B->A leak this mirrors).
    if (bridge != null) {
      try {
        if (isActive) {
          bridge.chatManagerOverride.value = _scopedManagerId;
        } else if (_scopedManagerId != null &&
            bridge.chatManagerOverride.value == _scopedManagerId) {
          bridge.chatManagerOverride.value = null;
        }
      } catch (_) {
        /* duck-typed bridge — swallow */
      }
    }
    final fn = _studioNewProjectHandler;
    final openFn = _studioOpenProjectHandler;
    if (bridge == null || fn == null) return;
    if (isActive) {
      bridge.newProjectInActive = fn;
      // Open slot — MCP `studio.project.open` routes here while App Builder is
      // the active tab, so it loads + `_rebindChat`s instead of falling
      // through to the host's path-only `_doOpenProject`. Mine-only release.
      if (openFn != null) bridge.openProjectInActive = openFn;
      // Project-info slot — `studio.project.info` reports THIS tab's loaded
      // `VibeProject`. App Builder tracks its project in `_project` (not the
      // host's `t.currentProject`), so without this the host's default reader
      // returns `{}` (or a sibling tab's stale reporter). Mirrors Scene.
      try {
        bridge.activeProjectInfo = _reportActiveProjectInfo;
      } catch (_) {
        /* duck-typed bridge — swallow */
      }
      // Slash dispatch — host chat routes `/cmd` to this tab's own
      // handler (UI-context aware) while it is the active tab. Bound
      // alongside the project slot so both clear together when the tab
      // deactivates (mine-only release via the `fn` identity check).
      bridge.runSlashCommandInActive = _runSlashCommand;
      // Lint badge — host statusbar's lint badge click opens this tab's
      // lint modal; the counts are pushed via `_pushLintToHostIfActive`.
      bridge.onTapLintInActive = () => _showLintDialog();
      _pushLintToHostIfActive();
    } else if (identical(bridge.newProjectInActive, fn)) {
      bridge.newProjectInActive = null;
      if (openFn != null && identical(bridge.openProjectInActive, openFn)) {
        bridge.openProjectInActive = null;
      }
      try {
        if (identical(bridge.activeProjectInfo, _reportActiveProjectInfo)) {
          bridge.activeProjectInfo = null;
        }
      } catch (_) {
        /* duck-typed bridge — swallow */
      }
      bridge.runSlashCommandInActive = null;
      bridge.onTapLintInActive = null;
    }
  }

  @override
  void didUpdateWidget(VibeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Built-in mount uses a GlobalKey so VibeShell keeps the same
    // State across `_AppBuilderMount.setState` rebuilds (boot of
    // lastProjectPath swaps `widget.project` from null → loaded).
    // Without this hook the State's `_project` stays at its
    // initState value and the view never reflects the loaded
    // project. Mirror initState's pickups on prop change.
    if (oldWidget.project != widget.project) {
      _project = widget.project;
      _projection = widget.projection;
      _dirty = widget.canonical.isDirty;
      _resyncSelection();
      if (widget.project != null) {
        // ignore: unawaited_futures
        _rebindChat(widget.project!);
      }
    } else if (!identical(oldWidget.projection, widget.projection)) {
      _projection = widget.projection;
    }
    // First-paint dirty scan: the canonical's `dirtyChanges` only fires
    // for the active channel, so non-active channels with leftover
    // draft directories (e.g. native.mbd.draft) would never light up
    // the badge until the user navigated to them. Scan every enabled
    // channel's bundle path on open so all stale drafts are visible
    // immediately.
    // ignore: unawaited_futures
    _refreshChannelDirtyFromDisk();
    // ignore: unawaited_futures
    _startChannelWatchers();
    widget.canonical.changes.listen((_) {
      if (!mounted) return;
      setState(() {
        _projection = LayerProjection.fromJson(widget.canonical.currentJson);
        _resyncSelection();
        _refreshLint();
        // Force the preview to fully tear down + remount so canonical
        // edits land in the runtime. Same path as the manual refresh
        // button — incrementing the externalRefreshEpoch cascades
        // into PreviewMcpUi's keyTag → UiView ValueKey, which is the
        // only reliable way we have to push new content through the
        // pipeline.
        _previewEpoch++;
      });
      _scheduleHealthRefresh();
    });
    _refreshLint();
    _scheduleHealthRefresh();
    widget.canonical.dirtyChanges.listen((isDirty) {
      if (!mounted) return;
      setState(() {
        _dirty = isDirty;
        final active = _project?.activeChannel;
        if (active != null) _channelDirty[active] = isDirty;
      });
    });
    _canUndo = widget.canonical.canUndo;
    _canRedo = widget.canonical.canRedo;
    widget.canonical.undoStateChanges.listen((s) {
      if (!mounted) return;
      setState(() {
        _canUndo = s.canUndo;
        _canRedo = s.canRedo;
      });
    });
    // Surface the recovery banner once the Scaffold is mounted so the
    // user knows their unsaved work was rescued from a prior session.
    if (widget.canonical.hasRestoredDraft) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _toast('Restored unsaved changes from the previous session');
      });
    }
    // Hand the LLM a live snapshot of the current selection so the
    // model can resolve "this widget" referents in user prompts.
    widget.llm?.bindSelectionContext(_selectionContextString);
    final initialProject = _project;
    if (initialProject != null) {
      widget.llm?.bindFileTools(
        FileToolsDispatcher(
          projectRoot: initialProject.projectPath,
          onAfterMutate: _onFileToolMutate,
        ),
      );
      widget.llm?.bindBuildTools(
        BuildToolsDispatcher(
          project: initialProject,
          canonical: widget.canonical,
          pipeline: widget.pipeline,
          validator: _validator,
          onRunBuild: _runBuildFromPreset,
          onCapturePreview: _capturePreviewBytes,
          onLayoutSnapshot: _captureLayoutSnapshotNodes,
        ),
      );
    }
    // Settings come from the parent now (widget.settings). The
    // in-shell async load that lived here used to race against the
    // first Open click and made the picker fall back to the default
    // dir before workspaceDir was populated. Single source of truth
    // = the parent's instance.
    _chatWidth = _clampPanelWidth(
      _settings.chatPanelWidth ?? VibeTokens.chatPanelWidth,
    );
    _propsWidth = _clampPanelWidth(
      _settings.propsPanelWidth ?? VibeTokens.propsPanelWidth,
    );
    _wireBridge();
  }

  @override
  void dispose() {
    _unwireBridge();
    // Liveness pointer teardown lives in the mount's dispose
    // (`VibeServerBridge.clearLiveIfMine`), not here.
    // Release the active-aware chrome slot only when this state's own
    // handler is still installed — a sibling built-in may have taken
    // it via its own `didChangeDependencies` between the last bind
    // and this dispose, and we don't want to strand that tab.
    final bridge = widget.studioChromeBridge;
    final fn = _studioNewProjectHandler;
    if (bridge != null &&
        fn != null &&
        identical(bridge.newProjectInActive, fn)) {
      bridge.newProjectInActive = null;
    }
    final openFn = _studioOpenProjectHandler;
    if (bridge != null &&
        openFn != null &&
        identical(bridge.openProjectInActive, openFn)) {
      bridge.openProjectInActive = null;
    }
    if (bridge != null &&
        identical(bridge.activeProjectInfo, _reportActiveProjectInfo)) {
      bridge.activeProjectInfo = null;
    }
    // Release the shared chat override if it's still ours — dispose-while-active
    // bypasses the deactivate clear, else the next tab's chat routes here.
    if (bridge != null && _scopedManagerId != null) {
      try {
        if (bridge.chatManagerOverride.value == _scopedManagerId) {
          bridge.chatManagerOverride.value = null;
        }
      } catch (_) {
        /* duck-typed bridge — swallow */
      }
    }
    _healthDebounce?.cancel();
    _watcherDebounce?.cancel();
    // ignore: unawaited_futures
    _stopChannelWatchers();
    _inspectorSessions.dispose();
    _logSub?.cancel();
    super.dispose();
  }

  static double _clampPanelWidth(double w) =>
      w.clamp(_minPanelWidth, _maxPanelWidth);

  Future<void> _persistPanelWidths() async {
    _settings.chatPanelWidth = _chatWidth;
    _settings.propsPanelWidth = _propsWidth;
    try {
      await _settings.save(VibeSettings.defaultPath('app_builder_vibe'));
    } catch (_) {
      /* best-effort */
    }
  }

  /// Hand the [VibeServerBridge] live closures over shell-owned state.
  /// MCP tool handlers (in `ServerBootstrap`) call through these slots
  /// rather than reaching into the shell directly. All closures read
  /// State `this`, so they pick up changes (project switch, selection)
  /// without needing re-registration.
  void _wireBridge() {
    final bridge = widget.bridge;
    if (bridge == null) return;

    // ── Project state getters ──
    bridge.getProject = () => _project;
    bridge.getRecents =
        () => List<String>.unmodifiable(_settings.recentProjects);
    bridge.getFileTools = () {
      final proj = _project;
      if (proj == null) return null;
      return FileToolsDispatcher(
        projectRoot: proj.projectPath,
        onAfterMutate: _onFileToolMutate,
      );
    };
    bridge.getBuildTools = () {
      final proj = _project;
      if (proj == null) return null;
      return BuildToolsDispatcher(
        project: proj,
        canonical: widget.canonical,
        pipeline: widget.pipeline,
        validator: _validator,
        onRunBuild: _runBuildFromPreset,
        onCapturePreview: _capturePreviewBytes,
        onLayoutSnapshot: _captureLayoutSnapshotNodes,
      );
    };
    bridge.getSettings = () => _settings;
    bridge.onUpdateSettings = (updated) async {
      await updated.save(VibeSettings.defaultPath('app_builder_vibe'));
      if (!mounted) return;
      setState(() => _settings = updated);
      widget.llm?.update(updated);
    };

    // ── Project lifecycle (headless — no GUI prompts) ──
    // Shared scaffolder used by both the VibeServerBridge slot
    // (`bridge.onNewProject`) and the host's chrome MCP path
    // (`chromeBridge.newProjectInActive`). Same VibeProject.openAt
    // call as the existing UI button — templates copied, preview
    // attached. Without this, the host MCP path only mkdir's and the
    // App Builder shell never re-mounts on the new project.
    Future<Map<String, dynamic>> scaffoldNewProject({
      required String name,
      required String parent,
      ProjectKind kind = ProjectKind.appPlayerApp,
    }) async {
      final dir = p.join(parent, name);
      if (await Directory(dir).exists()) {
        return <String, dynamic>{
          'ok': false,
          'error': 'A project already exists at $dir',
        };
      }
      try {
        final project = await VibeProject.openAt(
          projectDir: dir,
          canonical: widget.canonical,
          newProjectKind: kind,
          seedNewBundle: applyProjectSeed,
        );
        await project.save();
        await _rebindChat(project);
        final previous = _project;
        if (mounted) {
          setState(() {
            _project = project;
            _selectedPageId = null;
            _selectedComponentId = null;
            _focusedByChannelMode.clear();
            _channelDirty.clear();
          });
        }
        await previous?.dispose();
        _persistPrefs();
        await _recordRecent(project.projectPath);
        // ignore: unawaited_futures
        _refreshChannelDirtyFromDisk();
        // ignore: unawaited_futures
        _startChannelWatchers();
        return <String, dynamic>{
          'ok': true,
          'projectPath': project.projectPath,
          'projectName': name,
        };
      } catch (e) {
        return <String, dynamic>{'ok': false, 'error': e.toString()};
      }
    }

    bridge.onNewProject = (name, parent, {kind}) async {
      await scaffoldNewProject(
        name: name,
        parent: parent,
        kind: kind ?? ProjectKind.appPlayerApp,
      );
    };
    // Promote the scaffolder onto a state field so the chrome lifecycle
    // slot (`studioChromeBridge.newProjectInActive`) can be wired /
    // released in `didChangeDependencies` based on whether this tab is
    // the active built-in. Wiring unconditionally here would race
    // against every sibling built-in's own mount (the IndexedStack
    // mounts every tab eagerly + `_AppBuilderMount` boots through an
    // async path, so this `_wireBridge` call lands after Ops's
    // `initState` and the slot would always end up owned by App
    // Builder regardless of which tab the user is viewing). The
    // active-aware bind ensures the slot tracks the tab strip.
    _studioNewProjectHandler =
        ({required String name, required String parent}) =>
            scaffoldNewProject(name: name, parent: parent);
    _bindStudioProjectSlotIfActive();
    bridge.onOpenProject = (path) async {
      final r = await _openProjectAtPath(path);
      if (r['ok'] != true) {
        throw StateError(r['error']?.toString() ?? 'open failed');
      }
    };
    // Same path-based open feeds the host chrome slot
    // (`studioChromeBridge.openProjectInActive`, behind `studio.project.open`)
    // so MCP open re-mounts + `_rebindChat`s identically to the UI button.
    _studioOpenProjectHandler = _openProjectAtPath;
    bridge.onCloseProject = () async {
      final proj = _project;
      if (proj == null) return;
      await _stopChannelWatchers();
      _settings.lastProjectPath = null;
      // ignore: unawaited_futures
      _settings.save(VibeSettings.defaultPath('app_builder_vibe'));
      widget.chat.onTurnPersisted = null;
      widget.chat.onClearLog = null;
      widget.chat.clear();
      widget.llm?.resetHistory();
      widget.llm?.bindFileTools(null);
      widget.llm?.bindBuildTools(null);
      if (!mounted) return;
      setState(() {
        _project = null;
        _focusedByChannelMode.clear();
        _selectedPageId = null;
        _selectedComponentId = null;
        _channelDirty.clear();
      });
      await proj.dispose();
    };
    bridge.onSaveProject = () async {
      final proj = _project;
      if (proj == null) throw StateError('No project open');
      await proj.save();
      // Save purges the active channel's draft directory; refresh the
      // disk-side cache so non-active channels still showing leftover
      // drafts (likely the common case after an `Open` from disk)
      // don't get stale-cleared by a later setState that doesn't
      // touch them.
      // ignore: unawaited_futures
      _refreshChannelDirtyFromDisk();
    };
    bridge.onSaveAsProject = (newPath) async {
      final proj = _project;
      if (proj == null) throw StateError('No project open');
      if (await Directory(newPath).exists()) {
        throw StateError('A project already exists at $newPath');
      }
      final next = await proj.saveAs(newPath);
      widget.chat.onTurnPersisted = (turn) => next.chatLog.append(turn);
      widget.chat.onClearLog = () => next.chatLog.clear();
      if (!mounted) return;
      setState(() => _project = next);
      await _recordRecent(next.projectPath);
    };
    bridge.onRevertProject = () async {
      final proj = _project;
      if (proj == null) throw StateError('No project open');
      await proj.revert();
    };
    bridge.onRenameProject = (newName) async {
      final proj = _project;
      if (proj == null) throw StateError('No project open');
      await proj.rename(newName);
      if (!mounted) return;
      setState(() {});
    };

    // ── Channel lifecycle (delegates to existing shell handlers) ──
    bridge.onActivateChannel = _onActivateChannel;
    bridge.onCreateChannel = _onCreateChannel;
    bridge.onRemoveChannel = (id) async {
      final proj = _project;
      if (proj == null) throw StateError('No project open');
      await proj.removeChannel(id);
      if (!mounted) return;
      setState(() {
        _projection = LayerProjection.fromJson(widget.canonical.currentJson);
        _selectedPageId = null;
        _selectedComponentId = null;
        _selectedWidgetPath = null;
      });
    };
    bridge.onPurgeChannel = (id) async {
      final proj = _project;
      if (proj == null) throw StateError('No project open');
      await proj.purgeChannel(id);
      if (!mounted) return;
      setState(() {
        _projection = LayerProjection.fromJson(widget.canonical.currentJson);
        _selectedPageId = null;
        _selectedComponentId = null;
        _selectedWidgetPath = null;
      });
    };
    bridge.onCopyChannel = (from, to) async {
      final proj = _project;
      if (proj == null) throw StateError('No project open');
      await proj.copyChannel(source: from, target: to);
      if (!mounted) return;
      setState(() {
        _projection = LayerProjection.fromJson(widget.canonical.currentJson);
        _selectedPageId = null;
        _selectedComponentId = null;
        _selectedWidgetPath = null;
      });
    };
    bridge.onSwapChannels = (a, b) async {
      final proj = _project;
      if (proj == null) throw StateError('No project open');
      await proj.swapChannels(a, b);
      if (!mounted) return;
      setState(() {
        _projection = LayerProjection.fromJson(widget.canonical.currentJson);
        _selectedPageId = null;
        _selectedComponentId = null;
        _selectedWidgetPath = null;
      });
    };
    bridge.onCleanBuild = (target) async {
      final proj = _project;
      if (proj == null) throw StateError('No project open');
      return proj.cleanBuild(target: target);
    };

    // ── Build preset persistence ─────────────────────────────────
    bridge.onUpdateBuildConfig = ({
      String? target,
      String? channel,
      String? outDir,
      bool? runFlutterCreate,
    }) async {
      final proj = _project;
      if (proj == null) throw StateError('No project open');
      final existing =
          proj.prefs.buildConfig ??
          const BuildConfig(
            target: 'mcpb',
            channel: 'serving',
            outDir: '',
            runFlutterCreate: true,
          );
      proj.prefs.buildConfig = existing.copyWith(
        target: target,
        channel: channel,
        outDir: outDir,
        runFlutterCreate: runFlutterCreate,
      );
      await proj.savePrefs();
    };

    // ── Shell focus / selection ──
    bridge.getFocusedLayer = () => _focused.name;
    bridge.getSelectedPageId = () => _selectedPageId;
    bridge.getSelectedComponentId = () => _selectedComponentId;
    bridge.getSelectedWidgetPath = () {
      final path = _selectedWidgetPath;
      if (path == null) return null;
      return pointerOf(path);
    };
    bridge.getDirty = () => _dirty;

    bridge.onFocusLayer = (id) async {
      final layer = _layerFromString(id);
      if (!mounted) return;
      setState(() {
        _focused = layer;
        _selectedWidgetPath = null;
      });
      _persistPrefs();
    };
    bridge.onSelectPage = (pageId) async {
      if (!mounted) return;
      setState(() {
        _selectedPageId = pageId;
        _selectedWidgetPath = null;
      });
      _persistPrefs();
    };
    bridge.onSelectComponent = (componentId) async {
      if (!mounted) return;
      setState(() {
        _selectedComponentId = componentId;
        _selectedWidgetPath = null;
      });
      _persistPrefs();
    };
    bridge.onSelectWidget = (pointer) async {
      if (!mounted) return;
      setState(() => _selectedWidgetPath = _pathFromPointer(pointer));
    };
    bridge.onRequestPreviewRefresh = () async {
      if (!mounted) return;
      setState(() => _previewEpoch++);
    };
    bridge.getInspectorSessions = () => _inspectorSessions;
    bridge.spawnInspectorVariant = _spawnInspectorVariant;
    bridge.stopInspectorVariant = _stopInspectorVariant;
    bridge.onCapturePreview = _capturePreviewBytes;
    bridge.onCaptureLayoutSnapshot = _captureLayoutSnapshotNodes;
    // Debug surface — chat history / runtime errors / logs.
    bridge.getChatHistory = ({int limit = 50}) {
      final all = widget.chat.turns;
      final tail =
          all.length <= limit
              ? all.reversed.toList()
              : all.sublist(all.length - limit).reversed.toList();
      return <Map<String, dynamic>>[
        for (final t in tail)
          <String, dynamic>{
            'role': t.role,
            'text': t.text,
            'at': t.at.toIso8601String(),
            if (t.layer is LayerId) 'layer': (t.layer as LayerId).name,
            if (t.fileCount != null) 'fileCount': t.fileCount,
          },
      ];
    };
    bridge.getRuntimeErrors = ({int limit = 50}) {
      final n = math.min(limit, _runtimeErrors.length);
      return _runtimeErrors.reversed.take(n).toList(growable: false);
    };
    bridge.getLogsTail = ({int limit = 100, String? channel}) {
      Iterable<Map<String, dynamic>> filtered = _logRing.reversed;
      if (channel != null && channel.isNotEmpty) {
        filtered = filtered.where((e) => e['channel'] == channel);
      }
      return filtered.take(limit).toList(growable: false);
    };
    bridge.submitChatMessage = (text) async {
      // Same path as the user typing into the composer + pressing
      // Enter. Append the user turn to the feed first so chat_history
      // reads see the request; then run the controller's send and
      // return the resolved assistant turn.
      widget.chat.appendTurn(ChatTurn(role: 'user', text: text));
      final reply = await widget.chat
          .send(text)
          .timeout(const Duration(seconds: 120));
      widget.chat.appendTurn(reply);
      return <String, dynamic>{
        'role': reply.role,
        'text': reply.text,
        'at': reply.at.toIso8601String(),
        if (reply.layer is LayerId) 'layer': (reply.layer as LayerId).name,
        if (reply.fileCount != null) 'fileCount': reply.fileCount,
      };
    };
  }

  /// Hook FlutterError + package:logging streams into bounded ring
  /// buffers so the debug-surface MCP tools (`vibe_runtime_errors` /
  /// `vibe_logs_tail`) can answer "what went wrong without taking a
  /// screenshot or grep'ing stderr" calls.
  void _wireDebugSurface() {
    Logger.root.level = Level.ALL;
    _logSub = Logger.root.onRecord.listen((rec) {
      if (rec.loggerName.isEmpty && (rec.level.value < Level.INFO.value)) {
        return; // drop noisy unscoped low-level events
      }
      _logRing.add(<String, dynamic>{
        'at': rec.time.toUtc().toIso8601String(),
        'level': rec.level.name,
        'channel': rec.loggerName,
        'message': rec.message,
        if (rec.error != null) 'error': '${rec.error}',
        if (rec.stackTrace != null) 'stack': '${rec.stackTrace}',
      });
      if (_logRing.length > _kRingCap) {
        _logRing.removeRange(0, _logRing.length - _kRingCap);
      }
    });
    final prevHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      _runtimeErrors.add(<String, dynamic>{
        'at': DateTime.now().toUtc().toIso8601String(),
        'where': details.library ?? 'unknown',
        'kind': '${details.exception.runtimeType}',
        'message': details.exceptionAsString(),
        if (details.stack != null)
          'stack': details.stack.toString().split('\n').take(8).join('\n'),
      });
      if (_runtimeErrors.length > _kRingCap) {
        _runtimeErrors.removeRange(0, _runtimeErrors.length - _kRingCap);
      }
      // Preserve the existing handler chain so debug overlays keep
      // working — vibe only piggybacks off the stream, doesn't
      // suppress.
      if (prevHandler != null) prevHandler(details);
    };
  }

  /// Capture the live preview surface as PNG bytes. Used by the
  /// MCP `vibe_preview_capture` tool (via bridge) and by the chat
  /// LLM's `preview_capture` tool (via BuildToolsDispatcher).
  /// Returns null when no preview is mounted.
  Future<({Uint8List bytes, int width, int height})?> _capturePreviewBytes({
    double pixelRatio = 2.0,
  }) async {
    final box = _previewCaptureKey.currentContext?.findRenderObject();
    if (box is! RenderRepaintBoundary) return null;
    // `toImage` asserts `!debugNeedsPaint`. Triggering it while the
    // frame is still being scheduled (e.g. immediately after a
    // mutator that dirtied the preview) throws. Wait for the next
    // settled frame before attempting capture.
    if (box.debugNeedsPaint) {
      await WidgetsBinding.instance.endOfFrame;
    }
    final image = await box.toImage(pixelRatio: pixelRatio);
    try {
      final byteData = await image.toByteData(format: ImageByteFormat.png);
      if (byteData == null) return null;
      return (
        bytes: byteData.buffer.asUint8List(),
        width: image.width,
        height: image.height,
      );
    } finally {
      image.dispose();
    }
  }

  /// Walk the live preview's render tree (debug surface in debug
  /// mode, editor surface otherwise — falls back to the other key
  /// when the primary isn't mounted) and return per-widget rect /
  /// font / decoration / padding. Shared by the MCP
  /// `vibe_layout_snapshot` and the chat `layout_snapshot` tools.
  Future<List<Map<String, dynamic>>?> _captureLayoutSnapshotNodes() async {
    final keys =
        _centerMode == CenterMode.debug
            ? <GlobalKey>[_inspectorCaptureKey, _previewCaptureKey]
            : <GlobalKey>[_previewCaptureKey, _inspectorCaptureKey];
    for (final k in keys) {
      final ro = k.currentContext?.findRenderObject();
      if (ro is RenderBox && ro.attached && ro.hasSize) {
        return _captureLayoutSnapshot(ro);
      }
    }
    return null;
  }

  /// Walk the live preview's render tree and produce one entry per
  /// `RenderMetaData` node — each carries a `MetaData(metaData: <json
  /// node>)` wrapper from `_inspectorWrapper`. For every match we
  /// pull the rect (rooted at the preview's top), the source widget
  /// type, and any rendered style we can scrape off the descendants
  /// (text font/size/color, container decoration, padding, clip
  /// radius). Pure render-tree introspection — no spec parsing — so
  /// the values reflect what the user actually sees.
  List<Map<String, dynamic>> _captureLayoutSnapshot(RenderBox root) {
    final out = <Map<String, dynamic>>[];
    void visit(RenderObject ro, int depth) {
      if (ro is RenderMetaData) {
        final meta = ro.metaData;
        if (meta is Map<String, dynamic> && ro.hasSize && ro.attached) {
          final box = ro;
          final transform = box.getTransformTo(root);
          final rect = MatrixUtils.transformRect(
            transform,
            Offset.zero & box.size,
          );
          final entry = <String, dynamic>{
            'type': meta['type']?.toString() ?? '?',
            'depth': depth,
            'rect': <double>[rect.left, rect.top, rect.width, rect.height],
          };
          for (final key in const <String>['id', 'text', 'label', 'title']) {
            final v = meta[key];
            if (v is String && v.isNotEmpty) entry[key] = v;
          }
          // Walk the metadata-node's subtree (until the next
          // RenderMetaData) to pick up rendered style — text styles
          // live on the descendant RenderParagraph; clip / decoration
          // / padding live on intermediate RenderObjects the runtime
          // wraps around the actual widget.
          _scrapeRenderedStyle(ro, entry);
          out.add(entry);
        }
      }
      ro.visitChildren((child) => visit(child, depth + 1));
    }

    visit(root, 0);
    return out;
  }

  /// Pull whatever rendered-style hints we can from a metadata node's
  /// subtree without jumping past the next metadata boundary (those
  /// belong to the next entry). Best-effort — properties not exposed
  /// publicly are silently skipped.
  void _scrapeRenderedStyle(RenderObject root, Map<String, dynamic> entry) {
    void walk(RenderObject ro, int sinceMeta) {
      // Don't dive into another widget's metadata subtree.
      if (sinceMeta > 0 && ro is RenderMetaData) return;
      if (ro is RenderParagraph) {
        final style = ro.text.style;
        if (style != null) {
          final font = <String, dynamic>{};
          if (style.fontSize != null) font['size'] = style.fontSize;
          if (style.fontWeight != null) {
            font['weight'] = style.fontWeight!.value;
          }
          if (style.fontFamily != null && style.fontFamily!.isNotEmpty) {
            font['family'] = style.fontFamily;
          }
          if (style.color != null) {
            font['color'] = _hexOf(style.color!);
          }
          if (style.height != null) font['lineHeight'] = style.height;
          if (font.isNotEmpty) entry['font'] = font;
        }
      }
      if (ro is RenderDecoratedBox) {
        final dec = ro.decoration;
        if (dec is BoxDecoration) {
          final box = <String, dynamic>{};
          if (dec.color != null) box['color'] = _hexOf(dec.color!);
          final br = dec.borderRadius;
          if (br is BorderRadius) {
            box['radius'] = <String, double>{
              'tl': br.topLeft.x,
              'tr': br.topRight.x,
              'bl': br.bottomLeft.x,
              'br': br.bottomRight.x,
            };
          }
          if (dec.border != null) {
            box['borderTop'] = dec.border!.top.width;
            box['borderColor'] = _hexOf(dec.border!.top.color);
          }
          if (box.isNotEmpty) entry['box'] = box;
        }
      }
      if (ro is RenderPadding) {
        final pad = ro.padding;
        entry['padding'] = <String, double>{
          'l': pad.resolve(TextDirection.ltr).left,
          't': pad.resolve(TextDirection.ltr).top,
          'r': pad.resolve(TextDirection.ltr).right,
          'b': pad.resolve(TextDirection.ltr).bottom,
        };
      }
      ro.visitChildren((child) => walk(child, sinceMeta + 1));
    }

    root.visitChildren((c) => walk(c, 0));
  }

  /// Convert a Flutter [Color] to a `#RRGGBB[AA]` hex string. The
  /// `AA` byte is dropped when the colour is fully opaque to keep
  /// the snapshot output uncluttered.
  String _hexOf(Color c) {
    final r = (c.r * 255).round() & 0xff;
    final g = (c.g * 255).round() & 0xff;
    final b = (c.b * 255).round() & 0xff;
    final a = (c.a * 255).round() & 0xff;
    final base =
        '#${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}';
    return a == 0xff ? base : '$base${a.toRadixString(16).padLeft(2, '0')}';
  }

  /// Drop every bridge slot the shell registered. Called from
  /// `dispose()` so a hot-reload swap doesn't leave the MCP server
  /// driving a torn-down State.
  void _unwireBridge() {
    final bridge = widget.bridge;
    if (bridge == null) return;
    bridge
      ..getProject = null
      ..getRecents = null
      ..getFileTools = null
      ..getBuildTools = null
      ..getSettings = null
      ..onUpdateSettings = null
      ..onNewProject = null
      ..onOpenProject = null
      ..onCloseProject = null
      ..onSaveProject = null
      ..onSaveAsProject = null
      ..onRevertProject = null
      ..onRenameProject = null
      ..onActivateChannel = null
      ..onCreateChannel = null
      ..onRemoveChannel = null
      ..onPurgeChannel = null
      ..onCopyChannel = null
      ..onSwapChannels = null
      ..onUpdateBuildConfig = null
      ..onCleanBuild = null
      ..getFocusedLayer = null
      ..getSelectedPageId = null
      ..getSelectedComponentId = null
      ..getSelectedWidgetPath = null
      ..getDirty = null
      ..onFocusLayer = null
      ..onSelectPage = null
      ..onSelectComponent = null
      ..onSelectWidget = null
      ..onRequestPreviewRefresh = null
      ..onCapturePreview = null
      ..onCaptureLayoutSnapshot = null
      ..getChatHistory = null
      ..getRuntimeErrors = null
      ..getLogsTail = null
      ..submitChatMessage = null
      ..getInspectorSessions = null
      ..spawnInspectorVariant = null
      ..stopInspectorVariant = null;
  }

  /// MCP-driven inspector variant spawn — the same `connect()` path the
  /// Inspector's variant ▶ card drives (`_onVariantToggle` in
  /// inspector_panel.dart), exposed so the live-debug workflow is
  /// automatable over MCP. The card itself is a raw `GestureDetector`
  /// that synthetic `studio.ui.tap` events can't reach, and there was no
  /// other path to start a session, so this closes that gap.
  Future<Map<String, dynamic>> _spawnInspectorVariant(
    String slug, {
    String? transport,
  }) async {
    final proj = _project?.projectPath;
    if (proj == null) {
      return <String, dynamic>{'ok': false, 'error': 'no project open'};
    }
    // slug → isNative (mirror inspector_panel's _variants table).
    const known = <String, bool>{
      'inline': false,
      'bundle': false,
      'native_inline': true,
      'native_bundle': true,
    };
    if (!known.containsKey(slug)) {
      return <String, dynamic>{
        'ok': false,
        'error':
            'unknown variant "$slug" — one of '
            'inline / bundle / native_inline / native_bundle',
      };
    }
    final dir = p.join(proj, 'build', slug);
    if (!Directory(dir).existsSync()) {
      return <String, dynamic>{
        'ok': false,
        'error':
            'variant not built — run `build.run_build` with '
            'target:"$slug" first (expected build/$slug/).',
      };
    }
    final binary = _resolveVariantBinary(dir, known[slug]!);
    if (binary == null) {
      return <String, dynamic>{
        'ok': false,
        'error':
            'no executable under build/$slug — compile it first via '
            '`build.run_shell` (native: `flutter build macos`; '
            'bundle/inline: `dart compile exe bin/server.dart -o server`).',
      };
    }
    final t = switch (transport) {
      'http' => InspectorTransport.http,
      'sse' => InspectorTransport.sse,
      _ => InspectorTransport.stdio,
    };
    try {
      await _inspectorSessions.connect(
        slug: slug,
        binary: binary,
        transport: t,
      );
    } catch (e) {
      return <String, dynamic>{'ok': false, 'error': 'connect failed: $e'};
    }
    final session = _inspectorSessions[slug];
    return <String, dynamic>{
      'ok': true,
      'slug': slug,
      'status': session?.status.name ?? 'unknown',
      'transport': t.name,
      'binary': binary,
    };
  }

  Map<String, dynamic> _stopInspectorVariant(String slug) {
    // ignore: unawaited_futures
    _inspectorSessions.stop(slug);
    return <String, dynamic>{'ok': true, 'slug': slug, 'stopped': true};
  }

  /// Resolve a runnable executable for a built variant dir — native looks
  /// for the compiled macOS `.app`, others for an executable file. Mirrors
  /// `_InspectorPanelState._resolveBinary` (kept in sync).
  String? _resolveVariantBinary(String dir, bool isNative) {
    if (isNative) {
      if (!Platform.isMacOS) return null;
      final base = p.join(dir, 'build', 'macos', 'Build', 'Products', 'Debug');
      final products = Directory(base);
      if (!products.existsSync()) return null;
      for (final entry in products.listSync()) {
        if (entry is Directory && entry.path.endsWith('.app')) {
          final exeName = p.basenameWithoutExtension(entry.path);
          final exe = p.join(entry.path, 'Contents', 'MacOS', exeName);
          if (File(exe).existsSync()) return exe;
        }
      }
      return null;
    }
    final root = Directory(dir);
    if (!root.existsSync()) return null;
    for (final entry in root.listSync()) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (name.contains('.')) continue;
      final stat = entry.statSync();
      if ((stat.mode & 0x49) != 0) return entry.path;
    }
    return null;
  }

  static LayerId _layerFromString(String id) {
    switch (id) {
      case 'appStructure':
        return LayerId.appStructure;
      case 'theme':
        return LayerId.theme;
      case 'components':
        return LayerId.components;
      case 'dashboard':
        return LayerId.dashboard;
      case 'navigation':
        return LayerId.navigation;
      case 'pages':
        return LayerId.pages;
      case 'assets':
        return LayerId.assets;
      case 'whole':
        return LayerId.whole;
      default:
        throw ArgumentError.value(id, 'layer', 'unknown layer id');
    }
  }

  /// Decode an RFC-6901-style pointer (`""`, `/child`, `/children/0`,
  /// `/cells/0/text`) into the mixed-segment [WidgetPath] the tree
  /// view uses (string = map key, int = list index). Empty string
  /// means root.
  static WidgetPath _pathFromPointer(String pointer) {
    if (pointer.isEmpty || pointer == '/') return const <Object>[];
    if (!pointer.startsWith('/')) {
      throw ArgumentError.value(
        pointer,
        'widgetPath',
        'must start with "/" or be empty',
      );
    }
    final parts = pointer
        .substring(1)
        .split('/')
        .map((s) => s.replaceAll('~1', '/').replaceAll('~0', '~'));
    final out = <Object>[];
    for (final part in parts) {
      final asInt = int.tryParse(part);
      out.add(asInt ?? part);
    }
    return out;
  }

  /// Pull the project's persisted UI prefs into local state so the shell
  /// reopens to the same layer / selection the user left it on.
  void _restorePrefs() {
    final prefs = _project?.prefs;
    if (prefs == null) return;
    _focusedByChannelMode = _cloneFocusMap(prefs.focusedByChannelMode);
    if (prefs.selectedPageId != null) _selectedPageId = prefs.selectedPageId;
    if (prefs.selectedComponentId != null) {
      _selectedComponentId = prefs.selectedComponentId;
    }
  }

  /// Best-effort prefs persist. The shell calls this after every
  /// user-driven state change so closing the app preserves the
  /// session. Disk failures are swallowed (prefs are non-critical).
  void _persistPrefs() {
    final proj = _project;
    if (proj == null) return;
    proj.prefs
      ..focusedByChannelMode = _cloneFocusMap(_focusedByChannelMode)
      ..selectedPageId = _selectedPageId
      ..selectedComponentId = _selectedComponentId;
    proj.savePrefs().catchError((_) {});
  }

  /// Persist a preview-panel state change. The panel owns the ephemeral
  /// state; the shell only mirrors it into the project so reopens
  /// restore it.
  void _onPreviewPrefsChanged(PreviewPrefsSnapshot snapshot) {
    final proj = _project;
    if (proj == null) return;
    proj.prefs
      ..previewSizeChoice = snapshot.sizeChoice
      ..previewOrientation = snapshot.orientation
      ..previewBrightness = snapshot.brightness
      ..previewCustomW = snapshot.customW
      ..previewCustomH = snapshot.customH;
    proj.savePrefs().catchError((_) {});
  }

  /// Report the active App Builder project for the host chrome slot
  /// (`activeProjectInfo`, behind `studio.project.info`). Empty when no
  /// project is open. Wired only while this tab is active so a sibling tab's
  /// reads don't pick up a stale project.
  Map<String, dynamic> _reportActiveProjectInfo() {
    final proj = _project;
    if (proj == null) return const <String, dynamic>{};
    return <String, dynamic>{
      'projectPath': proj.projectPath,
      'projectName': p.basename(proj.projectPath),
    };
  }

  /// Path-based project open shared by the App Builder server bridge
  /// (`onOpenProject`) and the host chrome slot (`openProjectInActive`,
  /// behind `studio.project.open`). Loads the [path] project, re-binds the
  /// chat (which re-points the per-project manager override via
  /// [_applyScopedManager]), swaps it in, and disposes the previous one.
  /// Returns `{ok, projectPath, projectName}` or `{ok: false, error}` — the
  /// server-bridge caller rethrows on failure to keep its throwing contract.
  Future<Map<String, dynamic>> _openProjectAtPath(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      return <String, dynamic>{'ok': false, 'error': 'No such folder: $path'};
    }
    final hasNew = await File(p.join(path, VibeProject.projectFile)).exists();
    final hasLegacy =
        await File(p.join(path, VibeProject.legacyProjectFile)).exists();
    if (!hasNew && !hasLegacy) {
      return <String, dynamic>{
        'ok': false,
        'error': 'Not an AppPlayer Builder project: $path',
      };
    }
    try {
      final project = await VibeProject.openAt(
        projectDir: path,
        canonical: widget.canonical,
      );
      await _rebindChat(project);
      final previous = _project;
      if (!mounted) {
        await project.dispose();
        return <String, dynamic>{'ok': false, 'error': 'unmounted'};
      }
      setState(() {
        _project = project;
        _focusedByChannelMode = _cloneFocusMap(
          project.prefs.focusedByChannelMode,
        );
        _selectedPageId = project.prefs.selectedPageId;
        _selectedComponentId = project.prefs.selectedComponentId;
        // Drop the previous project's per-channel cache before the
        // disk scan repopulates it for the new project.
        _channelDirty.clear();
      });
      await previous?.dispose();
      await _recordRecent(project.projectPath);
      // ignore: unawaited_futures
      _refreshChannelDirtyFromDisk();
      // ignore: unawaited_futures
      _startChannelWatchers();
      return <String, dynamic>{
        'ok': true,
        'projectPath': project.projectPath,
        'projectName': p.basename(project.projectPath),
      };
    } catch (e) {
      return <String, dynamic>{'ok': false, 'error': e.toString()};
    }
  }

  /// Re-target the chat controller + LLM history at [proj]'s chat log.
  /// Called whenever the active project changes (New / Open) so the
  /// conversation feed reflects the project the user is now editing.
  Future<void> _rebindChat(VibeProject proj) async {
    widget.chat.onTurnPersisted = (turn) => proj.chatLog.append(turn);
    widget.chat.onClearLog = () => proj.chatLog.clear();
    widget.llm?.resetHistory();
    widget.llm?.bindFileTools(
      FileToolsDispatcher(
        projectRoot: proj.projectPath,
        onAfterMutate: _onFileToolMutate,
      ),
    );
    widget.llm?.bindBuildTools(
      BuildToolsDispatcher(
        project: proj,
        canonical: widget.canonical,
        pipeline: widget.pipeline,
        onRunBuild: _runBuildFromPreset,
        onCapturePreview: _capturePreviewBytes,
        onLayoutSnapshot: _captureLayoutSnapshotNodes,
      ),
    );
    final priorTurns = await proj.chatLog.readAll();
    widget.chat.seed(priorTurns);
    widget.llm?.seedHistory(priorTurns);
    // Per-project chat-context isolation — route the manager chat to a
    // project-scoped manager clone so the conversation doesn't carry across
    // projects (FlowBrain keys conv by agentId). See [_applyScopedManager].
    // ignore: unawaited_futures
    _applyScopedManager(proj);
  }

  /// Ensure a project-scoped manager (`<baseManager>.<projectId>`) exists and
  /// route this project's chat to it via `studioChromeBridge.chatManagerOverride`.
  /// The clone reuses the base manager's persona / model / tool scope (via
  /// `AgentHost.ensureScopedManager`); only the conversation differs → no
  /// cross-project leak. Base = the unscoped tab manager (`activeChatAgentId`).
  Future<void> _applyScopedManager(VibeProject proj) async {
    final bridge = widget.studioChromeBridge;
    if (bridge == null) return;
    String base;
    try {
      base = (bridge.activeChatAgentId.value as String?) ?? '';
    } catch (_) {
      return;
    }
    if (base.isEmpty) return;
    // Scope by the project's FULL path, not its basename — two projects with
    // the same folder name under different parents are different units and
    // must not share a conversation (the "same name ≠ same thing" rule, one
    // level down). `ensureScopedManager` sanitises it into the agent id.
    final scope = proj.projectPath;
    final qualified = await AgentHost.shared?.ensureScopedManager(base, scope);
    if (!mounted || qualified == null) return;
    _scopedManagerId = qualified;
    try {
      bridge.chatManagerOverride.value = qualified;
    } catch (_) {
      /* duck-typed bridge — swallow */
    }
  }

  String get _projectName {
    final proj = _project;
    if (proj != null) return proj.name;
    return 'No project open';
  }

  /// Compose a human-readable hint for the LLM describing the user's
  /// current focus + widget selection. Empty when nothing's selected
  /// — the adapter strips the line in that case. Includes project +
  /// active-channel context so the LLM doesn't have to ask which
  /// channel the user is looking at.
  String _selectionContextString() {
    final pieces = <String>[];
    final proj = _project;
    if (proj != null) {
      pieces.add('project = ${proj.name}');
      pieces.add('active channel = ${proj.activeChannel}');
      final enabled =
          proj.channels.entries
              .where((e) => e.value.enabled)
              .map((e) => e.key)
              .toList();
      if (enabled.length > 1) {
        pieces.add('enabled channels = ${enabled.join(", ")}');
      }
      if (_dirty) pieces.add('unsaved changes = yes');
    }
    pieces.add('focused layer = ${_focused.name}');
    if (_focused == LayerId.pages && _selectedPageId != null) {
      pieces.add('page = $_selectedPageId');
      final hash = _hashOfFocused();
      if (hash != null) pieces.add('contentHash = $hash');
      final path = _selectedWidgetPath;
      if (path != null) {
        pieces.add(
          'selected widget = /ui/pages/$_selectedPageId/content'
          '${pointerOf(path)}',
        );
      }
    } else if (_focused == LayerId.components && _selectedComponentId != null) {
      pieces.add('component = $_selectedComponentId');
      final hash = _hashOfFocused();
      if (hash != null) pieces.add('contentHash = $hash');
      final path = _selectedWidgetPath;
      if (path != null) {
        pieces.add(
          'selected widget = /ui/templates/$_selectedComponentId/content'
          '${pointerOf(path)}',
        );
      }
    }
    return pieces.join('; ');
  }

  /// Short sha256 of the focused page or component's raw map. The LLM
  /// uses this as an idempotency key — if the same hash appears in
  /// two consecutive selection contexts the underlying content hasn't
  /// changed and the LLM may skip re-reading.
  String? _hashOfFocused() {
    Map<String, dynamic>? raw;
    if (_focused == LayerId.pages && _selectedPageId != null) {
      raw = _projection.pages[_selectedPageId]?.raw;
    } else if (_focused == LayerId.components && _selectedComponentId != null) {
      raw = _projection.components.templates[_selectedComponentId];
    }
    if (raw == null) return null;
    final encoded = jsonEncode(raw);
    final digest = sha256.convert(utf8.encode(encoded)).toString();
    return digest.substring(0, 12);
  }

  /// After every projection rebuild, make sure the selected page / component
  /// id still exists. Falls back to the first available entry.
  void _resyncSelection() {
    final pageIds = _projection.pages.keys.toList();
    if (_selectedPageId == null || !pageIds.contains(_selectedPageId)) {
      _selectedPageId = pageIds.isNotEmpty ? pageIds.first : null;
    }
    final componentIds = _projection.components.templates.keys.toList();
    if (_selectedComponentId == null ||
        !componentIds.contains(_selectedComponentId)) {
      _selectedComponentId =
          componentIds.isNotEmpty ? componentIds.first : null;
    }
  }

  Future<bool> _dispatchPatch({
    required LayerId layer,
    required String path,
    required dynamic value,
  }) async {
    final result = await widget.pipeline.apply(
      CanonicalPatch(
        layer: layer,
        ops: <PatchOp>[
          if (value == null)
            PatchOp(op: 'remove', path: path)
          else
            PatchOp(op: 'replace', path: path, value: value),
        ],
        originator: const UserOriginator(note: 'properties'),
      ),
    );
    return result is PatchApplied;
  }

  /// Pick a default URL path for a new page. First page (empty
  /// routes) → `/`; otherwise `/<id>`. Falls back to `/<id>-N` if
  /// `/<id>` already exists.
  String _defaultRouteFor(String id) {
    final routes = (widget.canonical.currentJson['ui'] as Map?)?['routes'];
    final taken =
        routes is Map
            ? routes.keys.map((e) => e.toString()).toSet()
            : <String>{};
    if (taken.isEmpty) return '/';
    final base = '/$id';
    if (!taken.contains(base)) return base;
    for (var n = 2; ; n++) {
      final cand = '$base-$n';
      if (!taken.contains(cand)) return cand;
    }
  }

  /// JSON Pointer escape for a single segment per RFC 6901.
  static String _escapePtr(String s) =>
      s.replaceAll('~', '~0').replaceAll('/', '~1');

  Future<void> _addPage(BuildContext context) async {
    final id = await promptForInstanceId(
      context,
      title: 'New page id',
      hint: 'e.g. dashboard',
    );
    if (id == null) return;
    if (_projection.pages.containsKey(id)) return;
    final routeKey = _defaultRouteFor(id);
    final isFirstRoute =
        ((widget.canonical.currentJson['ui'] as Map?)?['routes'] as Map?)
            ?.isEmpty ??
        true;
    final ops = <PatchOp>[
      PatchOp(
        op: 'replace',
        path: '/ui/pages/${_escapePtr(id)}',
        value: <String, dynamic>{
          'type': 'page',
          'title': id,
          'content': <String, dynamic>{
            'type': 'box',
            'child': <String, dynamic>{'type': 'text', 'text': id},
          },
        },
      ),
      PatchOp(
        op: 'replace',
        path: '/ui/routes/${_escapePtr(routeKey)}',
        value: id,
      ),
      if (isFirstRoute)
        PatchOp(op: 'replace', path: '/ui/initialRoute', value: routeKey),
    ];
    final res = await widget.pipeline.apply(
      CanonicalPatch(
        layer: LayerId.pages,
        ops: ops,
        originator: const UserOriginator(note: 'addPage'),
      ),
    );
    if (res is PatchApplied) {
      setState(() => _selectedPageId = id);
    }
  }

  Future<void> _deletePage(String id) async {
    final routes = (widget.canonical.currentJson['ui'] as Map?)?['routes'];
    final initialRoute =
        (widget.canonical.currentJson['ui'] as Map?)?['initialRoute'];
    final ops = <PatchOp>[
      PatchOp(op: 'remove', path: '/ui/pages/${_escapePtr(id)}'),
    ];
    final removedRouteKeys = <String>[];
    if (routes is Map) {
      for (final entry in routes.entries) {
        if (entry.value == id) {
          final k = entry.key.toString();
          ops.add(PatchOp(op: 'remove', path: '/ui/routes/${_escapePtr(k)}'));
          removedRouteKeys.add(k);
        }
      }
    }
    // If the initialRoute pointed at a route we're removing, repoint
    // to the first surviving route (alphabetically) so the app still
    // boots. No-op when nothing left.
    if (initialRoute is String && removedRouteKeys.contains(initialRoute)) {
      final survivors =
          routes is Map
              ? routes.keys
                  .map((e) => e.toString())
                  .where((k) => !removedRouteKeys.contains(k))
                  .toList()
              : <String>[];
      survivors.sort();
      ops.add(
        PatchOp(
          op: 'replace',
          path: '/ui/initialRoute',
          value: survivors.isEmpty ? '' : survivors.first,
        ),
      );
    }
    await widget.pipeline.apply(
      CanonicalPatch(
        layer: LayerId.pages,
        ops: ops,
        originator: const UserOriginator(note: 'deletePage'),
      ),
    );
  }

  /// Add a route entry pointing to [pageId]. Default URL path is
  /// `/<pageId>` (or `/` when no routes exist yet); the dialog
  /// pre-fills it. If `routes` is empty we also bump
  /// `initialRoute` to the new key — same heuristic as `_addPage`,
  /// so the user gets a runnable app from a single click.
  Future<void> _addRouteForPage(BuildContext context, String pageId) async {
    final defaultPath = _defaultRouteFor(pageId);
    final path = await promptForInstanceId(
      context,
      title: 'Add route → $pageId',
      hint: defaultPath,
    );
    final pathTrim = path?.trim() ?? '';
    if (pathTrim.isEmpty) return;
    final pathKey = pathTrim.startsWith('/') ? pathTrim : '/$pathTrim';
    final routes = (widget.canonical.currentJson['ui'] as Map?)?['routes'];
    final isFirstRoute = routes is! Map || routes.isEmpty;
    if (routes is Map && routes.containsKey(pathKey)) return;
    final ops = <PatchOp>[
      PatchOp(
        op: 'replace',
        path: '/ui/routes/${_escapePtr(pathKey)}',
        value: pageId,
      ),
      if (isFirstRoute)
        PatchOp(op: 'replace', path: '/ui/initialRoute', value: pathKey),
    ];
    await widget.pipeline.apply(
      CanonicalPatch(
        layer: LayerId.appStructure,
        ops: ops,
        originator: const UserOriginator(note: 'addRoute'),
      ),
    );
  }

  Future<void> _duplicatePage(BuildContext context, String id) async {
    final source = _projection.pages[id]?.raw;
    if (source == null) return;
    final newId = await promptForInstanceId(
      context,
      title: 'Duplicate page id',
      hint: '${id}_copy',
    );
    if (newId == null) return;
    if (_projection.pages.containsKey(newId)) return;
    final routeKey = _defaultRouteFor(newId);
    final ops = <PatchOp>[
      PatchOp(
        op: 'replace',
        path: '/ui/pages/${_escapePtr(newId)}',
        value: _deepClone(source),
      ),
      PatchOp(
        op: 'replace',
        path: '/ui/routes/${_escapePtr(routeKey)}',
        value: newId,
      ),
    ];
    final res = await widget.pipeline.apply(
      CanonicalPatch(
        layer: LayerId.pages,
        ops: ops,
        originator: const UserOriginator(note: 'duplicatePage'),
      ),
    );
    if (res is PatchApplied) {
      setState(() => _selectedPageId = newId);
    }
  }

  Future<void> _addComponent(BuildContext context) async {
    final id = await promptForInstanceId(
      context,
      title: 'New template id',
      hint: 'e.g. PrimaryButton',
    );
    if (id == null) return;
    if (_projection.components.templates.containsKey(id)) return;
    final added = await _dispatchPatch(
      layer: LayerId.components,
      path: '/ui/templates/$id',
      value: <String, dynamic>{
        'name': id,
        'content': <String, dynamic>{'type': 'box'},
      },
    );
    if (added) {
      setState(() => _selectedComponentId = id);
    }
  }

  Future<void> _deleteComponent(String id) async {
    await _dispatchPatch(
      layer: LayerId.components,
      path: '/ui/templates/$id',
      value: null,
    );
  }

  Future<void> _duplicateComponent(BuildContext context, String id) async {
    final source = _projection.components.templates[id];
    if (source == null) return;
    final newId = await promptForInstanceId(
      context,
      title: 'Duplicate template id',
      hint: '${id}_copy',
    );
    if (newId == null) return;
    if (_projection.components.templates.containsKey(newId)) return;
    final cloned = Map<String, dynamic>.from(_deepClone(source) as Map);
    cloned['name'] = newId;
    final added = await _dispatchPatch(
      layer: LayerId.components,
      path: '/ui/templates/$newId',
      value: cloned,
    );
    if (added) {
      setState(() => _selectedComponentId = newId);
    }
  }

  static dynamic _deepClone(dynamic v) {
    if (v is Map) {
      return <String, dynamic>{
        for (final e in v.entries) '${e.key}': _deepClone(e.value),
      };
    }
    if (v is List) {
      return <dynamic>[for (final e in v) _deepClone(e)];
    }
    return v;
  }

  // -- Project management -------------------------------------------------

  String _defaultProjectsDir() {
    final configured = _settings.workspaceDir;
    if (configured == null || configured.isEmpty) {
      throw StateError(
        'workspaceDir is not configured. Set it via Settings → Workspace folder.',
      );
    }
    return configured;
  }

  /// Ensure the configured (or default) workspace dir exists on disk so
  /// pickers and child-path computations can lean on it.
  Future<String> _ensureWorkspaceDir() async {
    final root = _defaultProjectsDir();
    final dir = Directory(root);
    if (!await dir.exists()) {
      try {
        await dir.create(recursive: true);
      } catch (_) {
        // Ignore — picker / canonical will surface a clearer error if write
        // permission is the real problem.
      }
    }
    return root;
  }

  /// Resolve a bare project name against the configured workspace root.
  /// Absolute paths pass through; relative names land in the workspace.
  String _resolveProjectInput(String input, String root) {
    final isAbsolute = input.contains(p.separator);
    return isAbsolute ? input : p.join(root, input);
  }

  Future<void> _onNewProject(BuildContext context) async {
    final defaultParent = await _ensureWorkspaceDir();
    if (!context.mounted) return;
    final input = await promptForNewProject(
      context,
      defaultParent: defaultParent,
      kinds: appBuilderProjectKinds,
    );
    if (input == null) return;
    final dir = p.join(input.parent, input.name);
    if (await Directory(dir).exists()) {
      _toast('A project already exists at $dir');
      return;
    }
    try {
      final project = await VibeProject.openAt(
        projectDir: dir,
        canonical: widget.canonical,
        newProjectKind: projectKindFromId(input.kind),
        seedNewBundle: applyProjectSeed,
      );
      // Commit the new project skeleton (project.apbproj + empty bundle)
      // immediately so a subsequent reopen finds it on disk.
      await project.save();
      await _rebindChat(project);
      // Stop the previous project from logging stray transitions to
      // its own history.jsonl now that the canonical has been re-aimed.
      final previous = _project;
      if (!mounted) return;
      setState(() {
        _project = project;
        _selectedPageId = null;
        _selectedComponentId = null;
        _focusedByChannelMode.clear();
      });
      await previous?.dispose();
      _persistPrefs();
      await _recordRecent(project.projectPath);
    } catch (e) {
      _toast('Create project failed: $e');
    }
  }

  Future<void> _onOpenProject(BuildContext context) async {
    final initial = await _ensureWorkspaceDir();
    // Native panel — see `_pickFileOrPackage` for the rationale.
    // Empty `extensions` allows any directory or file; the caller
    // validates the picked folder against `project.apbproj` below.
    final picked = await _pickFileOrPackage(
      title: 'Open AppPlayer Builder project folder',
      initialDirectory: initial,
    );
    if (picked == null) return;
    final dir = Directory(picked);
    if (!await dir.exists()) {
      _toast('No such folder: $picked');
      return;
    }
    final hasNew = await File(p.join(picked, VibeProject.projectFile)).exists();
    final hasLegacy =
        await File(p.join(picked, VibeProject.legacyProjectFile)).exists();
    if (!hasNew && !hasLegacy) {
      _toast('Not an AppPlayer Builder project (no project.apbproj)');
      return;
    }
    try {
      final project = await VibeProject.openAt(
        projectDir: picked,
        canonical: widget.canonical,
      );
      await _rebindChat(project);
      final previous = _project;
      if (!mounted) return;
      setState(() {
        _project = project;
        _projection = LayerProjection.fromJson(widget.canonical.currentJson);
        // Defer to prefs for the focused layer + selections; fall back
        // to first-run defaults if prefs.json is missing.
        _focusedByChannelMode = _cloneFocusMap(
          project.prefs.focusedByChannelMode,
        );
        _selectedPageId = project.prefs.selectedPageId;
        _selectedComponentId = project.prefs.selectedComponentId;
        _previewEpoch++;
      });
      await previous?.dispose();
      await _recordRecent(project.projectPath);
    } catch (e, st) {
      _toast('Open project failed: $e');
      widget.chat.appendTurn(
        ChatTurn(
          role: 'error',
          text: 'Open project failed at $picked\n$e\n$st',
        ),
      );
    }
  }

  Future<void> _onSave(BuildContext context) async {
    final proj = _project;
    if (proj == null) {
      _toast('No project open');
      return;
    }
    if (!_dirty) {
      _toast('No changes to save');
      return;
    }
    try {
      await proj.save();
      _toast('Saved');
    } catch (e) {
      _toast('Save failed: $e');
    }
  }

  Future<void> _onRevert(BuildContext context) async {
    if (!_dirty) {
      _toast('No changes to revert');
      return;
    }
    final proj = _project;
    if (proj == null) {
      _toast('No project open');
      return;
    }
    final c = VibeTokens.colorOf(context);
    final ok = await showDialog<bool?>(
      context: context,
      builder:
          (ctx) => Dialog(
            backgroundColor: c.surface2,
            child: SizedBox(
              width: 360,
              child: Padding(
                padding: const EdgeInsets.all(VibeTokens.space4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      'Discard unsaved changes?',
                      style: TextStyle(
                        fontFamily: VibeTokens.fontSans,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: VibeTokens.space2),
                    Text(
                      'Reverts to the last saved state. The autosave draft will be cleared.',
                      style: TextStyle(fontSize: 12, color: c.textSecondary),
                    ),
                    const SizedBox(height: VibeTokens.space4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(false),
                          child: const Text('Keep editing'),
                        ),
                        const SizedBox(width: VibeTokens.space2),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: c.coral,
                          ),
                          onPressed: () => Navigator.of(ctx).pop(true),
                          child: const Text('Revert'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
    );
    if (ok != true) return;
    try {
      await proj.revert();
      // Defensive re-sync from the canonical's current state in the
      // same frame — the canonical fires `undoStateChanges` /
      // `dirtyChanges` asynchronously, so a stream-listener-based
      // refresh can lag behind a follow-up keypress (Cmd+Z right
      // after revert) by a microtask. Reading the getters here
      // guarantees the toolbar reflects "nothing to undo / redo"
      // before any post-revert input lands.
      if (mounted) {
        setState(() {
          _canUndo = widget.canonical.canUndo;
          _canRedo = widget.canonical.canRedo;
          _dirty = widget.canonical.isDirty;
          final active = _project?.activeChannel;
          if (active != null) _channelDirty[active] = _dirty;
        });
      }
      _toast('Reverted to last saved');
    } catch (e) {
      _toast('Revert failed: $e');
    }
  }

  Future<void> _onSaveAs(BuildContext context) async {
    final proj = _project;
    if (proj == null) {
      _toast('No project open');
      return;
    }
    final input = await promptForWorkspacePath(
      context,
      title: 'Save project as…',
      hint: 'new-project-name',
    );
    if (input == null) return;
    final root = await _ensureWorkspaceDir();
    final dir = _resolveProjectInput(input, root);
    if (await Directory(dir).exists()) {
      _toast('A project already exists at $dir');
      return;
    }
    try {
      final next = await proj.saveAs(dir);
      // The chat log was copied to the new path inside saveAs — re-bind
      // future appends without clobbering the in-memory feed (which is
      // already in sync with the copied log).
      widget.chat.onTurnPersisted = (turn) => next.chatLog.append(turn);
      widget.chat.onClearLog = () => next.chatLog.clear();
      if (!mounted) return;
      setState(() => _project = next);
      await _recordRecent(next.projectPath);
      _toast('Saved to $dir');
    } catch (e) {
      _toast('Save As failed: $e');
    }
  }

  int _enabledChannelCount() {
    final proj = _project;
    if (proj == null) return 0;
    return proj.channels.values.where((c) => c.enabled).length;
  }

  /// Open the channel diff modal — feeds it the project path + a
  /// concrete (id, label, subdir) tuple per enabled channel so the
  /// dialog doesn't need to know about the VibeProject API.
  Future<void> _onCompareChannels(BuildContext context) async {
    final proj = _project;
    if (proj == null) {
      _toast('Open or create a project first');
      return;
    }
    final entries = <({String id, String label, String subdir})>[];
    for (final id in const <String>['serving', 'native']) {
      final ch = proj.channels[id];
      if (ch == null || !ch.enabled) continue;
      entries.add((id: id, label: _channelLabel(id), subdir: ch.subdir));
    }
    if (entries.length < 2) {
      _toast('Both channels need to be enabled to compare');
      return;
    }
    await showChannelDiffDialog(
      context: context,
      projectPath: proj.projectPath,
      channels: entries,
    );
  }

  /// Resolve the active channel's bundle directory, then open the
  /// asset management dialog. Assets live outside the canonical so
  /// the dialog mutates the file system directly — see assets_dialog
  /// for the full caveat.
  Future<void> _onManageAssets(BuildContext context) async {
    final proj = _project;
    if (proj == null) {
      _toast('Open or create a project first');
      return;
    }
    final activeId = proj.activeChannel;
    final ch = proj.channels[activeId];
    if (ch == null) {
      _toast('No active channel');
      return;
    }
    final bundlePath = p.join(proj.projectPath, ch.subdir);
    await showAssetsDialog(
      context: context,
      bundlePath: bundlePath,
      channelLabel: _channelLabel(activeId),
    );
  }

  /// Bridge to the native `NSOpenPanel` registered in
  /// `macos/Runner/MainFlutterWindow.swift`. Returns the absolute path
  /// (file or `.mbd` package) the user picked, or `null` on cancel.
  /// Falls back to `null` on unsupported platforms — callers must
  /// keep their own pub `file_picker` path for those.
  // Built-in mode — host Runner (vibe_studio/macos) registers the
  // `pickFileOrPackage` handler under `vibe_studio/native_picker`.
  // The standalone app_builder_vibe Runner used a different name
  // (`app_builder_vibe/native_picker`); when running as a built-in,
  // we reach into the host's channel instead so the OS panel pops
  // through the same Swift handler.
  static const MethodChannel _nativePickerChannel = MethodChannel(
    'vibe_studio/native_picker',
  );

  Future<String?> _pickFileOrPackage({
    required String title,
    List<String> extensions = const <String>[],
    String? initialDirectory,
  }) async {
    if (!Platform.isMacOS) return null;
    final res = await _nativePickerChannel
        .invokeMethod<String>('pickFileOrPackage', <String, Object?>{
          'title': title,
          'extensions': extensions,
          if (initialDirectory != null) 'initialDirectory': initialDirectory,
        });
    return res;
  }

  Future<void> _onImportBundle(BuildContext context) async {
    final proj = _project;
    if (proj == null) {
      _toast('Open or create a project first');
      return;
    }
    final target = await _pickChannelTarget(
      context,
      proj: proj,
      title: 'Import .mbd into…',
      isImport: true,
    );
    if (target == null) return;
    if (!context.mounted) return;
    // `.mbd` is a `com.apple.package` UTI (declared by vibe_studio's
    // Info.plist and seen system-wide via LaunchServices). The
    // `file_picker` pub plugin's directory mode rejects packages, and
    // its file mode forces `canChooseDirectories=false` so package
    // selection doesn't surface either. Use a native NSOpenPanel via
    // method channel — the same pattern vibe_studio uses
    // (`MainFlutterWindow.swift` `pickFileOrPackage`) — which sets
    // `canChooseFiles=true && canChooseDirectories=true &&
    // treatsFilePackagesAsDirectories=false`, so `.mbd` packages are
    // selectable as a single item.
    final picked = await _pickFileOrPackage(
      title: 'Import .mbd bundle',
      extensions: const <String>['mbd'],
    );
    if (picked == null) return;
    if (!await File(p.join(picked, 'manifest.json')).exists()) {
      _toast('Not an mcp_ui bundle (no manifest.json)');
      return;
    }
    final peek = await peekMbd(picked);
    if (peek == null) {
      _toast('Could not read source bundle');
      return;
    }
    if (!context.mounted) return;
    // Existing TARGET channel ids — informs collision badges in the
    // picker. We re-read disk for the chosen target instead of using
    // `_projection`, because the user may have picked a non-active
    // channel (or an empty channel that shares an id pool with the
    // active one but has different content). Reading
    // `_projection.pages` would surface the wrong "already exists"
    // markers — that's the bug reported as "native shows serving's
    // collisions".
    final targetProjection = await _readTargetProjection(proj, target);
    final existingPages = targetProjection.pages.keys.toSet();
    final existingTemplates =
        targetProjection.components.templates.keys.toSet();
    final hasDashboard = targetProjection.dashboard != null;
    final existingPagesData = <String, Map<String, dynamic>>{
      for (final entry in targetProjection.pages.entries)
        entry.key: entry.value.raw,
    };
    final existingTemplatesData = Map<String, Map<String, dynamic>>.from(
      targetProjection.components.templates,
    );
    final existingDashboardData = targetProjection.dashboard?.raw;
    // Target bundle's theme block — fed into the diff preview so the
    // CURRENT slot wraps its render in the project's actual colour
    // scheme + typography (instead of Flutter defaults).
    final existingThemeData = targetProjection.lookup('/ui/theme');
    if (!context.mounted) return;
    final selection = await showImportSelectionDialog(
      context: context,
      channelLabel: _channelLabel(target),
      sourcePath: picked,
      peek: peek,
      existingPageIds: existingPages,
      existingTemplateIds: existingTemplates,
      targetHasDashboard: hasDashboard,
      existingPages: existingPagesData,
      existingTemplates: existingTemplatesData,
      existingDashboard: existingDashboardData,
      targetTheme:
          existingThemeData is Map
              ? Map<String, dynamic>.from(existingThemeData)
              : null,
    );
    if (selection == null) return;
    // Both paths route through the patch pipeline so the user can
    // undo. Activate the target channel first when it's a different
    // slot — the active canonical is what the pipeline writes into.
    if (target != proj.activeChannel) {
      try {
        await proj.activateChannel(target);
      } catch (_) {
        // Channel was disabled — materialise it (creates the bundle
        // dir, marks enabled, opens canonical) and continue.
        await proj.createChannel(target);
      }
    }
    if (!selection.isPartial) {
      // Whole-bundle replace path — but as a single atomic patch so
      // the user can undo. Confirm overwrite first when the channel
      // already had content.
      final ch = proj.channels[target];
      final overwriting = ch?.enabled == true && _projection.pages.isNotEmpty;
      if (overwriting) {
        if (!context.mounted) return;
        final ok = await _confirmDestructive(
          context,
          title: 'Overwrite ${_channelLabel(target)} channel?',
          body:
              'Importing replaces the bundle UI inside this project. '
              'Save to commit, Undo to revert.',
          confirmLabel: 'Continue',
        );
        if (ok != true) return;
      }
      try {
        final beforeHash = await widget.canonical.hash();
        final applied = await _applyWholeImport(picked);
        final afterHash = await widget.canonical.hash();
        final changed = applied && beforeHash != afterHash;
        if (!mounted) return;
        setState(() {
          _selectedPageId = null;
          _selectedComponentId = null;
          _selectedWidgetPath = null;
          _focused = LayerId.appStructure;
        });
        _toast(
          changed
              ? 'Imported into ${_channelLabel(target)} '
                  '(unsaved — Save to commit)'
              : 'Already up to date — no changes',
        );
      } catch (e) {
        _toast('Import failed: $e');
      }
      return;
    }
    // Partial merge — selected items only.
    try {
      final beforeHash = await widget.canonical.hash();
      final applied = await _applyPartialImport(peek, selection);
      final afterHash = await widget.canonical.hash();
      final changed = beforeHash != afterHash;
      if (!mounted) return;
      _toast(
        applied == 0
            ? 'Nothing to merge — every selected item was a skipped collision'
            : changed
            ? 'Merged $applied item${applied == 1 ? '' : 's'} '
                'into ${_channelLabel(target)} '
                '(unsaved — Save to commit)'
            : 'Already up to date — no changes',
      );
    } catch (e) {
      _toast('Merge failed: $e');
    }
  }

  /// Read the source `.mbd` and replace the active canonical's `/ui`
  /// block + `/manifest/assets` in one atomic patch. Goes through the
  /// same pipeline path as editor mutations so Undo can roll the
  /// whole import back. Also copies the source's `assets/` files
  /// onto disk so file-backed asset entries resolve at runtime.
  Future<bool> _applyWholeImport(String sourcePath) async {
    final fs = FileWorkspaceFsPort();
    final source = await fs.readJson(sourcePath);
    if (source == null) {
      throw StateError('Source bundle could not be read');
    }
    final ui = source['ui'];
    if (ui is! Map) {
      throw StateError('Source bundle has no `ui` content');
    }
    final ops = <PatchOp>[
      PatchOp(
        op: 'replace',
        path: '/ui',
        value: _deepClone(Map<String, dynamic>.from(ui)),
      ),
    ];
    final manifest = source['manifest'];
    final assetsSection = manifest is Map ? manifest['assets'] : null;
    if (assetsSection is Map) {
      ops.add(
        PatchOp(
          op: 'replace',
          path: '/manifest/assets',
          value: _deepClone(Map<String, dynamic>.from(assetsSection)),
        ),
      );
      // Copy file-backed asset bytes — entries with a `path` need
      // their bytes available under target's `assets/<path>` for the
      // runtime to resolve at startup.
      await _copyAssetFiles(
        sourcePath: sourcePath,
        ids: null, // null = all asset entries that have a path
      );
    }
    final result = await widget.pipeline.apply(
      CanonicalPatch(
        layer: LayerId.whole,
        ops: ops,
        originator: const UserOriginator(note: 'import.whole'),
      ),
    );
    return result is PatchApplied;
  }

  /// Translate the user's [ImportSelection] into one atomic patch
  /// against the canonical so the entire merge is a single undo unit.
  /// Returns the number of items that landed (skips count as 0).
  Future<int> _applyPartialImport(MbdPeek peek, ImportSelection sel) async {
    final existingPages = _projection.pages.keys.toSet();
    final existingTemplates = _projection.components.templates.keys.toSet();
    final ops = <PatchOp>[];
    var itemCount = 0;

    for (final id in sel.pages) {
      final page = peek.pages[id];
      if (page == null) continue;
      final exists = existingPages.contains(id);
      if (exists && !sel.replaceOnConflict) continue;
      ops.add(
        PatchOp(op: 'replace', path: '/ui/pages/$id', value: _deepClone(page)),
      );
      itemCount++;
    }

    for (final id in sel.templates) {
      final tpl = peek.templates[id];
      if (tpl == null) continue;
      final exists = existingTemplates.contains(id);
      if (exists && !sel.replaceOnConflict) continue;
      ops.add(
        PatchOp(
          op: 'replace',
          path: '/ui/templates/$id',
          value: _deepClone(tpl),
        ),
      );
      itemCount++;
    }

    if (sel.includeDashboard && peek.dashboard != null) {
      final hadDashboard = _projection.dashboard != null;
      if (!hadDashboard || sel.replaceOnConflict) {
        ops.add(
          PatchOp(
            op: 'replace',
            path: '/ui/dashboard',
            value: _deepClone(peek.dashboard!),
          ),
        );
        itemCount++;
      }
    }

    if (sel.includeTheme && peek.theme != null) {
      ops.add(
        PatchOp(
          op: 'replace',
          path: '/ui/theme',
          value: _deepClone(peek.theme!),
        ),
      );
      itemCount++;
    }

    if (sel.includeNavigation && peek.navigation != null) {
      ops.add(
        PatchOp(
          op: 'replace',
          path: '/ui/navigation',
          value: _deepClone(peek.navigation!),
        ),
      );
      itemCount++;
    }

    // Asset merge — both the manifest entries and (where present) the
    // backing files inside `<bundle>/assets/<path>`. Entry-level
    // collision uses `replaceOnConflict` against the existing target
    // assets; file-level collision is overwrite-on-replace.
    if (sel.assets.isNotEmpty) {
      final existingAssetsRaw =
          (widget.canonical.currentJson['manifest'] as Map?)?['assets'];
      final existingEntries = <Map<String, dynamic>>[];
      Map<String, dynamic> existingSection = <String, dynamic>{};
      if (existingAssetsRaw is Map) {
        existingSection = Map<String, dynamic>.from(existingAssetsRaw);
        final list = existingSection['assets'];
        if (list is List) {
          existingEntries.addAll(
            list.whereType<Map>().map((m) => Map<String, dynamic>.from(m)),
          );
        }
      }
      final byId = <String, Map<String, dynamic>>{
        for (final e in existingEntries)
          if (e['id'] is String) '${e['id']}': e,
      };
      final copyIds = <String>[];
      for (final id in sel.assets) {
        final entry = peek.assets[id];
        if (entry == null) continue;
        final exists = byId.containsKey(id);
        if (exists && !sel.replaceOnConflict) continue;
        byId[id] = Map<String, dynamic>.from(entry);
        if (entry['path'] is String) copyIds.add(id);
        itemCount++;
      }
      // Build the new section: keep schemaVersion / directories /
      // bundles, replace the entries list with the merged set.
      existingSection['assets'] = byId.values.toList(growable: false);
      if (!existingSection.containsKey('schemaVersion')) {
        existingSection['schemaVersion'] = '1.0.0';
      }
      ops.add(
        PatchOp(
          op: 'replace',
          path: '/manifest/assets',
          value: existingSection,
        ),
      );
      if (copyIds.isNotEmpty) {
        await _copyAssetFiles(
          sourcePath: peek.sourcePath,
          ids: copyIds.toSet(),
          peek: peek,
        );
      }
    }

    if (ops.isEmpty) return 0;
    final result = await widget.pipeline.apply(
      CanonicalPatch(
        layer: LayerId.whole,
        ops: ops,
        originator: const UserOriginator(note: 'import.partial'),
      ),
    );
    return result is PatchApplied ? itemCount : 0;
  }

  Future<void> _onExportBundle(BuildContext context) async {
    final proj = _project;
    if (proj == null) {
      _toast('No project open');
      return;
    }
    final target = await _pickChannelTarget(
      context,
      proj: proj,
      title: 'Export .mbd from…',
      isImport: false,
    );
    if (target == null) return;
    if (!context.mounted) return;
    // Build a projection for the chosen channel — when exporting a
    // non-active channel we need to read its disk state, not the
    // currently focused projection.
    final source = await _readTargetProjection(proj, target);
    if (!context.mounted) return;
    final selection = await showExportSelectionDialog(
      context: context,
      channelLabel: _channelLabel(target),
      source: source,
    );
    if (selection == null) return;
    if (!context.mounted) return;
    final initial = await _ensureWorkspaceDir();
    if (!context.mounted) return;
    final picked = await _pickFileOrPackage(
      title: 'Export .mbd to…',
      initialDirectory: initial,
    );
    if (picked == null) return;
    final dest = picked.endsWith('.mbd') ? picked : '$picked.mbd';
    if (await Directory(dest).exists()) {
      if (!mounted) return;
      final ok = await _confirmDestructive(
        this.context,
        title: 'Overwrite existing bundle?',
        body: '$dest already exists.',
        confirmLabel: 'Overwrite',
      );
      if (ok != true) return;
    }
    try {
      if (selection.everything) {
        await proj.exportBundle(dest, sourceChannel: target);
      } else {
        await _exportPartial(
          proj: proj,
          channelId: target,
          dest: dest,
          selection: selection,
          source: source,
        );
      }
      _toast('Exported ${_channelLabel(target)} → $dest');
    } catch (e) {
      _toast('Export failed: $e');
    }
  }

  /// Build a fresh `.mbd` at [dest] containing only the slices
  /// described by [selection]. Mirrors the import partial-merge
  /// algorithm: clone source manifest / ui filtered to picked items,
  /// copy file-backed asset bytes for chosen assets, write the
  /// resulting manifest.json + ui/ tree to disk. The destination is
  /// wiped before writing — the user already confirmed overwrite.
  Future<void> _exportPartial({
    required VibeProject proj,
    required String channelId,
    required String dest,
    required ExportSelection selection,
    required LayerProjection source,
  }) async {
    final sourceBundle = proj.bundlePathFor(channelId);
    if (sourceBundle == null) {
      throw StateError('Channel "$channelId" has no bundle path');
    }
    // Re-read the source manifest from disk so identity / asset
    // section / unknown extensions round-trip without lossy
    // re-projection.
    final fs = FileWorkspaceFsPort();
    final sourceJson = await fs.readJson(sourceBundle);
    if (sourceJson == null) {
      throw StateError('Channel "$channelId" bundle could not be read');
    }
    final manifest = sourceJson['manifest'];
    final uiSrc = sourceJson['ui'];
    final outManifest = <String, dynamic>{};
    if (selection.includeManifestMeta && manifest is Map) {
      for (final entry in manifest.entries) {
        if (entry.key == 'assets') continue; // re-built below
        outManifest[entry.key.toString()] = _deepClone(entry.value);
      }
    }
    final outUi = <String, dynamic>{};
    if (uiSrc is Map) {
      // Always carry the discriminator so the runtime parses the
      // result as an Application.
      outUi['type'] = uiSrc['type'] ?? 'application';
      // Always include identity-ish fields when present so the
      // exported bundle is self-contained.
      for (final k in const <String>[
        'title',
        'description',
        'version',
        'initialRoute',
      ]) {
        if (uiSrc[k] != null) outUi[k] = _deepClone(uiSrc[k]);
      }
      if (selection.pages.isNotEmpty) {
        final outPages = <String, dynamic>{};
        for (final id in selection.pages) {
          final page = source.pages[id]?.raw;
          if (page != null) outPages[id] = _deepClone(page);
        }
        outUi['pages'] = outPages;
        // Filter routes to the picked pages so the exported bundle
        // doesn't reference pages it didn't carry.
        final routesSrc = uiSrc['routes'];
        if (routesSrc is Map) {
          final outRoutes = <String, dynamic>{};
          routesSrc.forEach((k, v) {
            if (selection.pages.contains(v)) {
              outRoutes[k.toString()] = v;
            }
          });
          outUi['routes'] = outRoutes;
        }
      }
      if (selection.templates.isNotEmpty) {
        final outTpl = <String, dynamic>{};
        for (final id in selection.templates) {
          final tpl = source.components.templates[id];
          if (tpl != null) outTpl[id] = _deepClone(tpl);
        }
        outUi['templates'] = outTpl;
      }
      if (selection.includeDashboard && uiSrc['dashboard'] is Map) {
        outUi['dashboard'] = _deepClone(uiSrc['dashboard']);
      }
      if (selection.includeTheme && uiSrc['theme'] is Map) {
        outUi['theme'] = _deepClone(uiSrc['theme']);
      }
      if (selection.includeNavigation && uiSrc['navigation'] is Map) {
        outUi['navigation'] = _deepClone(uiSrc['navigation']);
      }
    }
    if (selection.assets.isNotEmpty) {
      final assetSection = manifest is Map ? manifest['assets'] : null;
      final entries = assetSection is Map ? assetSection['assets'] : null;
      final filteredEntries = <Map<String, dynamic>>[];
      if (entries is List) {
        for (final raw in entries) {
          if (raw is! Map) continue;
          final id = raw['id'];
          if (id is String && selection.assets.contains(id)) {
            filteredEntries.add(Map<String, dynamic>.from(raw));
          }
        }
      }
      outManifest['assets'] = <String, dynamic>{
        'schemaVersion':
            assetSection is Map && assetSection['schemaVersion'] is String
                ? assetSection['schemaVersion']
                : '1.0.0',
        'assets': filteredEntries,
      };
    }
    final root = <String, dynamic>{
      if (outManifest.isNotEmpty) 'manifest': outManifest,
      if (outUi.isNotEmpty) 'ui': outUi,
    };
    final destDir = Directory(dest);
    if (await destDir.exists()) {
      await destDir.delete(recursive: true);
    }
    await fs.writeAtomicJson(root, dest);
    // Copy file-backed asset bytes for picked assets.
    if (selection.assets.isNotEmpty) {
      final assetSection = manifest is Map ? manifest['assets'] : null;
      final entries = assetSection is Map ? assetSection['assets'] : null;
      if (entries is List) {
        for (final raw in entries) {
          if (raw is! Map) continue;
          final id = raw['id'];
          final relPath = raw['path'];
          if (id is! String || relPath is! String || relPath.isEmpty) {
            continue;
          }
          if (!selection.assets.contains(id)) continue;
          try {
            final src = File(p.join(sourceBundle, relPath));
            if (!await src.exists()) continue;
            final destFile = File(p.join(dest, relPath));
            await destFile.parent.create(recursive: true);
            await src.copy(destFile.path);
          } catch (_) {
            /* best effort */
          }
        }
      }
    }
  }

  static String _channelLabel(String id) {
    switch (id) {
      case 'serving':
        return 'Serving';
      case 'native':
        return 'Native';
      default:
        return id;
    }
  }

  /// Ask the user which channel an Import / Export operation should
  /// target. For import, includes disabled slots labelled `(create)`.
  /// For export, only enabled channels are offered. Returns null when
  /// the user cancels.
  Future<String?> _pickChannelTarget(
    BuildContext context, {
    required VibeProject proj,
    required String title,
    required bool isImport,
  }) async {
    final c = VibeTokens.colorOf(context);
    final entries = <_ChannelChoice>[];
    for (final id in const <String>['serving', 'native']) {
      final ch = proj.channels[id];
      if (ch == null) continue;
      if (!isImport && !ch.enabled) continue;
      entries.add(
        _ChannelChoice(
          id: id,
          label: _channelLabel(id),
          action: ch.enabled ? (isImport ? 'overwrite' : 'export') : 'create',
        ),
      );
    }
    if (entries.isEmpty) return null;
    if (entries.length == 1) return entries.first.id;
    String selected =
        proj.channels[proj.activeChannel]?.enabled == true
            ? proj.activeChannel
            : entries.first.id;
    return showDialog<String?>(
      context: context,
      builder:
          (ctx) => Dialog(
            backgroundColor: c.surface2,
            child: SizedBox(
              width: 360,
              child: StatefulBuilder(
                builder:
                    (ctx, setLocal) => Padding(
                      padding: const EdgeInsets.all(VibeTokens.space4),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Text(
                            title,
                            style: TextStyle(
                              fontFamily: VibeTokens.fontSans,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: c.textPrimary,
                            ),
                          ),
                          const SizedBox(height: VibeTokens.space3),
                          for (final e in entries)
                            InkWell(
                              onTap: () => setLocal(() => selected = e.id),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 6,
                                ),
                                child: Row(
                                  children: <Widget>[
                                    Icon(
                                      selected == e.id
                                          ? Icons.radio_button_checked
                                          : Icons.radio_button_unchecked,
                                      size: 16,
                                      color:
                                          selected == e.id
                                              ? c.mint
                                              : c.textSecondary,
                                    ),
                                    const SizedBox(width: VibeTokens.space2),
                                    Text(
                                      '${e.label} (${e.action})',
                                      style: vibeMono(
                                        size: 12,
                                        color: c.textPrimary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          const SizedBox(height: VibeTokens.space3),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: <Widget>[
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(null),
                                child: const Text('Cancel'),
                              ),
                              const SizedBox(width: VibeTokens.space2),
                              FilledButton(
                                onPressed:
                                    () => Navigator.of(ctx).pop(selected),
                                child: const Text('Continue'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
              ),
            ),
          ),
    );
  }

  Future<bool?> _confirmDestructive(
    BuildContext context, {
    required String title,
    required String body,
    required String confirmLabel,
  }) {
    final c = VibeTokens.colorOf(context);
    return showDialog<bool?>(
      context: context,
      builder:
          (ctx) => Dialog(
            backgroundColor: c.surface2,
            child: SizedBox(
              width: 360,
              child: Padding(
                padding: const EdgeInsets.all(VibeTokens.space4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      title,
                      style: TextStyle(
                        fontFamily: VibeTokens.fontSans,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: VibeTokens.space2),
                    Text(
                      body,
                      style: TextStyle(fontSize: 12, color: c.textSecondary),
                    ),
                    const SizedBox(height: VibeTokens.space4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(false),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: VibeTokens.space2),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: c.coral,
                          ),
                          onPressed: () => Navigator.of(ctx).pop(true),
                          child: Text(confirmLabel),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
    );
  }

  Future<void> _onUndo() async {
    final ok = await widget.canonical.undo();
    if (!ok) _toast('Nothing to undo');
  }

  Future<void> _onRedo() async {
    final ok = await widget.canonical.redo();
    if (!ok) _toast('Nothing to redo');
  }

  Future<void> _onBuild(BuildContext context) =>
      _openBuildDialog(context, mode: BuildDialogMode.previewBuild);

  Future<void> _onBuildSettings(BuildContext context) =>
      _openBuildDialog(context, mode: BuildDialogMode.settingsOnly);

  /// Show the Clean dialog (mirrors Build's target picker), wipe the
  /// chosen `build/<target>/` (or whole `build/`), then `setState` so
  /// dependent panels — notably the Inspector's variant cards — re-
  /// scan the directory and reflect the change immediately.
  Future<void> _onCleanBuild(BuildContext context) async {
    final proj = _project;
    if (proj == null) {
      _toast('No project open');
      return;
    }
    final req = await showCleanDialog(
      context,
      projectPath: proj.projectPath,
      lastTarget: proj.prefs.buildConfig?.target,
    );
    if (req == null) return;
    try {
      final deleted = await proj.cleanBuild(target: req.target);
      if (!mounted) return;
      // Force the shell + inspector card to rebuild — `_DiscoveredVariant`
      // is computed inside InspectorPanel.build by `Directory(...).existsSync()`,
      // so it picks up the freshly-deleted folders on the next rebuild.
      setState(() {});
      final label = req.target == null ? 'build/' : 'build/${req.target}/';
      _toast(
        deleted.isEmpty
            ? 'Nothing to clean — $label was already empty'
            : 'Cleaned $label',
      );
    } catch (e) {
      _toast('Clean failed: $e');
    }
  }

  /// Shared body for the Build / Build settings header buttons. The
  /// dialog mode controls which footer buttons appear; everything
  /// else (preset hydrate, Save persistence, build pipeline on
  /// `saveAndBuild`) is identical.
  Future<void> _openBuildDialog(
    BuildContext context, {
    required BuildDialogMode mode,
  }) async {
    final proj = _project;
    if (proj == null) {
      _toast('No project open');
      return;
    }
    if (_dirty) {
      try {
        await proj.save();
      } catch (e) {
        _toast('Save before build failed: $e');
        return;
      }
    }
    if (!mounted) return;
    final enabledChannels = <String>[
      for (final entry in proj.channels.entries)
        if (entry.value.enabled) entry.key,
    ];
    final saved = proj.prefs.buildConfig;
    final request = await showBuildDialog(
      this.context,
      projectName: proj.name,
      projectPath: proj.projectPath,
      availableChannels: enabledChannels,
      activeChannel: proj.activeChannel,
      mode: mode,
      initialTarget: saved == null ? null : buildTargetFromSlug(saved.target),
      initialChannel: saved?.channel,
      initialOutDir: saved?.outDir,
      initialRunFlutterCreate: saved?.runFlutterCreate,
    );
    if (request == null) return;
    // Persist the user's selection as the project's build preset so
    // re-opening the dialog (or an LLM driving via MCP) sees the same
    // values without asking. Done for both Save-only and Save+Build —
    // the action flag below decides whether we also run the pipeline.
    proj.prefs.buildConfig = BuildConfig(
      target: buildTargetSlug(request.target),
      channel: request.bundleChannel,
      outDir: request.outDir,
      runFlutterCreate: request.runFlutterCreate,
    );
    try {
      await proj.savePrefs();
    } catch (_) {
      /* prefs persistence is best-effort */
    }
    if (request.action == BuildAction.saveOnly) {
      _toast('Build settings saved');
      return;
    }
    try {
      final src = proj.bundlePathFor(request.bundleChannel) ?? proj.bundlePath;
      final outDir = Directory(request.outDir);
      await outDir.create(recursive: true);
      if (request.target == BuildTarget.mcpb) {
        final bytes = await McpBundlePacker.packDirectory(src);
        // Filename = manifest name (preferred) or project name,
        // sluggified. Falls back to "bundle" so we always produce
        // something.
        final manifest = proj.canonical.currentJson['manifest'];
        final manifestName =
            manifest is Map ? manifest['name'] as String? : null;
        final slug = _slugForBundle(
          (manifestName ?? '').trim().isNotEmpty ? manifestName! : proj.name,
        );
        final fileName = '${slug.isEmpty ? 'bundle' : slug}.mcpb';
        final file = File(p.join(outDir.path, fileName));
        await file.writeAsBytes(bytes, flush: true);
        if (!mounted) return;
        await _showBuildSuccessDialog(
          target: 'mcpb',
          artifacts: <String>[file.path],
          sizeBytes: bytes.length,
        );
        return;
      }
      // Dart-source targets — load the chosen channel's canonical from
      // disk (which may differ from the active canonical when the user
      // is building a non-active channel). Active channel reuses the
      // in-memory canonical so any post-save touch-ups are preserved.
      final dartTarget = _dartTargetFor(request.target);
      final canonical =
          request.bundleChannel == proj.activeChannel
              ? proj.canonical.current
              : await McpBundleLoader.loadDirectory(src);
      final result = await DartConverterImpl().run(
        canonical: canonical,
        target: dartTarget,
        outDir: outDir.path,
        sourceBundlePath: src,
      );
      var totalBytes = 0;
      for (final f in result.writtenFiles) {
        final entity = FileSystemEntity.typeSync(f);
        if (entity == FileSystemEntityType.file) {
          totalBytes += await File(f).length();
        }
      }
      var artifacts = List<String>.from(result.writtenFiles);
      String? flutterMessage;
      if (request.runFlutterCreate &&
          (request.target == BuildTarget.nativeBundle ||
              request.target == BuildTarget.nativeInline)) {
        final flutterOutcome = await _runFlutterCreate(
          outDir: outDir.path,
          projectName: _flutterProjectNameFor(
            target: request.target,
            project: proj,
          ),
        );
        flutterMessage = flutterOutcome.message;
        if (flutterOutcome.scaffoldedDirs.isNotEmpty) {
          artifacts = <String>[...artifacts, ...flutterOutcome.scaffoldedDirs];
        }
      }
      if (!mounted) return;
      await _showBuildSuccessDialog(
        target: dartTarget.name,
        artifacts: artifacts,
        sizeBytes: totalBytes,
        footer: flutterMessage,
      );
    } catch (e) {
      _toast('Build failed: $e');
      widget.chat.appendTurn(ChatTurn(role: 'error', text: 'build failed: $e'));
    }
  }

  /// Headless equivalent of the GUI Build button — runs the saved
  /// preset (with optional per-call overrides) without opening the
  /// dialog. Wired into [BuildToolsDispatcher.onRunBuild] so the
  /// chat LLM's `run_build` tool can ship an artifact directly.
  /// Auto-saves the canonical first to mirror the GUI behaviour.
  Future<Map<String, dynamic>> _runBuildFromPreset({
    String? target,
    String? channel,
    String? outDir,
  }) async {
    final proj = _project;
    if (proj == null) {
      throw StateError('no project open');
    }
    if (_dirty) {
      await proj.save();
    }
    final preset = proj.prefs.buildConfig;
    final targetSlug = target ?? preset?.target;
    if (targetSlug == null) {
      throw ArgumentError(
        'No build preset saved and no `target` argument given. '
        'Use the GUI Build dialog once to save a preset.',
      );
    }
    final dartTarget = _dartTargetForSlug(targetSlug);
    final channelId = channel ?? preset?.channel ?? proj.activeChannel;
    final ch = proj.channels[channelId];
    if (ch == null) {
      throw ArgumentError.value(channelId, 'channel', 'unknown channel');
    }
    final src = p.join(proj.projectPath, ch.subdir);
    final resolvedOutDir =
        outDir ?? preset?.outDir ?? p.join('build', targetSlug);
    final outDirAbs =
        p.isAbsolute(resolvedOutDir)
            ? resolvedOutDir
            : p.join(proj.projectPath, resolvedOutDir);
    final outDirHandle = Directory(outDirAbs);
    await outDirHandle.create(recursive: true);
    if (dartTarget == DartTarget.mcpb) {
      final bytes = await McpBundlePacker.packDirectory(src);
      final manifest = proj.canonical.currentJson['manifest'];
      final manifestName = manifest is Map ? manifest['name'] as String? : null;
      final slug = _slugForBundle(
        (manifestName ?? '').trim().isNotEmpty ? manifestName! : proj.name,
      );
      final fileName = '${slug.isEmpty ? 'bundle' : slug}.mcpb';
      final outFile = File(p.join(outDirAbs, fileName));
      await outFile.writeAsBytes(bytes, flush: true);
      // Broadcast for chat history parity with the GUI path.
      widget.chat.appendTurn(
        ChatTurn(
          role: 'system',
          text:
              'build · mcpb · 1 artifact · ${(bytes.length / 1024).toStringAsFixed(1)} KB\n${outFile.path}',
        ),
      );
      return <String, dynamic>{
        'target': 'mcpb',
        'channel': channelId,
        'outDir': outDirAbs,
        'writtenFiles': <String>[outFile.path],
        'sizeBytes': bytes.length,
      };
    }
    final canonical =
        channelId == proj.activeChannel
            ? proj.canonical.current
            : await McpBundleLoader.loadDirectory(src);
    final result = await DartConverterImpl().run(
      canonical: canonical,
      target: dartTarget,
      outDir: outDirAbs,
      sourceBundlePath: src,
    );
    var totalBytes = 0;
    for (final f in result.writtenFiles) {
      final entity = FileSystemEntity.typeSync(f);
      if (entity == FileSystemEntityType.file) {
        totalBytes += await File(f).length();
      }
    }
    widget.chat.appendTurn(
      ChatTurn(
        role: 'system',
        text:
            'build · ${dartTarget.name} · ${result.writtenFiles.length} artifact'
            '${result.writtenFiles.length == 1 ? '' : 's'} · '
            '${(totalBytes / 1024).toStringAsFixed(1)} KB',
      ),
    );
    return <String, dynamic>{
      'target': targetSlug,
      'channel': channelId,
      'outDir': result.outDir,
      'writtenFiles': result.writtenFiles,
      'sizeBytes': totalBytes,
    };
  }

  /// Map a target slug string onto [DartTarget].
  static DartTarget _dartTargetForSlug(String slug) {
    switch (slug) {
      case 'mcpb':
        return DartTarget.mcpb;
      case 'bundle':
        return DartTarget.bundle;
      case 'inline':
        return DartTarget.inline;
      case 'native_bundle':
        return DartTarget.nativeBundle;
      case 'native_inline':
        return DartTarget.nativeInline;
      default:
        throw ArgumentError.value(slug, 'target', 'unknown target slug');
    }
  }

  /// Map the dialog's [BuildTarget] onto the converter's [DartTarget].
  /// One-to-one — the dialog enum is purely the UI layer.
  static DartTarget _dartTargetFor(BuildTarget t) {
    switch (t) {
      case BuildTarget.mcpb:
        return DartTarget.mcpb;
      case BuildTarget.bundle:
        return DartTarget.bundle;
      case BuildTarget.inline:
        return DartTarget.inline;
      case BuildTarget.nativeBundle:
        return DartTarget.nativeBundle;
      case BuildTarget.nativeInline:
        return DartTarget.nativeInline;
    }
  }

  /// Pubspec-safe slug for the Flutter app emitted alongside the
  /// generated `main.dart`. Mirrors `DartConverterImpl._slug` rules so
  /// `flutter create --project-name` agrees with the generated
  /// pubspec's `name:` field.
  static String _flutterProjectNameFor({
    required BuildTarget target,
    required VibeProject project,
  }) {
    final manifest = project.canonical.currentJson['manifest'];
    final raw =
        manifest is Map
            ? (manifest['name'] as String?) ?? project.name
            : project.name;
    final cleaned = raw
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9_]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final base = cleaned.isEmpty ? 'app' : cleaned;
    final withLeading = RegExp(r'^[a-z]').hasMatch(base) ? base : 'app_$base';
    final variant =
        target == BuildTarget.nativeBundle
            ? '_native_bundle'
            : '_native_inline';
    return '$withLeading$variant';
  }

  /// Run `flutter create --project-name <slug> .` inside [outDir].
  /// Returns a human-readable summary of what happened — success
  /// message, skip reason (already scaffolded / flutter missing), or
  /// failure detail. The generated layout is standard Flutter
  /// (`lib/main.dart`), so flutter create finds the entry point with
  /// no `-t` flag. Best-effort: we never fail the build when
  /// scaffolding misbehaves; the emitted Dart sources are still valid.
  Future<_FlutterCreateOutcome> _runFlutterCreate({
    required String outDir,
    required String projectName,
  }) async {
    // Skip when platform scaffolding is already present so repeat
    // builds stay fast and idempotent.
    final existing = <String>[
      for (final dir in const <String>[
        'android',
        'ios',
        'macos',
        'linux',
        'windows',
        'web',
      ])
        if (Directory(p.join(outDir, dir)).existsSync()) dir,
    ];
    if (existing.isNotEmpty) {
      return _FlutterCreateOutcome(
        message:
            'flutter create skipped — '
            '${existing.join(', ')} already scaffolded.',
        scaffoldedDirs: const <String>[],
      );
    }
    final resolved = await _resolveOnPath('flutter');
    if (resolved == null) {
      return const _FlutterCreateOutcome(
        message:
            'flutter create skipped — `flutter` not on PATH. '
            'Install Flutter and rerun, or run '
            '`flutter create --project-name <slug> .` '
            'manually inside the build folder.',
        scaffoldedDirs: <String>[],
      );
    }
    Process process;
    try {
      process = await Process.start(
        resolved,
        <String>['create', '--project-name', projectName, '.'],
        workingDirectory: outDir,
        runInShell: false,
      );
    } on ProcessException catch (e) {
      return _FlutterCreateOutcome(
        message: 'flutter create failed to spawn: ${e.message}',
        scaffoldedDirs: const <String>[],
      );
    }
    final stdoutFut = process.stdout.transform(utf8.decoder).join();
    final stderrFut = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    await stdoutFut;
    final stderr = await stderrFut;
    if (code != 0) {
      final tail = stderr.trim();
      return _FlutterCreateOutcome(
        message:
            'flutter create exited $code'
            '${tail.isEmpty ? '' : ' — ${_oneLine(tail)}'}',
        scaffoldedDirs: const <String>[],
      );
    }
    final scaffolded = <String>[
      for (final dir in const <String>[
        'android',
        'ios',
        'macos',
        'linux',
        'windows',
        'web',
      ])
        if (Directory(p.join(outDir, dir)).existsSync()) p.join(outDir, dir),
    ];
    return _FlutterCreateOutcome(
      message:
          'flutter create added '
          '${scaffolded.length} platform folder(s).',
      scaffoldedDirs: scaffolded,
    );
  }

  /// Walk PATH for an executable, including bare names. Mirrors
  /// `BuildToolsDispatcher._resolveExecutable` minus the project-root
  /// scoping (flutter is a host-installed tool, not a project file).
  static Future<String?> _resolveOnPath(String command) async {
    if (p.isAbsolute(command)) {
      return await File(command).exists() ? command : null;
    }
    final pathEnv = Platform.environment['PATH'] ?? '';
    final separator = Platform.isWindows ? ';' : ':';
    final exts =
        Platform.isWindows
            ? (Platform.environment['PATHEXT']?.split(';') ??
                <String>['.EXE', '.BAT', '.CMD'])
            : const <String>[''];
    for (final dir in pathEnv.split(separator)) {
      if (dir.isEmpty) continue;
      for (final ext in exts) {
        final candidate = p.join(dir, '$command$ext');
        if (await File(candidate).exists()) return candidate;
      }
    }
    return null;
  }

  static String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Replace the post-build toast with a dialog that summarises what
  /// was written and points the user (via their connected LLM host) at
  /// the `vibe_customize_target` MCP prompt. Non-technical users
  /// otherwise have no signal that the next step is "ask the LLM to
  /// extend the scaffold".
  Future<void> _showBuildSuccessDialog({
    required String target,
    required List<String> artifacts,
    required int sizeBytes,
    String? footer,
  }) async {
    final ctx = context;
    final size = '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    // Broadcast the build outcome into the chat feed so the LLM has
    // context for follow-up turns ("now run it", "verify with stdio
    // handshake", "package as .mcpb"). Without this, GUI-driven builds
    // are invisible to the chat history and the LLM has to be told
    // about every artifact path manually.
    final note =
        'build · $target · ${artifacts.length} artifact'
        '${artifacts.length == 1 ? '' : 's'} · $size'
        '${artifacts.isEmpty ? '' : '\n${artifacts.join('\n')}'}';
    widget.chat.appendTurn(ChatTurn(role: 'system', text: note));
    await showDialog<void>(
      context: ctx,
      builder:
          (dialogCtx) => AlertDialog(
            title: const Text('Build complete'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Target: $target  ·  Size: $size'),
                  const SizedBox(height: 8),
                  for (final a in artifacts)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: SelectableText(
                        a,
                        style: Theme.of(dialogCtx).textTheme.bodySmall,
                      ),
                    ),
                  const SizedBox(height: 16),
                  const Text(
                    'Next',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Ask your connected LLM to customise this scaffold by '
                    'invoking the MCP prompt:',
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    'vibe_customize_target  target=$target  goal="<describe the change>"',
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'The prompt walks the LLM through reading the build '
                    'guide, locating the insertion markers, and editing '
                    'with vibe_file_edit_file.',
                    style: Theme.of(dialogCtx).textTheme.bodySmall,
                  ),
                  if (footer != null) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      footer,
                      style: Theme.of(dialogCtx).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
    );
  }

  /// `[a-z0-9_-]` slug for the .mcpb filename. Hyphen-friendly so
  /// names like "UI Showcase" become `ui-showcase.mcpb`.
  static String _slugForBundle(String raw) {
    final lower = raw.toLowerCase();
    final buf = StringBuffer();
    for (final code in lower.codeUnits) {
      final isLower = code >= 0x61 && code <= 0x7a;
      final isDigit = code >= 0x30 && code <= 0x39;
      if (isLower || isDigit) {
        buf.writeCharCode(code);
      } else if (buf.isNotEmpty) {
        final last = buf.toString().codeUnitAt(buf.length - 1);
        if (last != 0x2d) buf.writeCharCode(0x2d); // '-'
      }
    }
    var s = buf.toString();
    while (s.startsWith('-')) {
      s = s.substring(1);
    }
    while (s.endsWith('-')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Future<void> _onHistory(BuildContext context) async {
    final proj = _project;
    if (proj == null) {
      _toast('No project open');
      return;
    }
    await showHistoryDialog(context, historyLog: proj.historyLog);
  }

  Future<void> _onActivateChannel(String id) async {
    final proj = _project;
    if (proj == null) return;
    if (proj.activeChannel == id) return;
    try {
      await proj.activateChannel(id);
      if (!mounted) return;
      setState(() {
        _projection = LayerProjection.fromJson(widget.canonical.currentJson);
        _selectedPageId = null;
        _selectedComponentId = null;
        _selectedWidgetPath = null;
      });
      // Re-scan the now-non-active channel's draft state. The channel
      // we left behind keeps whatever dirty bit it held; the channel
      // we entered is now driven by the canonical's `dirtyChanges`.
      // ignore: unawaited_futures
      _refreshChannelDirtyFromDisk();
      // Watcher set unchanged (we still watch every enabled channel,
      // active or not), but a `createChannel` could enable a new one
      // mid-flight — re-arm to pick that up cheaply.
      // ignore: unawaited_futures
      _startChannelWatchers();
    } catch (e) {
      _toast('Switch channel failed: $e');
    }
  }

  Future<void> _onCreateChannel(String id) async {
    final proj = _project;
    if (proj == null) return;
    try {
      await proj.createChannel(id, activate: true);
      if (!mounted) return;
      setState(() {
        _projection = LayerProjection.fromJson(widget.canonical.currentJson);
        _selectedPageId = null;
        _selectedComponentId = null;
        _selectedWidgetPath = null;
      });
      _toast('Created $id channel');
    } catch (e) {
      _toast('Create channel failed: $e');
    }
  }

  /// Disable a channel slot from the chip's right-click menu.
  /// Matches `removeChannel` semantics — enabled flips to false but
  /// the on-disk bundle stays so re-enabling later restores the
  /// in-progress state. Refuses (via the toast) when this would leave
  /// the project with no enabled channels.
  Future<void> _onRemoveChannel(String id) async {
    final proj = _project;
    if (proj == null) return;
    try {
      await proj.removeChannel(id);
      if (!mounted) return;
      setState(() {
        _projection = LayerProjection.fromJson(widget.canonical.currentJson);
        _selectedPageId = null;
        _selectedComponentId = null;
        _selectedWidgetPath = null;
      });
      _toast('Disabled $id channel — bundle data preserved');
    } catch (e) {
      _toast('Disable channel failed: $e');
    }
  }

  /// Hard-remove a channel — confirms first because this deletes the
  /// channel's on-disk bundle directory and autosave draft. Used by
  /// the chip's context menu "Remove" item.
  Future<void> _onPurgeChannel(String id) async {
    final proj = _project;
    if (proj == null) return;
    final confirmed = await _confirmDestructive(
      context,
      title: 'Remove $id channel?',
      body:
          'This deletes the channel\'s bundle directory and autosave '
          'draft from disk. The slot stays as a "+" placeholder so you '
          'can re-create it later — but its prior content cannot be '
          'recovered.',
      confirmLabel: 'Remove',
    );
    if (confirmed != true) return;
    try {
      await proj.purgeChannel(id);
      if (!mounted) return;
      setState(() {
        _projection = LayerProjection.fromJson(widget.canonical.currentJson);
        _selectedPageId = null;
        _selectedComponentId = null;
        _selectedWidgetPath = null;
      });
      _toast('Removed $id channel');
    } catch (e) {
      _toast('Remove channel failed: $e');
    }
  }

  /// Copy `from` → `to`. When `to` already has on-disk data the
  /// shell asks the user to confirm overwriting (the underlying
  /// `VibeProject.copyChannel` always overwrites; the gate is here
  /// in the UI for safety).
  Future<void> _onCopyChannel(String from, String to) async {
    final proj = _project;
    if (proj == null) return;
    final destSubdir = proj.channels[to]?.subdir;
    var hadData = false;
    if (destSubdir != null) {
      final dir = Directory(p.join(proj.projectPath, destSubdir));
      hadData =
          await dir.exists() &&
          await dir.list().isEmpty.then((empty) => !empty);
    }
    if (hadData) {
      if (!mounted) return;
      final ok = await _confirmDestructive(
        context,
        title: 'Overwrite $to channel?',
        body:
            'This replaces the contents of the $to channel with a '
            'copy of $from. The current $to bundle (and its autosave '
            'draft) are erased — there is no undo.',
        confirmLabel: 'Overwrite',
      );
      if (ok != true) return;
    }
    try {
      await proj.copyChannel(source: from, target: to);
      if (!mounted) return;
      setState(() {
        _projection = LayerProjection.fromJson(widget.canonical.currentJson);
        _selectedPageId = null;
        _selectedComponentId = null;
        _selectedWidgetPath = null;
      });
      _toast('Copied $from → $to');
    } catch (e) {
      _toast('Copy channel failed: $e');
    }
  }

  /// Swap two channels' on-disk bundle data. Symmetric op — no
  /// "primary" or "secondary" channel here. We confirm because each
  /// channel's autosave draft moves with its bundle, so the user
  /// loses any unsaved edits that were sitting on the *destination*
  /// side of the swap.
  Future<void> _onSwapChannels(String a, String b) async {
    final proj = _project;
    if (proj == null) return;
    final ok = await _confirmDestructive(
      context,
      title: 'Swap $a and $b channels?',
      body:
          'This swaps the on-disk bundle data of the two channels. '
          'Both channels keep their identity (active flag, enabled '
          'flag) but exchange their bundle contents and autosave '
          'drafts.',
      confirmLabel: 'Swap',
    );
    if (ok != true) return;
    try {
      await proj.swapChannels(a, b);
      if (!mounted) return;
      setState(() {
        _projection = LayerProjection.fromJson(widget.canonical.currentJson);
        _selectedPageId = null;
        _selectedComponentId = null;
        _selectedWidgetPath = null;
      });
      _toast('Swapped $a ↔ $b');
    } catch (e) {
      _toast('Swap channels failed: $e');
    }
  }

  /// Start a recursive `Directory.watch` on every enabled channel's
  /// bundle path. Bursts of events are coalesced into a single
  /// `_refreshChannelDirtyFromDisk()` pass via a debounce timer.
  /// Idempotent: calls `_stopChannelWatchers` first so callers can
  /// re-arm after a project / channel registry change.
  Future<void> _startChannelWatchers() async {
    await _stopChannelWatchers();
    final proj = _project;
    if (proj == null) return;
    for (final entry in proj.channels.entries) {
      if (!entry.value.enabled) continue;
      final bundlePath = proj.bundlePathFor(entry.key);
      if (bundlePath == null) continue;
      final dir = Directory(bundlePath);
      if (!await dir.exists()) continue;
      try {
        final sub = dir
            .watch(recursive: true)
            .listen(
              (_) => _scheduleWatcherRefresh(),
              onError: (_) {
                /* watcher hiccup — drop silently */
              },
            );
        _channelWatchers[entry.key] = sub;
      } catch (_) {
        /* watch unsupported on this platform / fs */
      }
    }
  }

  Future<void> _stopChannelWatchers() async {
    _watcherDebounce?.cancel();
    _watcherDebounce = null;
    for (final sub in _channelWatchers.values) {
      try {
        await sub.cancel();
      } catch (_) {
        /* ignore */
      }
    }
    _channelWatchers.clear();
  }

  /// Coalesce the storm of `FileSystemEvent`s an editor save fires
  /// (one create + N modifies + close) into a single rescan.
  void _scheduleWatcherRefresh() {
    _watcherDebounce?.cancel();
    _watcherDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _onExternalDiskChange();
    });
  }

  /// Detect external drift on the active channel by comparing the
  /// canonical's last-committed hash to a fresh hash of disk content.
  /// When they diverge the channel almost certainly received writes
  /// from outside vibe (another editor, a script, git checkout, …) —
  /// surface that as dirty so the user notices BEFORE saving over it.
  /// Non-active channels still rely on the .draft/ existence check
  /// because we don't have a baseline hash for them.
  Future<void> _onExternalDiskChange() async {
    final proj = _project;
    if (proj == null) return;
    final activeBundle = proj.bundlePathFor(proj.activeChannel);
    if (activeBundle != null) {
      final committedHash = widget.canonical.committedHash;
      final diskHash = await _hashOfBundleOnDisk(activeBundle);
      // The canonical re-hashes its in-memory map after every save,
      // so `committedHash` is the byte-for-byte signature of what we
      // last persisted. If disk now hashes differently (using the
      // SAME formula — see `_hashOfBundleOnDisk`) something outside
      // vibe touched the bundle. The hash formula match is critical:
      // an earlier version of this method walked files
      // independently, which produced a different hash and made
      // every save look like external drift.
      if (diskHash != null &&
          committedHash != null &&
          diskHash != committedHash) {
        if (mounted && _channelDirty[proj.activeChannel] != true) {
          setState(() {
            _channelDirty[proj.activeChannel] = true;
            _dirty = true;
          });
        }
      }
    }
    await _refreshChannelDirtyFromDisk();
  }

  /// Hash the on-disk bundle using the SAME formula
  /// `WorkspaceCanonicalImpl._hashOfJson` uses for `committedHash` —
  /// read the bundle through `FileWorkspaceFsPort.readJson` (which
  /// re-merges `manifest.json` + `ui/app.json` + every page back into
  /// the canonical merged map), then `jsonEncode` + sha256. Without
  /// this round-trip the two hashes can't be compared.
  Future<String?> _hashOfBundleOnDisk(String bundlePath) async {
    try {
      final fsPort = FileWorkspaceFsPort();
      final merged = await fsPort.readJson(bundlePath);
      if (merged == null) return null;
      final encoded = jsonEncode(merged);
      final digest = sha256.convert(utf8.encode(encoded));
      return 'sha256:$digest';
    } catch (_) {
      return null;
    }
  }

  /// Hook fired by `FileToolsDispatcher` after any successful mutation.
  /// When the LLM (or any other caller of the file tools) writes
  /// directly into a channel's `<id>.mbd/...` we route around the
  /// canonical patch pipeline — so `dirtyChanges` doesn't fire and
  /// the orange badge stays dark even though disk now diverges. Mark
  /// the touched channel dirty here so the indicator catches up,
  /// and re-scan disk for the rest.
  Future<void> _onFileToolMutate(String absPath) async {
    final proj = _project;
    if (proj == null) return;
    final touched = _channelIdForPath(proj, absPath);
    if (touched != null && mounted) {
      setState(() {
        _channelDirty[touched] = true;
        if (touched == proj.activeChannel) _dirty = true;
      });
    }
    await _refreshChannelDirtyFromDisk();
  }

  /// Identify which channel (if any) [absPath] belongs to. Returns
  /// null when the path is outside every enabled channel's bundle
  /// directory — the file_tool wrote to `src/`, `assets/`, `build/`,
  /// or some other non-bundle area which doesn't drive the dirty
  /// badge.
  String? _channelIdForPath(VibeProject proj, String absPath) {
    final norm = p.normalize(absPath);
    for (final entry in proj.channels.entries) {
      if (!entry.value.enabled) continue;
      final bundlePath = proj.bundlePathFor(entry.key);
      if (bundlePath == null) continue;
      final root = p.normalize(bundlePath);
      if (norm == root || p.isWithin(root, norm)) {
        return entry.key;
      }
    }
    return null;
  }

  /// Build a `LayerProjection` for any channel by re-reading its
  /// `<bundle>.mbd` from disk. Used by the import dialog to surface
  /// collision badges + diff previews against the **target** channel
  /// even when the user is editing a different (active) channel.
  /// Falls back to an empty projection when the channel hasn't been
  /// materialised yet (e.g. user is creating a fresh channel slot).
  Future<LayerProjection> _readTargetProjection(
    VibeProject proj,
    String channelId,
  ) async {
    if (channelId == proj.activeChannel) return _projection;
    final bundlePath = proj.bundlePathFor(channelId);
    if (bundlePath == null) {
      return LayerProjection.fromJson(<String, dynamic>{});
    }
    try {
      final fs = FileWorkspaceFsPort();
      final json = await fs.readJson(bundlePath);
      if (json == null) {
        return LayerProjection.fromJson(<String, dynamic>{});
      }
      return LayerProjection.fromJson(json);
    } catch (_) {
      return LayerProjection.fromJson(<String, dynamic>{});
    }
  }

  /// Copy file-backed asset bytes from a source `.mbd/assets/...`
  /// into the active channel's `.mbd/assets/...`. Best-effort: a
  /// missing source file is logged-and-skipped (the manifest entry
  /// still imports — the user can re-import / re-pack later).
  ///
  /// When [ids] is null every asset entry with a `path` field is
  /// copied (whole-import path). Otherwise only the listed ids are
  /// copied (partial-import path, looked up via [peek]).
  Future<void> _copyAssetFiles({
    required String? sourcePath,
    required Set<String>? ids,
    MbdPeek? peek,
  }) async {
    final proj = _project;
    if (proj == null || sourcePath == null) return;
    final targetBundle = proj.bundlePathFor(proj.activeChannel);
    if (targetBundle == null) return;
    Iterable<Map<String, dynamic>> entries;
    if (ids == null) {
      // Whole import — re-read the manifest to enumerate every
      // asset with a backing file.
      final fs = FileWorkspaceFsPort();
      final src = await fs.readJson(sourcePath);
      final manifest = src == null ? null : src['manifest'];
      final section = manifest is Map ? manifest['assets'] : null;
      final list = section is Map ? section['assets'] : null;
      entries =
          list is List
              ? list.whereType<Map>().map((m) => Map<String, dynamic>.from(m))
              : const <Map<String, dynamic>>[];
    } else {
      // Partial — peek already loaded the entries; pick the chosen
      // ids out and copy.
      entries =
          ids.map((id) => peek?.assets[id]).whereType<Map<String, dynamic>>();
    }
    for (final entry in entries) {
      final relPath = entry['path'];
      if (relPath is! String || relPath.isEmpty) continue;
      try {
        final src = File(p.join(sourcePath, relPath));
        if (!await src.exists()) continue;
        final dest = File(p.join(targetBundle, relPath));
        await dest.parent.create(recursive: true);
        await src.copy(dest.path);
      } catch (_) {
        /* swallow — best effort */
      }
    }
  }

  /// Open the system file picker, copy the chosen file into the
  /// active channel's `.mbd/assets/<auto-folder>/<name>`, compute
  /// the mcp_bundle Asset metadata (id, type, mimeType, hash, size,
  /// path), and return the entry. Returns null when the user
  /// cancels or no project is open. The properties body appends the
  /// returned entry to `manifest.assets.assets[]` via the regular
  /// dispatcher — keeps file IO here, registry mutation there.
  Future<Map<String, dynamic>?> _pickAndImportAsset() async {
    final proj = _project;
    if (proj == null) return null;
    final bundlePath = proj.bundlePathFor(proj.activeChannel);
    if (bundlePath == null) return null;
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Import asset',
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return null;
    final source = picked.files.first;
    final sourcePath = source.path;
    if (sourcePath == null) return null;
    final filename = source.name;

    final type = _assetTypeForExtension(filename);
    final subFolder = _assetSubFolderFor(type);
    final assetsDir = Directory(p.join(bundlePath, 'assets', subFolder));
    await assetsDir.create(recursive: true);

    // Avoid id / file collisions — append `-N` when the suggested id
    // is already registered or the file already exists. Picks the
    // smallest free suffix so re-importing the same file produces a
    // predictable ladder.
    final existingIds =
        (widget.canonical.currentJson['manifest']?['assets']?['assets']
                as List?)
            ?.whereType<Map>()
            .map((m) => '${m['id']}')
            .toSet() ??
        <String>{};
    final baseId = _slugifyAssetId(filename);
    var id = baseId;
    var fileBase = filename;
    if (existingIds.contains(id) ||
        await File(p.join(assetsDir.path, fileBase)).exists()) {
      final dot = filename.lastIndexOf('.');
      final stem = dot > 0 ? filename.substring(0, dot) : filename;
      final ext = dot > 0 ? filename.substring(dot) : '';
      for (var n = 2; ; n++) {
        final cand = '$baseId-$n';
        final candFile = '$stem-$n$ext';
        if (!existingIds.contains(cand) &&
            !await File(p.join(assetsDir.path, candFile)).exists()) {
          id = cand;
          fileBase = candFile;
          break;
        }
      }
    }

    final destFile = File(p.join(assetsDir.path, fileBase));
    final bytes = await File(sourcePath).readAsBytes();
    await destFile.writeAsBytes(bytes, flush: true);

    final hash = 'sha256:${sha256.convert(bytes)}';
    final relPath =
        'assets/$subFolder/$fileBase'; // .mbd-relative, forward slashes
    return <String, dynamic>{
      'id': id,
      'path': relPath,
      'type': type,
      'mimeType': _mimeTypeForExtension(filename),
      'hash': hash,
      'size': bytes.length,
    };
  }

  /// Map a filename extension to mcp_bundle's `AssetType` name.
  static String _assetTypeForExtension(String filename) {
    final lower = filename.toLowerCase();
    bool any(List<String> exts) => exts.any(lower.endsWith);
    if (any(<String>['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'])) {
      return 'image';
    }
    if (any(<String>['.svg', '.ico'])) return 'icon';
    if (any(<String>['.ttf', '.otf', '.woff', '.woff2'])) return 'font';
    if (any(<String>['.mp3', '.wav', '.ogg', '.m4a', '.flac'])) {
      return 'audio';
    }
    if (any(<String>['.mp4', '.webm', '.mov'])) return 'video';
    if (any(<String>['.json'])) return 'json';
    if (any(<String>['.txt', '.md', '.csv'])) return 'text';
    if (any(<String>['.css'])) return 'style';
    if (any(<String>['.html', '.htm'])) return 'template';
    return 'file';
  }

  /// Reasonable subfolder under `.mbd/assets/` per asset type so the
  /// directory stays browsable in a file manager.
  static String _assetSubFolderFor(String type) {
    switch (type) {
      case 'image':
        return 'images';
      case 'icon':
        return 'icons';
      case 'font':
        return 'fonts';
      case 'audio':
        return 'audio';
      case 'video':
        return 'video';
      case 'json':
        return 'data';
      case 'text':
        return 'text';
      case 'template':
        return 'templates';
      case 'style':
        return 'styles';
      default:
        return 'files';
    }
  }

  /// Best-effort MIME for the canonical extensions we recognise.
  /// Returns null when we can't guess — the runtime / consumers can
  /// re-derive from the file extension if needed.
  static String? _mimeTypeForExtension(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.svg')) return 'image/svg+xml';
    if (lower.endsWith('.ico')) return 'image/x-icon';
    if (lower.endsWith('.ttf')) return 'font/ttf';
    if (lower.endsWith('.otf')) return 'font/otf';
    if (lower.endsWith('.woff')) return 'font/woff';
    if (lower.endsWith('.woff2')) return 'font/woff2';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.ogg')) return 'audio/ogg';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.json')) return 'application/json';
    if (lower.endsWith('.txt')) return 'text/plain';
    if (lower.endsWith('.md')) return 'text/markdown';
    if (lower.endsWith('.css')) return 'text/css';
    if (lower.endsWith('.html') || lower.endsWith('.htm')) return 'text/html';
    return null;
  }

  /// Convert a filename to a default asset id — drop the extension,
  /// lowercase, strip non-alphanumerics. Collisions with existing
  /// ids are resolved by the caller appending `-N`.
  static String _slugifyAssetId(String filename) {
    final dot = filename.lastIndexOf('.');
    final stem = dot > 0 ? filename.substring(0, dot) : filename;
    final cleaned = stem
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return cleaned.isEmpty ? 'asset' : cleaned;
  }

  /// Walk every enabled channel's `<bundle>.draft` sibling and
  /// reflect its existence in `_channelDirty`. The active channel's
  /// dirty state is always sourced from the canonical (subject to
  /// hash compare), so we don't overwrite it. Channels we haven't
  /// activated yet would otherwise be silent until first visit, even
  /// when leftover drafts sit on disk from a previous session.
  Future<void> _refreshChannelDirtyFromDisk() async {
    final proj = _project;
    if (proj == null) return;
    final updates = <String, bool>{};
    for (final entry in proj.channels.entries) {
      if (!entry.value.enabled) continue;
      final id = entry.key;
      if (id == proj.activeChannel) continue; // canonical drives this
      final bundlePath = proj.bundlePathFor(id);
      if (bundlePath == null) continue;
      final draftDir = Directory('$bundlePath.draft');
      var hasDraft = false;
      try {
        if (await draftDir.exists()) {
          // An empty draft directory shouldn't count — only flag when
          // the autosave wrote something. Cheap: list one entry.
          await for (final _ in draftDir.list(followLinks: false)) {
            hasDraft = true;
            break;
          }
        }
      } catch (_) {
        /* fs hiccup — best-effort */
      }
      updates[id] = hasDraft;
    }
    if (updates.isEmpty || !mounted) return;
    setState(() {
      // Drop entries for channels that no longer belong to this project
      // (channel renamed / removed). Keeps the cache aligned with the
      // current channel registry.
      _channelDirty.removeWhere(
        (id, _) => id != proj.activeChannel && !updates.containsKey(id),
      );
      updates.forEach((id, hasDraft) => _channelDirty[id] = hasDraft);
    });
  }

  Future<void> _onCloseProject() async {
    final proj = _project;
    if (proj == null) return;
    if (_dirty) {
      final c = VibeTokens.colorOf(context);
      final ok = await showDialog<bool?>(
        context: context,
        builder:
            (ctx) => Dialog(
              backgroundColor: c.surface2,
              child: SizedBox(
                width: 360,
                child: Padding(
                  padding: const EdgeInsets.all(VibeTokens.space4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                        'Close with unsaved changes?',
                        style: TextStyle(
                          fontFamily: VibeTokens.fontSans,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: c.textPrimary,
                        ),
                      ),
                      const SizedBox(height: VibeTokens.space2),
                      Text(
                        'Unsaved edits stay in the autosave draft and will be '
                        'restored next time this project is opened.',
                        style: TextStyle(fontSize: 12, color: c.textSecondary),
                      ),
                      const SizedBox(height: VibeTokens.space4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: <Widget>[
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            child: const Text('Keep editing'),
                          ),
                          const SizedBox(width: VibeTokens.space2),
                          FilledButton(
                            onPressed: () => Navigator.of(ctx).pop(true),
                            child: const Text('Close'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
      );
      if (ok != true) return;
    }
    await _stopChannelWatchers();
    _settings.lastProjectPath = null;
    // ignore: unawaited_futures
    _settings.save(VibeSettings.defaultPath('app_builder_vibe'));
    widget.chat.onClearLog = null;
    widget.chat.onTurnPersisted = null;
    widget.chat.clear();
    widget.llm?.resetHistory();
    widget.llm?.bindFileTools(null);
    widget.llm?.bindBuildTools(null);
    if (!mounted) return;
    setState(() {
      _project = null;
      _focusedByChannelMode.clear();
      _selectedPageId = null;
      _selectedComponentId = null;
      // Drop the per-channel dirty cache — those bits belonged to the
      // project we're closing. Without this, channels that happened to
      // share an id with the next project (typical: `serving` /
      // `native`) light up an inherited orange badge that doesn't
      // match the new project's actual draft state.
      _channelDirty.clear();
    });
    await proj.dispose();
  }

  Future<void> _onRename(BuildContext context) async {
    final proj = _project;
    if (proj == null) {
      _toast('No project open');
      return;
    }
    final next = await promptForWorkspacePath(
      context,
      title: 'Rename project',
      hint: proj.name,
    );
    if (next == null || next.trim().isEmpty) return;
    final trimmed = next.trim();
    if (trimmed == proj.name) return;
    try {
      await proj.rename(trimmed);
      if (!mounted) return;
      setState(() {});
      _toast('Renamed to $trimmed');
    } catch (e) {
      _toast('Rename failed: $e');
    }
  }

  Future<void> _recordRecent(String projectPath) async {
    if (projectPath.isEmpty) return;
    _settings.bumpRecent(projectPath);
    if (!mounted) return;
    setState(() {});
    try {
      await _settings.save(VibeSettings.defaultPath('app_builder_vibe'));
    } catch (_) {
      /* surface failure on the next explicit Settings save */
    }
  }

  Future<void> _onOpenRecent(String path) async {
    if (!await Directory(path).exists()) {
      _toast('Project no longer exists: $path');
      _settings.recentProjects.removeWhere((e) => e == path);
      if (_settings.lastProjectPath == path) _settings.lastProjectPath = null;
      // ignore: unawaited_futures
      _settings.save(VibeSettings.defaultPath('app_builder_vibe'));
      if (mounted) setState(() {});
      return;
    }
    final hasNew = await File(p.join(path, VibeProject.projectFile)).exists();
    final hasLegacy =
        await File(p.join(path, VibeProject.legacyProjectFile)).exists();
    if (!hasNew && !hasLegacy) {
      _toast('Not an AppPlayer Builder project: $path');
      return;
    }
    try {
      final project = await VibeProject.openAt(
        projectDir: path,
        canonical: widget.canonical,
      );
      await _rebindChat(project);
      final previous = _project;
      if (!mounted) return;
      setState(() {
        _project = project;
        _focusedByChannelMode = _cloneFocusMap(
          project.prefs.focusedByChannelMode,
        );
        _selectedPageId = project.prefs.selectedPageId;
        _selectedComponentId = project.prefs.selectedComponentId;
      });
      await previous?.dispose();
      await _recordRecent(project.projectPath);
    } catch (e) {
      _toast('Open failed: $e');
    }
  }

  Future<void> _onSettings(BuildContext context) async {
    // Settings are host-owned. Route to the standard Studio settings
    // dialog (`chromeBridge.openSettings`) — it edits the studio-wide
    // VibeSettings (workspace / MCP / LLM) and renders App Builder's
    // `domainSettingsProvider` sections. App Builder no longer forks its
    // own settings dialog or keeps a parallel settings store; the host
    // pushes the updated studio settings back via the mount's
    // `inheritedSettings`.
    final bridge = widget.studioChromeBridge;
    final open = bridge?.openSettings;
    if (open == null) return;
    await open();
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  /// Debounced re-run of the full health check. Each canonical
  /// change resets the timer so a burst of edits collapses into a
  /// single check; 800ms is the same window M3 motion uses for
  /// "settled" — feels live without thrashing.
  void _scheduleHealthRefresh() {
    _healthDebounce?.cancel();
    _healthDebounce = Timer(const Duration(milliseconds: 800), () async {
      if (!mounted) return;
      final proj = _project;
      if (proj == null) {
        if (!mounted) return;
        setState(() => _health = null);
        return;
      }
      final tools = BuildToolsDispatcher(
        project: proj,
        canonical: widget.canonical,
        pipeline: widget.pipeline,
        validator: _validator,
      );
      try {
        final result = await tools.dispatch('health_check', const {});
        if (!mounted || result == null || !result.success) return;
        final p = result.payload;
        if (p == null) return;
        final j = jsonDecode(p);
        if (j is! Map) return;
        final next = Map<String, dynamic>.from(j);
        setState(() => _health = next);
        _maybeEmitHealthTransitionNote(next);
      } catch (_) {
        // Silent — chat-side health bar renders a neutral pill on
        // missing data so the failure doesn't surface as an error.
      }
    });
  }

  /// Slash-command dispatcher wired into the chat composer. Inputs
  /// starting with `/` route here instead of going to the LLM —
  /// matches the input against a small command catalog and runs
  /// the corresponding `BuildToolsDispatcher` tool. Result lands
  /// in chat as a system note. Unknown command → falls back to a
  /// gentle "no such command" note instead of dropping silently.
  /// Catalog:
  ///   `/health`            → health_check
  ///   `/grade`             → grade
  ///   `/release [dryRun]`  → release_check
  ///   `/audit [page]`      → a11y_audit
  ///   `/routes`            → route_audit
  ///   `/find <kind:val>`   → find_references
  ///   `/graph`             → dependency_graph
  ///   `/tokens`            → tokenization_audit (focused page)
  ///   `/desc <pointer>`    → tree_outline rooted at pointer
  ///   `/lint`              → widget_lint (focused page)
  ///   `/extract <id>`      → extract_to_template (uses focused widget)
  ///   `/fix`               → a11y_quick_fix
  ///   `/preset <kind>`     → apply_layout_preset on focused page
  ///   `/recipe <name>`     → apply_recipe on focused widget /
  ///                          page
  ///   `/critique [focus]`  → vibe_design_critique
  Future<String?> _runSlashCommand(String input) async {
    final proj = _project;
    if (proj == null) {
      widget.chat.appendTurn(
        ChatTurn(role: 'error', text: 'Slash commands need an open project.'),
      );
      return null;
    }
    final trimmed = input.trim();
    final parts = trimmed.substring(1).split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) {
      return null;
    }
    final cmd = parts.first.toLowerCase();
    final tail = parts.length > 1 ? parts.sublist(1) : const <String>[];
    final tools = BuildToolsDispatcher(
      project: proj,
      canonical: widget.canonical,
      pipeline: widget.pipeline,
      validator: _validator,
      onCapturePreview: _capturePreviewBytes,
      onLayoutSnapshot: _captureLayoutSnapshotNodes,
    );
    String toolName;
    Map<String, dynamic> args = const <String, dynamic>{};
    switch (cmd) {
      case 'health':
        toolName = 'health_check';
        break;
      case 'grade':
        toolName = 'grade';
        break;
      case 'release':
        toolName = 'release_check';
        if (tail.contains('dryRun') || tail.contains('dry')) {
          args = const <String, dynamic>{'dryRun': true};
        }
        break;
      case 'audit':
        toolName = 'a11y_audit';
        if (tail.isNotEmpty) {
          args = <String, dynamic>{'pageId': tail.first};
        } else if (_selectedPageId != null) {
          args = <String, dynamic>{'pageId': _selectedPageId};
        }
        break;
      case 'routes':
        toolName = 'route_audit';
        break;
      case 'find':
        if (tail.isEmpty) {
          widget.chat.appendTurn(
            ChatTurn(
              role: 'error',
              text:
                  'Usage: /find <kind:value> — kinds: '
                  'template, state, route, asset.',
            ),
          );
          return null;
        }
        toolName = 'find_references';
        args = <String, dynamic>{'target': tail.first};
        break;
      case 'graph':
        toolName = 'dependency_graph';
        break;
      case 'tokens':
        toolName = 'tokenization_audit';
        if (_selectedPageId != null) {
          args = <String, dynamic>{'scope': '/ui/pages/$_selectedPageId'};
        }
        break;
      case 'desc':
        if (tail.isEmpty) {
          widget.chat.appendTurn(
            ChatTurn(
              role: 'error',
              text: 'Usage: /desc <jsonPointer> — e.g. /desc /ui/pages/home.',
            ),
          );
          return null;
        }
        toolName = 'tree_outline';
        args = <String, dynamic>{'rootPath': tail.first, 'maxDepth': 6};
        break;
      case 'lint':
        toolName = 'widget_lint';
        if (_selectedPageId != null) {
          args = <String, dynamic>{'scope': '/ui/pages/$_selectedPageId'};
        }
        break;
      case 'extract':
        if (tail.length < 2) {
          widget.chat.appendTurn(
            ChatTurn(
              role: 'error',
              text:
                  'Usage: /extract <widgetPath> <newTemplateId>. '
                  'Or select a widget in the tree and pass just the '
                  'newTemplateId — the path is filled from focus.',
            ),
          );
          return null;
        }
        // Two forms: /extract <ptr> <id>  OR
        //            /extract <id>  (uses focused widget path)
        String? widgetPath;
        String? newId;
        if (tail.first.startsWith('/')) {
          widgetPath = tail.first;
          newId = tail.skip(1).first;
        } else if (_selectedPageId != null && _selectedWidgetPath != null) {
          widgetPath =
              '/ui/pages/'
              '${_selectedPageId ?? ''}/content'
              '${_widgetPathSuffix(_selectedWidgetPath!)}';
          newId = tail.first;
        } else {
          widget.chat.appendTurn(
            ChatTurn(
              role: 'error',
              text:
                  'No widget selected — pass an explicit pointer: '
                  '/extract /ui/pages/home/content/children/2 myCard.',
            ),
          );
          return null;
        }
        toolName = 'extract_to_template';
        args = <String, dynamic>{
          'widgetPath': widgetPath,
          'newTemplateId': newId,
        };
        break;
      case 'fix':
        toolName = 'a11y_quick_fix';
        if (_selectedPageId != null) {
          args = <String, dynamic>{'pageId': _selectedPageId};
        }
        break;
      case 'preset':
        if (tail.isEmpty || _selectedPageId == null) {
          widget.chat.appendTurn(
            ChatTurn(
              role: 'error',
              text:
                  'Usage: /preset <hero|cardList|form|settings|gallery'
                  '|magazine|carousel|playlist|landing>. Pick a page '
                  'first via the Pages strip.',
            ),
          );
          return null;
        }
        toolName = 'apply_layout_preset';
        args = <String, dynamic>{'pageId': _selectedPageId, 'kind': tail.first};
        break;
      case 'recipe':
        if (tail.isEmpty) {
          widget.chat.appendTurn(
            ChatTurn(
              role: 'error',
              text:
                  'Usage: /recipe <wrap_with_card|wrap_with_padding|'
                  'wrap_with_scroll|wrap_with_expanded|wrap_with_hero|'
                  'wrap_with_animated_opacity|wrap_with_safearea|'
                  'add_floating_action|add_loading_state> [kw=val …].',
            ),
          );
          return null;
        }
        toolName = 'apply_recipe';
        final recipeArgs = <String, dynamic>{};
        for (final kv in tail.skip(1)) {
          final eq = kv.indexOf('=');
          if (eq <= 0) continue;
          final k = kv.substring(0, eq);
          final v = kv.substring(eq + 1);
          recipeArgs[k] = num.tryParse(v) ?? v;
        }
        // Default to focused widget path when none provided.
        if (!recipeArgs.containsKey('path') && _selectedWidgetPath != null) {
          recipeArgs['path'] =
              '/ui/pages/'
              '${_selectedPageId ?? ''}/content'
              '${_widgetPathSuffix(_selectedWidgetPath!)}';
        }
        if (!recipeArgs.containsKey('pageId') && _selectedPageId != null) {
          recipeArgs['pageId'] = _selectedPageId;
        }
        args = <String, dynamic>{'name': tail.first, 'args': recipeArgs};
        break;
      case 'critique':
        toolName = 'design_critique';
        // Note — design_critique is a top-level vibe tool, not a
        // build tool. Punt to dedicated path.
        widget.chat.appendTurn(
          ChatTurn(
            role: 'system',
            text:
                '↦ ask the LLM "critique this design" — '
                'design_critique returns multimodal content best '
                'consumed by the chat agent.',
          ),
        );
        return null;
      case 'help':
      case '?':
        widget.chat.appendTurn(
          ChatTurn(
            role: 'system',
            text:
                'Slash commands:\n'
                '  /health         — full health check\n'
                '  /grade          — letter A–F + rubric\n'
                '  /release [dry]  — multi-stage release verdict\n'
                '  /audit [page]   — a11y audit (defaults to focused)\n'
                '  /routes         — route ↔ page ↔ initialRoute audit\n'
                '  /find <k:v>     — find references (template/state/route/asset)\n'
                '  /graph          — dependency graph (page→template/asset/state)\n'
                '  /tokens         — hardcoded values audit (focused page)\n'
                '  /desc <ptr>     — tree outline rooted at JSON pointer\n'
                '  /lint           — widget_lint (focused page)\n'
                '  /extract <id>   — extract focused widget to template\n'
                '  /fix            — auto-fix a11y (focused page)\n'
                '  /preset <kind>  — apply layout preset to focused\n'
                '  /recipe <name>  — apply structural recipe\n'
                '  /critique       — multimodal design review\n'
                '  /help | /?      — this list',
          ),
        );
        return null;
      default:
        widget.chat.appendTurn(
          ChatTurn(
            role: 'error',
            text: 'Unknown slash command: /$cmd. Try /help.',
          ),
        );
        return null;
    }
    try {
      final result = await tools.dispatch(toolName, args);
      if (result == null) return null;
      widget.chat.appendTurn(
        ChatTurn(
          role: result.success ? 'system' : 'error',
          text:
              '${result.success ? '✓' : '✗'} $toolName · '
              '${result.message}',
        ),
      );
      return toolName;
    } catch (e) {
      widget.chat.appendTurn(
        ChatTurn(role: 'error', text: '$toolName exception: $e'),
      );
      return null;
    }
  }

  /// Convert a `WidgetPath` (mixed string/int segments) into the JSON
  /// pointer suffix that lives under a page's `content`. Empty path
  /// means "the page content root."
  String _widgetPathSuffix(WidgetPath path) {
    final buf = StringBuffer();
    for (final seg in path) {
      if (seg is int) {
        buf.write('/$seg');
      } else {
        final s = '$seg'.replaceAll('~', '~0').replaceAll('/', '~1');
        buf.write('/$s');
      }
    }
    return buf.toString();
  }

  /// Emit a chat-side `system` note when blocking count transitions
  /// across a meaningful boundary — regression (more issues than the
  /// previous snapshot) or full clear (was non-zero, now zero). All
  /// other drift (advisory wobble, same count) stays silent so the
  /// chat doesn't fill with noise on every keystroke.
  void _maybeEmitHealthTransitionNote(Map<String, dynamic> snapshot) {
    final summary = snapshot['summary'];
    if (summary is! Map) return;
    final blocking =
        ((summary['specIssues'] ?? 0) as int) +
        ((summary['wiringIssues'] ?? 0) as int) +
        ((summary['a11yFails'] ?? 0) as int) +
        ((summary['invalidAssets'] ?? 0) as int) +
        ((summary['undefinedState'] ?? 0) as int);
    final prev = _prevBlocking;
    _prevBlocking = blocking;
    if (prev == null) return; // First snapshot — quiet.
    if (blocking == prev) return;
    final chat = widget.chat;
    if (blocking == 0 && prev > 0) {
      chat.appendTurn(
        ChatTurn(
          role: 'system',
          text: '✓ All blocking issues cleared. Bundle ready to ship.',
        ),
      );
    } else if (blocking > prev) {
      final delta = blocking - prev;
      final hint =
          (summary['a11yFails'] ?? 0) > 0
              ? ' Try `a11y_quick_fix` or `health_check` for the breakdown.'
              : ' Try `health_check` for the breakdown.';
      chat.appendTurn(
        ChatTurn(
          role: 'system',
          text:
              'ℹ Health regressed: +$delta blocking '
              '(now $blocking total).$hint',
        ),
      );
    }
  }

  /// Group health findings by page id so InstanceStrip can render a
  /// per-card badge. Source: `_health.details.a11y.findings` (path
  /// rooted at `/ui/pages/[id]`) + `details.stateByPage` (undefined +
  /// unused state keys per page).
  Map<String, int> _issuesPerPageFromHealth() {
    return _issuesPerHealthEntry('/ui/pages/');
  }

  /// Same shape as `_issuesPerPageFromHealth` but rooted at templates.
  /// Templates live under `/ui/templates/<id>` so a11y findings whose
  /// path starts with that prefix get bucketed by their template id.
  Map<String, int> _issuesPerTemplateFromHealth() {
    return _issuesPerHealthEntry('/ui/templates/');
  }

  Map<String, int> _issuesPerHealthEntry(String prefix) {
    final h = _health;
    if (h == null) return const <String, int>{};
    final out = <String, int>{};
    final details = h['details'];
    if (details is Map) {
      final a11y = details['a11y'];
      if (a11y is Map) {
        final findings = a11y['findings'];
        if (findings is List) {
          for (final f in findings) {
            if (f is! Map) continue;
            final path = f['path'];
            if (path is! String || !path.startsWith(prefix)) continue;
            final tail = path.substring(prefix.length);
            final id = tail.split('/').first;
            if (id.isEmpty) continue;
            out[id] = (out[id] ?? 0) + 1;
          }
        }
      }
      // State usage rollup applies to pages only — templates don't
      // declare their own state map.
      if (prefix == '/ui/pages/') {
        final byPage = details['stateByPage'];
        if (byPage is Map) {
          for (final entry in byPage.entries) {
            final id = '${entry.key}';
            final v = entry.value;
            if (v is! Map) continue;
            final n =
                ((v['undefined'] as int?) ?? 0) + ((v['unused'] as int?) ?? 0);
            if (n > 0) out[id] = (out[id] ?? 0) + n;
          }
        }
      }
    }
    return out;
  }

  /// Re-run the spec validator over the current canonical bundle and
  /// cache the issue list. Called from the canonical changes listener
  /// + once on init so the lint badge reflects every patch.
  void _refreshLint() {
    try {
      final issues = <ValidationIssue>[
        ..._validator.validateFull(widget.canonical.current),
        ..._checkWidgetCapabilities(widget.canonical.currentJson),
      ];
      _lint = issues;
    } catch (_) {
      _lint = const <ValidationIssue>[];
    }
    _pushLintToHostIfActive();
  }

  /// Push the active tab's lint counts to the host statusbar badge.
  /// Deferred to post-frame because `_refreshLint` runs inside the
  /// canonical change-listener `setState`, and writing the bridge's lint
  /// ValueNotifiers there would mark the host statusbar dirty mid-build.
  /// Only the active tab pushes so sibling tabs don't clobber the badge.
  void _pushLintToHostIfActive() {
    final bridge = widget.studioChromeBridge;
    if (bridge == null) return;
    final blocks =
        _lint.where((i) => i.severity == ValidationSeverity.error).length;
    final warns =
        _lint.where((i) => i.severity == ValidationSeverity.warning).length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!WorkspaceTabActiveScope.isActiveOf(context)) return;
      bridge.lintBlocks.value = blocks;
      bridge.lintWarns.value = warns;
    });
  }

  /// Walk every widget tree in the canonical (pages content,
  /// templates content, dashboard content) and surface a WARN issue
  /// for each `type` that isn't in the DSL widget catalog. Catches
  /// typos and capability-tier mismatches the spec validator can't
  /// detect — the runtime would render an empty placeholder for
  /// unknown widgets, which is a silent failure mode in practice.
  List<ValidationIssue> _checkWidgetCapabilities(Map<String, dynamic> json) {
    final ui = json['ui'];
    if (ui is! Map) return const <ValidationIssue>[];
    final knownTypes = WidgetSchemaCatalog.instance.types.toSet();
    final issues = <ValidationIssue>[];
    final unknown = <String, List<String>>{};

    void walk(dynamic node, String path) {
      if (node is List) {
        for (var i = 0; i < node.length; i++) {
          walk(node[i], '$path/$i');
        }
        return;
      }
      if (node is! Map) return;
      final type = node['type'];
      if (type is String &&
          type.isNotEmpty &&
          !knownTypes.contains(type) &&
          // Top-level marker types we explicitly allow.
          type != 'application' &&
          type != 'page') {
        unknown.putIfAbsent(type, () => <String>[]).add(path);
      }
      for (final entry in node.entries) {
        walk(entry.value, '$path/${entry.key}');
      }
    }

    final pages = ui['pages'];
    if (pages is Map) {
      for (final e in pages.entries) {
        walk(e.value, '/ui/pages/${e.key}');
      }
    }
    final templates = ui['templates'];
    if (templates is Map) {
      for (final e in templates.entries) {
        walk(e.value, '/ui/templates/${e.key}');
      }
    }
    final dashboard = ui['dashboard'];
    if (dashboard is Map) {
      walk(dashboard, '/ui/dashboard');
    }

    for (final entry in unknown.entries) {
      final occurrences = entry.value.length;
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.warning,
          code: 'UNKNOWN_WIDGET_TYPE',
          layer: ValidationLayer.schema,
          pointer: entry.value.first,
          message:
              'Widget type "${entry.key}" is not in the DSL catalog '
              '(${occurrences == 1 ? '1 occurrence' : '$occurrences occurrences'}). '
              'It will render as an empty placeholder at runtime.',
        ),
      );
    }
    return issues;
  }

  /// Modal listing every active lint issue — block-level entries are
  /// pinned to the top, then warnings. Each row shows code · path ·
  /// message in the same monospace tone as the rest of the editor.
  Future<void> _showLintDialog() async {
    final c = VibeTokens.colorOf(context);
    final blocks =
        _lint.where((i) => i.severity == ValidationSeverity.error).toList();
    final warns =
        _lint.where((i) => i.severity == ValidationSeverity.warning).toList();
    await showDialog<void>(
      context: context,
      builder:
          (ctx) => Dialog(
            backgroundColor: c.surface2,
            child: SizedBox(
              width: 560,
              child: Padding(
                padding: const EdgeInsets.all(VibeTokens.space4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      'Spec lint — ${widget.specVersion}',
                      style: TextStyle(
                        fontFamily: VibeTokens.fontSans,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: VibeTokens.space2),
                    if (_lint.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          'No issues — bundle conforms to mcp_ui DSL '
                          '${widget.specVersion}.',
                          style: TextStyle(
                            fontFamily: VibeTokens.fontMono,
                            fontSize: 11,
                            color: VibeTokens.status.ok,
                          ),
                        ),
                      )
                    else
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 400),
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              for (final issue in <ValidationIssue>[
                                ...blocks,
                                ...warns,
                              ])
                                _LintRow(issue: issue),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: VibeTokens.space3),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Surface chrome-state changes (dirty / undo-redo / project meta)
    // to the host via `chromeStateRevision` so the surrounding
    // ProjectHeader / ActivityBar can re-render its actions without
    // every internal setState having to opt in manually.
    _maybeEmitChromeStateChanged();
    // Cmd/Ctrl+Z and Cmd/Ctrl+Shift+Z drive undo / redo. Bound at the
    // shell so the shortcut works regardless of which inner widget
    // currently has keyboard focus.
    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _onUndo,
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _onUndo,
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
          _onRedo,
      const SingleActivator(
            LogicalKeyboardKey.keyZ,
            control: true,
            shift: true,
          ):
          _onRedo,
    };
    return CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(
        autofocus: true,
        child: Container(
          key: const Key('vibe.shell'),
          color: VibeTokens.colorOf(context).bg,
          child: Column(
            children: <Widget>[
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Chat column is owned by the host chrome — VibeShell
                    // only paints the center + properties area so the user
                    // doesn't see two chat panels stacked. `widget.chat` is
                    // still consumed by `appendTurn` / `_runSlashCommand` /
                    // patch cards below; the host's per-tab chat panel
                    // surfaces those turns.
                    // Properties panel only meaningful while editing — debug
                    // mode reads the live MCP server, not the canonical, so
                    // hide the panel and give that width back to the centre.
                    // Properties panel meaningful in UI and Bundle mode (both
                    // edit the canonical). Debug mode reads the live MCP
                    // server, not the canonical, so hide and give the width
                    // back to the centre.
                    final showProps =
                        constraints.maxWidth >= 980 &&
                        _centerMode != CenterMode.debug;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        if (_project == null)
                          Expanded(
                            child: _WelcomePanel(
                              recents: List<String>.unmodifiable(
                                _settings.recentProjects,
                              ),
                              onNew: () => _onNewProject(context),
                              onOpen: () => _onOpenProject(context),
                              onPickRecent: _onOpenRecent,
                            ),
                          )
                        else ...<Widget>[
                          Expanded(
                            child: _CenterColumn(
                              // Include project path so swapping projects
                              // (Open / New) forces a full remount instead
                              // of letting stale internal state (focused
                              // page selection, preview epoch, layout
                              // snapshot caches) leak into the new project.
                              key: ValueKey<String>(
                                'center:${_project?.projectPath ?? 'none'}:${_project?.activeChannel ?? 'none'}',
                              ),
                              projection: _projection,
                              canonical: widget.canonical,
                              focused: _focused,
                              selfUiFramework: widget.selfUiFramework,
                              selfUiSimDir: widget.selfUiSimDir,
                              selectedPageId: _selectedPageId,
                              selectedComponentId: _selectedComponentId,
                              onFocus: (id) {
                                setState(() {
                                  _focused = id;
                                  _selectedWidgetPath = null;
                                });
                                _persistPrefs();
                              },
                              onSelectPage: (id) {
                                setState(() {
                                  _selectedPageId = id;
                                  _selectedWidgetPath = null;
                                });
                                _persistPrefs();
                              },
                              onAddPage: () => _addPage(context),
                              onDeletePage: _deletePage,
                              onDuplicatePage:
                                  (id) => _duplicatePage(context, id),
                              onAddRouteForPage:
                                  (id) => _addRouteForPage(context, id),
                              onSelectComponent: (id) {
                                setState(() {
                                  _selectedComponentId = id;
                                  _selectedWidgetPath = null;
                                });
                                _persistPrefs();
                              },
                              onAddComponent: () => _addComponent(context),
                              onDeleteComponent: _deleteComponent,
                              onDuplicateComponent:
                                  (id) => _duplicateComponent(context, id),
                              previewPrefs: PreviewPrefsSnapshot(
                                sizeChoice: _project?.prefs.previewSizeChoice,
                                orientation: _project?.prefs.previewOrientation,
                                brightness: _project?.prefs.previewBrightness,
                                customW: _project?.prefs.previewCustomW,
                                customH: _project?.prefs.previewCustomH,
                              ),
                              onPreviewPrefsChanged: _onPreviewPrefsChanged,
                              selectedWidgetPath: _selectedWidgetPath,
                              onSelectWidget: (p) {
                                setState(() => _selectedWidgetPath = p);
                              },
                              channels: _project?.channels,
                              activeChannel: _project?.activeChannel,
                              channelDirty: _channelDirty,
                              onActivateChannel: _onActivateChannel,
                              onCreateChannel: _onCreateChannel,
                              onRemoveChannel: _onRemoveChannel,
                              onPurgeChannel: _onPurgeChannel,
                              onCopyChannel: _onCopyChannel,
                              onSwapChannels: _onSwapChannels,
                              externalRefreshEpoch: _previewEpoch,
                              previewCaptureKey: _previewCaptureKey,
                              centerMode: _centerMode,
                              onCenterModeChanged: (m) {
                                setState(() => _centerMode = m);
                              },
                              projectPath: _project?.projectPath,
                              inspectorSessions: _inspectorSessions,
                              inspectorCaptureKey: _inspectorCaptureKey,
                              assetBundlePath: _project?.bundlePathFor(
                                _project!.activeChannel,
                              ),
                              issuesPerPage: _issuesPerPageFromHealth(),
                              issuesPerTemplate: _issuesPerTemplateFromHealth(),
                              // Bundle-mode cards need the host base
                              // ChromeBridge for surfaces (BundleToolsView /
                              // BundleAgentsView's reload + activate). app_builder
                              // is hosted inside Studio's shell, which exposes
                              // the bridge via [widget.studioChromeBridge] when
                              // present — null while running standalone (no
                              // host wiring) and the bundle cards fall back
                              // to a read-only view.
                              bundleChromeBridge: widget.studioChromeBridge,
                              projectKind:
                                  _project?.meta.kind ??
                                  ProjectKind.appPlayerApp,
                              bundlePath: _project?.bundlePath,
                              hostTabKey: widget.hostTabKey,
                            ),
                          ),
                          if (showProps) ...<Widget>[
                            _PanelSplitter(
                              onDelta: (dx) {
                                setState(() {
                                  _propsWidth = _clampPanelWidth(
                                    _propsWidth - dx,
                                  );
                                });
                              },
                              onDragEnd: _persistPanelWidths,
                            ),
                            PropertiesPanel(
                              // See _CenterColumn key — project-path
                              // qualifier forces a clean rebuild on swap.
                              key: ValueKey<String>(
                                'props:${_project?.projectPath ?? 'none'}:${_project?.activeChannel ?? 'none'}',
                              ),
                              focusedLayer: _focused,
                              projection: _projection,
                              pipeline: widget.pipeline,
                              dispatch: _dispatchPatch,
                              focusedPageId: _selectedPageId,
                              focusedComponentId: _selectedComponentId,
                              selectedWidgetPath: _selectedWidgetPath,
                              onSelectWidget: (p) {
                                setState(() => _selectedWidgetPath = p);
                              },
                              onAssetImport: _pickAndImportAsset,
                              assetBundlePath: _project?.bundlePathFor(
                                _project!.activeChannel,
                              ),
                              health: _health,
                              width: _propsWidth,
                              // Mode-aware header index: 01 Manifest in Bundle
                              // mode (matching OverviewStrip card numbering),
                              // 01 App in UI mode. Without this the header
                              // would use absolute enum order (e.g. 09
                              // Manifest) and confuse the user.
                              modeLayers: CenterMode.layersFor(_centerMode),
                            ),
                          ],
                        ],
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One row inside the lint dialog — severity tag · code · path ·
/// message. Block rows lead with a coral pill, warn rows with amber,
/// matching the statusbar badge colour scheme.
class _LintRow extends StatelessWidget {
  const _LintRow({required this.issue});
  final ValidationIssue issue;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final isBlock = issue.severity == ValidationSeverity.error;
    final tagColor = isBlock ? c.coral : c.amber;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: tagColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(2),
              border: Border.all(color: tagColor),
            ),
            child: Text(
              isBlock ? 'BLOCK' : 'WARN',
              style: TextStyle(
                fontFamily: VibeTokens.fontMono,
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: tagColor,
              ),
            ),
          ),
          const SizedBox(width: VibeTokens.space2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${issue.code} · ${issue.pointer ?? ''}',
                  style: TextStyle(
                    fontFamily: VibeTokens.fontMono,
                    fontSize: 11,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  issue.message,
                  style: TextStyle(
                    fontFamily: VibeTokens.fontMono,
                    fontSize: 10,
                    color: c.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CenterColumn extends StatelessWidget {
  const _CenterColumn({
    super.key,
    required this.projection,
    required this.canonical,
    required this.focused,
    required this.selfUiFramework,
    required this.selfUiSimDir,
    required this.selectedPageId,
    required this.selectedComponentId,
    required this.onFocus,
    required this.onSelectPage,
    required this.onAddPage,
    required this.onDeletePage,
    required this.onDuplicatePage,
    required this.onAddRouteForPage,
    required this.onSelectComponent,
    required this.onAddComponent,
    required this.onDeleteComponent,
    required this.onDuplicateComponent,
    required this.previewPrefs,
    required this.onPreviewPrefsChanged,
    required this.selectedWidgetPath,
    required this.onSelectWidget,
    required this.channels,
    required this.activeChannel,
    required this.channelDirty,
    required this.onActivateChannel,
    required this.onCreateChannel,
    required this.onRemoveChannel,
    required this.onPurgeChannel,
    required this.onCopyChannel,
    required this.onSwapChannels,
    required this.externalRefreshEpoch,
    required this.previewCaptureKey,
    required this.centerMode,
    required this.onCenterModeChanged,
    required this.projectPath,
    required this.inspectorSessions,
    required this.inspectorCaptureKey,
    required this.assetBundlePath,
    required this.issuesPerPage,
    required this.issuesPerTemplate,
    required this.bundleChromeBridge,
    required this.projectKind,
    required this.bundlePath,
    this.hostTabKey,
  });

  /// Chrome tab path of the shell hosting this column — forwarded to
  /// [PreviewPanel.hostTabKey] so the embedded [DslWorkspaceView]
  /// gates on the parent tab's activeness rather than its own bundle
  /// path.
  final String? hostTabKey;

  /// Authoring intent of the open project. Drives whether the UI-mode
  /// preview pane mounts the pure DSL preview ([PreviewMcpUi]) or the
  /// studio workspace view that registers vbu_* atoms
  /// ([DslWorkspaceView]). Defaults to [ProjectKind.appPlayerApp] when
  /// no project is open.
  final ProjectKind projectKind;

  /// Absolute path of the active channel's `.mbd/` directory. Required
  /// by [DslWorkspaceView] when [projectKind] is
  /// [ProjectKind.studioPackage]; ignored otherwise.
  final String? bundlePath;

  /// Chrome bridge handed to the bundle-mode cards' authoring views
  /// (`BundleManifestView`, `BundleToolsView`, `BundleKnowledgeView`,
  /// `BundleAgentsView`). Null when running outside a Studio host.
  final dynamic bundleChromeBridge;

  /// Per-page issue count (page id → blocking + advisory total).
  /// Drives the badge on each `_InstanceCard` in the Pages strip.
  final Map<String, int> issuesPerPage;

  /// Per-template issue count — same shape, scoped to /ui/templates.
  final Map<String, int> issuesPerTemplate;

  /// Editor / debug toggle. Drives the body of the centre column —
  /// editor renders the existing strip + preview, debug swaps in
  /// [InspectorPanel].
  final CenterMode centerMode;
  final ValueChanged<CenterMode> onCenterModeChanged;

  /// Currently-open project root (or null when no project is open).
  /// [InspectorPanel] reads this to discover built variants.
  final String? projectPath;

  /// Shell-owned session manager. Persists across editor↔debug
  /// toggles so connections, the wire log, and any in-flight
  /// `recordedCallTool` survive when the panel itself unmounts.
  final InspectorSessionManager inspectorSessions;
  final GlobalKey inspectorCaptureKey;

  /// `RepaintBoundary` key bound by the shell so MCP can capture the
  /// live preview surface for `vibe_preview_capture`.
  final GlobalKey previewCaptureKey;

  final LayerProjection projection;
  final WorkspaceCanonical canonical;
  final LayerId focused;
  final SelfUiFramework selfUiFramework;
  final String? selfUiSimDir;
  final String? selectedPageId;
  final String? selectedComponentId;
  final ValueChanged<LayerId> onFocus;
  final ValueChanged<String> onSelectPage;
  final VoidCallback onAddPage;
  final ValueChanged<String> onDeletePage;
  final ValueChanged<String> onDuplicatePage;
  final ValueChanged<String> onAddRouteForPage;
  final ValueChanged<String> onSelectComponent;
  final VoidCallback onAddComponent;
  final ValueChanged<String> onDeleteComponent;
  final ValueChanged<String> onDuplicateComponent;
  final PreviewPrefsSnapshot previewPrefs;
  final ValueChanged<PreviewPrefsSnapshot> onPreviewPrefsChanged;
  final WidgetPath? selectedWidgetPath;
  final ValueChanged<WidgetPath>? onSelectWidget;

  /// Channel registry (`serving` / `native`). Null = no project open.
  final Map<String, ChannelDef>? channels;

  /// Id of the active channel — drives the chip highlight.
  final String? activeChannel;

  /// Per-channel unsaved-edits state. Channels missing from the map
  /// haven't been visited yet (or have no draft) and render without a
  /// badge.
  final Map<String, bool> channelDirty;

  /// User picked an enabled channel chip — switch to that bundle.
  final ValueChanged<String> onActivateChannel;

  /// User picked a `+` placeholder — create that channel.
  final ValueChanged<String> onCreateChannel;

  /// User chose "Disable" from a chip's context menu — flip
  /// `enabled` to false. The on-disk bundle data stays so a later
  /// `onCreateChannel` restores it.
  final ValueChanged<String> onRemoveChannel;

  /// User chose "Remove" from a chip's context menu — destructive:
  /// disable + delete the channel's bundle dir + draft. The shell
  /// confirms before invoking; the slot stays as a `+` placeholder.
  final ValueChanged<String> onPurgeChannel;

  /// User chose `Copy to <other> channel` from a chip's context
  /// menu — clones the source channel's on-disk bundle into the
  /// target. Shell shows an overwrite confirm when the target
  /// already has data.
  final void Function(String from, String to) onCopyChannel;

  /// User chose `Swap with <other>` from a chip's context menu —
  /// swaps the two channels' on-disk bundle data (no enabled-flag
  /// movement, no active-channel change).
  final void Function(String a, String b) onSwapChannels;

  /// Shell-driven preview refresh counter — forwarded to PreviewPanel
  /// to force the inner runtime to rebuild.
  final int externalRefreshEpoch;

  /// Active channel's bundle root on disk — passed to AssetGalleryView
  /// so it can resolve `path`-backed asset thumbnails. Null when no
  /// project is open.
  final String? assetBundlePath;

  String? _focusedPageId() {
    if (focused == LayerId.pages) {
      // Selected page if any; on first load fall back to the app home so
      // the preview opens on a page rather than a blank slate.
      return selectedPageId ?? _appHomePageId();
    }
    // Dashboard renders via `dashboardMode`, not via this page id.
    // App / Theme / Components / Whole layers render the running app as a
    // whole — return null so the preview targets `mcp-ui:app`.
    return null;
  }

  String? _appHomePageId() {
    final entry = projection.appStructure.entryPageId;
    if (entry != null && projection.pages.containsKey(entry)) return entry;
    return projection.pages.keys.isNotEmpty
        ? projection.pages.keys.first
        : null;
  }

  bool _showsInstanceStrip() {
    // Dashboard is single-instance (spec §11.9) — no strip. Only Pages
    // and Components have multiple instances to navigate between.
    return focused == LayerId.pages || focused == LayerId.components;
  }

  /// Root of the widget tree the inspector should resolve hits against.
  /// `null` disables inspect mode in the preview tab bar (no tree to
  /// inspect — App / Theme / Whole layers).
  Map<String, dynamic>? _inspectRoot() {
    if (focused == LayerId.pages) {
      final pageId = _focusedPageId();
      if (pageId == null) return null;
      final raw = projection.pages[pageId]?.raw;
      final content = raw?['content'];
      if (content is Map<String, dynamic> && content.containsKey('type')) {
        return content;
      }
      return null;
    }
    if (focused == LayerId.components) {
      final id = selectedComponentId;
      if (id == null) return null;
      final tpl = projection.components.templates[id];
      final root = tpl?['content'];
      if (root is Map<String, dynamic> && root.containsKey('type')) {
        return root;
      }
      return null;
    }
    if (focused == LayerId.dashboard) {
      final raw = projection.dashboard?.raw;
      final content = raw?['content'];
      if (content is Map<String, dynamic> && content.containsKey('type')) {
        return content;
      }
      return null;
    }
    return null;
  }

  /// Builds the body that fills the UI-mode column under the
  /// InstanceStrip. Assets layer renders the gallery; everything else
  /// goes through [PreviewPanel] which then branches internally on
  /// [projectKind] between [PreviewMcpUi] (AppPlayer App) and
  /// [DslWorkspaceView] (Studio Package). Keeping the chrome (tab
  /// bar, device frame, reset / brightness / orient toggles, capture
  /// key) shared means both kinds inherit the same panel ergonomics.
  Widget _workspaceBody() {
    if (focused == LayerId.assets) {
      return AssetGalleryView(
        assets: projection.assets,
        bundlePath: assetBundlePath,
      );
    }
    return PreviewPanel(
      canonical: canonical,
      focusPageId: _focusedPageId(),
      focusComponentId:
          focused == LayerId.components ? selectedComponentId : null,
      dashboardMode: focused == LayerId.dashboard,
      selfUiFramework: selfUiFramework,
      selfUiSimDir: selfUiSimDir,
      initialPrefs: previewPrefs,
      onPrefsChanged: onPreviewPrefsChanged,
      selectedWidgetPath: selectedWidgetPath,
      onSelectWidget: onSelectWidget,
      inspectRoot: _inspectRoot(),
      externalRefreshEpoch: externalRefreshEpoch,
      captureKey: previewCaptureKey,
      // App Builder's only preview policy: a Studio package mounts the
      // workspace runtime (declared as a host PreviewVariant); everything
      // else uses the platform's default PreviewMcpUi body. The host panel
      // never learns about ProjectKind.
      variant:
          (projectKind == ProjectKind.studioPackage && bundlePath != null)
              ? studioPackagePreviewVariant(
                bundlePath: bundlePath!,
                chromeBridge:
                    bundleChromeBridge is ChromeBridge
                        ? bundleChromeBridge as ChromeBridge
                        : null,
                hostTabKey: hostTabKey,
              )
              : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasChannels = channels != null && channels!.isNotEmpty;
    // Channel chips drive editing scope (which `.mbd/` is canonical
    // right now). They are meaningful in UI mode only — Bundle mode
    // edits manifest sections directly through `studio.builder.*`
    // mutators which already write through the active channel, and
    // Debug mode walks every built variant under `build/<slug>/`
    // regardless of channel.
    final showChannelStrip = hasChannels && centerMode == CenterMode.ui;
    final c = VibeTokens.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          height: 40,
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(bottom: BorderSide(color: c.borderDefault)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              if (showChannelStrip)
                Expanded(
                  child: _ChannelStrip(
                    channels: channels!,
                    activeId: activeChannel,
                    dirty: channelDirty,
                    onActivate: onActivateChannel,
                    onCreate: onCreateChannel,
                    onRemove: onRemoveChannel,
                    onPurge: onPurgeChannel,
                    onCopy: onCopyChannel,
                    onSwap: onSwapChannels,
                    projectKind: projectKind,
                  ),
                )
              else if (centerMode == CenterMode.debug)
                const Expanded(child: _InspectorTitle())
              else
                const Spacer(),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _CenterModeToggle(
                  mode: centerMode,
                  onChanged: onCenterModeChanged,
                ),
              ),
            ],
          ),
        ),
        // Mount UI / Bundle / Debug bodies side-by-side and toggle
        // visibility with Offstage so the UI mode's DslWorkspaceView
        // is NOT torn down when the user switches to Bundle / Debug.
        // Earlier `if/else` swap would dispose the State, fire
        // `runtime.destroy()` (mcp_ui async), and leave the
        // `vibe_studio_runtime` fork's NavigationService.navigatorKey
        // in a half-released state — the next chrome tab that tries
        // to attach to that singleton couldn't, and the destination
        // tab silently froze. AppPlayer's RuntimeManager mirrors this
        // pattern: all session widgets stay mounted, only the active
        // one paints.
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Offstage(
                offstage: centerMode != CenterMode.ui,
                child: TickerMode(
                  enabled: centerMode == CenterMode.ui,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      OverviewStrip(
                        projection: projection,
                        focused: focused,
                        onFocus: onFocus,
                        layers: CenterMode.layersFor(CenterMode.ui),
                      ),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            if (_showsInstanceStrip())
                              _instanceStripFor(focused),
                            Expanded(child: _workspaceBody()),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Offstage(
                offstage: centerMode != CenterMode.bundle,
                child: TickerMode(
                  enabled: centerMode == CenterMode.bundle,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      OverviewStrip(
                        projection: projection,
                        focused: focused,
                        onFocus: onFocus,
                        layers: CenterMode.layersFor(CenterMode.bundle),
                      ),
                      Expanded(
                        child: _BundleCardCenter(
                          focused: focused,
                          bundlePath: assetBundlePath,
                          chromeBridge: bundleChromeBridge,
                          projectKind: projectKind,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Offstage(
                offstage: centerMode != CenterMode.debug,
                child: TickerMode(
                  enabled: centerMode == CenterMode.debug,
                  child: _DebugCenter(
                    projectPath: projectPath,
                    inspectorSessions: inspectorSessions,
                    inspectorCaptureKey: inspectorCaptureKey,
                    chromeBridge: bundleChromeBridge,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _instanceStripFor(LayerId layer) {
    if (layer == LayerId.components) {
      return InstanceStrip(
        layer: layer,
        axis: Axis.vertical,
        entries: projection.components.templates.keys.toList()..sort(),
        selectedId: selectedComponentId,
        onSelect: onSelectComponent,
        onAdd: onAddComponent,
        onDelete: onDeleteComponent,
        onDuplicate: onDuplicateComponent,
        issuesPerEntry: issuesPerTemplate,
      );
    }
    return InstanceStrip(
      layer: layer,
      axis: Axis.vertical,
      entries: projection.pages.keys.toList()..sort(),
      selectedId: selectedPageId,
      onSelect: onSelectPage,
      onAdd: onAddPage,
      onDelete: onDeletePage,
      onDuplicate: onDuplicatePage,
      onAddRoute: onAddRouteForPage,
      issuesPerEntry: issuesPerPage,
    );
  }
}

/// Header label shown in the channel-strip slot when the centre panel
/// is in debug mode. Mirrors `_ChannelStrip`'s `'Channels:'` label
/// (vibeMono 11/w500/textSecondary) so the row is visually uniform.
class _InspectorTitle extends StatelessWidget {
  const _InspectorTitle();

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space3),
      child: Row(
        children: <Widget>[
          Icon(Icons.bug_report_outlined, size: 14, color: c.textSecondary),
          const SizedBox(width: 8),
          Text(
            'Inspector — built variants',
            style: vibeMono(
              size: 11,
              weight: FontWeight.w500,
              color: c.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Debug-mode center body — wraps the existing [InspectorPanel] with a
/// 5-tab sub-nav so each `studio.debug.*` surface gets its own panel
/// without crowding the variant card view.
///
/// Sub-tabs:
///   * **Variants** (default) — the inspector's variant cards + wire
///     log + render preview.
///   * **Runtime** — live snapshot of the active bundle's runtime
///     state (driven by `studio.debug.runtime_state`).
///   * **Dispatch** — tool-call timeline (driven by
///     `studio.debug.dispatch_log`).
///   * **Scenario** — scenario replay / overlay / recorder
///     (`studio.scenario.*` + `studio.overlay.*` + `studio.recorder.*`).
///   * **Boot** — bundle activation + boot event log
///     (`studio.debug.boot_log` + `studio.debug.activation`).
///
/// Non-Variants tabs surface their data through chrome bridge MCP
/// dispatch once that bridge is plumbed into app_builder (Phase E.1);
/// the initial cut shows a hint card so the structure is visible.
class _DebugCenter extends StatefulWidget {
  const _DebugCenter({
    required this.projectPath,
    required this.inspectorSessions,
    required this.inspectorCaptureKey,
    required this.chromeBridge,
  });

  final String? projectPath;
  final InspectorSessionManager inspectorSessions;
  final GlobalKey inspectorCaptureKey;
  // Studio chrome bridge (dynamic — `ChromeBridge` from
  // vibe_studio_base when running as a built-in app). Sub-panels
  // call `chromeBridge.callHostTool` to poll `studio.debug.*` tools.
  final dynamic chromeBridge;

  @override
  State<_DebugCenter> createState() => _DebugCenterState();
}

class _DebugCenterState extends State<_DebugCenter> {
  int _activeSubTab = 0;

  static const List<_DebugSubTab> _tabs = <_DebugSubTab>[
    _DebugSubTab('Variants', Icons.dashboard_outlined),
    _DebugSubTab('Runtime', Icons.memory_outlined),
    _DebugSubTab('Dispatch', Icons.timeline_outlined),
    _DebugSubTab('Scenario', Icons.play_arrow_outlined),
    _DebugSubTab('Boot', Icons.power_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Column(
      children: <Widget>[
        Container(
          height: 32,
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(bottom: BorderSide(color: c.borderSubtle)),
          ),
          child: Row(
            children: <Widget>[
              for (int i = 0; i < _tabs.length; i++)
                _DebugSubTabChip(
                  spec: _tabs[i],
                  selected: i == _activeSubTab,
                  onTap: () => setState(() => _activeSubTab = i),
                ),
            ],
          ),
        ),
        Expanded(child: _bodyFor(_activeSubTab)),
      ],
    );
  }

  Widget _bodyFor(int idx) {
    switch (idx) {
      case 0:
        return InspectorPanel(
          projectPath: widget.projectPath,
          sessions: widget.inspectorSessions,
          captureKey: widget.inspectorCaptureKey,
        );
      case 1:
        return _DebugMcpPanel(
          key: const ValueKey('debug-runtime'),
          chromeBridge: widget.chromeBridge,
          toolName: 'studio.debug.runtime_state',
          title: 'Runtime state',
          subtitle:
              'Active tab\'s bundle state snapshot · '
              '`studio.debug.runtime_state` · refreshes every 2 s',
          pollInterval: const Duration(seconds: 2),
        );
      case 2:
        return _DebugMcpPanel(
          key: const ValueKey('debug-dispatch'),
          chromeBridge: widget.chromeBridge,
          toolName: 'studio.debug.dispatch_log',
          args: const <String, dynamic>{'limit': 50},
          title: 'Dispatch log',
          subtitle:
              'Last 50 `tools/call` dispatches handled by the '
              'studio server · `studio.debug.dispatch_log` · '
              'refreshes every 3 s',
          pollInterval: const Duration(seconds: 3),
        );
      case 3:
        return _DebugScenarioPanel(
          key: const ValueKey('debug-scenario'),
          chromeBridge: widget.chromeBridge,
        );
      case 4:
        return _DebugMcpPanel(
          key: const ValueKey('debug-boot'),
          chromeBridge: widget.chromeBridge,
          toolName: 'studio.debug.boot_log',
          title: 'Boot + activation log',
          subtitle:
              'Boot events + bundle activation trace · '
              '`studio.debug.boot_log` · snapshot on tab open',
          // Static snapshot — boot log only changes on activation
          // events, no point polling. Tap the refresh button on the
          // panel to re-fetch.
          pollInterval: null,
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

class _DebugSubTab {
  const _DebugSubTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

class _DebugSubTabChip extends StatelessWidget {
  const _DebugSubTabChip({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  final _DebugSubTab spec;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      onTap: selected ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(spec.icon, size: 13, color: color),
            const SizedBox(width: 6),
            Text(
              spec.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Generic Debug-mode sub-panel — polls a host MCP tool through
/// `chromeBridge.callHostTool` and renders the response as
/// pretty-printed JSON. Use for read-only diagnostic surfaces
/// (`studio.debug.runtime_state` · `dispatch_log` · `boot_log`).
class _DebugMcpPanel extends StatefulWidget {
  const _DebugMcpPanel({
    super.key,
    required this.chromeBridge,
    required this.toolName,
    required this.title,
    required this.subtitle,
    required this.pollInterval,
    this.args = const <String, dynamic>{},
  });

  /// Studio chrome bridge (dynamic to dodge the cross-package type
  /// dep — `ChromeBridge` from vibe_studio_base when running as a
  /// built-in app inside Studio).
  final dynamic chromeBridge;
  final String toolName;
  final Map<String, dynamic> args;
  final String title;
  final String subtitle;

  /// Poll cadence — null = fetch once on mount (the user uses the
  /// refresh icon to re-pull).
  final Duration? pollInterval;

  @override
  State<_DebugMcpPanel> createState() => _DebugMcpPanelState();
}

class _DebugMcpPanelState extends State<_DebugMcpPanel> {
  Map<String, dynamic>? _response;
  String? _error;
  Timer? _poll;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _fetch();
    final interval = widget.pollInterval;
    if (interval != null) {
      _poll = Timer.periodic(interval, (_) => _fetch());
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    final bridge = widget.chromeBridge;
    if (bridge == null) {
      if (!mounted) return;
      setState(() {
        _error = 'Studio chrome bridge not wired (running standalone).';
        _response = null;
      });
      return;
    }
    if (_busy) return;
    _busy = true;
    try {
      // Duck-typed `chromeBridge.callHostTool(tool, params)` — bridges
      // wired by Studio expose this slot.
      final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
      fn = bridge.callHostTool;
      if (fn == null) {
        if (!mounted) return;
        setState(() {
          _error = 'Chrome bridge has no `callHostTool` — host wiring stale.';
          _response = null;
        });
        return;
      }
      final r = await fn(widget.toolName, widget.args);
      if (!mounted) return;
      setState(() {
        _response = r;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.title,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: c.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 16),
                tooltip: 'Refresh now',
                onPressed: _fetch,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    final c = VibeTokens.colorOf(context);
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: c.textSecondary,
            ),
          ),
        ),
      );
    }
    final response = _response;
    if (response == null) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    String pretty;
    try {
      pretty = const JsonEncoder.withIndent('  ').convert(response);
    } catch (_) {
      pretty = response.toString();
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SelectableText(
        pretty,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: c.textPrimary,
        ),
      ),
    );
  }
}

/// Debug-mode Scenario sub-panel — lists scenarios via
/// `studio.scenario.list`, previews the selected one via
/// `studio.scenario.read`, and dispatches `studio.scenario.run` from
/// the same chrome bridge slot the other debug panels use.
///
/// Overlay / recorder catalogues stay in their own sub-tabs in a
/// future round — this surface is scenario-only by design (one MCP
/// catalogue per Debug sub-tab so the controls don't crowd).
class _DebugScenarioPanel extends StatefulWidget {
  const _DebugScenarioPanel({super.key, required this.chromeBridge});

  final dynamic chromeBridge;

  @override
  State<_DebugScenarioPanel> createState() => _DebugScenarioPanelState();
}

class _DebugScenarioPanelState extends State<_DebugScenarioPanel> {
  List<Map<String, dynamic>> _entries = const <Map<String, dynamic>>[];
  String? _selectedId;
  Map<String, dynamic>? _selectedDetail;
  String? _error;
  bool _running = false;
  String? _lastRunResult;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<Map<String, dynamic>?> _call(
    String tool,
    Map<String, dynamic> args,
  ) async {
    final bridge = widget.chromeBridge;
    if (bridge == null) {
      setState(() => _error = 'Studio chrome bridge not wired.');
      return null;
    }
    try {
      final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
      fn = bridge.callHostTool;
      if (fn == null) {
        setState(() => _error = 'Chrome bridge has no `callHostTool`.');
        return null;
      }
      return await fn(tool, args);
    } catch (e) {
      setState(() => _error = e.toString());
      return null;
    }
  }

  Future<void> _refresh() async {
    final r = await _call('studio.scenario.list', const <String, dynamic>{});
    if (!mounted || r == null) return;
    final entries = <Map<String, dynamic>>[];
    final raw = r['entries'];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) entries.add(Map<String, dynamic>.from(e));
      }
    }
    setState(() {
      _entries = entries;
      _error = null;
      if (_selectedId != null && !entries.any((e) => e['id'] == _selectedId)) {
        _selectedId = null;
        _selectedDetail = null;
      }
    });
  }

  Future<void> _selectScenario(String id) async {
    setState(() {
      _selectedId = id;
      _selectedDetail = null;
      _lastRunResult = null;
    });
    final r = await _call('studio.scenario.read', <String, dynamic>{'id': id});
    if (!mounted || r == null) return;
    setState(() => _selectedDetail = r);
  }

  Future<void> _run() async {
    final id = _selectedId;
    if (id == null || _running) return;
    setState(() {
      _running = true;
      _lastRunResult = null;
    });
    final r = await _call('studio.scenario.run', <String, dynamic>{'id': id});
    if (!mounted) return;
    setState(() {
      _running = false;
      _lastRunResult =
          r == null
              ? '(no response)'
              : const JsonEncoder.withIndent('  ').convert(r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Scenario',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'studio.scenario.list / .read / .run — '
                      '${_entries.length} scenario(s) discovered',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: c.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 16),
                tooltip: 'Refresh list',
                onPressed: _refresh,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(width: 240, child: _list()),
              VerticalDivider(width: 1, color: c.borderDefault),
              Expanded(child: _detail()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _list() {
    final c = VibeTokens.colorOf(context);
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: c.textSecondary,
            ),
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'No scenarios under <configRoot>/scenarios/ or the active '
            'project. Save one via `studio.scenario.save`.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 10,
              color: c.textTertiary,
            ),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, i) {
        final e = _entries[i];
        final id = e['id']?.toString() ?? '?';
        final source = e['source']?.toString() ?? '';
        final title = e['title']?.toString();
        final isSel = id == _selectedId;
        return InkWell(
          onTap: () => _selectScenario(id),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isSel ? c.surface3 : Colors.transparent,
              border: Border(
                bottom: BorderSide(color: c.borderSubtle, width: 0.5),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  id,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    fontWeight: isSel ? FontWeight.w600 : FontWeight.w500,
                    color: isSel ? c.textPrimary : c.textSecondary,
                  ),
                ),
                if (title != null && title.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: c.textTertiary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (source.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    'source: $source',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 9,
                      color: c.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _detail() {
    final c = VibeTokens.colorOf(context);
    if (_selectedId == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'Pick a scenario on the left to preview + run.',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: c.textTertiary,
            ),
          ),
        ),
      );
    }
    final detail = _selectedDetail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _selectedId!,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: c.textPrimary,
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed: _running ? null : _run,
                icon:
                    _running
                        ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(Icons.play_arrow, size: 14),
                label: Text(_running ? 'Running…' : 'Run'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (detail == null)
                  const Center(
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  SelectableText(
                    () {
                      try {
                        return const JsonEncoder.withIndent(
                          '  ',
                        ).convert(detail);
                      } catch (_) {
                        return detail.toString();
                      }
                    }(),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: c.textPrimary,
                    ),
                  ),
                if (_lastRunResult != null) ...<Widget>[
                  const SizedBox(height: 16),
                  Text(
                    'LAST RUN',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: c.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: c.surface2,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: c.borderSubtle),
                    ),
                    child: SelectableText(
                      _lastRunResult!,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: c.textPrimary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Bundle-mode center body — dispatches to one of the four card detail
/// views based on the focused layer. Manifest / Knowledge cards run
/// without a host bridge (they call `McpBundleMutator.mutate` directly
/// per Phase A). Tools / Agents cards plumb [chromeBridge] when present
/// (host base authoring view dependency) and otherwise render a
/// read-only placeholder.
class _BundleCardCenter extends StatelessWidget {
  const _BundleCardCenter({
    required this.focused,
    required this.bundlePath,
    required this.chromeBridge,
    required this.projectKind,
  });

  final LayerId focused;
  final String? bundlePath;
  final dynamic chromeBridge;

  /// Drives which surfaces BundleToolsView exposes. AppPlayer App
  /// projects only carry `tools` + `settings`; Studio Package
  /// projects carry the full Tools / Domain Icons / / Commands /
  /// Settings / Lifecycle set.
  final ProjectKind projectKind;

  @override
  Widget build(BuildContext context) {
    final path = bundlePath;
    if (path == null || path.isEmpty) {
      return _placeholder(
        'No bundle adopted yet',
        'Open or create a project to author its bundle.',
      );
    }
    switch (focused) {
      case LayerId.manifest:
        return BundleManifestView(
          key: ValueKey('bundle-card-manifest::$path'),
          bundlePath: path,
        );
      case LayerId.knowledge:
        return BundleKnowledgeView(
          key: ValueKey('bundle-card-knowledge::$path'),
          bundlePath: path,
        );
      case LayerId.tools:
        final bridge = chromeBridge;
        if (bridge is! ChromeBridge) {
          return _placeholder(
            'Tools editor needs the host chrome bridge',
            'Studio host wires the bridge on mount — running standalone '
                'shows a read-only view (coming in a follow-up phase).',
          );
        }
        final visibleKinds =
            projectKind == ProjectKind.appPlayerApp
                ? <BundleToolsKind>{
                  BundleToolsKind.tool,
                  BundleToolsKind.section,
                }
                : null; // null = show every kind (Studio Package)
        return BundleToolsView(
          key: ValueKey('bundle-card-tools::$path'),
          bundlePath: path,
          overridesFile: packageOverridesFile(configRoot: null, pkgPath: path),
          chromeBridge: bridge,
          reloadCounter: 0,
          visibleKinds: visibleKinds,
        );
      case LayerId.agents:
        return BundleAgentsView(
          key: ValueKey('bundle-card-agents::$path'),
          bundlePath: path,
        );
      default:
        return _placeholder(
          'Pick a bundle card',
          'Manifest · Tools · Knowledge · Agents — choose one above.',
        );
    }
  }

  Widget _placeholder(String title, String body) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Text(
              title,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: Colors.white54,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CenterModeToggle extends StatelessWidget {
  const _CenterModeToggle({required this.mode, required this.onChanged});
  final CenterMode mode;
  final ValueChanged<CenterMode> onChanged;

  /// Original segmented-switch form — a single Material pill with
  /// three inline chips inside. Icon + label per chip; selected chip
  /// inverts to the mint accent. Equal-width chips so the three sit
  /// flush. Font matches the channel/properties chrome family
  /// (vibeMono).
  static const double _chipWidth = 84;
  static const double _chipHeight = 26;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final scheme = Theme.of(context).colorScheme;
    Widget chip(CenterMode m, IconData icon, String label) {
      final selected = mode == m;
      final fg = selected ? c.mint : c.textSecondary;
      return inspectTag(
        type: 'center_mode_chip',
        id: m.name,
        label: label,
        extra: <String, dynamic>{'selected': selected},
        child: InkWell(
          borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
          onTap: selected ? null : () => onChanged(m),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: _chipWidth,
            height: _chipHeight,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? c.surface3 : Colors.transparent,
              borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(icon, size: 13, color: fg),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: vibeMono(size: 11, weight: FontWeight.w500, color: fg),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Material(
      elevation: 0,
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            chip(CenterMode.ui, Icons.brush_outlined, 'UI'),
            chip(CenterMode.bundle, Icons.inventory_2_outlined, 'Bundle'),
            chip(CenterMode.debug, Icons.bug_report_outlined, 'Debug'),
          ],
        ),
      ),
    );
  }
}

/// Vertical drag handle used between panels to resize them. The handle
/// is 6 px wide with a subtle 1 px divider; mint highlights on hover so
/// the affordance is discoverable without being noisy.
class _PanelSplitter extends StatefulWidget {
  const _PanelSplitter({required this.onDelta, required this.onDragEnd});

  /// Horizontal pointer delta in logical pixels per drag update.
  final ValueChanged<double> onDelta;
  final VoidCallback onDragEnd;

  @override
  State<_PanelSplitter> createState() => _PanelSplitterState();
}

class _PanelSplitterState extends State<_PanelSplitter> {
  bool _hovered = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final highlight = _dragging || _hovered;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (d) => widget.onDelta(d.delta.dx),
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          widget.onDragEnd();
        },
        child: AnimatedContainer(
          duration: VibeTokens.durFast,
          curve: VibeTokens.easeStandard,
          width: 6,
          color:
              highlight ? c.mint.withValues(alpha: 0.18) : Colors.transparent,
          alignment: Alignment.center,
          child: Container(
            width: 1,
            color: highlight ? c.mint : c.borderDefault,
          ),
        ),
      ),
    );
  }
}

/// Empty-state panel shown in place of the editor when no project is
/// open. Exposes the explicit creation / open / recents actions —
/// project folders are never materialised on disk implicitly.
class _WelcomePanel extends StatelessWidget {
  const _WelcomePanel({
    required this.recents,
    required this.onNew,
    required this.onOpen,
    required this.onPickRecent,
  });

  final List<String> recents;
  final VoidCallback onNew;
  final VoidCallback onOpen;
  final ValueChanged<String> onPickRecent;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Container(
      color: c.bg,
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(VibeTokens.space5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'AppPlayer Builder',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: VibeTokens.fontSans,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(height: VibeTokens.space2),
              Text(
                'No project open. Create a new one or open an existing project to start.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: VibeTokens.fontSans,
                  fontSize: 13,
                  color: c.textSecondary,
                ),
              ),
              const SizedBox(height: VibeTokens.space5),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: onNew,
                    style: FilledButton.styleFrom(
                      backgroundColor: c.mint,
                      foregroundColor: c.bg,
                      padding: const EdgeInsets.symmetric(
                        horizontal: VibeTokens.space4,
                        vertical: VibeTokens.space3,
                      ),
                    ),
                    icon: const Icon(Icons.add_circle_outlined, size: 16),
                    label: const Text('New Project'),
                  ),
                  const SizedBox(width: VibeTokens.space3),
                  OutlinedButton.icon(
                    onPressed: onOpen,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.textPrimary,
                      side: BorderSide(color: c.borderStrong),
                      padding: const EdgeInsets.symmetric(
                        horizontal: VibeTokens.space4,
                        vertical: VibeTokens.space3,
                      ),
                    ),
                    icon: const Icon(Icons.folder_open_outlined, size: 16),
                    label: const Text('Open Project'),
                  ),
                ],
              ),
              if (recents.isNotEmpty) ...<Widget>[
                const SizedBox(height: VibeTokens.space5),
                Padding(
                  padding: const EdgeInsets.only(left: VibeTokens.space2),
                  child: Text(
                    'RECENT PROJECTS',
                    style: TextStyle(
                      fontFamily: VibeTokens.fontMono,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.0,
                      color: c.textTertiary,
                    ),
                  ),
                ),
                const SizedBox(height: VibeTokens.space2),
                Container(
                  decoration: BoxDecoration(
                    color: c.surface2,
                    borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
                    border: Border.all(color: c.borderDefault),
                  ),
                  child: Column(
                    children: <Widget>[
                      for (var i = 0; i < recents.length; i++) ...<Widget>[
                        if (i > 0)
                          Divider(
                            height: 1,
                            thickness: 1,
                            color: c.borderDefault,
                          ),
                        _RecentRow(
                          path: recents[i],
                          onTap: () => onPickRecent(recents[i]),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentRow extends StatefulWidget {
  const _RecentRow({required this.path, required this.onTap});

  final String path;
  final VoidCallback onTap;

  @override
  State<_RecentRow> createState() => _RecentRowState();
}

class _RecentRowState extends State<_RecentRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final base = widget.path.split(Platform.pathSeparator).last;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: VibeTokens.durFast,
          curve: VibeTokens.easeStandard,
          color: _hovered ? c.surface3 : Colors.transparent,
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space3,
            vertical: VibeTokens.space2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                base,
                style: vibeMono(
                  size: 13,
                  weight: FontWeight.w500,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                widget.path,
                style: TextStyle(
                  fontFamily: VibeTokens.fontMono,
                  fontSize: 11,
                  color: c.textTertiary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChannelChoice {
  const _ChannelChoice({
    required this.id,
    required this.label,
    required this.action,
  });
  final String id;
  final String label;
  final String action;
}

/// One row inside a chip's right-click context menu. The strip
/// builds these per-slot so each chip's menu can vary (serving has
/// only "Copy to Native"; native has Disable / Remove / Swap with
/// Serving). An empty list means the chip has no context menu and
/// secondary tap is ignored.
class _ChannelMenuItem {
  const _ChannelMenuItem({
    required this.label,
    required this.onSelected,
    this.enabled = true,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onSelected;
  final bool enabled;

  /// Render the label in coral so the user reads "this is a
  /// destructive action" before clicking.
  final bool destructive;
}

class _ChannelStrip extends StatelessWidget {
  const _ChannelStrip({
    required this.channels,
    required this.activeId,
    required this.dirty,
    required this.onActivate,
    required this.onCreate,
    required this.onRemove,
    required this.onPurge,
    required this.onCopy,
    required this.onSwap,
    required this.projectKind,
  });

  final Map<String, ChannelDef> channels;
  final String? activeId;
  final Map<String, bool> dirty;
  final ValueChanged<String> onActivate;
  final ValueChanged<String> onCreate;
  final ValueChanged<String> onRemove;
  final ValueChanged<String> onPurge;

  /// Drives the leading `Target:` label and whether the channel chips
  /// (Serving / Native) are rendered. Studio Package projects keep a
  /// single bundle so the chip row collapses, but the target label
  /// stays so the user can still tell what kind of project is open.
  final ProjectKind projectKind;

  /// Copy `from`'s on-disk bundle into `to`. `to` may be disabled —
  /// the handler enables it. The shell shows an overwrite confirm
  /// when `to` already has data.
  final void Function(String from, String to) onCopy;

  /// Swap two channels' on-disk bundle data. Order doesn't matter —
  /// it's symmetrical.
  final void Function(String a, String b) onSwap;

  static const List<String> _slotOrder = <String>["serving", "native"];
  static const Map<String, String> _slotLabel = <String, String>{
    "serving": "Serving",
    "native": "Native",
  };

  /// True when [slot] can be disabled — must be enabled itself, AND
  /// at least one *other* enabled channel must remain afterwards
  /// (matches `VibeProject.removeChannel`'s "cannot remove the only
  /// enabled channel" guard).
  bool _canRemove(String slot) {
    final ch = channels[slot];
    if (ch == null || !ch.enabled) return false;
    var enabledOthers = 0;
    for (final entry in channels.entries) {
      if (entry.key == slot) continue;
      if (entry.value.enabled) enabledOthers++;
    }
    return enabledOthers >= 1;
  }

  /// Build the per-slot context menu. Items are conditional on
  /// channel state so the menu only ever shows relevant actions.
  List<_ChannelMenuItem> _menuFor(String slot) {
    final ch = channels[slot];
    if (ch == null || !ch.enabled) return const <_ChannelMenuItem>[];
    final items = <_ChannelMenuItem>[];
    if (slot == 'serving') {
      // Serving's only context menu action is mirroring its bundle
      // into Native — the spine itself stays put.
      items.add(
        _ChannelMenuItem(
          label: 'Copy to Native channel',
          onSelected: () => onCopy('serving', 'native'),
        ),
      );
    } else if (slot == 'native') {
      items.add(
        _ChannelMenuItem(
          label: 'Swap with Serving',
          onSelected: () => onSwap('native', 'serving'),
        ),
      );
      items.add(
        _ChannelMenuItem(
          label:
              _canRemove(slot) ? 'Disable' : 'Disable (only enabled channel)',
          enabled: _canRemove(slot),
          onSelected: () => onRemove(slot),
        ),
      );
      items.add(
        _ChannelMenuItem(
          label: 'Remove',
          destructive: true,
          onSelected: () => onPurge(slot),
        ),
      );
    }
    return items;
  }

  static String _targetLabelFor(ProjectKind kind) {
    switch (kind) {
      case ProjectKind.appPlayerApp:
        return 'AppPlayer App';
      case ProjectKind.studioPackage:
        return 'Studio Package';
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final showChannels = projectKind == ProjectKind.appPlayerApp;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space3),
      child: Row(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: VibeTokens.space3),
            child: Text(
              'Target: ${_targetLabelFor(projectKind)}',
              style: vibeMono(
                size: 11,
                weight: FontWeight.w500,
                color: c.textSecondary,
              ),
            ),
          ),
          if (showChannels) ...<Widget>[
            Padding(
              padding: const EdgeInsets.only(right: VibeTokens.space3),
              child: Text(
                'Channels:',
                style: vibeMono(
                  size: 11,
                  weight: FontWeight.w500,
                  color: c.textSecondary,
                ),
              ),
            ),
            for (final slot in _slotOrder) ...<Widget>[
              _ChannelChip(
                id: slot,
                label: _slotLabel[slot]!,
                channel: channels[slot],
                active: activeId == slot,
                dirty: dirty[slot] == true,
                menuItems: _menuFor(slot),
                onActivate: () => onActivate(slot),
                onCreate: () => onCreate(slot),
              ),
              const SizedBox(width: VibeTokens.space2),
            ],
          ],
          const Spacer(),
        ],
      ),
    );
  }
}

class _ChannelChip extends StatefulWidget {
  const _ChannelChip({
    required this.id,
    required this.label,
    required this.channel,
    required this.active,
    required this.dirty,
    required this.menuItems,
    required this.onActivate,
    required this.onCreate,
  });

  final String id;
  final String label;
  final ChannelDef? channel;
  final bool active;
  final bool dirty;

  /// Right-click menu rows. Empty list = no context menu (secondary
  /// tap becomes a no-op).
  final List<_ChannelMenuItem> menuItems;

  final VoidCallback onActivate;
  final VoidCallback onCreate;

  @override
  State<_ChannelChip> createState() => _ChannelChipState();
}

class _ChannelChipState extends State<_ChannelChip> {
  bool _hovered = false;
  final GlobalKey _chipKey = GlobalKey();

  bool get _menuAvailable => widget.menuItems.isNotEmpty;

  /// Show the channel context menu anchored under the chip itself —
  /// matches `VibeEnumEditor._open` (property_editors.dart): rounded
  /// `radiusMd` border, `c.elevated` surface, no animation, compact
  /// 28-height items with `vibeMono` 11pt text. Anchoring to the chip
  /// (vs the cursor) keeps the popup tight to the trigger the way
  /// vibe's other dropdowns do.
  Future<void> _showContextMenu(BuildContext context) async {
    if (!_menuAvailable) return;
    final c = VibeTokens.colorOf(context);
    final box = _chipKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final overlaySize = overlayBox.size;
    final offset = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final size = box.size;
    final anchor = Rect.fromLTWH(
      offset.dx,
      offset.dy + size.height + 2,
      size.width,
      0,
    );
    final items = widget.menuItems;
    final selected = await showMenu<int>(
      context: context,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      menuPadding: EdgeInsets.zero,
      color: c.elevated,
      constraints: const BoxConstraints(minWidth: 160, maxWidth: 260),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
        side: BorderSide(color: c.borderStrong),
      ),
      position: RelativeRect.fromRect(anchor, Offset.zero & overlaySize),
      items: <PopupMenuEntry<int>>[
        for (var i = 0; i < items.length; i++)
          PopupMenuItem<int>(
            value: i,
            enabled: items[i].enabled,
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              items[i].label,
              style: vibeMono(
                size: 11,
                color:
                    !items[i].enabled
                        ? c.textTertiary
                        : items[i].destructive
                        ? c.coral
                        : c.textPrimary,
              ),
            ),
          ),
      ],
    );
    if (selected != null && selected >= 0 && selected < items.length) {
      final picked = items[selected];
      if (picked.enabled) picked.onSelected();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final ch = widget.channel;
    final enabled = ch?.enabled ?? false;
    final borderColor =
        widget.active ? c.mint : (_hovered ? c.borderStrong : c.borderDefault);
    final bg = widget.active ? c.surface3 : (_hovered ? c.surface2 : c.surface);
    final fg =
        widget.active
            ? c.textPrimary
            : (enabled ? c.textSecondary : c.textTertiary);
    final menuHint = _menuAvailable ? ' · right-click for options' : '';
    final tooltip =
        enabled
            ? (widget.active
                ? "${widget.label} channel (active)$menuHint"
                : "Switch to ${widget.label}$menuHint")
            : "Create ${widget.label} channel";
    final chip = AnimatedContainer(
      key: _chipKey,
      duration: VibeTokens.durFast,
      curve: VibeTokens.easeStandard,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
        border: Border.all(
          color: borderColor,
          width: widget.active ? 1.5 : 1.0,
          style: enabled ? BorderStyle.solid : BorderStyle.solid,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (!enabled) ...<Widget>[
            Icon(Icons.add, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            widget.label,
            style: vibeMono(size: 11, weight: FontWeight.w500, color: fg),
          ),
        ],
      ),
    );
    final body =
        enabled && widget.dirty
            ? Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                chip,
                Positioned(
                  right: 4,
                  top: 4,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: c.amber,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            )
            : chip;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 400),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? widget.onActivate : widget.onCreate,
          // Right-click — only optional + enabled chips have a menu
          // (serving is the required spine; disabled chips have
          // nothing to remove). The popup is anchored to the chip
          // itself (via `_chipKey`) the way vibe's other dropdowns
          // are, so cursor coordinates aren't needed.
          onSecondaryTap:
              _menuAvailable ? () => _showContextMenu(context) : null,
          child: body,
        ),
      ),
    );
  }
}

/// Outcome of a `flutter create` invocation triggered by the Build
/// dialog. The build still succeeds when scaffolding fails — the
/// emitted Dart sources are independent of platform folders — but the
/// dialog footer surfaces the message so the user knows whether the
/// scaffolding step actually ran.
class _FlutterCreateOutcome {
  const _FlutterCreateOutcome({
    required this.message,
    required this.scaffoldedDirs,
  });

  final String message;
  final List<String> scaffoldedDirs;
}
