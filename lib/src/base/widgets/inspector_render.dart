// Render surface for the active inspector session — same UiView +
// UiRuntimeRegistry path the editor preview uses, only the source
// changes: editor reads the workspace canonical, the inspector reads
// the connected MCP server through `InspectorUiViewAdapter`. Tool
// actions in the rendered UI go over the wire via
// `InspectorSessionManager.recordedCallTool` and the response folds
// back into the originating runtime per spec §3.10.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';
import 'package:brain_kernel/mcp_client.dart';
import 'package:appplayer_ui_view/appplayer_ui_view.dart';

import 'package:appplayer_studio/base.dart';

/// Frame size presets for the inspector APP surface — mirrors the
/// editor preview's `_DeviceSizeChoice` so the two debug surfaces
/// feel uniform.
enum InspectorSize { mobile, tablet, desktop, custom }

/// Frame orientation, applied by swapping width/height of the chosen
/// preset.
enum InspectorOrient { portrait, landscape }

/// Forced brightness override for the rendered inspector — `system`
/// defers to the bundle's own theme.mode.
enum InspectorBright { system, light, dark }

class InspectorRender extends StatefulWidget {
  const InspectorRender({
    super.key,
    required this.session,
    required this.sessions,
    required this.size,
    required this.orient,
    this.brightness = InspectorBright.system,
    this.customW = 390,
    this.customH = 844,
    this.resetEpoch = 0,
  });
  final InspectorSession session;
  final InspectorSessionManager sessions;
  final InspectorSize size;
  final InspectorOrient orient;
  final InspectorBright brightness;
  final int customW;
  final int customH;
  final int resetEpoch;

  @override
  State<InspectorRender> createState() => _InspectorRenderState();
}

class _InspectorRenderState extends State<InspectorRender> {
  late InspectorUiViewAdapter _adapter;
  late UiRuntimeRegistry _registry;
  bool _dashboardOpen = false;

  /// Fraction of the column reserved for the dashboard pane when open.
  /// Drag the tab vertically to resize.
  double _dashboardFraction = 0.4;

  @override
  void initState() {
    super.initState();
    _initSources();
  }

  @override
  void didUpdateWidget(covariant InspectorRender old) {
    super.didUpdateWidget(old);
    if (!identical(old.session, widget.session)) {
      _adapter.dispose();
      _initSources();
    } else if (old.brightness != widget.brightness) {
      _adapter.setModeOverride(_modeOverrideFor(widget.brightness));
    }
  }

  @override
  void dispose() {
    _adapter.dispose();
    super.dispose();
  }

  void _initSources() {
    _adapter = InspectorUiViewAdapter(
      widget.session,
      modeOverride: _modeOverrideFor(widget.brightness),
    );
    _registry =
        UiRuntimeRegistry()..register(
          McpUiRuntimePort(
            onToolCall: _onToolCall,
            pageLoader: _resolvePage,
            onRuntimeReady: _onRuntimeReady,
            // Wrap every rendered widget with `MetaData(metaData: <json>)`
            // so `vibe_layout_snapshot` can walk this surface the same way
            // it walks the editor preview. Translucent hit behaviour keeps
            // the wrapper invisible to taps that should hit the runtime.
            inspector: _wrapWithMetadata,
          ),
        );
  }

  static Widget _wrapWithMetadata(Widget child, Map<String, dynamic> node) {
    return MetaData(
      metaData: node,
      behavior: HitTestBehavior.translucent,
      child: child,
    );
  }

  /// Called by [McpUiRuntimePort] right after each surface's runtime
  /// initialises. Forward the (target → runtime) pair to the session
  /// manager so the State panel can subscribe to live updates and
  /// dispatch edits regardless of which surface is focused.
  void _onRuntimeReady(String target, MCPUIRuntime runtime) {
    widget.sessions.bindRuntime(widget.session, target, runtime);
  }

  String? _modeOverrideFor(InspectorBright b) {
    switch (b) {
      case InspectorBright.system:
        return null;
      case InspectorBright.light:
        return 'light';
      case InspectorBright.dark:
        return 'dark';
    }
  }

  /// Resolve `ui://pages/<id>` and the dashboard sentinel against the
  /// session's already-fetched pages. Inline routes are not allowed by
  /// the 0.4.x runtime validator, so the adapter keeps string URIs and
  /// this loader does the lookup in-memory.
  Future<Map<String, dynamic>> _resolvePage(String uri) async {
    final session = widget.session;
    if (uri == '__inspector_dashboard__') {
      final dash = session.dashboard;
      final content = dash != null ? dash['content'] : null;
      if (content is Map) {
        return <String, dynamic>{
          'type': 'page',
          'content': Map<String, dynamic>.from(content),
        };
      }
      throw StateError('Inspector pageLoader: dashboard content missing');
    }
    if (uri.startsWith('ui://pages/')) {
      final id = uri.substring('ui://pages/'.length);
      final page = session.pages[id];
      if (page != null) return Map<String, dynamic>.from(page);
    }
    throw StateError('Inspector pageLoader: page not found for "$uri"');
  }

  /// Default tool executor — forwards to the connected MCP client via
  /// the session manager (so the call shows up in the wire log) and
  /// folds the response into the originating runtime's state per spec
  /// §3.10. The runtime reference comes from `McpUiRuntimePort` so the
  /// fold lands on whichever surface (APP / DASHBOARD) fired the tool.
  Future<void> _onToolCall(
    String tool,
    Map<String, dynamic> params,
    MCPUIRuntime runtime,
  ) async {
    final result = await widget.sessions.recordedCallTool(
      session: widget.session,
      tool: tool,
      params: params,
    );
    if (result == null || result.content.isEmpty) return;
    final first = result.content.first;
    if (first is! TextContent) return;
    try {
      final decoded = jsonDecode(first.text);
      if (decoded is! Map<String, dynamic>) return;
      decoded.forEach((key, value) {
        runtime.stateManager.set(key, value);
      });
    } catch (_) {
      /* logger captures the parse failure */
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final hasDashboard = widget.session.dashboard != null;
    final frame = inspectorFrameFor(
      widget.size,
      widget.orient,
      customW: widget.customW,
      customH: widget.customH,
    );
    final appView = UiView(
      key: ValueKey<String>(
        'inspector.app:${widget.session.slug}:${frame.id}:${widget.resetEpoch}',
      ),
      adapter: _adapter,
      target: 'mcp-ui:app',
      registry: _registry,
      showStatusStrip: false,
      frame: frame,
    );
    final dashView =
        hasDashboard
            ? UiView(
              key: ValueKey<String>('inspector.dash:${widget.session.slug}'),
              adapter: _adapter,
              target: 'mcp-ui:dashboard',
              registry: _registry,
              showStatusStrip: false,
            )
            : Center(
              child: Text(
                'No dashboard surface',
                style: vibeMono(size: 11, color: c.textTertiary),
              ),
            );
    return ColoredBox(
      color: c.bg,
      child: LayoutBuilder(
        builder: (ctx, box) {
          // Some ancestors hand down an unbounded vertical constraint
          // (Row cross-axis). Use a finite fallback so flex children
          // never get an infinite tight height.
          final h = box.maxHeight.isFinite ? box.maxHeight : 600.0;
          const tabH = 22.0;
          final body = (h - tabH).clamp(0.0, double.infinity);
          final dashH =
              !_dashboardOpen
                  ? 0.0
                  : (body * _dashboardFraction).clamp(0.0, body * 0.9);
          return SizedBox(
            height: h,
            child: Column(
              children: <Widget>[
                Expanded(child: _SurfacePane(label: 'APP', child: appView)),
                _DashboardTab(
                  open: _dashboardOpen,
                  onTap: () => setState(() => _dashboardOpen = !_dashboardOpen),
                  onDragDelta:
                      !_dashboardOpen
                          ? null
                          : (dy) {
                            setState(() {
                              final next = ((dashH - dy) / body).clamp(
                                0.1,
                                0.9,
                              );
                              _dashboardFraction = next;
                            });
                          },
                ),
                if (_dashboardOpen) SizedBox(height: dashH, child: dashView),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Build a `DeviceFrame` for the chosen size/orientation pair.
/// Mirrors `preview_panel._currentFrame` so editor and inspector
/// share the same physical canvas presets.
DeviceFrame inspectorFrameFor(
  InspectorSize s,
  InspectorOrient o, {
  int customW = 390,
  int customH = 844,
}) {
  late DeviceFrame base;
  switch (s) {
    case InspectorSize.mobile:
      base = DeviceFrame.phone;
      break;
    case InspectorSize.tablet:
      base = DeviceFrame.tablet;
      break;
    case InspectorSize.desktop:
      base = DeviceFrame.desktop;
      break;
    case InspectorSize.custom:
      base = DeviceFrame.custom(
        customW.toDouble(),
        customH.toDouble(),
        bezel: const BezelConfig(thickness: 6, cornerRadius: 12),
      );
      break;
  }
  final logical =
      o == InspectorOrient.landscape
          ? Size(base.logicalSize.height, base.logicalSize.width)
          : base.logicalSize;
  return DeviceFrame(
    id: '${base.id}-${o.name}',
    label: '${base.label} (${o.name})',
    logicalSize: logical,
    devicePixelRatio: base.devicePixelRatio,
    bezel: base.bezel,
    safeArea: base.safeArea,
  );
}

/// Bottom-anchored toggle for the dashboard surface. Tapping it
/// flips the open/closed state — closed shows just the 22-px header
/// bar, open expands the dashboard pane above it.
/// Toggle / splitter for the dashboard pane. Click flips open/close;
/// when open, vertical drag resizes the dashboard fraction.
class _DashboardTab extends StatelessWidget {
  const _DashboardTab({
    required this.open,
    required this.onTap,
    this.onDragDelta,
  });
  final bool open;
  final VoidCallback onTap;
  final ValueChanged<double>? onDragDelta;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return MouseRegion(
      cursor: open ? SystemMouseCursors.resizeRow : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onVerticalDragUpdate:
            onDragDelta == null ? null : (d) => onDragDelta!(d.delta.dy),
        child: Container(
          height: 22,
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(
              top: BorderSide(color: c.borderSubtle),
              bottom: BorderSide(color: c.borderSubtle),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space3),
          child: Row(
            children: <Widget>[
              Text(
                'DASHBOARD',
                style: vibeMono(
                  size: 10,
                  weight: FontWeight.w500,
                  color: open ? c.mint : c.textTertiary,
                ),
              ),
              const Spacer(),
              Icon(
                open ? Icons.drag_handle : Icons.keyboard_arrow_up,
                size: open ? 12 : 14,
                color: open ? c.mint : c.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One render surface (APP or DASHBOARD) with a thin label header,
/// keeps the two panes visually distinct in the split view.
class _SurfacePane extends StatelessWidget {
  const _SurfacePane({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Column(
      children: <Widget>[
        Container(
          height: 22,
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(bottom: BorderSide(color: c.borderSubtle)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space3),
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            style: vibeMono(
              size: 10,
              weight: FontWeight.w500,
              color: c.textTertiary,
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
