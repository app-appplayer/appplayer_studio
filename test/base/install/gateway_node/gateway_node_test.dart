import 'package:appplayer_studio/src/base/install/gateway_node/gateway_node.dart';
import 'package:mcp_gateway/mcp_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exposeThroughGateway registers a provider and wires local dispatch',
      () async {
    final runtime = GatewayRuntime(GatewayConfig());
    await runtime.start();
    addTearDown(runtime.dispose);
    var dispatched = false;
    final adapter = await exposeThroughGateway(
      runtime: runtime,
      registration: ProviderRegistration(
        providerId: 'studio-node',
        schemaVersion: 1,
        schema: ProviderSchemaBody(),
      ),
      onToolCall: (dispatch) async {
        dispatched = true;
        return DispatchResult(content: const []);
      },
    );

    // Local dispatch is wired, and the provider registered (poll would throw
    // "Not registered" otherwise).
    expect(adapter.onDispatch, isNotNull);
    await expectLater(
      adapter.poll(timeout: Duration.zero),
      completes,
    );
    expect(dispatched, isFalse); // no dispatch delivered in this unit
    await adapter.unregister();
  });

  test('connectThroughGateway starts a consumer adapter', () async {
    final runtime = GatewayRuntime(GatewayConfig());
    await runtime.start();
    addTearDown(runtime.dispose);
    final adapter =
        await connectThroughGateway(runtime: runtime, consumerId: 'c1');
    expect(adapter.isStarted, isTrue);
    await adapter.stop();
  });
}
