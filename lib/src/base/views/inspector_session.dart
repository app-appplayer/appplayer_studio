// Inspector session manager — owns the lifecycle of every variant
// process the user spawns from the Inspector. Phase 2A wires
// `mcp_client` on top of Phase 1B-2's process supervision: stdio uses
// the client's own StdioClientTransport (the client owns the spawn),
// http/sse first launch a `Process.start` with `--http`/`--sse` flags
// and then connect a streamable-HTTP / SSE client to the live port.
//
// On `stop` the session disconnects the client and (for non-stdio
// transports) kills the process. `dispose` does the same for every
// session — no orphans when the panel rebuilds or vibe shuts down.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';
import 'package:brain_kernel/mcp_client.dart';

/// What status a variant card should display.
enum InspectorStatus { idle, spawning, connecting, connected, exited, error }

/// Direction of a single MCP wire frame logged in the Inspector.
enum InspectorFrameKind { request, response, notification, error, info }

/// One entry in the wire log. `payload` holds whatever JSON-shaped
/// data the call carried (params for a request, result for a response,
/// content for a tool call, etc). Errors carry the message in `error`.
class InspectorFrame {
  InspectorFrame({
    required this.kind,
    required this.method,
    this.payload,
    this.error,
    this.duration,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final InspectorFrameKind kind;
  final String method;
  final dynamic payload;
  final String? error;
  final Duration? duration;
  final DateTime timestamp;

  /// Wire-log fixture serialization. Round-trips through a JSON file
  /// so a session's frame stream can be exported, re-imported, and
  /// replayed against another running variant.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind.name,
    'method': method,
    'timestamp': timestamp.toIso8601String(),
    if (payload != null) 'payload': payload,
    if (error != null) 'error': error,
    if (duration != null) 'duration_ms': duration!.inMilliseconds,
  };

  static InspectorFrame fromJson(Map<String, dynamic> json) {
    final kindName = json['kind'] as String? ?? 'info';
    final kind = InspectorFrameKind.values.firstWhere(
      (k) => k.name == kindName,
      orElse: () => InspectorFrameKind.info,
    );
    final ts = json['timestamp'];
    final dur = json['duration_ms'];
    return InspectorFrame(
      kind: kind,
      method: (json['method'] as String?) ?? 'unknown',
      payload: json['payload'],
      error: json['error'] as String?,
      duration: dur is int ? Duration(milliseconds: dur) : null,
      timestamp: ts is String ? DateTime.tryParse(ts) : null,
    );
  }
}

/// Transport the user (or default heuristic) picked for a variant.
enum InspectorTransport { stdio, http, sse }

extension InspectorTransportLabel on InspectorTransport {
  String get label {
    switch (this) {
      case InspectorTransport.stdio:
        return 'stdio';
      case InspectorTransport.http:
        return 'http';
      case InspectorTransport.sse:
        return 'sse';
    }
  }
}

/// Per-variant session record. Tracks the spawned process (or null
/// when `mcp_client`'s stdio transport owns the spawn), the connected
/// client, and the application definition / dashboard pulled from
/// `ui://app`, `ui://app/info`, and each `ui://pages/<id>` route.
class InspectorSession {
  InspectorSession({
    required this.slug,
    required this.transport,
    this.host = '127.0.0.1',
    this.port = 8080,
    this.endpoint = '/mcp',
  });

  final String slug;
  InspectorTransport transport;
  String host;
  int port;
  String endpoint;

  Process? proc;
  Client? client;
  InspectorStatus status = InspectorStatus.idle;
  String? errorMessage;
  DateTime? startedAt;
  String? endpointUrl;

  // ── Pulled MCP surface ──────────────────────────────────────────────
  List<Tool> tools = const <Tool>[];
  Map<String, dynamic>? appDefinition;
  Map<String, dynamic>? appInfo;
  final Map<String, Map<String, dynamic>> pages =
      <String, Map<String, dynamic>>{};

  /// Live MCPUIRuntime instance per rendered target (e.g. `mcp-ui:app`,
  /// `mcp-ui:dashboard`). Recreated whenever the surface re-initialises
  /// (snapshot version bump). The Inspector State panel reads
  /// `runtime.stateManager` from the focused entry to display + edit
  /// state values live.
  final Map<String, MCPUIRuntime> runtimes = <String, MCPUIRuntime>{};

  /// Convenience accessor — `appDefinition.dashboard` if present.
  Map<String, dynamic>? get dashboard {
    final d = appDefinition?['dashboard'];
    return d is Map<String, dynamic> ? d : null;
  }

  StreamSubscription<int>? _exitSub;
  StreamSubscription<DisconnectReason>? _disconnectSub;
  final List<String> stderrBuffer = <String>[];

  /// Rolling wire-log. Capped to keep memory bounded; old entries
  /// drop off the front.
  static const int _maxFrames = 500;
  final List<InspectorFrame> frames = <InspectorFrame>[];

  void addFrame(InspectorFrame f) {
    frames.add(f);
    if (frames.length > _maxFrames) {
      frames.removeRange(0, frames.length - _maxFrames);
    }
  }

  String get displayLabel {
    switch (transport) {
      case InspectorTransport.stdio:
        return 'stdio';
      case InspectorTransport.http:
      case InspectorTransport.sse:
        return '${transport.label} · $host:$port$endpoint';
    }
  }
}

/// Owns every active inspector session. Lives at the panel level.
/// `dispose` kills every spawned process and disconnects every client
/// — no orphans.
class InspectorSessionManager extends ChangeNotifier {
  final Map<String, InspectorSession> _sessions = <String, InspectorSession>{};

  InspectorSession? operator [](String slug) => _sessions[slug];

  Iterable<InspectorSession> get values => _sessions.values;

  /// Slug list — used by MCP tools to surface "available sessions"
  /// when a caller omits the slug argument or passes an unknown one.
  Iterable<String> get allSlugs => _sessions.keys;

  /// Connect to the variant. For stdio the `mcp_client` transport
  /// spawns the binary itself; for http/sse we `Process.start` first
  /// and then connect a streamable-HTTP / SSE client to the live port.
  Future<void> connect({
    required String slug,
    required String binary,
    required InspectorTransport transport,
    String host = '127.0.0.1',
    int port = 8080,
    String endpoint = '/mcp',
  }) async {
    // Single-session model — but the user must stop the active
    // variant *explicitly* before starting another one. The panel
    // enforces that gate; this method just tears down the same-slug
    // session so reconnect-after-error works without an extra click.
    await stop(slug);
    final session = InspectorSession(
      slug: slug,
      transport: transport,
      host: host,
      port: port,
      endpoint: endpoint,
    )..status = InspectorStatus.spawning;
    _sessions[slug] = session;
    notifyListeners();

    try {
      switch (transport) {
        case InspectorTransport.stdio:
          await _connectStdio(session, binary);
          break;
        case InspectorTransport.http:
        case InspectorTransport.sse:
          await _connectNetwork(session, binary);
          break;
      }
      // External kills, transport closes, peer-side errors all surface
      // through `Client.onDisconnect` — flip the card to `exited` so
      // the user sees the green dot drop without having to click Stop.
      session._disconnectSub = session.client?.onDisconnect.listen((_) {
        if (session.status == InspectorStatus.connected ||
            session.status == InspectorStatus.connecting) {
          session.status = InspectorStatus.exited;
          notifyListeners();
        }
      });
      await _hydrate(session);
      session.status = InspectorStatus.connected;
      session.startedAt = DateTime.now();
      notifyListeners();
    } catch (e) {
      session
        ..status = InspectorStatus.error
        ..errorMessage = e.toString();
      notifyListeners();
    }
  }

  Future<void> _connectStdio(InspectorSession session, String binary) async {
    session.status = InspectorStatus.connecting;
    notifyListeners();
    final result = await McpClient.createAndConnect(
      config: const McpClientConfig(name: 'vibe-inspector', version: '0.1.0'),
      transportConfig: TransportConfig.stdio(
        command: binary,
        arguments: const <String>[],
      ),
    );
    if (!result.isSuccess) {
      throw Exception('stdio connect failed: ${result.failureOrNull}');
    }
    session.client = result.get();
  }

  Future<void> _connectNetwork(InspectorSession session, String binary) async {
    final args = <String>[
      if (session.transport == InspectorTransport.http) '--http' else '--sse',
      '--host',
      session.host,
      '--port',
      session.port.toString(),
      '--endpoint',
      session.endpoint,
    ];
    final proc = await Process.start(binary, args);
    session.proc = proc;
    session.endpointUrl =
        'http://${session.host}:${session.port}${session.endpoint}';
    proc.stderr.transform(const SystemEncoding().decoder).listen((line) {
      if (session.stderrBuffer.length >= 200) {
        session.stderrBuffer.removeAt(0);
      }
      session.stderrBuffer.add(line);
    });
    proc.stdout.drain<void>();
    session._exitSub = proc.exitCode.asStream().listen((code) {
      session.status =
          code == 0 ? InspectorStatus.exited : InspectorStatus.error;
      if (code != 0 && session.errorMessage == null) {
        session.errorMessage = 'exit code $code';
      }
      notifyListeners();
    });

    // Wait briefly for the server to bind the port before connecting.
    await _waitForPort(
      session.host,
      session.port,
      timeout: const Duration(seconds: 5),
    );

    session.status = InspectorStatus.connecting;
    notifyListeners();
    final TransportConfig tc;
    if (session.transport == InspectorTransport.http) {
      tc = TransportConfig.streamableHttp(
        baseUrl: session.endpointUrl!,
        timeout: const Duration(seconds: 10),
      );
    } else {
      tc = TransportConfig.sse(serverUrl: session.endpointUrl!);
    }
    final result = await McpClient.createAndConnect(
      config: const McpClientConfig(name: 'vibe-inspector', version: '0.1.0'),
      transportConfig: tc,
    );
    if (!result.isSuccess) {
      throw Exception(
        '${session.transport.label} connect failed: '
        '${result.failureOrNull}',
      );
    }
    session.client = result.get();
  }

  Future<void> _waitForPort(
    String host,
    int port, {
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final sock = await Socket.connect(
          host,
          port,
          timeout: const Duration(milliseconds: 500),
        );
        await sock.close();
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    throw Exception('Server did not bind $host:$port within $timeout');
  }

  /// Pull `ui://app`, `ui://app/info`, every `ui://pages/<id>` route,
  /// and the tool list. Stored on the session for the panel to render.
  Future<void> _hydrate(InspectorSession session) async {
    final client = session.client!;
    session.addFrame(
      InspectorFrame(
        kind: InspectorFrameKind.info,
        method: 'connected',
        payload: <String, dynamic>{
          'transport': session.transport.label,
          if (session.endpointUrl != null) 'endpoint': session.endpointUrl,
        },
      ),
    );
    final t0 = DateTime.now();
    session.addFrame(
      InspectorFrame(kind: InspectorFrameKind.request, method: 'tools/list'),
    );
    session.tools = await client.listTools();
    // Expand the response to a list of `{name, description, inputSchema}`
    // maps so the wire log shows everything the host advertised — not
    // just the names.
    session.addFrame(
      InspectorFrame(
        kind: InspectorFrameKind.response,
        method: 'tools/list',
        duration: DateTime.now().difference(t0),
        payload: <String, dynamic>{
          'tools': <Map<String, dynamic>>[
            for (final t in session.tools)
              <String, dynamic>{
                'name': t.name,
                if (t.description.isNotEmpty) 'description': t.description,
                if (t.inputSchema.isNotEmpty) 'inputSchema': t.inputSchema,
              },
          ],
        },
      ),
    );

    Map<String, dynamic>? readJson(ReadResourceResult r) {
      final c = r.contents.isEmpty ? null : r.contents.first;
      if (c == null) return null;
      final text = c.text;
      if (text == null) return null;
      try {
        final decoded =
            (text.isEmpty)
                ? <String, dynamic>{}
                : (jsonDecode(text) as Map<String, dynamic>);
        return decoded;
      } catch (_) {
        return null;
      }
    }

    Future<Map<String, dynamic>?> readResource(String uri) async {
      final t = DateTime.now();
      session.addFrame(
        InspectorFrame(
          kind: InspectorFrameKind.request,
          method: 'resources/read',
          payload: <String, dynamic>{'uri': uri},
        ),
      );
      try {
        final r = await client.readResource(uri);
        final body = readJson(r);
        // Log the full body — the user wants to see exactly what the
        // server returned, not a key summary.
        session.addFrame(
          InspectorFrame(
            kind: InspectorFrameKind.response,
            method: 'resources/read',
            duration: DateTime.now().difference(t),
            payload: <String, dynamic>{
              'uri': uri,
              if (body != null) 'body': body,
            },
          ),
        );
        return body;
      } catch (e) {
        session.addFrame(
          InspectorFrame(
            kind: InspectorFrameKind.error,
            method: 'resources/read',
            duration: DateTime.now().difference(t),
            payload: <String, dynamic>{'uri': uri},
            error: e.toString(),
          ),
        );
        return null;
      }
    }

    session.appDefinition = await readResource('ui://app');
    session.appInfo = await readResource('ui://app/info');

    // Walk routes → ui://pages/<id>. Routes can be either an inline
    // PageDefinition or a string URI. Only string URIs need a fetch.
    final routes = session.appDefinition?['routes'];
    if (routes is Map) {
      for (final entry in routes.entries) {
        final value = entry.value;
        if (value is String && value.startsWith('ui://pages/')) {
          final id = value.substring('ui://pages/'.length);
          final page = await readResource(value);
          if (page != null) session.pages[id] = page;
        } else if (value is Map<String, dynamic>) {
          // Inline page definition. Use the route path as id (strip
          // the leading slash) so callers can look it up uniformly.
          final id = (entry.key as String).replaceFirst(RegExp(r'^/'), '');
          session.pages[id] = value;
        }
      }
    }
  }

  /// Run a tool call on the active session, recording request +
  /// response frames. The render surface uses this so every wire
  /// interaction shows up in the logger.
  Future<CallToolResult?> recordedCallTool({
    required InspectorSession session,
    required String tool,
    required Map<String, dynamic> params,
  }) async {
    final client = session.client;
    if (client == null) return null;
    final t = DateTime.now();
    session.addFrame(
      InspectorFrame(
        kind: InspectorFrameKind.request,
        method: 'tools/call · $tool',
        payload: params,
      ),
    );
    notifyListeners();
    try {
      final r = await client.callTool(tool, params);
      final dur = DateTime.now().difference(t);
      // Decode the first text content for a structured payload preview.
      dynamic preview;
      if (r.content.isNotEmpty && r.content.first is TextContent) {
        try {
          preview = jsonDecode((r.content.first as TextContent).text);
        } catch (_) {
          preview = (r.content.first as TextContent).text;
        }
      }
      session.addFrame(
        InspectorFrame(
          kind:
              r.isError ?? false
                  ? InspectorFrameKind.error
                  : InspectorFrameKind.response,
          method: 'tools/call · $tool',
          duration: dur,
          payload: preview,
        ),
      );
      notifyListeners();
      return r;
    } catch (e) {
      session.addFrame(
        InspectorFrame(
          kind: InspectorFrameKind.error,
          method: 'tools/call · $tool',
          duration: DateTime.now().difference(t),
          payload: params,
          error: e.toString(),
        ),
      );
      notifyListeners();
      return null;
    }
  }

  /// Track the latest [MCPUIRuntime] instance for [target] under
  /// [session]. Replaces any prior entry — the runtime is re-created
  /// each time the snapshot bumps, and the State panel always wants
  /// the freshest reference.
  void bindRuntime(
    InspectorSession session,
    String target,
    MCPUIRuntime runtime,
  ) {
    session.runtimes[target] = runtime;
    notifyListeners();
  }

  /// Replay a previously-exported wire-log fixture against an active
  /// [session]. Walks the recorded frames in order; for every
  /// `tools/call · <name>` request it fires the same tool with the
  /// recorded params, logs a `→ replay …` request frame and a
  /// `← replay <pass|fail>` response frame so the diff vs the
  /// expected payload shows up in the wire log inline.
  Future<int> replayFixture({
    required InspectorSession session,
    required List<InspectorFrame> fixture,
  }) async {
    final client = session.client;
    if (client == null) return 0;
    var replayed = 0;
    for (var i = 0; i < fixture.length; i++) {
      final f = fixture[i];
      if (f.kind != InspectorFrameKind.request) continue;
      if (!f.method.startsWith('tools/call · ')) continue;
      final tool = f.method.substring('tools/call · '.length);
      final params =
          f.payload is Map<String, dynamic>
              ? Map<String, dynamic>.from(f.payload as Map)
              : <String, dynamic>{};
      // Find the recorded response for this request — first frame
      // after `i` with the same method that's a response/error.
      dynamic expected;
      for (var j = i + 1; j < fixture.length; j++) {
        final g = fixture[j];
        if (g.method != f.method) continue;
        if (g.kind == InspectorFrameKind.response ||
            g.kind == InspectorFrameKind.error) {
          expected = g.payload;
          break;
        }
      }
      session.addFrame(
        InspectorFrame(
          kind: InspectorFrameKind.info,
          method: 'replay → $tool',
          payload: params,
        ),
      );
      notifyListeners();
      final t = DateTime.now();
      try {
        final r = await client.callTool(tool, params);
        final dur = DateTime.now().difference(t);
        dynamic actual;
        if (r.content.isNotEmpty && r.content.first is TextContent) {
          try {
            actual = jsonDecode((r.content.first as TextContent).text);
          } catch (_) {
            actual = (r.content.first as TextContent).text;
          }
        }
        final pass = _payloadEquals(actual, expected);
        session.addFrame(
          InspectorFrame(
            kind: pass ? InspectorFrameKind.response : InspectorFrameKind.error,
            method: 'replay ${pass ? 'PASS' : 'FAIL'} $tool',
            duration: dur,
            payload: <String, dynamic>{
              'actual': actual,
              if (!pass) 'expected': expected,
            },
          ),
        );
        replayed++;
      } catch (e) {
        session.addFrame(
          InspectorFrame(
            kind: InspectorFrameKind.error,
            method: 'replay ERROR $tool',
            duration: DateTime.now().difference(t),
            error: e.toString(),
          ),
        );
      }
      notifyListeners();
    }
    return replayed;
  }

  /// Deep equality for the replay diff. Maps + lists compare member-
  /// wise; primitives via ==. Treats string-encoded numerics
  /// loosely is overkill here — fixtures are JSON round-trips already.
  static bool _payloadEquals(dynamic a, dynamic b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!b.containsKey(k)) return false;
        if (!_payloadEquals(a[k], b[k])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_payloadEquals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  Future<void> stop(String slug) async {
    final session = _sessions[slug];
    if (session == null) return;
    final client = session.client;
    if (client != null) {
      try {
        client.disconnect();
      } catch (_) {
        /* best effort */
      }
    }
    final proc = session.proc;
    await session._exitSub?.cancel();
    session._exitSub = null;
    await session._disconnectSub?.cancel();
    session._disconnectSub = null;
    if (proc != null) {
      proc.kill();
      try {
        await proc.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        proc.kill(ProcessSignal.sigkill);
      }
    }
    _sessions.remove(slug);
    notifyListeners();
  }

  Future<void> stopAll() async {
    final slugs = List<String>.from(_sessions.keys);
    for (final slug in slugs) {
      await stop(slug);
    }
  }

  @override
  void dispose() {
    for (final session in _sessions.values) {
      session._exitSub?.cancel();
      session._disconnectSub?.cancel();
      try {
        session.client?.disconnect();
      } catch (_) {
        /* ignore */
      }
      session.proc?.kill();
    }
    _sessions.clear();
    super.dispose();
  }
}
