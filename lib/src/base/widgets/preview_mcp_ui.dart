import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';
// `WidgetCache` is the runtime's internal Widget memoiser — not on the
// package's public surface but loadable via its file path. We need it
// here to disable / clear the singleton when an editor preview mounts
// (see initState comment).
// ignore: implementation_imports
import 'package:flutter_mcp_ui_runtime/src/optimization/widget_cache.dart';
import 'package:appplayer_ui_view/appplayer_ui_view.dart';

import 'package:appplayer_studio/base.dart';
import 'package:brain_kernel/brain_kernel.dart' show CanonicalChange;

const String _kMcpUiPrefix = 'mcp-ui:';

/// Sentinel URI vibe routes the synthetic dashboard App at. The
/// `_pageLoaderFor` callback recognises it and synthesises a page whose
/// `content` is `ui.dashboard.content` from the canonical bundle.
const String _kDashboardUri = 'ui://__vibe_dashboard__';

/// Synthetic URI prefix for the component preview sentinel. Single
/// path segment (`ui://__vibe_component_<id>__`) keeps the URI shape
/// consistent with the dashboard sentinel and avoids path-segment
/// surprises in any URI parser the runtime might use.
/// `_pageLoaderFor` picks it apart and returns the component template
/// wrapped as a synthetic page so the existing renderer pipeline runs
/// unchanged.
const String _kComponentUriPrefix = 'ui://__vibe_component_';
const String _kComponentUriSuffix = '__';

/// Adapter that exposes the canonical bundle's UI section to
/// `tools/core/view/ui`. Targets:
///
/// - `mcp-ui:app`             → ui app block
/// - `mcp-ui:page/<id>`       → single page definition
class CanonicalUiViewAdapter implements UiViewAdapter {
  CanonicalUiViewAdapter(this._canonical) {
    _canonical.changes.listen(_onChange);
  }

  final WorkspaceCanonical _canonical;
  final Map<String, StreamController<UiTargetUpdate>> _watchers =
      <String, StreamController<UiTargetUpdate>>{};

  /// Optional `theme.mode` override applied to every snapshot. When the
  /// preview's brightness toggle is set to `light` or `dark` we force that
  /// mode regardless of the bundle's declared theme.mode — useful for
  /// inspecting the rendered output under a specific brightness without
  /// touching the canonical bundle. `null` means "respect the bundle".
  String? _modeOverride;
  set modeOverride(String? mode) {
    if (_modeOverride == mode) return;
    _modeOverride = mode;
    // Push a synthetic update so any active watchers re-fetch with the
    // new override applied.
    for (final entry in _watchers.entries) {
      final snap = _snapshotOf(entry.key);
      if (snap == null) continue;
      entry.value.add(UiTargetUpdate(snap));
    }
  }

  void _onChange(CanonicalChange change) {
    for (final entry in _watchers.entries) {
      final snap = _snapshotOf(entry.key);
      if (snap == null) continue;
      entry.value.add(UiTargetUpdate(snap));
    }
  }

  UiTargetSnapshot? _snapshotOf(String target) {
    if (!target.startsWith(_kMcpUiPrefix)) return null;
    final tail = target.substring(_kMcpUiPrefix.length);
    // Use the raw canonical JSON — `current.toJson()` rebuilds via mcp_bundle's
    // typed UiSection which drops mcp_ui DSL ApplicationDefinition fields
    // (routes, lifecycle, services, …). The runtime needs the full payload.
    final json = _canonical.currentJson;
    final ui = (json['ui'] as Map?) ?? const <String, dynamic>{};
    Map<String, dynamic>? section;
    if (tail == 'app') {
      // The `ui` map IS the ApplicationDefinition. Strip the pages sub-map so
      // the runtime receives a flat top-level definition (it loads pages
      // separately via the page/<id> target).
      final flat = Map<String, dynamic>.from(ui);
      flat.remove('pages');
      section = flat;
    } else if (tail == 'dashboard') {
      // Dashboard is its own root view (spec §11.9), not a page. When
      // the bundle has authored one, wrap its content in a synthetic
      // single-route App so it goes through the same theme pipeline as
      // any page; `_pageLoaderFor()` resolves the sentinel URI back to
      // `{type: page, content: dashboard.content}`. Templates are
      // forwarded so any `use` widget in the dashboard content
      // resolves through the runtime's TemplateRegistry.
      //
      // When the bundle has NOT authored a dashboard, return an empty
      // section so the runtime throws on init with the same
      // "Definition must be valid application or page type" error the
      // empty App / Page targets produce — that lands on the same
      // `_Fallback` diagnostic, giving every empty preview state one
      // consistent failure UI.
      final dash = ui['dashboard'];
      if (dash is Map) {
        section = <String, dynamic>{
          'type': 'application',
          if (ui['theme'] is Map) 'theme': ui['theme'],
          if (ui['templates'] is Map) 'templates': ui['templates'],
          'routes': <String, dynamic>{'/': _kDashboardUri},
          'initialRoute': '/',
        };
      } else {
        section = <String, dynamic>{};
      }
    } else if (tail.startsWith('component/')) {
      // Component preview — render the focused template through the
      // standard `use` widget so it goes through TemplateRegistry the
      // same way pages render templates. The synthetic App carries
      // every authored template so the runtime auto-registers them at
      // init; the page loader resolves the sentinel route to a Page
      // whose content is `{type:"use", template:"<id>"}`.
      final id = tail.substring('component/'.length);
      final widgets = ui['templates'];
      final tpl = widgets is Map ? widgets[id] : null;
      if (tpl is! Map || tpl['content'] == null) {
        section = <String, dynamic>{};
      } else {
        section = <String, dynamic>{
          'type': 'application',
          if (ui['theme'] is Map) 'theme': ui['theme'],
          if (ui['templates'] is Map) 'templates': ui['templates'],
          'routes': <String, dynamic>{
            '/': '$_kComponentUriPrefix$id$_kComponentUriSuffix',
          },
          'initialRoute': '/',
        };
      }
    } else if (tail.startsWith('page/')) {
      final id = tail.substring(5);
      final pages = ui['pages'];
      final page = pages is Map ? pages[id] : null;
      if (page is! Map) return null;
      // Runtime engine only reads `theme` (and registers `templates`)
      // from an ApplicationDefinition. Wrap the focused page in a
      // synthetic single-route App so page preview runs through the
      // same theme + template pipeline as the app target.
      //
      // `ApplicationDefinition.routes` is typed `Map<String, String>` —
      // route values MUST be URI strings, never inline page maps. We
      // route `/` to `ui://pages/<id>` and let `_pageLoaderFor()`
      // resolve it back to the page data from canonical on demand.
      section = <String, dynamic>{
        'type': 'application',
        if (ui['theme'] is Map) 'theme': ui['theme'],
        if (ui['templates'] is Map) 'templates': ui['templates'],
        'routes': <String, dynamic>{'/': 'ui://pages/$id'},
        'initialRoute': '/',
      };
    } else {
      return null;
    }
    if (_modeOverride != null) {
      final theme = section['theme'];
      final updated =
          theme is Map ? Map<String, dynamic>.from(theme) : <String, dynamic>{};
      updated['mode'] = _modeOverride;
      section['theme'] = updated;
    }
    // Section-only hash. Auto-refresh on canonical content edits is
    // driven by the shell bumping `externalRefreshEpoch` (which feeds
    // PreviewMcpUi's `resetEpoch` → `keyTag` → UiView ValueKey) so
    // the entire runtime is torn down and remounted, matching the
    // manual refresh button's path. An earlier revision tried folding
    // content into the hash for a lighter in-place swap, but the
    // FutureBuilder did not always settle on the new render — only
    // the full ValueKey rebuild proved reliable.
    final encoded = jsonEncode(section);
    final hash = sha256.convert(utf8.encode(encoded)).toString();
    return UiTargetSnapshot(
      target: target,
      data: section,
      sourceHash: 'sha256:$hash',
      fetchedAt: DateTime.now(),
      source: 'workspace',
    );
  }

  @override
  Future<UiTargetSnapshot> fetch(String target) async {
    final snap = _snapshotOf(target);
    if (snap == null) {
      throw StateError('unknown target: $target');
    }
    return snap;
  }

  @override
  Stream<UiTargetUpdate> watch(String target) {
    final controller = _watchers.putIfAbsent(
      target,
      () => StreamController<UiTargetUpdate>.broadcast(),
    );
    return controller.stream;
  }

  Future<void> dispose() async {
    for (final c in _watchers.values) {
      await c.close();
    }
    _watchers.clear();
  }
}

/// Runtime port that drives `flutter_mcp_ui_runtime.MCPUIRuntime` from a
/// snapshot. On initialization failure it falls back to a readable info
/// panel so the preview pane stays useful while the bundle is incomplete.
class McpUiRuntimePort implements UiRuntimePort {
  McpUiRuntimePort({
    this.canonical,
    this.inspector,
    this.onToolCall,
    this.pageLoader,
    this.onRuntimeReady,
  });

  /// Optional canonical reference. When set, the runtime gets a
  /// `pageLoader` callback that resolves `ui://<id>` URIs (and the
  /// `ui://pages/<id>` long form) against the bundle's pages map. This
  /// lets the `mcp-ui:app` target render the full ApplicationDefinition
  /// — the runtime fetches each route's page on demand.
  final WorkspaceCanonical? canonical;

  /// Generic page loader override — used by the Inspector port to
  /// resolve `ui://pages/<id>` against the connected session's
  /// already-fetched page resources. Takes precedence over the
  /// canonical-derived loader when both are supplied.
  final Future<Map<String, dynamic>> Function(String uri)? pageLoader;

  /// Optional inspector wrapper. When supplied, the runtime is built
  /// via [MCPUIRuntime.withInspector] so each rendered widget is paired
  /// with its source JSON node. Null = production fast path.
  final RenderInspector? inspector;

  /// Optional tool-call callback wired into the rendered runtime as
  /// the `default` executor. Vibe's editor preview leaves this null —
  /// canonical-source previews dispatch tool actions through their
  /// per-tool specific executors. The Inspector port supplies a
  /// callback that forwards to the connected MCP client and folds
  /// the response into runtime state per spec §3.10. The runtime
  /// reference lets the callback `mergeState` directly into the
  /// surface that fired the action.
  final Future<void> Function(
    String tool,
    Map<String, dynamic> params,
    MCPUIRuntime runtime,
  )?
  onToolCall;

  /// Fired right after `runtime.initialize` completes for a target.
  /// The Inspector hooks this to track per-target runtime instances so
  /// the State panel can subscribe to `runtime.stateManager.stream` and
  /// poke values directly. Null = caller doesn't care.
  final void Function(String target, MCPUIRuntime runtime)? onRuntimeReady;

  @override
  String get id => 'vibe.mcp_ui';

  @override
  List<String> get supportedPrefixes => const <String>[_kMcpUiPrefix];

  @override
  Future<Widget> render(
    UiTargetSnapshot snapshot, {
    DeviceFrame? frame,
    double scale = 1.0,
  }) async {
    final runtime =
        inspector == null
            ? MCPUIRuntime(enableDebugMode: false)
            : MCPUIRuntime.withInspector(
              widgetWrapper: inspector!,
              enableDebugMode: false,
            );
    try {
      await runtime.initialize(
        Map<String, dynamic>.from(snapshot.data),
        pageLoader:
            pageLoader ??
            (canonical == null ? null : _pageLoaderFor(canonical!)),
      );
      onRuntimeReady?.call(snapshot.target, runtime);
      // Resolve the brightness the rendered runtime should operate under.
      // Driven entirely by the tab-bar toggle (which mutates the snapshot's
      // `theme.mode` for `light` / `dark`). When the toggle is `System`
      // and the bundle's mode is `system`/null, default to LIGHT — vibe
      // intentionally does NOT read the host OS brightness so the preview
      // stays deterministic and never inherits the vibe shell's dark
      // chrome.
      final mode = _modeOf(snapshot.data);
      final Brightness brightness =
          mode == 'dark' ? Brightness.dark : Brightness.light;
      return Builder(
        builder: (context) {
          final base = Theme.of(context);
          final mq = MediaQuery.of(context);
          return MediaQuery(
            data: mq.copyWith(platformBrightness: brightness),
            child: Theme(
              data: base.copyWith(brightness: brightness),
              child: runtime.buildUI(
                context: context,
                onToolCall:
                    onToolCall == null
                        ? null
                        : (tool, params) => onToolCall!(tool, params, runtime),
              ),
            ),
          );
        },
      );
    } catch (e) {
      return _Fallback(snapshot: snapshot, error: e);
    }
  }

  /// Resolve the effective `theme.mode` on a definition. App definitions
  /// carry it at the top level; pages get an injected `theme` (see
  /// [CanonicalUiViewAdapter._snapshotOf]).
  String? _modeOf(Map<String, dynamic> def) {
    final theme = def['theme'];
    if (theme is Map && theme['mode'] is String) {
      return theme['mode'] as String;
    }
    return null;
  }

  /// Resolve `ui://<rel>` against `canonical.currentJson['ui']['pages']`.
  /// Accepts both `ui://pages/<id>` (vibe / spec long form) and
  /// `ui://<id>` (appplayer short form).
  Future<Map<String, dynamic>> Function(String uri) _pageLoaderFor(
    WorkspaceCanonical canonical,
  ) {
    return (String uri) async {
      // Component sentinel — synthesise a Page whose content is the
      // focused template's `content` widget tree inlined directly.
      //
      // This is a vibe-side authoring affordance, not a spec deviation:
      // the user is editing the template body, so clicks on the
      // rendered preview should drill into widgets at canonical paths
      // under `tpl.content` rather than collapsing onto a `use` widget
      // boundary (which would be opaque to the inspect chain
      // resolver). The `use` widget + TemplateRegistry path is still
      // exercised end-to-end by the app target and by any page that
      // references the template via `{type:"use", ...}` — those carry
      // the regular runtime contract.
      if (uri.startsWith(_kComponentUriPrefix) &&
          uri.endsWith(_kComponentUriSuffix)) {
        final id = uri.substring(
          _kComponentUriPrefix.length,
          uri.length - _kComponentUriSuffix.length,
        );
        final ui = canonical.currentJson['ui'];
        final templates = ui is Map ? ui['templates'] : null;
        final tpl = templates is Map ? templates[id] : null;
        final body = tpl is Map ? tpl['content'] : null;
        if (body is Map<String, dynamic>) {
          return <String, dynamic>{'type': 'page', 'content': body};
        }
        if (body is Map) {
          return <String, dynamic>{
            'type': 'page',
            'content': Map<String, dynamic>.from(body),
          };
        }
        throw StateError(
          'mcp_ui pageLoader: component template missing for "$uri"',
        );
      }
      // Dashboard sentinel — synthesise a Page whose content is
      // ui.dashboard.content from the canonical bundle.
      if (uri == _kDashboardUri) {
        final ui = canonical.currentJson['ui'];
        final dash = ui is Map ? ui['dashboard'] : null;
        final content = dash is Map ? dash['content'] : null;
        if (content is Map<String, dynamic>) {
          return <String, dynamic>{'type': 'page', 'content': content};
        }
        if (content is Map) {
          return <String, dynamic>{
            'type': 'page',
            'content': Map<String, dynamic>.from(content),
          };
        }
        throw StateError('mcp_ui pageLoader: dashboard content missing');
      }
      const pagesPrefix = 'ui://pages/';
      const uiPrefix = 'ui://';
      String id;
      if (uri.startsWith(pagesPrefix)) {
        id = uri.substring(pagesPrefix.length);
      } else if (uri.startsWith(uiPrefix)) {
        id = uri.substring(uiPrefix.length);
      } else {
        id = uri;
      }
      final ui = canonical.currentJson['ui'];
      final pages = ui is Map ? ui['pages'] : null;
      final page = pages is Map ? pages[id] : null;
      if (page is Map<String, dynamic>) return page;
      if (page is Map) return Map<String, dynamic>.from(page);
      throw StateError('mcp_ui pageLoader: page not found for "$uri"');
    };
  }

  @override
  Future<void> dispose() async {}
}

class _Fallback extends StatelessWidget {
  const _Fallback({required this.snapshot, required this.error});
  final UiTargetSnapshot snapshot;
  final Object error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(VibeTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'mcp-ui preview',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: VibeTokens.colorOf(context).textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'target: ${snapshot.target}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Text(
            'hash: ${snapshot.sourceHash}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: VibeTokens.space2),
          Text(
            'rendering: $error',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: VibeTokens.colorOf(context).textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

/// mcp_ui preview pane embedded inside [PreviewPanel]. Wires the canonical
/// bundle into `tools/core/view/ui`'s [UiView] widget so changes flow as
/// [UiTargetUpdate]s the runtime can hot-reconcile.
class PreviewMcpUi extends StatefulWidget {
  const PreviewMcpUi({
    super.key,
    required this.canonical,
    this.focusPageId,
    this.focusComponentId,
    this.dashboardMode = false,
    this.frame,
    this.previewMode,
    this.resetEpoch = 0,
    this.inspectRoot,
    this.selectedWidgetPath,
    this.onSelectWidget,
  });

  final WorkspaceCanonical canonical;
  final String? focusPageId;

  /// Component id to render standalone — when set, the preview wraps
  /// the component's `template` in a synthetic single-route App.
  /// Mutually exclusive with [focusPageId] / [dashboardMode] in
  /// practice. The synthesised page declares no initial state, so any
  /// `{{...}}` bindings inside the template resolve to empty/null —
  /// fine for visual layout preview.
  final String? focusComponentId;

  /// Root of the widget tree to resolve hits against (the focused page's
  /// `content` or component's `template`). When non-null the runtime is
  /// built via `MCPUIRuntime.withInspector` and a translucent listener
  /// fires [onSelectWidget] on tap. Null = no tree (App / Theme / Whole
  /// layers) — production fast path with no wrapper.
  final Map<String, dynamic>? inspectRoot;

  final WidgetPath? selectedWidgetPath;
  final ValueChanged<WidgetPath>? onSelectWidget;

  /// True when an inspect tree is available — drives the runtime build
  /// path and the highlight overlay.
  bool get inspectMode => inspectRoot != null;

  /// When true, render the application dashboard (`ui.dashboard.content`).
  /// Mutually exclusive with [focusPageId] in practice — when true the
  /// page id is ignored.
  final bool dashboardMode;

  /// Render frame (logical size + bezel + safe area). When null the
  /// underlying [UiView] falls back to its default ([DeviceFrame.phone]).
  final DeviceFrame? frame;

  /// Force-override `theme.mode` for the rendered preview only — does not
  /// touch the canonical bundle or the surrounding tool chrome. Accepts
  /// `light`, `dark`, or null (respect the bundle).
  final String? previewMode;

  /// Bumped by the host to force a full re-mount of the framed device —
  /// resets the shift-pan / zoom transform back to the device preset's
  /// initial position and scale.
  final int resetEpoch;

  @override
  State<PreviewMcpUi> createState() => _PreviewMcpUiState();
}

class _PreviewMcpUiState extends State<PreviewMcpUi> {
  late final CanonicalUiViewAdapter _adapter;
  late UiRuntimeRegistry _registry;
  // GlobalKey on the runtime root so the inspect overlay can hit-test
  // against the rendered tree at the tap position.
  final GlobalKey _runtimeKey = GlobalKey();
  // Rect of the currently selected widget within the runtime root, in
  // its local coordinate space. Driven by an Element-tree walk that
  // finds the [RenderMetaData] paired with the selected JSON node.
  // Null when nothing is selected, inspect mode is off, or layout
  // hasn't settled yet.
  Rect? _highlightRect;
  // Pointer-down position recorded while the inspect listener is
  // translucently observing. Used to gate selection on quick taps
  // versus drags so scrolling inside the rendered preview still works.
  Offset? _tapStart;

  /// Subscription to canonical changes — every patch should trigger a
  /// fresh highlight retry chain so the rect lands on the new render
  /// tree as soon as it attaches. didUpdateWidget alone misses the
  /// case where the widget params (selectedWidgetPath, inspectRoot)
  /// don't actually change but the underlying tree references did.
  StreamSubscription<dynamic>? _canonicalChangesSub;

  /// Periodic ticker used while inspect mode is on. Re-checks the
  /// highlight rect every frame-ish so any race between widget
  /// rebuild, runtime remount, and RenderMetaData attachment is
  /// caught on the next tick. Cheap — `_findRectFor` is a render-tree
  /// walk that bails fast when nothing matches and the rect is
  /// only setState'd when it actually changed.
  Timer? _highlightTicker;

  @override
  void initState() {
    super.initState();
    _adapter = CanonicalUiViewAdapter(widget.canonical)
      ..modeOverride = widget.previewMode;
    _registry = _buildRegistry();
    // The runtime's singleton WidgetCache memoises Widget instances by
    // hashed JSON definition. In an editor that flips inspect mode on
    // and off, a Widget cached without the MetaData wrapper gets
    // replayed back in inspect mode — so children of a recently-patched
    // page render WITHOUT their RenderMetaData markers, and the
    // overlay can't draw boxes for them. The cache's value is
    // negligible for an interactive editor; disable it outright and
    // clear the existing entries so already-cached wrappers are
    // dropped.
    WidgetCache.instance.disable();
    _canonicalChangesSub = widget.canonical.changes.listen((_) {
      if (!mounted) return;
      // Defensive: even with the cache disabled, a patch may have
      // landed mid-render and left a stale entry around. Clear on
      // every canonical change so inspector wrappers always rebuild.
      WidgetCache.instance.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateHighlight());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateHighlight());
    _ensureHighlightTicker();
  }

  void _ensureHighlightTicker() {
    if (_highlightTicker != null) return;
    _highlightTicker = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (!mounted) {
        _highlightTicker?.cancel();
        _highlightTicker = null;
        return;
      }
      if (!widget.inspectMode) return;
      _updateHighlight();
    });
  }

  @override
  void didUpdateWidget(covariant PreviewMcpUi old) {
    super.didUpdateWidget(old);
    if (old.previewMode != widget.previewMode) {
      _adapter.modeOverride = widget.previewMode;
    }
    if (old.inspectMode != widget.inspectMode) {
      // Rebuild the registry so the runtime port either picks up or
      // drops the inspector wrapper. UiView re-renders next frame.
      _registry = _buildRegistry();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateHighlight());
  }

  // Cold boot can take a while (Dart pub warmup, FutureBuilder fetch +
  // first render, RenderMetaData attach). Cap retries by total elapsed
  // time, not iteration count, so cold boots get enough headroom while
  // hot rebuilds settle quickly.
  static const Duration _highlightRetryBudget = Duration(seconds: 6);
  static const Duration _highlightRetryStep = Duration(milliseconds: 80);

  /// Token incremented on every fresh `_updateHighlight` invocation
  /// (cold boot, didUpdateWidget). Stale retry chains still ticking
  /// from a previous trigger compare their captured token to this and
  /// bail out — prevents one chain from clearing a rect another chain
  /// just established.
  int _highlightSeq = 0;

  void _updateHighlight({int? seq, Duration elapsed = Duration.zero}) {
    if (!mounted) return;
    final mySeq = seq ?? ++_highlightSeq;
    if (mySeq != _highlightSeq) return;
    // No inspect mode or no selection target → clear the highlight.
    if (!widget.inspectMode) {
      if (_highlightRect != null) {
        setState(() => _highlightRect = null);
      }
      return;
    }
    final target = _resolveSelectedNode();
    if (target == null) {
      if (_highlightRect != null) {
        setState(() => _highlightRect = null);
      }
      return;
    }
    final next = _findRectFor(target);
    if (next != null) {
      if (_highlightRect != next) {
        setState(() => _highlightRect = next);
      }
      return;
    }
    // Target still exists in the canonical, but the runtime widget
    // tree has not produced a RenderMetaData for it yet — typical on
    // cold boot (runtime still warming) or during the rebuild that
    // follows a canonical patch. KEEP the previous rect on screen and
    // retry; clearing here would manifest as a visible flicker.
    if (elapsed < _highlightRetryBudget) {
      Future<void>.delayed(_highlightRetryStep, () {
        if (!mounted) return;
        _updateHighlight(seq: mySeq, elapsed: elapsed + _highlightRetryStep);
      });
    }
  }

  Map<String, dynamic>? _resolveSelectedNode() {
    final root = widget.inspectRoot;
    final path = widget.selectedWidgetPath;
    if (root == null || path == null) return null;
    final node = atPath(root, path);
    if (node is Map<String, dynamic>) return node;
    return null;
  }

  /// Walk the runtime's render tree looking for a [RenderMetaData] whose
  /// `metaData` is the same JSON node ref. Returns the node's bounding
  /// rect in `_runtimeKey`'s local coordinates so the overlay can
  /// position itself directly without further conversion.
  Rect? _findRectFor(Map<String, dynamic> target) {
    final ctx = _runtimeKey.currentContext;
    if (ctx == null) return null;
    final rootObj = ctx.findRenderObject();
    if (rootObj is! RenderBox) return null;
    // Two-pass walk: identity matches win; if no identity hit, accept
    // a shallow-same map as a fallback. The runtime's `UIDefinition.
    // fromJson` produces a shallow copy of `content` for synthetic page
    // wrappers (template / dashboard / page editor views), so the root
    // RenderMetaData carries a Map<String,dynamic> with identical
    // values but a fresh top-level identity. Without this, root-level
    // selection on those editor views never highlights.
    // Three-tier walk mirroring the path resolver's tiers — identity,
    // shallow-same, structural. The runtime sometimes leaves a child's
    // RenderMetaData stuck on a stale Map ref from an earlier render
    // generation while the parent's metaData has updated; without the
    // structural tier the walker can't locate the rect for the
    // selected widget and the highlight goes invisible.
    RenderBox? exact;
    RenderBox? shallow;
    RenderBox? structural;
    void visit(RenderObject ro) {
      if (exact != null) return;
      if (ro is RenderMetaData) {
        final meta = ro.metaData;
        if (identical(meta, target)) {
          if (ro.hasSize) exact = ro;
          return;
        }
        if (meta is Map<String, dynamic>) {
          if (shallow == null && shallowSameMap(meta, target)) {
            if (ro.hasSize) shallow = ro;
          } else if (structural == null &&
              structurallySameWidget(meta, target)) {
            if (ro.hasSize) structural = ro;
          }
        }
      }
      ro.visitChildren(visit);
    }

    visit(rootObj);
    final box = exact ?? shallow ?? structural;
    if (box == null) return null;
    if (!box.attached) return null;
    final transform = box.getTransformTo(rootObj);
    return MatrixUtils.transformRect(transform, Offset.zero & box.size);
  }

  UiRuntimeRegistry _buildRegistry() {
    return UiRuntimeRegistry()..register(
      McpUiRuntimePort(
        canonical: widget.canonical,
        inspector: widget.inspectMode ? _inspectorWrapper : null,
      ),
    );
  }

  /// Tag every rendered widget with its source JSON node so the
  /// overlay can resolve hits back to a [WidgetPath]. Behavior is
  /// `translucent` — it doesn't add its own opaque hit region but
  /// participates in hit-test results, which is exactly what we want.
  Widget _inspectorWrapper(Widget child, Map<String, dynamic> node) {
    return MetaData(
      metaData: node,
      behavior: HitTestBehavior.translucent,
      child: child,
    );
  }

  @override
  void dispose() {
    _highlightTicker?.cancel();
    _highlightTicker = null;
    _canonicalChangesSub?.cancel();
    _adapter.dispose();
    super.dispose();
  }

  void _handleInspectTap(Offset globalPosition, {int retriesLeft = 4}) {
    final root = widget.inspectRoot;
    final cb = widget.onSelectWidget;
    if (root == null || cb == null) return;
    final ctx = _runtimeKey.currentContext;
    // Right after a target / runtime swap the runtime widget tree may
    // not be attached on the very first frame. Schedule a retry instead
    // of dropping the tap.
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
    // Empty hit-test usually means the runtime tree is still settling.
    // Retry once or twice — gives the inspector RenderMetaData wrappers
    // time to attach so the next pass can find them.
    if (!hit || result.path.isEmpty) {
      if (retriesLeft > 0 && mounted) {
        Future<void>.delayed(const Duration(milliseconds: 60), () {
          if (!mounted) return;
          _handleInspectTap(globalPosition, retriesLeft: retriesLeft - 1);
        });
      }
      return;
    }
    // Build a leaf-first chain of MetaData maps from the cursor's hit
    // path. Each runtime widget definition is wrapped in a MetaData,
    // so this chain encodes parent-child structure of the rendered
    // tree.
    final candidates = <Object>[];
    for (final entry in result.path) {
      final t = entry.target;
      if (t is RenderMetaData) {
        final m = t.metaData;
        if (m is Map<String, dynamic>) candidates.add(m);
      }
    }
    // Two resolvers:
    //  1) Chain-based: derives the path from the runtime's own
    //     metadata nesting. Immune to identity drift between the
    //     runtime's metadata refs and the shell's `widget.inspectRoot`
    //     during transitions after a canonical patch — the runtime's
    //     MetaData chain is internally consistent regardless.
    //  2) Identity / shallow fallback against `root`. Used when the
    //     chain resolver bails (e.g. when the runtime wraps the page
    //     in additional non-MetaData widgets that break the chain
    //     between root and leaf in the hit path).
    final chainPath = resolveTapPathFromChain(root, candidates);
    final winner = chainPath ?? selectCanonicalPath(root, candidates);
    if (chainPath != null && chainPath.isNotEmpty) {
      cb(chainPath);
      return;
    }
    if (winner != null) cb(winner);
    // No node in the cursor's hit path belongs to the focused subtree.
    // Silently ignore — inspect mode shouldn't surface foreign nodes.
  }

  @override
  Widget build(BuildContext context) {
    final String target;
    if (widget.dashboardMode) {
      target = '${_kMcpUiPrefix}dashboard';
    } else if (widget.focusComponentId != null) {
      target = '${_kMcpUiPrefix}component/${widget.focusComponentId}';
    } else if (widget.focusPageId == null) {
      target = '${_kMcpUiPrefix}app';
    } else {
      target = '${_kMcpUiPrefix}page/${widget.focusPageId}';
    }
    // Key by target so changing the focused page tears down the previous
    // UiViewState (and the cached MCPUIRuntime inside its FutureBuilder)
    // and rebuilds fresh — avoids stale state from the prior page.
    final frame = widget.frame;
    // Key on (target, frame.id, mode-override) so changing any of them
    // tears down the previous UiView state cleanly and the FutureBuilder
    // refetches with the new snapshot data.
    final keyTag =
        '$target|${frame?.id ?? 'default'}|${widget.previewMode ?? 'auto'}|${widget.resetEpoch}|${widget.inspectMode ? 'inspect' : 'live'}';
    // (target picked above; dashboardMode forces mcp-ui:dashboard.)
    final view = UiView(
      key: ValueKey<String>('vibe.preview.mcp_ui:$keyTag'),
      adapter: _adapter,
      target: target,
      registry: _registry,
      showStatusStrip: false,
      frame: frame,
      // Plain wheel scrolls inner content (Scrollables in the rendered DSL).
      // Shift+wheel zooms; Shift+drag pans the framed device. Lets the
      // preview surface real app behaviour without stealing every scroll.
      viewportInteraction: ViewportInteractionMode.shiftToTransform,
    );
    final keyed = KeyedSubtree(key: _runtimeKey, child: view);
    if (!widget.inspectMode) return keyed;
    // Inspect mode — observe pointer events as a parent of the
    // runtime, NOT as a sibling. Listener wraps the runtime so its
    // child (the runtime → button → InkWell) still receives the tap
    // and fires its onPressed. With translucent behavior the Listener
    // ALSO sees the events for inspect selection. A previous design
    // put the Listener as a Positioned.fill sibling in a Stack; that
    // looked the same on screen but stopped Stack hit-testing at the
    // first sibling, swallowing taps before they reached buttons.
    //
    // Highlight overlay stays a sibling above the runtime, wrapped in
    // IgnorePointer so it never blocks anything.
    final rect = _highlightRect;
    final runtimeWithListener = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _tapStart = e.position;
      },
      onPointerUp: (e) {
        final start = _tapStart;
        _tapStart = null;
        if (start == null) return;
        if ((e.position - start).distance > 8.0) return;
        _handleInspectTap(e.position);
      },
      onPointerCancel: (_) => _tapStart = null,
      child: keyed,
    );
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        runtimeWithListener,
        if (rect != null)
          Positioned.fromRect(
            rect: rect,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: VibeTokens.color.mint, width: 1.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
