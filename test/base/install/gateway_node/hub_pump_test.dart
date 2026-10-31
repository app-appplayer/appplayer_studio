import 'dart:async';

import 'package:appplayer_studio/src/base/install/gateway_node/gateway_node.dart';
import 'package:mcp_gateway/mcp_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

/// End-to-end round-trip through a REAL [GatewayRuntime]: a provider node
/// exposes a tool + pushes events, a remote [HubGatewayConsumer] lists/calls it
/// and receives events — all across an in-memory relay, proving the pump rides
/// only `mcp_gateway`'s public surface (no core change).
void main() {
  late GatewayRuntime runtime;
  late GatewayClientAdapter provider;
  late HubMemoryTransport wire;
  late HubGatewayProvider bridge;
  late HubGatewayConsumer consumer;

  Future<void> setUpNode({
    Future<DispatchResult> Function(DispatchPayload)? onToolCall,
    List<ResourceDefinition> resources = const [],
    ProviderCapabilities capabilities =
        const ProviderCapabilities(eventPush: true),
  }) async {
    runtime = GatewayRuntime(GatewayConfig());
    await runtime.start();

    provider = await exposeThroughGateway(
      runtime: runtime,
      registration: ProviderRegistration(
        providerId: 'node1',
        schemaVersion: 1,
        schema: ProviderSchemaBody(
          tools: const [
            ToolDefinition(name: 'echo', description: 'echoes its args'),
          ],
          resources: resources,
        ),
        capabilities: capabilities,
      ),
      onToolCall: onToolCall ??
          (dispatch) async => DispatchResult(content: [
                {'type': 'text', 'echo': dispatch.params['arguments']}
              ]),
    );
    unawaited(provider.startPollLoop());

    wire = HubMemoryTransport();
    // Provider side = endpoint A; consumer side = endpoint B.
    bridge = HubGatewayProvider(
      runtime: runtime,
      consumerId: 'consumer-1',
      incoming: wire.incomingA,
      send: wire.sendA,
    );
    await bridge.start();
    consumer = HubGatewayConsumer(incoming: wire.incomingB, send: wire.sendB)
      ..start();
  }

  Future<void> tearDownNode() async {
    await consumer.close();
    await bridge.stop();
    await provider.unregister();
    await wire.close();
    await runtime.dispose();
  }

  test('listTools surfaces the remote node\'s namespaced tools', () async {
    await setUpNode();
    addTearDown(tearDownNode);

    final tools = await consumer.listTools();
    expect(tools, hasLength(1));
    expect(tools.single['name'], 'node1.echo');
  });

  test('callTool round-trips through the real runtime to the provider tool',
      () async {
    await setUpNode();
    addTearDown(tearDownNode);

    final r = await consumer.callTool('node1.echo', {'x': 42});
    expect(r.isError, isFalse);
    expect(r.content.single['echo'], {'x': 42});
  });

  test('provider error propagates as isError', () async {
    await setUpNode(
      onToolCall: (_) async => const DispatchResult(
        content: [
          {'type': 'text', 'text': 'boom'}
        ],
        isError: true,
      ),
    );
    addTearDown(tearDownNode);

    final r = await consumer.callTool('node1.echo', const {});
    expect(r.isError, isTrue);
  });

  test('unknown tool routes to no provider and returns an error result',
      () async {
    await setUpNode();
    addTearDown(tearDownNode);

    final r = await consumer.callTool('nope.missing', const {});
    expect(r.isError, isTrue);
  });

  test('events flow from provider pushEvent to a subscribed consumer',
      () async {
    await setUpNode();
    addTearDown(tearDownNode);

    await consumer.subscribe('node1', eventTypes: const ['ping']);
    final received = consumer.events.first;

    await provider.pushEvent(GatewayEvent(
      providerId: 'node1',
      eventType: 'ping',
      payload: const {'v': 1},
    ));

    final ev = await received.timeout(const Duration(seconds: 2));
    expect(ev['eventType'], 'ping');
    expect(ev['payload'], {'v': 1});
  });

  test('concurrent calls correlate to their own results', () async {
    await setUpNode(
      onToolCall: (dispatch) async {
        final n = dispatch.params['arguments']['n'] as int;
        // Reverse the completion order to prove id-correlation, not ordering.
        await Future<void>.delayed(Duration(milliseconds: 20 - n * 10));
        return DispatchResult(content: [
          {'n': n}
        ]);
      },
    );
    addTearDown(tearDownNode);

    final results = await Future.wait([
      consumer.callTool('node1.echo', {'n': 0}),
      consumer.callTool('node1.echo', {'n': 1}),
    ]);
    expect(results[0].content.single['n'], 0);
    expect(results[1].content.single['n'], 1);
  });
  // ── full-MCP wire (0.1.1 확장): resources over the hub ────────────────────

  test('resources: list keeps ORIGINAL uris; read routes to the owning provider',
      () async {
    await setUpNode(
      resources: const [
        ResourceDefinition(
            uri: 'ui://app', name: 'UI application', mimeType: 'application/json'),
        ResourceDefinition(
            uri: 'ui://pages/main', name: 'UI page main', mimeType: 'application/json'),
      ],
      onToolCall: (dispatch) async {
        if (dispatch.method == 'resources/read') {
          return DispatchResult(content: [
            {
              'uri': dispatch.params['uri'],
              'mimeType': 'application/json',
              'text': '{"type":"page","from":"node"}',
            }
          ]);
        }
        return DispatchResult(content: [
          {'type': 'text', 'echo': dispatch.params['arguments']}
        ]);
      },
    );
    addTearDown(tearDownNode);

    final resources = await consumer.listResources();
    expect(resources.map((r) => r['uri']),
        containsAll(['ui://app', 'ui://pages/main'])); // 원 URI 무변형

    final r = await consumer.readResource('ui://pages/main');
    expect(r.isError, isFalse);
    expect(r.content.single['uri'], 'ui://pages/main');
    expect(r.content.single['text'], contains('"from":"node"'));
  });

  test('resources: unknown uri → error result (no provider owns it)', () async {
    await setUpNode(resources: const [
      ResourceDefinition(uri: 'ui://app', name: 'app'),
    ]);
    addTearDown(tearDownNode);

    final r = await consumer.readResource('ui://nope');
    expect(r.isError, isTrue);
  });

  test('resources: subscribe rides the wire and acks', () async {
    await setUpNode(
      resources: const [ResourceDefinition(uri: 'ui://app', name: 'app')],
      // resources/subscribe 는 provider capability(resourceSubscription) 게이트 —
      // capability 선언 + provider ack(빈 결과)로 성립.
      capabilities: const ProviderCapabilities(
          eventPush: true, resources: true, resourceSubscription: true),
      onToolCall: (dispatch) async => const DispatchResult(content: []),
    );
    addTearDown(tearDownNode);

    final r = await consumer.subscribeResource('ui://app');
    expect(r.isError, isFalse);
  });

}
