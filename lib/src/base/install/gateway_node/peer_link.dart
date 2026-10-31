import 'dart:async';
import 'dart:convert';

import 'package:mcp_gateway/mcp_gateway.dart';

import 'hub_caller.dart';
import 'hub_node.dart';

/// Account peer link (platform spec 22) — the same hub session moving between
/// two paths: the relay it always opens on, and a direct peer-to-peer pipe the
/// two ends negotiate inside that session.
///
/// Nothing here is a new protocol. Gateway frames stay gateway frames
/// (mcp_gateway 1.0) and the node side stays a [HubRelayNodeServer]; what this
/// adds is where each frame travels, plus the in-band `k:"link"` control frames
/// that negotiate the direct path.

/// Wire keys of the link control frame (spec 22 §4.3). `k:"link"` never
/// collides with a gateway frame kind (`req` · `res` · `event` · `rreq` ·
/// `rres`), so the two ends can tell them apart without an envelope.
class LinkWire {
  LinkWire._();

  static const kind = 'link';
  static const op = 'op';
  static const sdp = 'sdp';
  static const candidate = 'candidate';

  static const offer = 'offer';
  static const answer = 'answer';
  static const iceCandidate = 'candidate';

  /// Sent by the consuming end once its direct pipe is open: from here on the
  /// node answers this session over the direct pipe.
  static const switchPath = 'switch';

  /// Either end is giving the direct path up; frames go back to the relay.
  static const bye = 'bye';

  static bool isLink(Map<String, dynamic> frame) => frame['k'] == kind;

  static Map<String, dynamic> frame(String op, [Map<String, dynamic>? body]) =>
      {'k': kind, LinkWire.op: op, ...?body};
}

/// An ordered duplex text pipe between two peers — a WebRTC data channel in
/// the hosts, an in-memory pair in tests. One pipe carries one session.
abstract interface class PeerPipe {
  /// Frames from the other end, in order.
  Stream<String> get incoming;

  /// Send one frame. Throws when the pipe is already closed.
  void send(String text);

  /// Completes when the pipe closes, from either end.
  Future<void> get done;

  void close();
}

Map<String, dynamic>? _decode(String text) {
  try {
    final value = jsonDecode(text);
    return value is Map ? value.cast<String, dynamic>() : null;
  } on FormatException {
    return null;
  }
}

/// The lending end (A). One node server serves every session, whichever path
/// its frames arrive on; replies leave on the path the session currently uses.
class PeerNodeLink {
  PeerNodeLink({
    required GatewayRuntime runtime,
    required HubCallerVerifier verifyCaller,
  }) {
    _server = HubRelayNodeServer(
      runtime: runtime,
      incoming: _toServer.stream,
      send: _route,
      verifyCaller: verifyCaller,
    );
  }

  late final HubRelayNodeServer _server;
  final StreamController<Map<String, dynamic>> _toServer =
      StreamController<Map<String, dynamic>>.broadcast();
  final Map<String, PeerPipe> _direct = {};
  final Map<String, StreamSubscription<String>> _directSubs = {};
  final Set<String> _switched = {};
  Future<void> Function(Map<String, dynamic> envelope)? _relaySend;
  StreamSubscription<Map<String, dynamic>>? _relaySub;

  /// A link control frame arrived for [sessionId] (offer · answer · candidate ·
  /// bye). `switch` is handled here and never reaches this callback.
  void Function(String sessionId, Map<String, dynamic> frame)? onLink;

  /// Sessions currently open on this node.
  Set<String> get sessions => _server.sessions;

  /// Whether [sessionId] is answered over its direct pipe.
  bool isDirect(String sessionId) =>
      _switched.contains(sessionId) && _direct.containsKey(sessionId);

  Future<void> start() => _server.start();

  /// Serve the relay node socket: [envelopes] are the relay's
  /// `{type, sessionId, frame}` messages, [send] writes `{sessionId, frame}`
  /// back to it.
  void attachRelay(
    Stream<Map<String, dynamic>> envelopes,
    Future<void> Function(Map<String, dynamic> envelope) send,
  ) {
    _relaySub?.cancel();
    _relaySend = send;
    _relaySub = envelopes.listen(_onRelayEnvelope);
  }

  void _onRelayEnvelope(Map<String, dynamic> env) {
    final sessionId = env['sessionId'];
    if (sessionId is! String) return;
    if (env['type'] == 'frame') {
      final raw = env['frame'];
      if (raw is! String) return;
      final frame = _decode(raw);
      // The node server decodes without a guard; a frame that is not a JSON
      // object stops here instead of taking the session's handler down.
      if (frame == null) return;
      if (LinkWire.isLink(frame)) {
        _onLinkFrame(sessionId, frame);
        return;
      }
    }
    if (env['type'] == 'close') _dropDirect(sessionId);
    _toServer.add(env);
  }

  /// Carry [sessionId] over [pipe] as well. Frames arriving on it are served
  /// like relay frames; replies move to it once the consumer sends `switch`.
  void attachDirect(String sessionId, PeerPipe pipe) {
    // Replace a previous pipe but keep a `switch` that already arrived.
    _dropPipe(sessionId);
    _direct[sessionId] = pipe;
    _directSubs[sessionId] = pipe.incoming.listen((text) {
      final frame = _decode(text);
      if (frame == null) return;
      if (LinkWire.isLink(frame)) {
        _onLinkFrame(sessionId, frame);
        return;
      }
      _toServer.add({'type': 'frame', 'sessionId': sessionId, 'frame': text});
    });
    pipe.done.whenComplete(() {
      if (identical(_direct[sessionId], pipe)) _dropDirect(sessionId);
    });
  }

  void _onLinkFrame(String sessionId, Map<String, dynamic> frame) {
    switch (frame[LinkWire.op]) {
      case LinkWire.switchPath:
        // Kept even before the pipe is attached: the consumer may see its end
        // open first, and the switch must not be lost to that race.
        _switched.add(sessionId);
      case LinkWire.bye:
        _dropDirect(sessionId);
        onLink?.call(sessionId, frame);
      default:
        onLink?.call(sessionId, frame);
    }
  }

  /// Send a link control frame to the consumer of [sessionId]. Always over the
  /// relay: negotiation must travel the path the session was authenticated on.
  Future<void> sendLink(String sessionId, Map<String, dynamic> frame) async {
    final send = _relaySend;
    if (send == null) return;
    await send({'sessionId': sessionId, 'frame': jsonEncode(frame)});
  }

  Future<void> _route(Map<String, dynamic> envelope) async {
    final sessionId = envelope['sessionId'] as String;
    final frame = envelope['frame'] as String;
    final pipe = _direct[sessionId];
    if (pipe != null && (_switched.contains(sessionId) || _relaySend == null)) {
      try {
        pipe.send(frame);
        return;
      } catch (_) {
        // The pipe died between frames — the relay still carries the session.
        _dropDirect(sessionId);
      }
    }
    await _relaySend?.call(envelope);
  }

  /// The direct path for [sessionId] is over: replies go back to the relay.
  void _dropDirect(String sessionId) {
    _switched.remove(sessionId);
    _dropPipe(sessionId);
  }

  void _dropPipe(String sessionId) {
    _directSubs.remove(sessionId)?.cancel();
    _direct.remove(sessionId)?.close();
  }

  Future<void> stop() async {
    await _relaySub?.cancel();
    _relaySub = null;
    for (final id in _direct.keys.toList()) {
      _dropDirect(id);
    }
    await _server.stop();
    await _toServer.close();
  }
}

/// The borrowing end (B) of one session. Presents gateway frames as the
/// `(incoming, send)` pair a [HubGatewayConsumer] takes, and decides per frame
/// which path it leaves on.
class PeerSessionLink {
  PeerSessionLink({
    required Stream<String> relayIncoming,
    required void Function(String text) relaySend,
  }) : _relaySend = relaySend {
    _relaySub = relayIncoming.listen(_onText, onDone: _onRelayDone);
  }

  final void Function(String text) _relaySend;
  late final StreamSubscription<String> _relaySub;
  final StreamController<Map<String, dynamic>> _incoming =
      StreamController<Map<String, dynamic>>.broadcast();
  PeerPipe? _direct;
  StreamSubscription<String>? _directSub;
  final Completer<void> _relayClosed = Completer<void>();

  /// A link control frame arrived from the node.
  void Function(Map<String, dynamic> frame)? onLink;

  /// The direct pipe closed; frames are back on the relay.
  void Function()? onDirectLost;

  /// Gateway frames from the node, from whichever path they came.
  Stream<Map<String, dynamic>> get incoming => _incoming.stream;

  bool get isDirect => _direct != null;

  /// Completes when the relay side of the session is gone — the session is
  /// over, whatever the direct pipe is doing.
  Future<void> get closed => _relayClosed.future;

  void _onText(String text) {
    final frame = _decode(text);
    if (frame == null) return;
    if (LinkWire.isLink(frame)) {
      if (frame[LinkWire.op] == LinkWire.bye) _dropDirect();
      onLink?.call(frame);
      return;
    }
    if (!_incoming.isClosed) _incoming.add(frame);
  }

  void _onRelayDone() {
    if (!_relayClosed.isCompleted) _relayClosed.complete();
  }

  /// Send a gateway frame on the current path.
  Future<void> send(Map<String, dynamic> frame) async {
    final text = jsonEncode(frame);
    final pipe = _direct;
    if (pipe != null) {
      try {
        pipe.send(text);
        return;
      } catch (_) {
        _dropDirect();
      }
    }
    _relaySend(text);
  }

  /// Send a link control frame to the node over the relay.
  void sendLink(Map<String, dynamic> frame) => _relaySend(jsonEncode(frame));

  /// Move this session onto [pipe]. Requests already sent keep their answers
  /// on whichever path those answers take — the consumer pairs them by id.
  void useDirect(PeerPipe pipe) {
    _dropDirect();
    _direct = pipe;
    _directSub = pipe.incoming.listen(_onText);
    sendLink(LinkWire.frame(LinkWire.switchPath));
    pipe.done.whenComplete(() {
      if (identical(_direct, pipe)) {
        _dropDirect();
        onDirectLost?.call();
      }
    });
  }

  void _dropDirect() {
    _directSub?.cancel();
    _directSub = null;
    final pipe = _direct;
    _direct = null;
    pipe?.close();
  }

  Future<void> close() async {
    _dropDirect();
    await _relaySub.cancel();
    _onRelayDone();
    await _incoming.close();
  }
}

/// A linked in-memory [PeerPipe] pair, for tests and local wiring.
class PeerMemoryPipe implements PeerPipe {
  PeerMemoryPipe._(this._in, this._out, this._done);

  /// Two ends: what one sends, the other receives.
  static (PeerMemoryPipe, PeerMemoryPipe) pair() {
    final ab = StreamController<String>.broadcast();
    final ba = StreamController<String>.broadcast();
    final done = Completer<void>();
    return (PeerMemoryPipe._(ba, ab, done), PeerMemoryPipe._(ab, ba, done));
  }

  final StreamController<String> _in;
  final StreamController<String> _out;
  final Completer<void> _done;

  @override
  Stream<String> get incoming => _in.stream;

  @override
  void send(String text) {
    if (_done.isCompleted) throw StateError('pipe closed');
    _out.add(text);
  }

  @override
  Future<void> get done => _done.future;

  @override
  void close() {
    if (!_done.isCompleted) _done.complete();
  }
}
