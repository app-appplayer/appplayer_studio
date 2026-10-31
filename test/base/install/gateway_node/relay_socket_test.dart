import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/src/base/install/gateway_node/gateway_node.dart';
import 'package:flutter_test/flutter_test.dart';

/// [RelaySocket] against a loopback ws server shaped like the hub relay: the
/// token must arrive in the subprotocol offer (never the query), the server
/// echoes that subprotocol, and node envelopes decode.
void main() {
  late HttpServer server;
  Uri? seenUri;
  String? seenProtocol;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      seenUri = req.uri;
      seenProtocol = req.headers.value('sec-websocket-protocol');
      final ws = await WebSocketTransformer.upgrade(
        req,
        protocolSelector: (offered) => offered.first,
      );
      ws.listen((data) {
        final m = jsonDecode(data as String) as Map<String, dynamic>;
        if (req.uri.queryParameters['role'] == 'node') {
          ws.add(jsonEncode(
              {'type': 'frame', 'sessionId': m['sessionId'], 'frame': m['frame']}));
          ws.add('not json');
        } else {
          ws.add(jsonEncode({'echo': m}));
        }
      });
    });
  });

  tearDown(() => server.close(force: true));

  String url() => 'ws://${server.address.host}:${server.port}';

  test('client socket carries the token in the subprotocol, not the query',
      () async {
    final socket = await RelaySocket.client(
        relayUrl: url(), sessionId: 's1', relayToken: 'tok');
    addTearDown(socket.close);

    final reply = socket.incoming.first;
    socket.send(jsonEncode({'k': 'req', 'id': 1}));
    expect(jsonDecode(await reply.timeout(const Duration(seconds: 2))),
        {'echo': {'k': 'req', 'id': 1}});
    expect(seenProtocol, 'relay-token.tok');
    expect(seenUri!.queryParameters, {'role': 'client', 'sessionId': 's1'});
  });

  test('node socket decodes envelopes and drops what is not one', () async {
    final socket = await RelaySocket.node(
        relayUrl: url(), nodeId: 'n1', relayToken: 'tok');
    addTearDown(socket.close);

    final envelopes = socket.nodeEnvelopes.take(1).toList();
    await socket.sendEnvelope({'sessionId': 's9', 'frame': '{"k":"res"}'});
    final got = await envelopes.timeout(const Duration(seconds: 2));
    expect(got.single, {'type': 'frame', 'sessionId': 's9', 'frame': '{"k":"res"}'});
    expect(seenUri!.queryParameters, {'role': 'node', 'nodeId': 'n1'});
  });
}
