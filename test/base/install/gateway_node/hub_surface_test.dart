import 'dart:async';
import 'dart:convert';

import 'package:appplayer_studio/src/base/install/gateway_node/gateway_node.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:mcp_gateway/mcp_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

/// Full surfacing chain: a REAL gateway node → HubGatewayConsumer →
/// [HubConsumerTransport] → a REAL `mcp_client` Client. Proves a host can open a
/// hub node through its ordinary MCP server-open path (connect + listTools +
/// callTool) with no host glue and no core change.
void main() {
  test('mcp_client opens a hub node via HubConsumerTransport and calls a tool',
      () async {
    final runtime = GatewayRuntime(GatewayConfig());
    await runtime.start();
    addTearDown(runtime.dispose);

    final provider = await exposeThroughGateway(
      runtime: runtime,
      registration: ProviderRegistration(
        providerId: 'svc',
        schemaVersion: 1,
        schema: ProviderSchemaBody(tools: const [
          ToolDefinition(name: 'echo', description: 'echoes its args'),
        ]),
      ),
      onToolCall: (d) async => DispatchResult(content: [
        {'type': 'text', 'text': jsonEncode(d.params['arguments'])}
      ]),
    );
    unawaited(provider.startPollLoop());
    addTearDown(provider.unregister);

    final wire = HubMemoryTransport();
    addTearDown(wire.close);
    final bridge = HubGatewayProvider(
      runtime: runtime,
      consumerId: 'pro',
      incoming: wire.incomingA,
      send: wire.sendA,
    );
    await bridge.start();
    addTearDown(bridge.stop);

    final consumer =
        HubGatewayConsumer(incoming: wire.incomingB, send: wire.sendB)..start();
    addTearDown(consumer.close);

    // The host side: open the hub node as an ordinary MCP server.
    final client = Client(name: 'studio', version: '1.0.0');
    final transport = HubConsumerTransport(consumer);
    await client.connect(transport);

    final tools = await client.listTools();
    expect(tools.map((t) => t.name), contains('svc.echo'));

    final result = await client.callTool('svc.echo', {'hello': 'hub'});
    expect(result.isError ?? false, isFalse);
    final text = (result.content.first as TextContent).text;
    expect(jsonDecode(text), {'hello': 'hub'});

    client.disconnect();
  });

  test(
      'mcp_client reads a hub-served resource with its ORIGINAL uri (ui:// intact)',
      () async {
    final runtime = GatewayRuntime(GatewayConfig());
    await runtime.start();
    addTearDown(runtime.dispose);

    // Provider that serves a ui:// resource; resources/read is routed here as a
    // dispatch (onToolCall == onDispatch) exactly like the real serving runtime.
    final provider = await exposeThroughGateway(
      runtime: runtime,
      registration: ProviderRegistration(
        providerId: 'svc',
        schemaVersion: 1,
        schema: ProviderSchemaBody(
          tools: const [ToolDefinition(name: 'noop', description: 'noop')],
          resources: const [
            ResourceDefinition(
                uri: 'ui://pages/main',
                name: 'main page',
                mimeType: 'application/json'),
          ],
        ),
      ),
      onToolCall: (d) async {
        if (d.method == 'resources/read') {
          return DispatchResult(content: [
            {
              'uri': d.params['uri'],
              'mimeType': 'application/json',
              'text': '{"type":"page","from":"hub"}',
            }
          ]);
        }
        return const DispatchResult(content: []);
      },
    );
    unawaited(provider.startPollLoop());
    addTearDown(provider.unregister);

    final wire = HubMemoryTransport();
    addTearDown(wire.close);
    final bridge = HubGatewayProvider(
      runtime: runtime,
      consumerId: 'pro',
      incoming: wire.incomingA,
      send: wire.sendA,
    );
    await bridge.start();
    addTearDown(bridge.stop);

    final consumer =
        HubGatewayConsumer(incoming: wire.incomingB, send: wire.sendB)..start();
    addTearDown(consumer.close);

    final client = Client(name: 'studio', version: '1.0.0');
    final transport = HubConsumerTransport(consumer);
    await client.connect(transport);

    // initialize advertised resources → the Client permits resource verbs.
    expect(client.serverCapabilities?.resources, isTrue);

    final resources = await client.listResources();
    expect(resources.map((r) => r.uri), contains('ui://pages/main'));

    // The renderer's contract: read the ui:// URI as-authored, unrewritten.
    final read = await client.readResource('ui://pages/main');
    final content = read.contents.first;
    expect(content.uri, 'ui://pages/main');
    expect(content.text, contains('"from":"hub"'));

    client.disconnect();
  });

  test('forwardEvents surfaces node notifications as JSON-RPC notifications',
      () async {
    // Transport-level: a node event carrying a standard MCP notification name is
    // re-emitted verbatim on the transport's message stream so a host's
    // notification handlers fire (e.g. resources/updated → re-read). A plain
    // event (non-notification name) must NOT be forwarded.
    final incoming = StreamController<Map<String, dynamic>>.broadcast();
    final consumer = HubGatewayConsumer(
      incoming: incoming.stream,
      send: (_) async {},
    )..start();
    addTearDown(consumer.close);

    final transport = HubConsumerTransport(consumer)..forwardEvents();
    addTearDown(transport.close);

    final seen = transport.onMessage.firstWhere(
        (m) => (m as Map)['method'] == 'notifications/resources/updated');

    incoming.add({
      HubWire.kind: HubWire.event,
      HubWire.eventType: 'ping',
      HubWire.payload: const {'ignored': true},
    });
    incoming.add({
      HubWire.kind: HubWire.event,
      HubWire.eventType: 'notifications/resources/updated',
      HubWire.payload: const {'uri': 'ui://pages/main'},
    });

    final msg = await seen.timeout(const Duration(seconds: 2));
    expect((msg as Map)['jsonrpc'], '2.0');
    expect(msg['params'], {'uri': 'ui://pages/main'});
    expect(msg.containsKey('id'), isFalse); // notification: no id
  });
}
