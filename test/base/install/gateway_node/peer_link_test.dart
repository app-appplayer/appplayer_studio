import 'dart:async';
import 'dart:convert';

import 'package:appplayer_studio/src/base/install/gateway_node/gateway_node.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:mcp_gateway/mcp_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/market_tokens.dart';

/// Account peer link (platform spec 22): a session opened over the relay keeps
/// working while its frames move to a direct pipe and back. The node is a REAL
/// gateway runtime behind [PeerNodeLink]; the far side is a REAL `mcp_client`
/// Client over [HubConsumerTransport]. The "relay" is the relay's own wire —
/// node envelopes one way, raw frames the other — so what is proven is the
/// path switching, not a stand-in for it.
class _Rig {
  _Rig._(this.runtime, this.node, this.link, this.client);

  final GatewayRuntime runtime;
  final PeerNodeLink node;
  final PeerSessionLink link;
  final Client client;

  /// Frames that crossed the relay in either direction, link frames included.
  int relayFrames = 0;

  static Future<_Rig> open({
    required String target,
    List<String> providers = const ['lamp'],
  }) async {
    final runtime = GatewayRuntime(GatewayConfig());
    await runtime.start();
    for (final id in providers) {
      final adapter = await exposeThroughGateway(
        runtime: runtime,
        registration: ProviderRegistration(
          providerId: id,
          schemaVersion: 1,
          schema: ProviderSchemaBody(tools: [ToolDefinition(name: '$id-tool')]),
        ),
        onToolCall: (d) async => DispatchResult(content: [
          {'type': 'text', 'text': '$id:${d.params['name']}'},
        ]),
      );
      unawaited(adapter.startPollLoop());
    }

    final market = await TestMarket.create();
    final node =
        PeerNodeLink(runtime: runtime, verifyCaller: market.verifier('peer-node'));
    await node.start();

    final toNode = StreamController<Map<String, dynamic>>.broadcast();
    final toClient = StreamController<String>.broadcast();
    late final _Rig rig;
    node.attachRelay(toNode.stream, (env) async {
      rig.relayFrames++;
      toClient.add(env['frame'] as String);
    });
    toNode.add({
      'type': 'open',
      'sessionId': 's1',
      'caller': await market.token(nodeId: 'peer-node'),
    });

    final link = PeerSessionLink(
      relayIncoming: toClient.stream,
      relaySend: (text) {
        rig.relayFrames++;
        toNode.add({'type': 'frame', 'sessionId': 's1', 'frame': text});
      },
    );
    final consumer = HubGatewayConsumer(
      incoming: link.incoming,
      send: link.send,
      target: target,
    )..start();
    final client = Client(name: 'b', version: '1.0.0');
    await client.connect(HubConsumerTransport(consumer));
    rig = _Rig._(runtime, node, link, client);
    return rig;
  }

  Future<String> call(String tool) async {
    final r = await client.callTool(tool, const {});
    return (r.content.first as TextContent).text;
  }

  Future<void> dispose() async {
    client.disconnect();
    await link.close();
    await node.stop();
    await runtime.dispose();
  }
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 20));

/// A pipe that declines a frame — what a real one does when the body is over
/// the platform's message ceiling or the send buffer is filling.
class _RefusingPipe implements PeerPipe {
  _RefusingPipe(this._inner);
  final PeerPipe _inner;
  bool refuse = false;

  @override
  Stream<String> get incoming => _inner.incoming;

  @override
  void send(String text) {
    if (refuse) throw StateError('direct path declined this frame');
    _inner.send(text);
  }

  @override
  Future<void> get done => _inner.done;

  @override
  void close() => _inner.close();
}

void main() {
  test('over the relay, a targeted session sees one app under its own names',
      () async {
    final rig = await _Rig.open(target: 'lamp', providers: ['lamp', 'fan']);
    addTearDown(rig.dispose);

    final tools = await rig.client.listTools();
    expect(tools.map((t) => t.name), ['lamp-tool'],
        reason: 'the other provider on the node is not this app');
    expect(await rig.call('lamp-tool'), 'lamp:lamp-tool');
    expect(rig.relayFrames, greaterThan(0));
    expect(rig.node.isDirect('s1'), isFalse);
  });

  test('switching to a direct pipe moves the frames and keeps the session',
      () async {
    final rig = await _Rig.open(target: 'lamp');
    addTearDown(rig.dispose);
    expect(await rig.call('lamp-tool'), 'lamp:lamp-tool');

    final (aEnd, bEnd) = PeerMemoryPipe.pair();
    rig.node.attachDirect('s1', aEnd);
    rig.link.useDirect(bEnd);
    await _settle();
    expect(rig.node.isDirect('s1'), isTrue);

    final before = rig.relayFrames;
    expect(await rig.call('lamp-tool'), 'lamp:lamp-tool');
    expect(await rig.call('lamp-tool'), 'lamp:lamp-tool');
    expect(rig.relayFrames, before, reason: 'nothing crossed the relay');
  });

  test('when the direct pipe dies the same session answers over the relay',
      () async {
    final rig = await _Rig.open(target: 'lamp');
    addTearDown(rig.dispose);

    final (aEnd, bEnd) = PeerMemoryPipe.pair();
    rig.node.attachDirect('s1', aEnd);
    var lost = false;
    rig.link.onDirectLost = () => lost = true;
    rig.link.useDirect(bEnd);
    await _settle();
    expect(await rig.call('lamp-tool'), 'lamp:lamp-tool');

    bEnd.close();
    await _settle();
    expect(lost, isTrue);
    expect(rig.link.isDirect, isFalse);
    expect(rig.node.isDirect('s1'), isFalse);

    final before = rig.relayFrames;
    expect(await rig.call('lamp-tool'), 'lamp:lamp-tool');
    expect(rig.relayFrames, greaterThan(before));
  });

  test('a frame the direct pipe refuses goes over the relay, session intact',
      () async {
    final rig = await _Rig.open(target: 'lamp');
    addTearDown(rig.dispose);

    final (aEnd, bEnd) = PeerMemoryPipe.pair();
    final refusing = _RefusingPipe(bEnd);
    rig.node.attachDirect('s1', aEnd);
    rig.link.useDirect(refusing);
    await _settle();
    expect(await rig.call('lamp-tool'), 'lamp:lamp-tool');

    // What a full send buffer or an oversize body looks like at this seam.
    refusing.refuse = true;
    final before = rig.relayFrames;
    expect(await rig.call('lamp-tool'), 'lamp:lamp-tool',
        reason: 'the relay carried it');
    expect(rig.relayFrames, greaterThan(before));
    expect(rig.link.isDirect, isFalse);
  });

  test('link frames reach the other end and never the gateway', () async {
    final rig = await _Rig.open(target: 'lamp');
    addTearDown(rig.dispose);

    final atNode = <(String, Map<String, dynamic>)>[];
    rig.node.onLink = (sid, f) => atNode.add((sid, f));
    final atClient = <Map<String, dynamic>>[];
    rig.link.onLink = atClient.add;

    rig.link.sendLink(LinkWire.frame(LinkWire.offer, {LinkWire.sdp: 'v=0'}));
    await rig.node.sendLink(
        's1', LinkWire.frame(LinkWire.answer, {LinkWire.sdp: 'v=1'}));
    await _settle();

    expect(atNode.single.$1, 's1');
    expect(atNode.single.$2[LinkWire.sdp], 'v=0');
    expect(atClient.single[LinkWire.op], LinkWire.answer);
    // The session still serves normally — no stray reply to the link frames.
    expect(await rig.call('lamp-tool'), 'lamp:lamp-tool');
  });

  test('a switch that arrives before the node attaches its pipe is kept',
      () async {
    final rig = await _Rig.open(target: 'lamp');
    addTearDown(rig.dispose);

    final (aEnd, bEnd) = PeerMemoryPipe.pair();
    rig.link.useDirect(bEnd); // switch goes out first
    await _settle();
    rig.node.attachDirect('s1', aEnd);
    await _settle();
    expect(rig.node.isDirect('s1'), isTrue);

    final before = rig.relayFrames;
    expect(await rig.call('lamp-tool'), 'lamp:lamp-tool');
    expect(rig.relayFrames, before);
  });

  test('a malformed frame on either path is ignored', () async {
    final rig = await _Rig.open(target: 'lamp');
    addTearDown(rig.dispose);
    final (aEnd, bEnd) = PeerMemoryPipe.pair();
    rig.node.attachDirect('s1', aEnd);
    rig.link.useDirect(bEnd);
    await _settle();

    bEnd.send('not json');
    aEnd.send(jsonEncode([1, 2]));
    await _settle();
    expect(await rig.call('lamp-tool'), 'lamp:lamp-tool');
  });
}
