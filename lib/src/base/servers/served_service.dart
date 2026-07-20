/// Render + connection helpers for a connected MCP SERVER's served app.
///
/// A server "install" is its connect/registration — the host holds a live
/// kernel connection and the served app UI (`ui://app` + `ui://pages/*`) is
/// fetched over it and mounted as a first-class studio tab, with button
/// tool-actions dispatched back through `tools/call` and the JSON result
/// folded into runtime state (spec §3.10), exactly like the App Builder debug
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
/// two-variant definition instead of whatever the singleton ThemeManager
/// last held (fresh boot = an empty light default → dim dark-on-dark text).
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
  final conn = clientHost.connections
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
/// but `flutter_mcp_ui_runtime`'s ThemeManager / WidgetCache / navigatorKey are
/// PROCESS singletons — two co-mounted served surfaces would fight over them
/// and render each other's UI (two market-service tabs showing the same app).
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
    this.themeReinjectTick,
  });

  final mk.KernelClientHost clientHost;
  final String connectionId;

  /// Cross-tab "the shared singleton ThemeManager was just reset" signal
  /// (`ChromeBridge.themeReinjectTick`). Bumped when ANY served/authoring
  /// runtime is torn down (a tab closing); an active tab listens and re-injects
  /// its own theme so a sibling's close doesn't blank it. Null in mount paths
  /// with no chrome (tests, standalone) — the active-edge re-inject still runs.
  final ValueNotifier<int>? themeReinjectTick;

  @override
  State<ServedServiceBody> createState() => _ServedServiceBodyState();
}

class _ServedServiceBodyState extends State<ServedServiceBody> {
  Future<Widget>? _rendered;
  bool _wasActive = false;
  // Re-assert THIS surface's theme on the shared singleton the moment the tab
  // becomes active again (a sibling tab's runtime dispose resets the singleton
  // ThemeManager). Captured once the runtime is ready.
  void Function(Brightness)? _reapplyTheme;
  Brightness _lastBrightness = Brightness.dark;

  @override
  void initState() {
    super.initState();
    widget.themeReinjectTick?.addListener(_onThemeReinjectTick);
  }

  @override
  void dispose() {
    widget.themeReinjectTick?.removeListener(_onThemeReinjectTick);
    // This tab is closing — its runtime tears down and resets the process-
    // singleton ThemeManager behind the surviving active tab's back. Signal
    // survivors to re-inject (same contract as DslWorkspaceView.dispose).
    final tick = widget.themeReinjectTick;
    if (tick != null) tick.value++;
    super.dispose();
  }

  // A sibling tab closed and reset the singleton — if we're the active tab,
  // re-inject our theme after the frame so our palette survives.
  void _onThemeReinjectTick() {
    if (!_wasActive) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reapplyTheme?.call(_lastBrightness);
    });
  }

  void _retry() {
    setState(() {
      _rendered = _renderServedApp(Theme.of(context).brightness);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    _lastBrightness = brightness;
    final active = WorkspaceTabActiveScope.isActiveOf(context);
    // Inactive→active edge: re-inject our theme onto the shared singleton.
    // TWICE, on purpose:
    //  - synchronously, so this build's first rebuild already sees our palette;
    //  - after the frame, so we WIN over a sibling service tab whose runtime
    //    unmounts during this same switch frame — that dispose resets the
    //    singleton ThemeManager (host-brightness → null, theme → default), and
    //    if it runs after our synchronous inject the newly-active tab would show
    //    a blank/stale theme (the exact "theme goes weird on switch" symptom).
    //    A post-frame re-inject is the last writer, so our theme sticks. Same
    //    class the DSL workspace solves for authoring tabs.
    if (active && !_wasActive) {
      _wasActive = true;
      _reapplyTheme?.call(brightness);
      final b = brightness;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reapplyTheme?.call(b);
      });
    } else if (!active && _wasActive) {
      _wasActive = false;
    }
    // Only the active tab mounts the runtime (see the class doc). Inactive tabs
    // return a bare surface so `runtime.buildUI()` never touches the singletons
    // while another tab owns them. The render future is preserved, so switching
    // back is instant (no re-fetch).
    if (!active) {
      return Container(color: scheme.surface);
    }
    _rendered ??= _renderServedApp(brightness);
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

  Future<Widget> _renderServedApp(Brightness hostBrightness) async {
    final conn = liveServiceConnection(clientHost, connectionId);
    final app = await readServiceJson(conn, 'ui://app');
    final port = McpUiRuntimePort(
      pageLoader: (uri) => readServiceJson(conn, uri),
      hostBrightnessOf: () => hostBrightness,
      onRuntimeReady: (target, runtime) {
        // Re-arm the process-singleton ThemeManager for THIS surface: studio
        // baseline + bundle-wins merge, then pin the host brightness — same
        // discipline as the workspace surface.
        final bundleTheme = app['theme'];
        void apply(Brightness b) {
          runtime.themeManager.setTheme(
            mergeServedTheme(
              VbuTheme.studioRuntimeTheme(),
              bundleTheme is Map ? bundleTheme.cast<String, dynamic>() : null,
            ),
          );
          runtime.themeManager.setHostBrightness(b);
        }

        apply(hostBrightness);
        // Keep the re-arm handle so the active-edge gate can re-assert this
        // surface's theme after a sibling tab resets the shared singleton.
        _reapplyTheme = apply;
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
