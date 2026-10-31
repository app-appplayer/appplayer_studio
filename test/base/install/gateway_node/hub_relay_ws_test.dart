import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/src/base/install/gateway_node/gateway_node.dart';
import 'package:flutter_test/flutter_test.dart';

/// Round-trips [HubRelayConnection] against a loopback ws server that inspects
/// the upgrade query and echoes an answer — proves the stream-mode transport
/// (connect with the hub query params, JSON frame send/receive) works e2e.
void main() {
  test('connect sends role/sessionId/token and round-trips JSON frames',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    Uri? seenUri;
    server.listen((req) async {
      seenUri = req.uri;
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((data) {
        final frame = jsonDecode(data as String) as Map<String, dynamic>;
        ws.add(jsonEncode({'echo': frame['payload']}));
      });
    });

    final conn = await HubRelayConnection.connect(
      relayUrl: 'ws://${server.address.host}:${server.port}',
      sessionId: 'sess-1',
      relayToken: 'tok-1',
    );
    addTearDown(conn.close);

    final firstReply = conn.incoming.first;
    await conn.send({'payload': {'x': 1}});
    final reply = await firstReply.timeout(const Duration(seconds: 2));

    expect(reply['echo'], {'x': 1});
    expect(seenUri!.queryParameters['role'], 'client');
    expect(seenUri!.queryParameters['sessionId'], 'sess-1');
    expect(seenUri!.queryParameters['token'], 'tok-1');
  });
}
