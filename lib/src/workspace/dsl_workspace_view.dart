/// `DslWorkspaceView` — Flutter widget that mounts a `.mbd` bundle (or
/// the `ui/app.json` it ships) inside a runtime instance. The runtime
/// is the namespaced `vibe_studio_runtime` fork so that two runtimes
/// (one for the host's own preview, one for the active domain bundle)
/// can coexist without process-global singleton clashes.
///
/// Round B initial form: load the bundle directory, read
/// `ui/app.json`, hand it to `MCPUIRuntime`, render. Multi-bundle
/// composition (split / tabbed / nested workspace) lands in Round C.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
// Workspace view uses the namespaced `vibe_studio_runtime` fork (see
// `project_vibe_studio_runtime_fork`). The preview path inside
// app_builder keeps `flutter_mcp_ui_runtime`, so both runtimes
// coexist as separate Dart libraries with their own process-global
// singletons (NavigationService, NavigatorState GlobalKey,
// WidgetCache). Without the fork, opening a workspace tab while a
// preview tab is alive produced a duplicate-key crash.
import 'package:appplayer_studio/runtime.dart' as studio;
import 'package:appplayer_studio/base.dart' as base;
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:appplayer_studio/ui.dart' as ui;

/// Mounts the DSL UI of a single domain bundle. Pass either a
/// directory path containing `ui/app.json` (and any reserved-folder
/// content) or a packed `.mcpb` archive — the loader unpacks `.mcpb`
/// to a temp directory before mounting.
class DslWorkspaceView extends StatefulWidget {
  const DslWorkspaceView({
    super.key,
    required this.bundlePath,
    this.boot,
    this.chromeBridge,
    this.initialState,
    this.entryRoute = '/',
    this.placeholder,
    this.errorBuilder,
    this.enablePageNav = false,
    this.previewMode,
    this.gateTabKey,
    this.selectedWidgetPath,
    this.onSelectWidget,
    this.inspectRoot,
  });

  /// Currently-selected widget path — used to draw the mint highlight
  /// over the matching node. Null = no selection / inspect disabled.
  /// Mirrors `base.PreviewPanel.selectedWidgetPath` so the AppBuilder
  /// shell can wire its `_selectedWidgetPath` straight through.
  final base.WidgetPath? selectedWidgetPath;

  /// Reports tap-to-select events from the inspector overlay. Hosts
  /// take the path and write it back into their own selection state
  /// (which then flows back through [selectedWidgetPath] on the next
  /// build). Null = inspect mode disabled.
  final ValueChanged<base.WidgetPath>? onSelectWidget;

  /// Root JSON node the inspector resolves hits against (the focused
  /// page's `content` or component's `template`). When null the
  /// inspect overlay stays off and `runtime.buildUI()` uses the fast
  /// path (no MetaData wrapping, zero per-node overhead). Non-null
  /// switches `_bootRuntime` to `MCPUIRuntime.withInspector(...)` so
  /// every rendered widget is paired with its source JSON node.
  final Map<String, dynamic>? inspectRoot;

  /// Forced brightness for the rendered bundle UI — `'light'` /
  /// `'dark'` / null (= dark to match the studio chrome). Drives the
  /// inner `Theme.brightness` so a host preview can flip themes
  /// without touching the canonical bundle. Mirrors PreviewMcpUi's
  /// `previewMode` so the AppPlayer and Studio Package previews
  /// honour the same brightness toggle.
  final String? previewMode;

  /// Optional MCP `ServerBootstrap` — when provided, every
  /// `type: "tool"` action inside the bundle's UI routes through
  /// `boot.callTool` so the bundle's declared tools (plus any
  /// `requires.builtinTools` it depends on) actually dispatch instead
  /// of silently no-op'ing. Falls through to a 'default' tool
  /// executor that wraps the result body for spec §3.10 auto-merge.
  final mk.KernelServerHost? boot;

  /// Optional chrome bridge — when supplied, this view wires
  /// `bridge.updateRuntimeState` to its runtime so host paths can
  /// push state into the running DSL (chrome row 2 clicks, external
  /// MCP `studio.renderer.activate` callers — both bypass DSL's own
  /// tool executor so their response flags never auto-merge naturally).
  final base.ChromeBridge? chromeBridge;

  /// Initial state map written into the DSL runtime right after
  /// `initialize`. Use for host-known values that DSL bindings need
  /// before the user interacts (e.g., `currentProject` for embedded
  /// target previews). Subsequent updates flow through
  /// `chromeBridge.updateRuntimeState`.
  final Map<String, dynamic>? initialState;

  /// Absolute path to the bundle root. Either a directory (`.mbd/`
  /// flavour) or a `.mcpb` archive — Round B handles the directory
  /// case; the archive path falls through to [errorBuilder] until
  /// runtime-side unpack lands.
  final String bundlePath;

  /// Initial route in the bundle's `routes` map. Bundles without
  /// `routes` fall back to the application body.
  final String entryRoute;

  /// Widget shown while the bundle is loading. Defaults to a centred
  /// progress indicator with a small caption.
  final Widget? placeholder;

  /// Widget shown when load fails. Defaults to a coral-ish error pane.
  final Widget Function(BuildContext, Object error)? errorBuilder;

  /// When true, overlay a draggable page-nav strip on top of the
  /// rendered runtime UI listing each router case as a pill. Default
  /// false — the outer builder shell does not show its own nav since
  /// the shell already exposes its pages through domain-icon chrome.
  /// Set to true only for embedded target workspaces (the bundle being
  /// authored) where in-canvas page switching is the entire point.
  final bool enablePageNav;

  /// Override for the active-tab gate key. Default = null → the view
  /// gates on its own `bundlePath` (which is what
  /// [_DslWorkspaceViewState._registeredTabKey] resolves to), matching
  /// the chrome-tab path where the bundle lives. Hosts that mount this
  /// view *embedded* inside another tab's body (e.g. AppBuilder's
  /// preview canvas hosting the active studioPackage target) must
  /// override this with the parent tab's key so the embed mounts when
  /// the parent tab is active — without the override the embed
  /// compares its own bundle path against the chrome's `activeTabKey`,
  /// which is the *parent* path, and the gate never resolves to active.
  final String? gateTabKey;

  @override
  State<DslWorkspaceView> createState() => _DslWorkspaceViewState();
}

class _DslWorkspaceViewState extends State<DslWorkspaceView> {
  studio.MCPUIRuntime? _runtime;
  Object? _error;
  bool _booting = true;
  bool _uiMissing = false;
  void Function()? _runtimeStateUnbind;
  String? _registeredTabKey;

  /// Bundle-authored theme map (from `ui/app.json#theme`) — null when
  /// the bundle doesn't ship its own theme. Cached at boot so
  /// [_applyHostBrightness] can re-push it on every swap without
  /// re-reading the file.
  Map<String, Object?>? _bundleTheme;

  /// Tracks whether this tab was the active one on the previous build
  /// of the gate's [ValueListenableBuilder]. Used to detect the
  /// inactive → active edge so we can re-inject the theme (bundle +
  /// host merge) the moment we become active. Closing another tab
  /// fires `_runtime.destroy()` on that view which resets the
  /// process-singleton ThemeManager; the surviving active tab needs
  /// to re-push its own theme to restore visible styling.
  bool _wasActive = false;
  // Page-nav overlay: populated when the bundle's manifest opts in via
  // `wiring.showPageNav: true` AND `ui/app.json` declares a `VbuRouter`
  // with `cases`. Hidden otherwise.
  bool _showPageNav = false;
  List<base.WorkspacePageNavEntry> _pageNavEntries =
      const <base.WorkspacePageNavEntry>[];

  /// Root key for the runtime's render tree — used by the inspector
  /// hit-test to resolve globalToLocal coordinates against the rendered
  /// widget surface. Mirrors AppBuilder's `_runtimeKey`
  /// (`vibe_studio/lib/src/apps/app_builder/feat/preview_mcp_ui.dart`).
  final GlobalKey _runtimeKey = GlobalKey(debugLabel: 'dsl-runtime-root');

  /// Current mint highlight rect (in the runtime root's local space).
  /// Null when inspect is off, no selection, or the selected widget's
  /// RenderMetaData hasn't attached yet.
  Rect? _highlightRect;

  /// Retry ticker for the highlight rect — runs after a target /
  /// canonical patch so the rect lands on the new render tree once
  /// the RenderMetaData wrappers attach. Stops as soon as the rect
  /// settles or the retry budget elapses.
  Timer? _highlightTicker;
  int _highlightSeq = 0;
  static const Duration _highlightRetryBudget = Duration(seconds: 6);
  static const Duration _highlightRetryStep = Duration(milliseconds: 80);

  /// Stored start point for press-vs-drag discrimination — taps that
  /// move more than 8 logical px are treated as drags and never fire
  /// an inspect select. Mirrors AppBuilder's `_tapStart`.
  Offset? _tapStart;

  @override
  void initState() {
    super.initState();
    _bootRuntime();
    // Inactive-close path — another tab closing fires that view's
    // `_runtime.destroy()` which resets the process-singleton
    // ThemeManager. The current active tab needs to re-inject its
    // merged theme so its visible styling survives.
    widget.chromeBridge?.themeReinjectTick.addListener(_onThemeReinjectTick);
    // Debug-mode toggle — Settings → Debug mode flips
    // `chromeBridge.inspectorEnabled`. Live-reboot so the runtime
    // mounts through `MCPUIRuntime.withInspector(...)` (or the fast
    // path) under the new mode without forcing a tab reload.
    widget.chromeBridge?.inspectorEnabled.addListener(
      _onInspectorEnabledChanged,
    );
  }

  void _onInspectorEnabledChanged() {
    if (!mounted) return;
    _bootRuntime();
  }

  void _onThemeReinjectTick() {
    if (!_wasActive) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyHostBrightness(context);
    });
  }

  @override
  void didUpdateWidget(covariant DslWorkspaceView old) {
    super.didUpdateWidget(old);
    final inspectActivationChanged =
        (old.inspectRoot == null) != (widget.inspectRoot == null) ||
        (old.onSelectWidget == null) != (widget.onSelectWidget == null);
    if (old.bundlePath != widget.bundlePath ||
        old.entryRoute != widget.entryRoute ||
        inspectActivationChanged) {
      // Re-boot when the inspect toggle flips — the runtime is built
      // through a different constructor (`MCPUIRuntime.withInspector`
      // vs `MCPUIRuntime()`) so the widget tree needs a fresh mount
      // to pick up or drop the per-node MetaData wrappers.
      _bootRuntime();
    }
    if (old.previewMode != widget.previewMode) {
      // didUpdateWidget runs after the parent finished its setState,
      // so `context` is valid and `widget.previewMode` is the latest
      // value. Single source of brightness updates — calling from
      // build's post-frame loop produced race conditions across
      // rapid toggles.
      _applyHostBrightness(context);
    }
    if (old.selectedWidgetPath != widget.selectedWidgetPath ||
        old.inspectRoot != widget.inspectRoot) {
      // Selection or focused subtree changed — repoll the highlight
      // rect until the RenderMetaData for the new node attaches.
      _scheduleHighlightSettle();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Picks up host Theme changes (Settings dialog flipping the shell
    // light/dark) when `previewMode` is the default — the workspace
    // view inherits the chrome brightness in that mode.
    _applyHostBrightness(context);
  }

  /// Push the host's `previewMode` into the runtime's ThemeManager so
  /// the inner MaterialApp picks the matching light/dark variant.
  /// Effective only when `theme.mode == 'system'` (we force that
  /// inside [_bootRuntime]).
  ///
  /// `'system'` (or null) inherits the ancestor `Theme.of(context)`
  /// brightness — the workspace view is part of the studio chrome, so
  /// it follows the shell theme. Explicit `'light'` / `'dark'` pin the
  /// preview to that brightness regardless of host.
  /// Last brightness pushed into the runtime — guards
  /// [_applyHostBrightness] from re-emitting the same theme on every
  /// didChangeDependencies tick.
  Brightness? _lastAppliedBrightness;

  void _applyHostBrightness(BuildContext context) {
    final r = _runtime;
    if (r == null) return;
    Brightness b;
    switch (widget.previewMode) {
      case 'light':
        b = Brightness.light;
        break;
      case 'dark':
        b = Brightness.dark;
        break;
      default:
        b = Theme.of(context).brightness;
    }
    // Re-inject the ThemeDefinition on every mount / swap. Closing
    // a tab fires `_runtime.destroy()` which resets the
    // process-singleton ThemeManager (mcp_ui_runtime.dart:506
    // `ThemeManager.instance.reset()`); without re-injection the
    // other alive tabs lose their theme and revert to the default
    // Blue indigo seed.
    //
    // Bundle-authored theme (`ui/app.json#theme`) and the studio's
    // default merge field-by-field — bundle wins when present,
    // host fills the gaps. So a bundle that ships only a `light`
    // variant still gets the studio's `dark` variant for dark mode
    // (and vice versa). Top-level common (color / typography / …)
    // follows the same rule.
    r.themeManager.setTheme(_resolvedTheme());
    // `setStateManager` overlaps with `setHostBrightness` (both
    // drive the effective mode — bundle state.theme.mode binding vs
    // host brightness override). Priority undecided; skip the
    // wiring for now and let `setHostBrightness` be the single mode
    // source. Re-enable once the precedence is settled.
    // r.themeManager.setStateManager(r.stateManager);
    //
    // No `b == _lastAppliedBrightness` short-circuit — the swap-edge
    // caller invokes this AFTER the previous `MCPRuntimeWidget.dispose`
    // wiped the singleton's `_hostBrightnessOverride` to null (package
    // src/mcp_ui_runtime.dart:604). The chrome shell brightness is
    // unchanged across the swap, but the singleton is in a different
    // state; without re-pushing the same value the inner MaterialApp's
    // first build evaluates `flutterThemeMode='system'` and falls back
    // to OS platformBrightness, producing a visible light/dark flip
    // when chrome and OS disagree (e.g. chrome dark + OS light).
    _lastAppliedBrightness = b;
    r.themeManager.setHostBrightness(b);
  }

  /// Merge the bundle-authored theme (when present) with the
  /// studio's default `studioRuntimeTheme()`. Bundle fields win;
  /// missing variants / common fields fall back to the host.
  Map<String, Object?> _resolvedTheme() {
    final host = ui.VbuTheme.studioRuntimeTheme();
    final bundle = _bundleTheme;
    if (bundle == null) return host;
    final merged = <String, Object?>{...host, ...bundle};
    // light / dark sub-variants — merge entry-by-entry so a partial
    // override (e.g. bundle ships only `light.color`) still inherits
    // missing siblings from the host.
    for (final key in const <String>['light', 'dark']) {
      final hostVariant = host[key];
      final bundleVariant = bundle[key];
      if (hostVariant is Map<String, Object?>) {
        if (bundleVariant is Map<String, Object?>) {
          merged[key] = <String, Object?>{...hostVariant, ...bundleVariant};
        } else {
          merged[key] = hostVariant;
        }
      } else if (bundleVariant is Map<String, Object?>) {
        merged[key] = bundleVariant;
      }
    }
    return merged;
  }

  /// `RenderInspector` wrapper passed to
  /// `MCPUIRuntime.withInspector(widgetWrapper:)` when inspect mode is
  /// active. Tags every rendered widget with its source JSON node so
  /// the overlay's hit-test can chain back to a [base.WidgetPath].
  /// Behaviour is `translucent` — the wrapper participates in hit-test
  /// results but doesn't add an opaque hit region, so the underlying
  /// runtime widget still receives the tap (button presses still fire
  /// even with inspect on).
  Widget _wrapForInspector(Widget child, Map<String, dynamic> node) {
    return MetaData(
      metaData: node,
      behavior: HitTestBehavior.translucent,
      child: child,
    );
  }

  /// Hit-test a tap against the runtime's render tree, walk the
  /// resulting RenderMetaData chain into a [base.WidgetPath], and
  /// forward it to [DslWorkspaceView.onSelectWidget]. Mirrors
  /// AppBuilder's `_handleInspectTap`
  /// (`vibe_studio/lib/src/apps/app_builder/feat/preview_mcp_ui.dart`):
  /// retries up to 4 times with a 60 ms gap so the inspector
  /// RenderMetaData wrappers have time to attach right after a target
  /// / runtime swap.
  void _handleInspectTap(Offset globalPosition, {int retriesLeft = 4}) {
    final root = widget.inspectRoot;
    final cb = widget.onSelectWidget;
    if (root == null || cb == null) return;
    final ctx = _runtimeKey.currentContext;
    if (ctx == null) {
      if (retriesLeft > 0 && mounted) {
        Future<void>.delayed(const Duration(milliseconds: 60), () {
          if (!mounted) return;
          _handleInspectTap(globalPosition, retriesLeft: retriesLeft - 1);
        });
      }
      return;
    }
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.attached) {
      if (retriesLeft > 0 && mounted) {
        Future<void>.delayed(const Duration(milliseconds: 60), () {
          if (!mounted) return;
          _handleInspectTap(globalPosition, retriesLeft: retriesLeft - 1);
        });
      }
      return;
    }
    final localPosition = box.globalToLocal(globalPosition);
    final result = BoxHitTestResult();
    final hit = box.hitTest(result, position: localPosition);
    if (!hit || result.path.isEmpty) {
      if (retriesLeft > 0 && mounted) {
        Future<void>.delayed(const Duration(milliseconds: 60), () {
          if (!mounted) return;
          _handleInspectTap(globalPosition, retriesLeft: retriesLeft - 1);
        });
      }
      return;
    }
    final candidates = <Object>[];
    for (final entry in result.path) {
      final t = entry.target;
      if (t is RenderMetaData) {
        final m = t.metaData;
        if (m is Map<String, dynamic>) candidates.add(m);
      }
    }
    final chainPath = base.resolveTapPathFromChain(root, candidates);
    if (chainPath != null && chainPath.isNotEmpty) {
      cb(chainPath);
      return;
    }
    final winner = base.selectCanonicalPath(root, candidates);
    if (winner != null) cb(winner);
  }

  /// Walk the runtime's render tree looking for the RenderMetaData
  /// whose metadata Map matches the node at [widget.selectedWidgetPath]
  /// inside [widget.inspectRoot]; convert its bounds into the runtime
  /// root's local space so the overlay can position the mint border.
  /// Returns null when inspect is off, no path is selected, the node
  /// is missing from the tree, or any RenderObject involved is detached.
  Rect? _resolveHighlightRect() {
    final root = widget.inspectRoot;
    final path = widget.selectedWidgetPath;
    final cb = widget.onSelectWidget;
    if (root == null || cb == null || path == null || path.isEmpty) {
      return null;
    }
    final targetNode = base.atPath(root, path);
    if (targetNode is! Map<String, dynamic>) return null;
    final rootCtx = _runtimeKey.currentContext;
    if (rootCtx == null) return null;
    final rootObj = rootCtx.findRenderObject();
    if (rootObj is! RenderBox || !rootObj.attached) return null;

    // Three-tier match — identity → shallow-same → structural. Same
    // ladder AppBuilder's `_findRectFor` uses; needed because the
    // runtime that mounts here (`raw` loaded inside `_bootRuntime`)
    // is a separate decode from the shell's `inspectRoot`, so
    // identity always misses on this view and a naïve `type+id`
    // shallow check collapses every sibling of the same type onto
    // the first match (visible bug: clicking the 3rd text in a
    // page lit the 2nd one's box). The shallow + structural tiers
    // compare every scalar field instead, which discriminates
    // siblings by their literal `value` / `text` / etc.
    RenderBox? exact;
    RenderBox? shallow;
    RenderBox? structural;
    void visit(RenderObject ro) {
      if (exact != null) return;
      if (ro is RenderMetaData) {
        final meta = ro.metaData;
        if (identical(meta, targetNode)) {
          if (ro.child is RenderBox) exact = ro.child as RenderBox;
          return;
        }
        if (meta is Map<String, dynamic>) {
          if (shallow == null && base.shallowSameMap(meta, targetNode)) {
            if (ro.child is RenderBox) shallow = ro.child as RenderBox;
          } else if (structural == null &&
              base.structurallySameWidget(meta, targetNode)) {
            if (ro.child is RenderBox) structural = ro.child as RenderBox;
          }
        }
      }
      ro.visitChildren(visit);
    }

    visit(rootObj);
    final box = exact ?? shallow ?? structural;
    if (box == null || !box.attached) return null;
    final transform = box.getTransformTo(rootObj);
    return MatrixUtils.transformRect(transform, Offset.zero & box.size);
  }

  /// Kick off a short ticker that polls [_resolveHighlightRect] until
  /// it settles or the retry budget elapses. Mirrors AppBuilder's
  /// `_highlightTicker` — covers the race where the inspector
  /// RenderMetaData wrappers attach a frame or two after the widget
  /// params update.
  void _scheduleHighlightSettle() {
    final mySeq = ++_highlightSeq;
    _highlightTicker?.cancel();
    final deadline = DateTime.now().add(_highlightRetryBudget);
    _highlightTicker = Timer.periodic(_highlightRetryStep, (t) {
      if (!mounted || mySeq != _highlightSeq) {
        t.cancel();
        _highlightTicker = null;
        return;
      }
      final next = _resolveHighlightRect();
      if (next != _highlightRect) {
        setState(() => _highlightRect = next);
      }
      if (next != null || DateTime.now().isAfter(deadline)) {
        t.cancel();
        _highlightTicker = null;
      }
    });
  }

  /// Resolve this tab's `DispatchSession` from the chrome bridge so
  /// every `callTool` going through `boot.callTool` runs
  /// inside the right Zone — knowledge tool handlers' `scopeId`
  /// then sees this bundle's caller automatically. Returns null
  /// when chrome bridge is unwired or the bundle hasn't activated
  /// yet (early boot probes).
  base.DispatchSession? _resolveSession() {
    final chrome = widget.chromeBridge;
    if (chrome == null) return null;
    final bundleId = chrome.bundleIdForTab(widget.bundlePath);
    if (bundleId == null) return null;
    final sessions = base.SessionRegistry.instance.forBundle(bundleId);
    return sessions.isEmpty ? null : sessions.first;
  }

  /// Wrapper that calls a host MCP tool inside this tab's session
  /// Zone (when one is open). Decodes the response body the same
  /// way the three call sites used to do inline.
  Future<Map<String, dynamic>> _callHostTool(
    mk.KernelServerHost boot,
    String tool,
    Map<String, dynamic> params,
  ) async {
    Future<mk.KernelToolResult> doCall() => boot.callTool(tool, params);
    final session = _resolveSession();
    final result =
        session == null
            ? await doCall()
            : await base.DispatchContext.instance.runScoped(session, doCall);
    if (result.content.isEmpty ||
        result.content.first is! mk.KernelTextContent) {
      return <String, dynamic>{};
    }
    final text = (result.content.first as mk.KernelTextContent).text;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{'value': decoded};
    } catch (_) {
      return <String, dynamic>{'text': text};
    }
  }

  Future<void> _bootRuntime() async {
    setState(() {
      _booting = true;
      _error = null;
      _uiMissing = false;
      _showPageNav = false;
      _pageNavEntries = const <base.WorkspacePageNavEntry>[];
    });
    try {
      final stat = await FileSystemEntity.type(widget.bundlePath);
      if (stat == FileSystemEntityType.notFound) {
        throw FileSystemException('bundle not found', widget.bundlePath);
      }
      if (stat == FileSystemEntityType.file) {
        throw UnimplementedError(
          'Round B handles directory bundles only; .mcpb archive support '
          'lands once `vibe_studio_runtime` exposes its unpack helper.',
        );
      }

      // Directory bundle — read `ui/app.json`. Other reserved-folder
      // content (templates, components) is loaded transparently by the
      // runtime once it runs `loadFromUri('ui://app')`.
      final appFile = File(p.join(widget.bundlePath, 'ui', 'app.json'));
      if (!await appFile.exists()) {
        // Empty scaffold case — bundle has no UI yet. Surface a
        // builder-prompt placeholder so the user knows to drive the
        // chat agent ("describe what to build"). This is the empty
        // canvas the studio.builder agent fills in via
        // studio.builder.writeUI.
        if (mounted)
          setState(() {
            _booting = false;
            _uiMissing = true;
          });
        return;
      }
      final raw = jsonDecode(await appFile.readAsString());
      if (raw is! Map<String, dynamic>) {
        throw FormatException('ui/app.json must be a JSON object');
      }

      // Resolve `ui://pages/<id>` (or any `ui://<rel>`) to the bundle's
      // local page JSON under `ui/<rel>.json`. Shared by:
      //   - the application-envelope unwrap below (single-page case),
      //   - the runtime's pageLoader hook (multi-page routing case).
      Future<Map<String, dynamic>> loadPage(String uri) async {
        if (!uri.startsWith('ui://')) {
          throw FormatException(
            'unsupported page URI scheme: $uri (expected ui://)',
          );
        }
        final rel = uri.substring('ui://'.length);
        final pageFile = File(p.join(widget.bundlePath, 'ui', '$rel.json'));
        if (!await pageFile.exists()) {
          throw StateError('page file not found: ${pageFile.path} (uri=$uri)');
        }
        final decoded = jsonDecode(await pageFile.readAsString());
        if (decoded is! Map<String, dynamic>) {
          throw FormatException('page JSON must be an object: $uri');
        }
        return decoded;
      }

      final mountDef = raw;

      // Cache the bundle's own theme (if it ships one) so
      // `_applyHostBrightness` can re-inject it on every swap.
      // Bundle theme wins over the studio's default — authoring
      // intent of the bundle, not the host shell.
      final bundleThemeRaw = mountDef['theme'];
      _bundleTheme =
          bundleThemeRaw is Map<String, Object?>
              ? Map<String, Object?>.from(bundleThemeRaw)
              : null;

      // Mount through `MCPUIRuntime.withInspector(...)` whenever the
      // host has flipped `chromeBridge.inspectorEnabled` (driven by
      // Settings → Debug mode) OR the caller explicitly supplied an
      // inspect callback (AppBuilder's preview pane). The wrapper
      // doubles the RenderObject count per widget, so production
      // sessions default to the fast path; debug / recording
      // sessions opt-in. When inspector mode flips at runtime,
      // `_onInspectorEnabledChanged` reboots the runtime.
      final inspectByHost =
          widget.chromeBridge?.inspectorEnabled.value ?? false;
      final inspectByCaller =
          widget.inspectRoot != null && widget.onSelectWidget != null;
      final inspectActive = inspectByHost || inspectByCaller;
      final runtime =
          inspectActive
              ? studio.MCPUIRuntime.withInspector(
                widgetWrapper: _wrapForInspector,
              )
              : studio.MCPUIRuntime();
      // No host-side theme injection. AppPlayer pattern: only the
      // bundle's own `ui.theme` (if any) reaches the runtime;
      // otherwise mcp_ui's default ThemeData applies. Injecting
      // `studioRuntimeTheme()` on every mount drove the singleton
      // ThemeManager through repeated `setTheme` calls, leaving the
      // last-mounted bundle's theme winning across all alive tabs
      // (visible regression: returning to an earlier tab loses its
      // text styling). Per-runtime brightness still flows through
      // `setHostBrightness` from `_applyHostBrightness` below.
      // Disable schema validation — the studio extensively uses
      // host-registered custom widgets (Vbu*) that aren't in the
      // mcp_ui core widgets schema. Schema gating rejects them up
      // front even though the factories are registered. Validation
      // is the wrong gate for a host with custom widget catalogue;
      // missing/typo'd widgets surface as render-time fallbacks.
      //
      // pageLoader stays registered for any nested `use` widget or
      // future multi-route case the runtime may invoke.
      await runtime.initialize(
        mountDef,
        validateSchema: false,
        pageLoader: loadPage,
      );
      base.registerToolWidgets(runtime);
      base.registerVbuWidgets(runtime);
      // Override the base-side `VbuBundleEmbed` placeholder factory
      // with the real one that mounts a nested DslWorkspaceView. Base
      // can't register it directly without an import cycle (base ←
      // workspace), so the workspace overrides post-registration.
      runtime.registerWidget(
        'VbuBundleEmbed',
        _VbuBundleEmbedFactory(
          boot: widget.boot,
          chromeBridge: widget.chromeBridge,
        ),
      );
      // Same override for `VbuBundleToolsEditor` — mounts the host's
      // BundleToolsView against the target bundle (Tools / Domain Icons /
      // Slash Commands / Settings / Lifecycle, click-to-edit detail).
      runtime.registerWidget(
        'VbuBundleToolsEditor',
        _VbuBundleToolsEditorFactory(chromeBridge: widget.chromeBridge),
      );
      // Override `VbuPreviewMcpUi` placeholder with the real PreviewPanel
      // factory — loads a `WorkspaceCanonical` for the target bundle and
      // mounts the full chrome (track tabs + device frame + mcp_ui_runtime).
      // Without a `bundlePath` prop or active project, renders an
      // explicit empty-target placeholder (no self-mount fallback).
      runtime.registerWidget(
        'VbuPreviewMcpUi',
        _VbuPreviewMcpUiRealFactory(chromeBridge: widget.chromeBridge),
      );

      // Wire tool actions to the host's MCP server. Must be AFTER
      // initialize() — registerToolExecutor asserts the runtime is
      // initialized. The 'default' executor catches every tool the
      // UI invokes; result body is JSON-decoded so spec §3.10
      // auto-merge picks up its top-level keys.
      //
      // Caveat: lifecycle.onInit hooks fire during initialize() with
      // no executor registered. We re-fire any declared onInit hooks
      // ourselves after register so the first auto-load lands.
      final boot = widget.boot;
      if (boot != null) {
        Future<Map<String, dynamic>> exec(
          String tool,
          Map<String, dynamic> params,
        ) => _callHostTool(boot, tool, params);

        runtime.registerToolExecutor('default', (tool, params) async {
          final args =
              params is Map
                  ? Map<String, dynamic>.from(params)
                  : <String, dynamic>{};
          return exec(tool as String, args);
        });
        // DSL `{"type":"resource","action":"subscribe","uri":"kb://..."}`
        // resolves through the host MCP server's `resources/read`
        // endpoint — that side is wired by R40's resourceServerAdapter
        // dual-write so registering the same kb URI on `bridge` also
        // lands on `boot.server.addResource`. The self-rendered
        // MCPUIRuntime here exposes `registerResourceSubscription`,
        // not a local resource handler; spec §6.4 path is via the
        // server, which is already covered.
        // _reFireOnInit is deferred until after `registerTabRuntime`
        // below — onInit hooks may call host MCP verbs (e.g.
        // `studio.project.open`) whose state-push side effects route
        // through `chromeBridge.updateRuntimeState` → this tab's
        // hooks. Firing before registration would silently drop those
        // pushes.
      }

      _runtime?.destroy();
      _runtime = runtime;
      _booting = false;
      // Push the host's brightness onto the freshly-booted runtime
      // exactly once. didUpdateWidget handles subsequent toggles;
      // doing it on every build led to race conditions where rapid
      // toggles landed out of order.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applyHostBrightness(context);
      });
      // Register this tab's runtime hooks on the chrome bridge so the
      // workspace can route navigation / state-push calls to the
      // ACTIVE tab's runtime — not whichever DslWorkspaceView booted
      // most recently. The workspace owns the singleton chrome-bridge
      // slots; each tab just publishes its hooks under its own tab key.
      _registeredTabKey = widget.bundlePath;
      widget.chromeBridge?.registerTabRuntime?.call(
        _registeredTabKey!,
        base.TabRuntimeHooks(
          navigate: (route) {
            try {
              // chrome↔bundle navigation contract — chrome writes the
              // active route to `currentRoute` (top-level). Bundles
              // that want chrome-driven routing bind their router
              // widget (e.g. VbuRouter) to `{{currentRoute}}` and use
              // `currentRoute` as the `stateKey` of their nav
              // selectGroup in `manifest.wiring.domainActions[]`.
              // (Per mcp_ui_dsl 1.3, `runtime.*` binding paths are
              // reserved for engine capability info — version,
              // platform, locale, debug — and aren't reachable from
              // `{{...}}` bindings.)
              runtime.updateState('currentRoute', route);
              return true;
            } catch (_) {
              return false;
            }
          },
          updateState: (state) {
            for (final entry in state.entries) {
              runtime.updateState(entry.key, entry.value);
            }
          },
          readState:
              () => Map<String, Object?>.from(runtime.stateManager.state),
          // Dispatch a tool through the same default-executor path
          // button clicks use, and mirror spec §3.10 auto-merge by
          // writing the response's top-level keys into runtime state.
          // Returns the parsed response so the debug tool can hand it
          // back to the caller — useful for external LLMs that want
          // to chain (dispatch → read state → dispatch next).
          dispatchTool:
              widget.boot == null
                  ? null
                  : (tool, params) async {
                    final result = await _callHostTool(
                      widget.boot!,
                      tool,
                      params,
                    );
                    for (final entry in result.entries) {
                      runtime.updateState(entry.key, entry.value);
                    }
                    return result;
                  },
        ),
      );
      // Seed initial state (e.g., currentProject path) so DSL bindings
      // pick it up before the user interacts.
      final init = widget.initialState;
      if (init != null) {
        for (final entry in init.entries) {
          runtime.updateState(entry.key, entry.value);
        }
      }
      // Now fire app-envelope `lifecycle.onInit` hooks. Deferred to
      // this point so the tab's runtime hooks are already registered
      // on the chrome bridge — onInit tools may call host verbs
      // (e.g. `studio.project.open`) that push state via
      // `chromeBridge.updateRuntimeState` → this tab. Firing earlier
      // (before registration) silently dropped those pushes.
      final bootForOnInit = widget.boot;
      if (bootForOnInit != null) {
        Future<Map<String, dynamic>> execOnInit(
          String tool,
          Map<String, dynamic> params,
        ) => _callHostTool(bootForOnInit, tool, params);

        // ignore: unawaited_futures
        _reFireOnInit(runtime, raw, execOnInit);
      }
      // Stream the bundle's runtime state out to the chrome — every
      // change forwards a fresh snapshot so chrome surfaces
      // (header-action emphasis, peek hints, …) react without any
      // host-side knowledge of which keys the bundle declared. The
      // listener stays alive until the next boot or destroy.
      final bridge = widget.chromeBridge;
      _runtimeStateUnbind?.call();
      _runtimeStateUnbind = null;
      if (bridge != null) {
        void emit() {
          try {
            bridge.onRuntimeStateChange?.call(
              Map<String, Object?>.from(runtime.stateManager.state),
            );
          } catch (_) {
            /* swallow — chrome listener is best-effort */
          }
        }

        runtime.stateManager.addListener(emit);
        _runtimeStateUnbind = () => runtime.stateManager.removeListener(emit);
        // First emission — chrome's cache starts empty so the active
        // tab's initial state needs to land immediately.
        emit();
      }

      // Page-nav overlay: only when the caller asked for it (embed
      // factory sets this true). Builder shells themselves leave it
      // off — their pages are already exposed through chrome domain
      // icons; the overlay belongs to the target being authored.
      final navEntries =
          widget.enablePageNav
              ? _extractRouterEntries(raw['content'])
              : const <base.WorkspacePageNavEntry>[];
      _showPageNav = widget.enablePageNav && navEntries.isNotEmpty;
      _pageNavEntries = navEntries;

      if (mounted) setState(() {});
    } catch (e) {
      _error = e;
      _booting = false;
      if (mounted) setState(() {});
    }
  }

  /// Re-execute the bundle's declared `lifecycle.onInit` `tool` hooks
  /// directly through [exec], then mirror the spec §3.10 auto-merge
  /// by writing each top-level key of the response into runtime state
  /// via [studio.MCPUIRuntime.updateState]. The engine's own
  /// `executeOnInit` fires during [studio.MCPUIRuntime.initialize] —
  /// before any host-side executor exists — so the first auto-load
  /// is otherwise silently lost.
  Future<void> _reFireOnInit(
    studio.MCPUIRuntime runtime,
    Map<String, dynamic> raw,
    Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) exec,
  ) async {
    final lifecycle = raw['lifecycle'];
    if (lifecycle is! Map<String, dynamic>) return;
    final hooks = lifecycle['onInit'];
    if (hooks is! List) return;
    for (final hook in hooks) {
      if (hook is! Map<String, dynamic>) continue;
      if (hook['type'] != 'tool') continue;
      final tool = hook['tool'];
      if (tool is! String || tool.isEmpty) continue;
      final params = hook['params'];
      final paramsMap =
          params is Map<String, dynamic>
              ? params
              : (params is Map
                  ? Map<String, dynamic>.from(params)
                  : <String, dynamic>{});
      Map<String, dynamic>? result;
      // Retry on "Tool not found" — `_activateBundle` registers JS
      // tools asynchronously after the tab mounts, so the first
      // onInit fire may race ahead of registration. Backoff up to
      // ~3 s, then give up silently.
      for (int attempt = 0; attempt < 15; attempt++) {
        try {
          result = await exec(tool, paramsMap);
          break;
        } catch (e) {
          final msg = e.toString();
          if (msg.contains('Tool not found') && attempt < 14) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            continue;
          }
          break;
        }
      }
      if (result == null) continue;
      // Mirror auto-merge: write each top-level key into state.
      for (final entry in result.entries) {
        runtime.updateState(entry.key, entry.value);
      }
    }
  }

  @override
  void dispose() {
    _highlightTicker?.cancel();
    _highlightTicker = null;
    widget.chromeBridge?.themeReinjectTick.removeListener(_onThemeReinjectTick);
    widget.chromeBridge?.inspectorEnabled.removeListener(
      _onInspectorEnabledChanged,
    );
    _runtimeStateUnbind?.call();
    _runtimeStateUnbind = null;
    final key = _registeredTabKey;
    if (key != null) {
      widget.chromeBridge?.registerTabRuntime?.call(key, null);
      _registeredTabKey = null;
    }
    _runtime?.destroy();
    // Notify surviving tabs to re-inject their merged theme — the
    // destroy() above just reset the process-singleton ThemeManager.
    widget.chromeBridge?.themeReinjectTick.value++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Multi-tab gate — `vibe_studio_runtime` hard-codes its
    // `NavigationService.instance.navigatorKey` as a process singleton.
    // Two `application`-typed workspaces alive at the same time would
    // both call `runtime.buildUI()`, both reach for that same key,
    // and Flutter would reparent the Navigator from one to the other
    // (visible regression: the chrome tab content vanishes the moment
    // a second authoring tab opens). Mirror AppPlayer's
    // `RuntimeManager` pattern — keep per-tab runtime state alive
    // (IndexedStack preserves it across switches), but only the
    // active tab calls `buildUI()`. Inactive tabs render a token-bg
    // placeholder so the swap is invisible against the chrome.
    final c = ui.VbuTokens.colorOf(context);
    Widget wrap(Widget child) => Container(color: c.bg, child: child);
    if (_booting) {
      return wrap(widget.placeholder ?? const _DefaultPlaceholder());
    }
    if (_uiMissing) {
      return wrap(const _BuilderEmptyCanvas());
    }
    final err = _error;
    if (err != null) {
      final builder = widget.errorBuilder;
      if (builder != null) return wrap(builder(context, err));
      return wrap(_DefaultErrorPane(error: err));
    }
    final runtime = _runtime;
    if (runtime == null) {
      return wrap(widget.placeholder ?? const _DefaultPlaceholder());
    }
    // Brightness override for the rendered bundle. Mirrors the path
    // PreviewMcpUi uses for AppPlayer App previews — outer
    // `MediaQuery(platformBrightness:)` + `Theme(brightness:)` wrap
    // around `runtime.buildUI()`. Explicit `'light'`/`'dark'` pin the
    // preview regardless of host; default (null/'system') inherits
    // the ancestor Theme so the workspace view follows the chrome.
    final brightness = switch (widget.previewMode) {
      'light' => Brightness.light,
      'dark' => Brightness.dark,
      _ => Theme.of(context).brightness,
    };
    // Inspect overlay — active when host wired both an `inspectRoot`
    // and an `onSelectWidget` callback. Mirrors AppBuilder's
    // `feat/preview_mcp_ui.dart`: a translucent `Listener` parent
    // observes taps (drag-vs-tap discriminated by an 8px threshold)
    // so widgets inside the runtime still receive their own onPressed,
    // a [KeyedSubtree] with `_runtimeKey` roots the hit-test
    // coordinate space, and the mint border floats as an
    // `IgnorePointer` sibling above the runtime.
    final inspectActive =
        widget.inspectRoot != null && widget.onSelectWidget != null;
    final baseBody = Builder(
      builder: (context) {
        final baseTheme = Theme.of(context);
        final mq = MediaQuery.of(context);
        Widget runtimeRoot = KeyedSubtree(
          key: _runtimeKey,
          child: runtime.buildUI(),
        );
        if (inspectActive) {
          final highlight = _highlightRect;
          runtimeRoot = Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (e) => _tapStart = e.position,
                onPointerUp: (e) {
                  final start = _tapStart;
                  _tapStart = null;
                  if (start == null) return;
                  if ((e.position - start).distance > 8.0) return;
                  _handleInspectTap(e.position);
                },
                onPointerCancel: (_) => _tapStart = null,
                child: runtimeRoot,
              ),
              if (highlight != null)
                Positioned.fromRect(
                  rect: highlight,
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: ui.VbuTokens.colorOf(context).mint,
                          width: 1.5,
                        ),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
            ],
          );
        }
        return MediaQuery(
          data: mq.copyWith(platformBrightness: brightness),
          child: Theme(
            data: baseTheme.copyWith(brightness: brightness),
            child: runtimeRoot,
          ),
        );
      },
    );
    // Wrap with Material + DefaultTextStyle so DSL `text` widgets
    // outside the runtime's own MaterialApp (e.g. the page-nav
    // overlay below) inherit visible defaults. Use `c.textPrimary`
    // directly (light: near-black, dark: near-white) — `Colors.black87`
    // is 87% opacity black, which renders inner text as a washed-out
    // grey when the runtime's text widget inherits it via DefaultTextStyle.
    final body = Material(
      type: MaterialType.transparency,
      textStyle: TextStyle(
        fontFamily: ui.VbuTokens.fontSans,
        fontSize: 14,
        color: c.textPrimary,
      ),
      child: DefaultTextStyle(
        style: TextStyle(
          fontFamily: ui.VbuTokens.fontSans,
          fontSize: 14,
          color: c.textPrimary,
        ),
        child: Container(color: c.bg, child: baseBody),
      ),
    );
    // Active-tab gate — see the build() header comment. Watch the
    // chrome bridge's `activeTabKey`; only mount the inner runtime
    // body when this tab key is the active one. Inactive tabs return
    // a token-bg placeholder so the swap is invisible against the
    // chrome. Bridge / key absent (embed or standalone mount path) ⇒
    // skip the gate (single-instance lifecycle).
    final bridge = widget.chromeBridge;
    final myTabKey = widget.gateTabKey ?? _registeredTabKey;
    Widget gated(Widget child) {
      if (bridge == null || myTabKey == null) return child;
      return ValueListenableBuilder<String?>(
        valueListenable: bridge.activeTabKey,
        builder: (ctx, activeKey, __) {
          final nowActive = activeKey == myTabKey;
          // Inactive → active edge — `MCPRuntimeWidget.dispose` on
          // the previous SizedBox.expand swap fired
          // `themeManager.setHostBrightness(null)` (package source
          // `flutter_mcp_ui_runtime/lib/src/mcp_ui_runtime.dart:604`),
          // wiping the singleton's host-brightness override. The
          // newly-mounted inner MaterialApp evaluates
          // `themeManager.flutterThemeMode` during its first build;
          // with the override null and `_themeMode='system'`,
          // MaterialApp falls back to the OS platformBrightness —
          // which is detached from our chrome-shell brightness when
          // settings pins a mode (e.g. chrome dark, OS light). Re-
          // inject SYNCHRONOUSLY here (before `return child`) so the
          // inner widget's first build sees the host override and
          // picks the matching theme variant. A postFrame call is
          // too late: it only fires AFTER the first build, leaving
          // one frame of the wrong color visible (and persistent
          // because subsequent rebuilds don't re-evaluate). Build-
          // phase setTheme/setHostBrightness is safe — both only
          // touch ThemeManager state and notify listeners (which
          // run in the next frame), not the current build.
          if (nowActive && !_wasActive) {
            _wasActive = true;
            _applyHostBrightness(ctx);
          } else if (!nowActive && _wasActive) {
            _wasActive = false;
          }
          if (!nowActive) return const SizedBox.expand();
          return child;
        },
      );
    }

    if (!_showPageNav || _pageNavEntries.isEmpty) {
      return wrap(gated(body));
    }
    // Overlay the floating page-nav strip on top of the workspace body.
    // Rebuilds the active-route highlight whenever the runtime's state
    // changes (specifically when `currentRoute` is written). Same
    // active-tab gate as the no-overlay branch — overlay tracks the
    // body's mount state.
    return wrap(
      gated(
        Stack(
          fit: StackFit.expand,
          children: <Widget>[
            body,
            Positioned.fill(
              child: AnimatedBuilder(
                animation: runtime.stateManager,
                builder: (context, _) {
                  final activeRaw = runtime.stateManager.get<dynamic>(
                    'currentRoute',
                  );
                  final active = activeRaw is String ? activeRaw : null;
                  return _PageNavOverlayHost(
                    entries: _pageNavEntries,
                    activeRoute: active,
                    onNavigate: (route) {
                      runtime.updateState('currentRoute', route);
                      runtime.updateState(
                        'runtime.navigation.currentRoute',
                        route,
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Walks a DSL widget tree looking for the first `VbuRouter` and
/// returns its `cases` keys as page-nav entries. Returns empty when no
/// router is present or `cases` is malformed. The label is derived
/// from the route key: leading slash stripped, first segment
/// capitalised (`/tools` → `Tools`, `/ui` → `UI`).
List<base.WorkspacePageNavEntry> _extractRouterEntries(dynamic node) {
  final router = _findVbuRouter(node);
  if (router == null) return const <base.WorkspacePageNavEntry>[];
  final cases = router['cases'];
  if (cases is! Map) return const <base.WorkspacePageNavEntry>[];
  final out = <base.WorkspacePageNavEntry>[];
  for (final entry in cases.entries) {
    final route = entry.key;
    if (route is! String || route.isEmpty) continue;
    out.add(
      base.WorkspacePageNavEntry(route: route, label: _routeLabel(route)),
    );
  }
  return out;
}

Map<String, dynamic>? _findVbuRouter(dynamic node) {
  if (node is Map<String, dynamic>) {
    if (node['type'] == 'VbuRouter') return node;
    for (final v in node.values) {
      final hit = _findVbuRouter(v);
      if (hit != null) return hit;
    }
  } else if (node is List) {
    for (final v in node) {
      final hit = _findVbuRouter(v);
      if (hit != null) return hit;
    }
  }
  return null;
}

String _routeLabel(String route) {
  final stripped = route.startsWith('/') ? route.substring(1) : route;
  if (stripped.isEmpty) return route;
  // First segment only (split on '/'), then upper-case the whole token
  // when short (≤3 chars, e.g., "ui" → "UI"), otherwise title-case.
  final first = stripped.split('/').first;
  if (first.length <= 3) return first.toUpperCase();
  return first[0].toUpperCase() + first.substring(1);
}

/// Thin shell so the import of [base.WorkspacePageNavOverlay] doesn't
/// leak into the runtime-state AnimatedBuilder body — keeps the
/// builder block tight.
class _PageNavOverlayHost extends StatelessWidget {
  const _PageNavOverlayHost({
    required this.entries,
    required this.activeRoute,
    required this.onNavigate,
  });
  final List<base.WorkspacePageNavEntry> entries;
  final String? activeRoute;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) {
    return base.WorkspacePageNavOverlay(
      entries: entries,
      activeRoute: activeRoute,
      onNavigate: onNavigate,
    );
  }
}

class _DefaultPlaceholder extends StatelessWidget {
  const _DefaultPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(strokeWidth: 2),
          SizedBox(height: 12),
          Text(
            'Loading workspace bundle…',
            style: TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _BuilderEmptyCanvas extends StatelessWidget {
  const _BuilderEmptyCanvas();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.architecture_outlined,
              size: 36,
              color: Colors.white24,
            ),
            const SizedBox(height: 12),
            const Text(
              'Empty bundle — no UI yet.',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Tell vibe what to build in the chat panel on the left.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DefaultErrorPane extends StatelessWidget {
  const _DefaultErrorPane({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Workspace bundle failed to load:\n\n$error',
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
    );
  }
}

/// Factory for `VbuBundleEmbed` — mounts a nested [DslWorkspaceView]
/// pointing at the bundle path resolved from the DSL definition. Used
/// by studio_builder's seed UI to embed the target package's
/// `ui/app.json` inside its workspace's UI page.
class _VbuBundleEmbedFactory extends studio.WidgetFactory {
  _VbuBundleEmbedFactory({this.boot, this.chromeBridge});
  final mk.KernelServerHost? boot;
  final base.ChromeBridge? chromeBridge;

  @override
  Widget build(Map<String, dynamic> definition, studio.RenderContext context) {
    final props = extractProperties(definition);
    final bundlePath = context.resolve<String?>(props['bundlePath']) ?? '';
    if (bundlePath.isEmpty) {
      // Empty embed slot — render nothing. The host bundle's own
      // `{{currentProject}}` branching owns the "no project" UX; the
      // workspace view does not inject any placeholder.
      return const SizedBox.expand();
    }
    return DslWorkspaceView(
      key: ValueKey('embed::$bundlePath'),
      bundlePath: bundlePath,
      boot: boot,
      // Child bundle gets its own chrome bridge slot or nothing — the
      // outer seed's bridge is already consumed by the parent
      // DslWorkspaceView. Embedded bundles run standalone.
      //
      // Enable the floating page-nav overlay for the embedded target —
      // this is the surface the user authors against, and the overlay
      // is how they switch between the target's own pages while inside
      // the builder's `/ui` view.
      enablePageNav: true,
    );
  }
}

/// Factory for `VbuBundleToolsEditor` — mounts the host's
/// [base.BundleToolsView] against the bundle path resolved from the DSL
/// definition. Studio Builder's `/tools` page uses this to expose the
/// full wiring editor (Tools / Domain Icons / Slash Commands / Settings /
/// Lifecycle, click-to-edit detail) of the target package being authored.
class _VbuBundleToolsEditorFactory extends studio.WidgetFactory {
  _VbuBundleToolsEditorFactory({this.chromeBridge});
  final base.ChromeBridge? chromeBridge;

  @override
  Widget build(Map<String, dynamic> definition, studio.RenderContext context) {
    final props = extractProperties(definition);
    final bundlePath = context.resolve<String?>(props['bundlePath']) ?? '';
    if (bundlePath.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No bundle adopted yet — create or open a package.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: Colors.white54,
            ),
          ),
        ),
      );
    }
    final bridge = chromeBridge;
    if (bridge == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Tools editor needs a chrome bridge — host did not wire one.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: Colors.white54,
            ),
          ),
        ),
      );
    }
    final cfg = bridge.debugConfig?.call();
    final configRoot = (cfg?['configRoot'] as String?);
    final overridesFile = base.packageOverridesFile(
      configRoot: configRoot,
      pkgPath: bundlePath,
    );
    return base.BundleToolsView(
      key: ValueKey('tools-editor::$bundlePath'),
      bundlePath: bundlePath,
      overridesFile: overridesFile,
      chromeBridge: bridge,
      reloadCounter: 0,
      layout: base.BundleToolsLayout.panel,
    );
  }
}

/// Factory for `VbuPreviewMcpUi` — mounts the real [base.PreviewPanel]
/// against the **target project's** [base.WorkspaceCanonical]. Target
/// resolution order:
///   1. DSL `bundlePath` prop (resolved through the binding context).
///   2. `chromeBridge.activeProjectInfo`'s `projectPath` (the project
///      the host has currently adopted in the active tab).
///
/// When neither yields a path, renders an empty-target placeholder
/// (NOT a self-preview of the hosting bundle — that mounts the wrong
/// widget tree and hides the real "no project selected" state behind
/// a misleading render). The hosting bundle (e.g. app_builder) drives
/// the preview by creating / opening a project and surfacing its path
/// through `activeProjectInfo`; the preview shows that target only.
class _VbuPreviewMcpUiRealFactory extends studio.WidgetFactory {
  _VbuPreviewMcpUiRealFactory({this.chromeBridge});
  final base.ChromeBridge? chromeBridge;

  @override
  Widget build(Map<String, dynamic> definition, studio.RenderContext context) {
    final props = extractProperties(definition);
    final propBundlePath = context.resolve<String?>(props['bundlePath']) ?? '';
    final activeInfo = chromeBridge?.activeProjectInfo?.call();
    final activePath = activeInfo?['projectPath'] as String? ?? '';
    final bundlePath = propBundlePath.isNotEmpty ? propBundlePath : activePath;
    final focusPageId = context.resolve<String?>(props['focusPageId']);
    final focusComponentId = context.resolve<String?>(
      props['focusComponentId'],
    );
    final dashboardMode =
        context.resolve<bool?>(props['dashboardMode']) ?? false;

    if (bundlePath.isEmpty) {
      // No target project — render the inert `VbuPreviewMcpUi` atom
      // (device frame + "Wire factory" wireframe). The factory is
      // intentionally NOT mounted against a runtime here: there's
      // nothing to load. Self-mount fallback (hostBundlePath) removed
      // — it rendered the hosting bundle's own UI here, which is
      // misleading and triggered nested MaterialApp polymorphism.
      return ui.VbuPreviewMcpUi(
        bundleId: context.resolve<String?>(props['bundleId']),
        uiPath: context.resolve<String?>(props['uiPath']) ?? 'ui/app.json',
        deviceSize: context.resolve<String?>(props['deviceSize']),
        orientation:
            context.resolve<String?>(props['orientation']) ?? 'portrait',
        brightness: context.resolve<String?>(props['brightness']) ?? 'auto',
        showInspector: context.resolve<bool?>(props['showInspector']) ?? false,
      );
    }
    return _PreviewLoader(
      key: ValueKey('vbu_preview::$bundlePath'),
      bundlePath: bundlePath,
      focusPageId: focusPageId,
      focusComponentId: focusComponentId,
      dashboardMode: dashboardMode,
    );
  }
}

/// Lifecycle wrapper that owns a per-bundle [base.WorkspaceCanonical].
/// Loads on mount, disposes on unmount, and re-opens when [bundlePath]
/// changes so a parent-driven target swap (e.g. selecting a different
/// user-app project) re-mounts the preview cleanly.
class _PreviewLoader extends StatefulWidget {
  const _PreviewLoader({
    super.key,
    required this.bundlePath,
    this.focusPageId,
    this.focusComponentId,
    this.dashboardMode = false,
  });
  final String bundlePath;
  final String? focusPageId;
  final String? focusComponentId;
  final bool dashboardMode;

  @override
  State<_PreviewLoader> createState() => _PreviewLoaderState();
}

class _PreviewLoaderState extends State<_PreviewLoader> {
  base.WorkspaceCanonicalImpl? _canonical;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _PreviewLoader old) {
    super.didUpdateWidget(old);
    if (old.bundlePath != widget.bundlePath) {
      _dispose();
      setState(() {
        _loading = true;
        _error = null;
      });
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final canon = base.WorkspaceCanonicalImpl(
        fsPort: base.FileWorkspaceFsPort(),
        validator: base.SpecValidatorImpl(),
      );
      await canon.open(widget.bundlePath);
      if (!mounted) {
        canon.dispose();
        return;
      }
      setState(() {
        _canonical = canon;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  void _dispose() {
    final canon = _canonical;
    _canonical = null;
    // Fire-and-forget — dispose() returns Future<void> but the State
    // lifecycle is sync. Errors during shutdown are tolerable: the
    // worst case is a dangling FS handle that gets reclaimed on
    // process exit.
    if (canon != null) {
      unawaited(canon.dispose());
    }
  }

  @override
  void dispose() {
    _dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Preview load failed:\n${_error}',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: Colors.white54,
            ),
          ),
        ),
      );
    }
    final canon = _canonical;
    if (_loading || canon == null) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return base.PreviewPanel(
      canonical: canon,
      focusPageId: widget.focusPageId,
      focusComponentId: widget.focusComponentId,
      dashboardMode: widget.dashboardMode,
    );
  }
}
