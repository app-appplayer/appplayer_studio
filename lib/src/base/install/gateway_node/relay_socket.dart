import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// A hub relay socket that works wherever `web_socket_channel` does — native
/// and browser alike — so AppPlayer Cloud dials the relay the way the native
/// tiers do (platform spec 15 §4, spec 22 §4.2).
///
/// The token rides the WebSocket subprotocol offer (`relay-token.<token>`),
/// never the query string: a URL ends up in logs, and the relay echoes the
/// offered subprotocol so strict (browser) clients complete the handshake.
class RelaySocket {
  RelaySocket._(this._channel)
    : incoming =
          _channel.stream
              .where((d) => d is String)
              .cast<String>()
              .asBroadcastStream();

  final WebSocketChannel _channel;

  /// Text frames from the relay, in order.
  final Stream<String> incoming;

  /// Completes when the socket closes, from either end.
  Future<void> get done => _channel.sink.done;

  void send(String text) => _channel.sink.add(text);

  Future<void> close() async => _channel.sink.close();

  static const tokenPrefix = 'relay-token.';

  /// Consume direction: one session, raw frame strings both ways.
  static Future<RelaySocket> client({
    required String relayUrl,
    required String sessionId,
    required String relayToken,
  }) => _open(relayUrl, {'role': 'client', 'sessionId': sessionId}, relayToken);

  /// Lending direction: the node socket, carrying the relay's
  /// `{type, sessionId, frame}` envelopes in and `{sessionId, frame}` out —
  /// see [nodeEnvelopes] and [sendEnvelope].
  static Future<RelaySocket> node({
    required String relayUrl,
    required String nodeId,
    required String relayToken,
  }) => _open(relayUrl, {'role': 'node', 'nodeId': nodeId}, relayToken);

  static Future<RelaySocket> _open(
    String relayUrl,
    Map<String, String> query,
    String token,
  ) async {
    final base = Uri.parse(relayUrl);
    final uri = base.replace(
      queryParameters: {...base.queryParameters, ...query},
    );
    final channel = WebSocketChannel.connect(
      uri,
      protocols: ['$tokenPrefix$token'],
    );
    await channel.ready;
    return RelaySocket._(channel);
  }

  /// The node socket's envelopes as maps (non-object messages dropped).
  Stream<Map<String, dynamic>> get nodeEnvelopes =>
      incoming
          .map((text) {
            try {
              final v = jsonDecode(text);
              return v is Map ? v.cast<String, dynamic>() : null;
            } on FormatException {
              return null;
            }
          })
          .where((m) => m != null)
          .cast<Map<String, dynamic>>();

  /// Write one node → relay envelope.
  Future<void> sendEnvelope(Map<String, dynamic> envelope) async =>
      send(jsonEncode(envelope));
}
