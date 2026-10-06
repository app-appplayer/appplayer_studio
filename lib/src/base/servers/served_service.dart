/// Render + connection helpers for a connected MCP SERVER's served app.
///
/// A server "install" is its connect/registration — the host holds a live
/// kernel connection and the served app UI (`ui://app` + `ui://pages/*`) is
/// fetched over it and mounted as a first-class studio tab, with button
/// tool-actions dispatched back through `tools/call` and the JSON result
/// folded into runtime state, exactly like the App Builder debug
/// surface.
///
/// This is host-neutral (no marketplace types): both the marketplace embed
/// (pro) and the local-server feature (base) render a connected server the
/// same way. Connections are in-memory (session-scoped), so the body resolves
/// the LIVE connection by id and fails actionably when it is gone — the caller
/// owns the reconnect path.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:appplayer_ui_view/appplayer_ui_view.dart' show UiTargetSnapshot;

import '../main/chrome_bridge.dart' show WorkspaceTabActiveScope;
import '../widgets/preview_mcp_ui.dart' show McpUiRuntimePort;
import 'reconnect_watch.dart' show StudioReconnectWatch;
import 'composition_seam.dart'
    show StudioCompositionSeam, applyCompositionHooks;
import '../../ui/theme.dart' show VbuTheme;

/// Contract prefix for a connected-service install id (`service:<endpoint>`).
const String kServiceInstallIdPrefix = 'service:';

/// True when an install id denotes a connected service rather than a
/// materialized bundle (a filesystem path). Accepts both the contract
/// (`service:` prefix) and a bare http(s) endpoint.
bool isServiceInstallId(String installId) {
  if (installId.startsWith(kServiceInstallIdPrefix)) return true;
  final uri = Uri.tryParse(installId);
  return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
}

/// The live kernel connection id for a service install id — the endpoint with
/// the contract prefix stripped.
String serviceConnectionIdOf(String installId) =>
    installId.startsWith(kServiceInstallIdPrefix)
        ? installId.substring(kServiceInstallIdPrefix.length)
        : installId;

/// Merge a served bundle's own `theme` block over the studio's complete
/// baseline definition — bundle fields win, host fills the gaps, and the
/// `light` / `dark` sub-variants merge entry-by-entry (same rule as the
/// workspace surface). A themeless served app therefore still gets a full
/// two-variant definition instead of the runtime's stock default (an empty
/// light default → dim dark-on-dark text).
Map<String, Object?> mergeServedTheme(
  Map<String, Object?> host,
  Map<String, dynamic>? bundle,
) {
  if (bundle == null || bundle.isEmpty) return host;
  final merged = <String, Object?>{...host, ...bundle};
  for (final variant in const <String>['light', 'dark']) {
    final h = host[variant];
    final b = bundle[variant];
    if (h is Map && b is Map) {
      merged[variant] = <String, Object?>{
        ...h.cast<String, Object?>(),
        ...b.cast<String, Object?>(),
      };
    }
  }
  return merged;
}

/// Resolve the live connection for [connectionId], or throw an actionable
/// error. The caller (marketplace library / local-server reconnect) owns the
/// recovery path referenced in the message.
mk.KernelClientConnection liveServiceConnection(
  mk.KernelClientHost clientHost,
  String connectionId,
) {
  final conn =
      clientHost.connections
          .where((c) => c.id == connectionId && c.isConnected)
          .firstOrNull;
  if (conn == null) {
    throw StateError(
      'Service connection "$connectionId" is not live — reconnect it.',
    );
  }
  return conn;
}

/// Ceiling for any single served-resource read — a half-dead connection must
/// surface an actionable error, never an endless spinner.
const Duration kServiceReadTimeout = Duration(seconds: 15);

/// Read a JSON-object resource over [conn]. Times out (see
/// [kServiceReadTimeout]) so a stalled connection fails visibly.
Future<Map<String, dynamic>> readServiceJson(
  mk.KernelClientConnection conn,
  String uri,
) async {
  final r = await conn
      .readResource(uri)
      .timeout(
        kServiceReadTimeout,
        onTimeout:
            () =>
                throw StateError(
                  'Service did not answer for "$uri" within '
                  '${kServiceReadTimeout.inSeconds}s — the connection may be '
                  'stale. Reconnect it.',
                ),
      );
  final text = r.contents.isEmpty ? null : r.contents.first.text;
  if (text == null) {
    throw StateError('Service returned no content for "$uri".');
  }
  final decoded = jsonDecode(text);
  if (decoded is! Map<String, dynamic>) {
    throw StateError('Service resource "$uri" is not a JSON object.');
  }
  return decoded;
}

/// The served-app render for one connected service — mounted as an extension
/// TAB body.
///
/// Stateful so the render future is created ONCE (and on explicit Retry),
/// never per build — the tab world rebuilds often (IndexedStack / workspace
/// setState), and a build-time future restarts the FutureBuilder each time: an
/// endless spinner that re-fires network calls on every repaint.
///
/// ACTIVE-GATED: the workspace keeps EVERY open tab alive in an IndexedStack,
/// but `flutter_mcp_ui_runtime`'s WidgetCache is a PROCESS singleton — two
/// co-mounted served surfaces would fight over it and render each other's UI
/// (two market-service tabs showing the same app).
/// So only the ACTIVE service tab mounts its runtime; inactive tabs show a
/// token-bg placeholder (their render future + runtime stay alive for instant
/// re-entry). This is the same single-runtime-at-a-time discipline the DSL
/// workspace applies to authoring tabs (`WorkspaceTabActiveScope`). Where no
/// scope is present (tests, standalone mounts), the gate defaults to active and
/// nothing changes.
class ServedServiceBody extends StatefulWidget {
  const ServedServiceBody({
    super.key,
    required this.clientHost,
    required this.connectionId,
    this.reconnect,
  });

  final mk.KernelClientHost clientHost;
  final String connectionId;

  /// The host's reconnect watch (platform spec 17 §7.6d). Mounting HOLDS
  /// [connectionId] and disposing RELEASES it — that hold is what tells the
  /// watch an app is open and waiting, which is both the licence to keep
  /// dialling and the bound on how long it may. Null in mount paths with no
  /// host wiring (tests, standalone), where the view behaves as before.
  final StudioReconnectWatch? reconnect;

  @override
  State<ServedServiceBody> createState() => _ServedServiceBodyState();
}

class _ServedServiceBodyState extends State<ServedServiceBody> {
  Future<Widget>? _rendered;
  // Re-applies this surface's theme under a new host brightness (the Studio
  // theme flipped). Captured once the runtime is ready.
  void Function(Brightness)? _reapplyTheme;
  Brightness? _appliedBrightness;
  Brightness _lastBrightness = Brightness.dark;
  // Last liveness this view acted on, so the watch's ticks are turned into the
  // dead→live edge rather than a rebuild storm.
  bool _lastLive = false;

  @override
  void initState() {
    super.initState();
    final reconnect = widget.reconnect;
    if (reconnect != null) {
      _lastLive = _isLive();
      reconnect.hold(widget.connectionId);
      reconnect.changes.addListener(_onReconnectChanged);
    }
  }

  @override
  void dispose() {
    final reconnect = widget.reconnect;
    if (reconnect != null) {
      reconnect.changes.removeListener(_onReconnectChanged);
      reconnect.release(widget.connectionId);
    }
    super.dispose();
  }

  bool _isLive() => widget.clientHost.connections.any(
    (c) => c.id == widget.connectionId && c.isConnected,
  );

  /// The watch reports a change. Re-render on the dead→live EDGE only: that is
  /// the moment the error screen has something new to show, and rebuilding on
  /// every tick would restart a healthy render.
  void _onReconnectChanged() {
    final live = _isLive();
    if (live == _lastLive) return;
    _lastLive = live;
    if (!live || !mounted) return;
    setState(() {
      _rendered = _startRender(_lastBrightness);
    });
  }

  /// Manual Retry. Re-rendering alone cannot recover a dropped connection —
  /// [liveServiceConnection] throws on a dead one, so the old behaviour handed
  /// back the same error however many times it was pressed. The press is a
  /// reachability hint: it cuts the watch's remaining interval so the dial
  /// happens now, and the re-render either succeeds (the connection was live
  /// again already) or shows the error until the watch gets it back.
  void _retry() {
    widget.reconnect?.hintReachable(widget.connectionId);
    setState(() {
      _rendered = _startRender(Theme.of(context).brightness);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    _lastBrightness = brightness;
    final active = WorkspaceTabActiveScope.isActiveOf(context);
    // The surface follows the Studio theme: a brightness change since the last
    // apply re-pins it on this runtime's own ThemeManager.
    if (active &&
        _appliedBrightness != null &&
        _appliedBrightness != brightness) {
      _reapplyTheme?.call(brightness);
    }
    // Only the active tab mounts the runtime (see the class doc). Inactive tabs
    // return a bare surface so `runtime.buildUI()` never touches the widget
    // cache while another tab owns it. The render future is preserved, so switching
    // back is instant (no re-fetch).
    if (!active) {
      return Container(color: scheme.surface);
    }
    _rendered ??= _startRender(brightness);
    return Container(
      color: scheme.surface,
      child: FutureBuilder<Widget>(
        future: _rendered,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '${snap.error}',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.error),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _retry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return snap.data!;
        },
      ),
    );
  }

  mk.KernelClientHost get clientHost => widget.clientHost;
  String get connectionId => widget.connectionId;

  /// Starts a render and marks its failure as already accounted for.
  ///
  /// A dead connection makes this future reject, which is the intended path —
  /// [build]'s FutureBuilder turns it into the actionable error + Retry. But a
  /// future created inside `setState` rejects during the microtask BEFORE the
  /// rebuild attaches the FutureBuilder's listener, and an error with no
  /// listener yet is reported as an unhandled async error. The rejection is
  /// still delivered when the builder does listen (a completed future replays
  /// to later listeners), so nothing is swallowed — only the false alarm is.
  Future<Widget> _startRender(Brightness hostBrightness) {
    final rendering = _renderServedApp(hostBrightness);
    rendering.ignore();
    return rendering;
  }

  Future<Widget> _renderServedApp(Brightness hostBrightness) async {
    final conn = liveServiceConnection(clientHost, connectionId);
    final app = await readServiceJson(conn, 'ui://app');
    final port = McpUiRuntimePort(
      pageLoader: (uri) => readServiceJson(conn, uri),
      hostBrightnessOf: () => hostBrightness,
      onRuntimeReady: (target, runtime) {
        // This surface's theme: studio baseline + bundle-wins merge, then pin
        // the host brightness — same discipline as the workspace surface.
        final bundleTheme = app['theme'];
        void apply(Brightness b) {
          runtime.themeManager.setTheme(
            mergeServedTheme(
              VbuTheme.studioRuntimeTheme(),
              bundleTheme is Map ? bundleTheme.cast<String, dynamic>() : null,
            ),
          );
          runtime.themeManager.setHostBrightness(b);
          _appliedBrightness = b;
        }

        apply(hostBrightness);
        _reapplyTheme = apply;
        // Composition Profile (MCP UI DSL v1.4): this served app may `$ref` a
        // definition living on ANOTHER server and then drive and track that
        // server's device. Registered here — after `initialize`, before
        // `buildUI` — so the first render already resolves foreign refs.
        //
        // All four or none: a resolver on its own renders the embedded subtree
        // and sends its controls down THIS surface's connection, landing on a
        // session with no client for that device. When the seam is unwired
        // (headless mounts, tests) nothing is registered and `view` fails
        // closed to its own fallback, which is the honest degrade.
        applyCompositionHooks(
          runtime,
          StudioCompositionSeam.hooksFor(
            clientHost: () => clientHost,
            // A source that names no origin is this surface's own server.
            readOwn: (uri) => readServiceJson(conn, uri),
          ),
        );
      },
      onToolCall: (tool, params, runtime) async {
        final result = await conn.callTool(tool, params);
        final first = result.content.isEmpty ? null : result.content.first;
        if (first is! mk.KernelTextContent) return;
        try {
          final decoded = jsonDecode(first.text);
          if (decoded is! Map<String, dynamic>) return;
          decoded.forEach((key, value) {
            runtime.stateManager.set(key, value);
          });
        } catch (_) {
          // Non-JSON tool payloads simply do not fold into state.
        }
      },
    );
    return port.render(
      UiTargetSnapshot(
        target: 'mcp-ui:app',
        data: app,
        sourceHash: 'server:$connectionId',
        fetchedAt: DateTime.now(),
        source: 'server',
      ),
    );
  }
}
