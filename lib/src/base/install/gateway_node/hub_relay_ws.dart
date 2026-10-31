import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// ws relay transport (spec 15 §4 `stream` mode) — connects to the hub relay as
/// `role=client` and exposes the raw MCP-frame pipe as an `(incoming, send)`
/// pair for [connectHubViaGateway]/the hub pump. Frames are JSON maps; the relay
/// carries them opaquely (no seq envelope — TCP ordering, reconnect = fresh).
///
/// Desktop hosts (Studio, a local gateway app) inject this. Web hosts don't
/// connect to the hub, so `dart:io WebSocket` (no extra dependency) is enough.
class HubRelayConnection {
  HubRelayConnection._(this._ws, this.incoming);

  final WebSocket _ws;

  /// Frames arriving from the peer (JSON maps).
  final Stream<Map<String, dynamic>> incoming;

  /// Send a frame to the peer.
  Future<void> send(Map<String, dynamic> frame) async =>
      _ws.add(jsonEncode(frame));

  /// Close the ws connection.
  Future<void> close() async => _ws.close();

  /// Connect as a **client** (consume direction) for [sessionId] with
  /// [relayToken] — `?role=client&sessionId=<id>&token=<token>`. The client
  /// socket carries **raw frame strings** (the relay does not envelope them); the
  /// relay resolves the peer nodeId server-side (host never sends it).
  static Future<HubRelayConnection> connect({
    required String relayUrl,
    required String sessionId,
    required String relayToken,
  }) => _open(relayUrl, {
    'role': 'client',
    'sessionId': sessionId,
    'token': relayToken,
  });

  /// Connect as a **node** (expose direction) for [nodeId] with the node
  /// [relayToken] from registration — `?role=node&nodeId=<id>&token=<token>`. The
  /// node socket carries the **`{type, sessionId, frame}` envelope** (the relay
  /// multiplexes many client sessions over this one socket); drive it with a
  /// [HubRelayNodeServer]. `frame` is a stringified frame — the node server
  /// decodes/encodes the inner payload.
  static Future<HubRelayConnection> connectNode({
    required String relayUrl,
    required String nodeId,
    required String relayToken,
  }) =>
      _open(relayUrl, {'role': 'node', 'nodeId': nodeId, 'token': relayToken});

  static Future<HubRelayConnection> _open(
    String relayUrl,
    Map<String, String> query,
  ) async {
    final base = Uri.parse(relayUrl);
    final uri = base.replace(
      queryParameters: {...base.queryParameters, ...query},
    );
    final ws = await WebSocket.connect(uri.toString());
    final incoming =
        ws
            .where((d) => d is String)
            .map((d) => jsonDecode(d as String))
            .where((m) => m is Map)
            .map((m) => (m as Map).cast<String, dynamic>())
            .asBroadcastStream();
    return HubRelayConnection._(ws, incoming);
  }
}
