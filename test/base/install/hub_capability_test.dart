/// `hub.*` host tools: driven by tool name with JSON arguments, the way the
/// workbench LLM, an external Claude or the settings screen would. Remote hub
/// tools must show up next to local ones and vanish on disconnect; the host's
/// own surface served to remote callers must keep internal tools home.
library;

import 'dart:async';
import 'dart:convert';

import 'package:appplayer_studio/src/base/install/gateway_node/gateway_node.dart';
import 'package:appplayer_studio/src/base/install/hub_capability.dart';
import 'package:appplayer_studio/src/base/install/hub_connections.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_gateway/mcp_gateway.dart';

class _Market implements HubMarketPort {
  @override
  Future<List<HubChoice>> hubs({String? publisher}) async => const [
        HubChoice(listingId: 'A', title: 'Arche Mine', via: 'owner', mine: true),
      ];
  @override
  Future<List<HubConnectOutcome>> connect(
          {List<String>? listingIds, bool all = false, String? publisher}) async =>
      [
        for (final id in all ? ['A'] : listingIds!)
          HubConnectOutcome(
            listingId: id,
            grant: HubGrant(
                sessionId: '$id#1', relayUrl: 'wss://r', relayToken: 't'),
          ),
      ];
}

class _Counting extends HubConnections {
  _Counting() : super(market: _Market());
  int calls = 0;
  @override
  Future<List<HubToolRef>> tools() async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    return const <HubToolRef>[];
  }
}

Map<String, dynamic> _json(mk.KernelToolResult r) =>
    jsonDecode(r.content.whereType<mk.KernelTextContent>().first.text)
        as Map<String, dynamic>;

void main() {
  late mk.InProcessKernelServerHost boot;
  late HubConnections connections;
  late HubCapability cap;
  late GatewayRuntime nodeRuntime;
  late GatewayClientAdapter provider;
  late HubGatewayProvider bridge;
  late HubMemoryTransport wire;

  setUp(() async {
    nodeRuntime = GatewayRuntime(GatewayConfig());
    await nodeRuntime.start();
    provider = await exposeThroughGateway(
      runtime: nodeRuntime,
      registration: ProviderRegistration(
        providerId: 'svc',
        schemaVersion: 1,
        schema: ProviderSchemaBody(
            tools: const [ToolDefinition(name: 'echo', description: 'echoes')]),
      ),
      onToolCall: (d) async => DispatchResult(content: [
        {'type': 'text', 'text': 'remote:${jsonEncode(d.params['arguments'])}'}
      ]),
    );
    unawaited(provider.startPollLoop());
    wire = HubMemoryTransport();
    bridge = HubGatewayProvider(
        runtime: nodeRuntime,
        consumerId: 'c',
        incoming: wire.incomingA,
        send: wire.sendA);
    await bridge.start();

    boot = mk.InProcessKernelServerHost();
    final registry = mk.HostToolRegistry(
      endpoint: boot,
      attachToDispatcher: (_, _) {},
      detachFromDispatcher: (_) {},
    );
    connections = HubConnections(
      market: _Market(),
      open: (grant) async => HubChannel(
        incoming: wire.incomingB,
        send: wire.sendB,
        close: () async {},
        done: Completer<void>().future,
      ),
    );
    cap = HubCapability(registry: registry, connections: connections);
  });

  tearDown(() async {
    await cap.dispose();
    await connections.dispose();
    await bridge.stop();
    await wire.close();
    await provider.unregister();
    await nodeRuntime.dispose();
  });

  Future<Map<String, dynamic>> run(String tool, [Map<String, dynamic>? a]) async =>
      _json(await boot.callTool(tool, a ?? {}));

  test('surface: every hub verb is a tool', () {
    expect(
      boot.toolDefinitions.map((t) => t.name),
      containsAll(<String>[
        'hub.select', 'hub.disconnect',
        'hub.status', 'hub.node_start', 'hub.node_stop', 'hub.node_remove',
      ]),
    );
  });

  test('connect publishes the remote tool beside the local ones; disconnect '
      'takes it away', () async {
    final conn = await connections.connect(all: true);
    expect(conn.single.state, HubLinkState.connected);

    await until(() => boot.toolDefinitions.any((t) => t.name == 'arche_mine.svc.echo'));
    final called = await boot.callTool('arche_mine.svc.echo', {'n': 7});
    expect(called.content.whereType<mk.KernelTextContent>().single.text,
        'remote:{"n":7}');

    final status = await run('hub.status');
    expect((status['connections'] as List).single['namespace'], 'arche_mine');
    expect(status['node'], isNull);

    await run('hub.disconnect', {'listingId': 'A'});
    await until(() => !boot.toolDefinitions.any((t) => t.name == 'arche_mine.svc.echo'));
  });

  test('select hides a connected hub from the model', () async {
    await connections.connect(all: true);
    await until(() => boot.toolDefinitions.any((t) => t.name == 'arche_mine.svc.echo'));
    await run('hub.select', {'listingIds': ['none']});
    await until(() => !boot.toolDefinitions.any((t) => t.name == 'arche_mine.svc.echo'));
  });

  test('bad input and a host without a node answer with codes, not crashes',
      () async {
    final bad = _json(await boot.callTool('hub.select', {}));
    expect(bad['code'], 'hub.bad_input');
    final noNode = _json(await boot.callTool('hub.node_start', {}));
    expect(noNode['code'], 'hub.node_unavailable');
  });

  test('the served surface keeps internal tools home and relays results',
      () async {
    final host = mk.InProcessKernelServerHost();
    host.addTool(
      name: 'studio.public',
      description: 'ok',
      inputSchema: const {'type': 'object'},
      handler: (a) async => mk.KernelToolResult(
          content: [mk.KernelTextContent(text: 'public:${a['x']}')]),
    );
    host.addTool(
      name: 'studio.private',
      description: 'secret',
      inputSchema: const {'type': 'object'},
      scope: mk.ToolScope.internal,
      handler: (a) async =>
          mk.KernelToolResult(content: [mk.KernelTextContent(text: 'no')]),
    );
    final surface =
        KernelHostToolSurface(host, exclude: const {'hub.node_remove'});
    final names = (await surface.list()).map((d) => d.name);
    expect(names, contains('studio.public'));
    expect(names, isNot(contains('studio.private')));
    final ok = await surface.call('studio.public', {'x': 3});
    expect(ok.content!.single['text'], 'public:3');
    final denied = await surface.call('studio.private', {});
    expect(denied.isError, isTrue);
  });

  test('a burst of change events runs two passes at most, not one per event',
      () async {
    final counting = _Counting();
    final registry = mk.HostToolRegistry(
      endpoint: mk.InProcessKernelServerHost(),
      attachToDispatcher: (_, _) {},
      detachFromDispatcher: (_) {},
    );
    final burst = HubCapability(registry: registry, connections: counting);
    for (var i = 0; i < 40; i++) {
      counting.select(['A']);
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(counting.calls, lessThanOrEqualTo(2));
    expect(counting.calls, greaterThanOrEqualTo(1));
    await burst.dispose();
    await counting.dispose();
  });
}

Future<void> until(bool Function() done,
    {Duration timeout = const Duration(seconds: 3)}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('condition not met in $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
