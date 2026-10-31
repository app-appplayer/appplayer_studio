import 'dart:async';
import 'dart:convert';

import 'package:appplayer_studio/src/base/install/gateway_node/gateway_node.dart';
import 'package:mcp_gateway/mcp_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/market_tokens.dart';

/// Drives [HubRelayNodeServer] with the relay's node-socket envelope
/// (`{type, sessionId, frame}`) against a REAL runtime + exposed provider —
/// proves the expose direction demuxes sessions, serves tools/list + tools/call,
/// routes events per session, and tracks open/close (the multiplexed node the
/// relay fans consumer sessions into).
void main() {
  test('demux: sessions serve tools + events over the node envelope', () async {
    final runtime = GatewayRuntime(GatewayConfig());
    await runtime.start();
    addTearDown(runtime.dispose);

    final provider = await exposeThroughGateway(
      runtime: runtime,
      registration: ProviderRegistration(
        providerId: 'svc',
        schemaVersion: 1,
        schema: ProviderSchemaBody(tools: const [ToolDefinition(name: 'echo')]),
        capabilities: const ProviderCapabilities(eventPush: true),
      ),
      onToolCall: (d) async => DispatchResult(content: [
        {'echoed': d.params['arguments']}
      ]),
    );
    unawaited(provider.startPollLoop());
    addTearDown(provider.unregister);

    final toNode = StreamController<Map<String, dynamic>>.broadcast();
    final fromNode = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(() async {
      await toNode.close();
      await fromNode.close();
    });

    final market = await TestMarket.create();
    final node = HubRelayNodeServer(
      runtime: runtime,
      incoming: toNode.stream,
      send: (env) async => fromNode.add(env),
      verifyCaller: market.verifier('node-1'),
    );
    await node.start();
    addTearDown(node.stop);

    Future<Map<String, dynamic>> next() =>
        fromNode.stream.first.timeout(const Duration(seconds: 2));
    void deliver(String sid, Map<String, dynamic> req) =>
        toNode.add({'type': 'frame', 'sessionId': sid, 'frame': jsonEncode(req)});
    Map<String, dynamic> inner(Map<String, dynamic> env) =>
        (jsonDecode(env['frame'] as String) as Map).cast<String, dynamic>();

    // s1 opens.
    toNode.add({
      'type': 'open',
      'sessionId': 's1',
      'caller': await market.token(nodeId: 'node-1'),
    });
    await until(() => node.sessions.contains('s1'));

    // tools/list
    var f = next();
    deliver('s1', {'k': 'req', 'id': 0, 'method': 'tools/list', 'params': const {}});
    var env = await f;
    expect(env['sessionId'], 's1');
    expect((inner(env)['result']['tools'] as List).first['name'], 'svc.echo');

    // tools/call
    f = next();
    deliver('s1', {
      'k': 'req',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': 'svc.echo', 'arguments': {'x': 1}}
    });
    env = await f;
    expect(inner(env)['result']['content'].first['echoed'], {'x': 1});

    // subscribe, then a provider event routes back to s1.
    f = next();
    deliver('s1', {
      'k': 'req',
      'id': 2,
      'method': 'subscribe',
      'params': {'providerId': 'svc', 'eventTypes': ['ping']}
    });
    await f; // subscribe ack

    f = next();
    await provider.pushEvent(GatewayEvent(
        providerId: 'svc', eventType: 'ping', payload: const {'v': 1}));
    env = await f;
    expect(env['sessionId'], 's1');
    expect(inner(env)['k'], 'event');
    expect(inner(env)['eventType'], 'ping');

    // A second session is tracked independently; close drops only s1.
    toNode.add({
      'type': 'open',
      'sessionId': 's2',
      'caller': await market.token(nodeId: 'node-1', sub: 'bob'),
    });
    await until(() => node.sessions.contains('s2'));
    expect(node.sessions, containsAll(<String>['s1', 's2']));

    toNode.add({'type': 'close', 'sessionId': 's1'});
    await Future<void>.delayed(Duration.zero);
    expect(node.sessions.contains('s1'), isFalse);
    expect(node.sessions.contains('s2'), isTrue);
  });
}
