import 'dart:async';
import 'dart:convert';

import 'package:mcp_gateway/mcp_gateway.dart';

import 'hub_caller.dart';
import 'hub_pump.dart';

/// Serves a node socket (expose direction) for one hub node. The relay
/// multiplexes many client sessions over this single socket with a
/// `{type, sessionId, frame}` envelope (hub `relay.ts` `RelayHub`), so this
/// demuxes by `sessionId` and serves each session against the shared [runtime]
/// as its own consumer — reusing [handleHubRequest] (same verbs as the
/// single-session [HubGatewayProvider]) and owning the runtime's `onEventRelay`
/// to route events back to the right session's envelope.
///
/// Wire (confirmed against `relay.ts`):
/// - relay → node: `{type:'open', sessionId, caller}` ·
///   `{type:'frame', sessionId, frame}` · `{type:'close', sessionId}`, where
///   `frame` is a **stringified** frame (double-encoded — the client's raw ws
///   message). This server decodes/encodes that inner payload.
/// - node → relay: `{sessionId, frame}` (no `type`; `frame` is a string).
///
/// Identity: `caller` is the market-signed caller token. It is checked once by
/// [verifyCaller] when the session opens and bound to the session; every frame
/// of the session runs as that caller. A session that was never opened, whose
/// caller is missing or does not verify, or whose token has expired is refused
/// — a session without identity is never served.
///
/// The host owns the [runtime] (started, local tools exposed via
/// `exposeThroughGateway` + a running poll loop) and the transport: inject the
/// decoded node-socket envelopes as [incoming] and the node→relay envelope sink
/// as [send] (e.g. from `HubRelayConnection.connectNode`).
class HubRelayNodeServer {
  HubRelayNodeServer({
    required this.runtime,
    required Stream<Map<String, dynamic>> incoming,
    required Future<void> Function(Map<String, dynamic> envelope) send,
    required HubCallerVerifier verifyCaller,
    DateTime Function()? now,
  }) : _incoming = incoming,
       _send = send,
       _verifyCaller = verifyCaller,
       _now = now ?? DateTime.now;

  final GatewayRuntime runtime;
  final Stream<Map<String, dynamic>> _incoming;
  final Future<void> Function(Map<String, dynamic> envelope) _send;
  final HubCallerVerifier _verifyCaller;
  final DateTime Function() _now;

  /// A session is its verification in flight or done. Frames right behind
  /// their `open` (the relay drains waiting frames immediately after it) wait
  /// for the verdict instead of racing it.
  final Map<String, Future<HubCaller?>> _pending = {};
  final Map<String, HubCaller> _callers = {};
  StreamSubscription<Map<String, dynamic>>? _sub;
  bool _started = false;

  bool get isStarted => _started;

  /// Live session ids this node is serving — those with a verified caller.
  Set<String> get sessions => Set.unmodifiable(_callers.keys);

  /// The verified caller of [sessionId], or `null` if it is not being served.
  /// A host reads this to decide what the session may do (plan · features).
  HubCaller? callerOf(String sessionId) => _callers[sessionId];

  /// Wire event egress (per-session) and start consuming envelopes.
  Future<void> start() async {
    if (_started) return;
    runtime.eventBus.onEventRelay = (cid, event) async {
      if (!_callers.containsKey(cid)) return false;
      await _sendFrame(cid, hubEventFrame(event));
      return true;
    };
    _sub = _incoming.listen(_onEnvelope);
    _started = true;
  }

  Future<void> _onEnvelope(Map<String, dynamic> env) async {
    final sessionId = env['sessionId'] as String?;
    if (sessionId == null) return;
    switch (env['type']) {
      case 'open':
        final token = env['caller'];
        final verdict =
            token is String && token.isNotEmpty
                ? _verify(token)
                : Future<HubCaller?>.value();
        _pending[sessionId] = verdict;
        final caller = await verdict;
        // A close that arrived while verifying wins.
        if (caller != null && identical(_pending[sessionId], verdict)) {
          _callers[sessionId] = caller;
        }
      case 'close':
        _drop(sessionId);
      case 'frame':
        final raw = env['frame'];
        if (raw is! String) return;
        final Map<String, dynamic> reqFrame;
        try {
          reqFrame = (jsonDecode(raw) as Map).cast<String, dynamic>();
        } catch (_) {
          return;
        }
        if (reqFrame[HubWire.kind] != HubWire.req) return;
        final id = reqFrame[HubWire.id];
        final caller = await (_pending[sessionId] ?? Future.value());
        if (caller == null || !_callers.containsKey(sessionId)) {
          await _sendFrame(
            sessionId,
            _refusal(id, 'session has no verified caller'),
          );
          return;
        }
        if (caller.isExpiredAt(_now())) {
          _drop(sessionId);
          await _sendFrame(sessionId, _refusal(id, 'session caller expired'));
          return;
        }
        final res = await handleHubRequest(runtime, sessionId, reqFrame);
        if (res != null) await _sendFrame(sessionId, res);
    }
  }

  /// A verifier that fails refuses the session; it never takes the node down.
  Future<HubCaller?> _verify(String token) async {
    try {
      return await _verifyCaller(token);
    } catch (_) {
      return null;
    }
  }

  void _drop(String sessionId) {
    _pending.remove(sessionId);
    if (_callers.remove(sessionId) != null) {
      runtime.eventBus.cleanupConsumer(sessionId);
    }
  }

  Map<String, dynamic> _refusal(Object? id, String message) => {
    HubWire.kind: HubWire.res,
    HubWire.id: id,
    HubWire.ok: false,
    HubWire.result: {HubWire.error: message},
  };

  Future<void> _sendFrame(String sessionId, Map<String, dynamic> frame) =>
      _send({'sessionId': sessionId, 'frame': jsonEncode(frame)});

  /// Stop consuming, release the event hook, and clear per-session state.
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    if (runtime.isStarted) runtime.eventBus.onEventRelay = null;
    for (final s in _callers.keys) {
      runtime.eventBus.cleanupConsumer(s);
    }
    _callers.clear();
    _pending.clear();
    _started = false;
  }
}
