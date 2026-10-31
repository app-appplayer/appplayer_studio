/// Hub connections (consumer side of the market hub): several hubs at once,
/// per-hub tool namespaces, "only these" selection, partial failure, and
/// reconnection when a session lapses — driven over a REAL gateway node and a
/// REAL mcp_client, with the market's two doors faked.
library;

import 'dart:async';
import 'dart:convert';

import 'package:appplayer_studio/src/base/install/gateway_node/gateway_node.dart';
import 'package:appplayer_studio/src/base/install/hub_connections.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:mcp_gateway/mcp_gateway.dart';

/// A hub node serving one tool `echo` that answers with [tag].
class _Node {
  _Node(this.tag);
  final String tag;
  Duration delay = Duration.zero;
  late final GatewayRuntime runtime;
  late final GatewayClientAdapter provider;
  final List<HubMemoryTransport> wires = [];
  final List<HubGatewayProvider> bridges = [];

  Future<void> start() async {
    runtime = GatewayRuntime(GatewayConfig());
    await runtime.start();
    provider = await exposeThroughGateway(
      runtime: runtime,
      registration: ProviderRegistration(
        providerId: 'svc',
        schemaVersion: 1,
        schema: ProviderSchemaBody(
          tools: const [ToolDefinition(name: 'echo', description: 'echoes')],
        ),
      ),
      onToolCall: (d) async {
        await Future<void>.delayed(delay);
        return DispatchResult(
          content: [
            {
              'type': 'text',
              'text': '$tag:${jsonEncode(d.params['arguments'])}',
            },
          ],
        );
      },
    );
    unawaited(provider.startPollLoop());
  }

  /// A fresh relay session onto this node; [drop] ends it like a lapse.
  Future<(HubChannel, Completer<void>)> session() async {
    final wire = HubMemoryTransport();
    wires.add(wire);
    final bridge = HubGatewayProvider(
      runtime: runtime,
      consumerId: 'c${bridges.length}',
      incoming: wire.incomingA,
      send: wire.sendA,
    );
    await bridge.start();
    bridges.add(bridge);
    final done = Completer<void>();
    return (
      HubChannel(
        incoming: wire.incomingB,
        send: wire.sendB,
        close: () async {},
        done: done.future,
      ),
      done,
    );
  }

  Future<void> stop() async {
    for (final b in bridges) {
      await b.stop();
    }
    for (final w in wires) {
      await w.close();
    }
    await provider.unregister();
    await runtime.dispose();
  }
}

class _FakeMarket implements HubMarketPort {
  _FakeMarket(this.choices);
  final List<HubChoice> choices;
  final Set<String> refuse = {};
  final List<List<String>> connectCalls = [];
  final Map<String, int> grantSeq = {};

  @override
  Future<List<HubChoice>> hubs({String? publisher}) async => choices;

  @override
  Future<List<HubConnectOutcome>> connect({
    List<String>? listingIds,
    bool all = false,
    String? publisher,
  }) async {
    final ids = all ? [for (final c in choices) c.listingId] : listingIds!;
    connectCalls.add(ids);
    return [
      for (final id in ids)
        if (refuse.contains(id))
          HubConnectOutcome(
            listingId: id,
            errorCode: 'access_denied',
            errorMessage: 'no',
          )
        else
          HubConnectOutcome(
            listingId: id,
            grant: HubGrant(
              sessionId:
                  '$id#${grantSeq.update(id, (n) => n + 1, ifAbsent: () => 1)}',
              relayUrl: 'wss://relay.test',
              relayToken: 't',
            ),
          ),
    ];
  }
}

HubChoice _choice(String id, String title, {bool mine = true}) =>
    HubChoice(listingId: id, title: title, via: 'owner', mine: mine);

void main() {
  late _Node nodeA;
  late _Node nodeB;
  late _FakeMarket market;
  final dropA = <Completer<void>>[];
  late HubConnections hubs;

  HubChannelOpener opener() => (grant) async {
    final node = grant.sessionId.startsWith('A') ? nodeA : nodeB;
    final (channel, done) = await node.session();
    if (node == nodeA) dropA.add(done);
    return channel;
  };

  setUp(() async {
    nodeA = _Node('A');
    nodeB = _Node('B');
    await nodeA.start();
    await nodeB.start();
    dropA.clear();
    market = _FakeMarket([
      _choice('A', 'Arche Mine'),
      _choice('B', 'Arche Team', mine: false),
    ]);
    hubs = HubConnections(
      market: market,
      open: opener(),
      renewAfter: const Duration(hours: 1),
      reconnectWait: const Duration(seconds: 3),
    );
  });

  tearDown(() async {
    await hubs.dispose();
    await nodeA.stop();
    await nodeB.stop();
  });

  Future<String> text(String tool, [Map<String, dynamic>? args]) async {
    final r = await hubs.call(tool, args ?? {'x': 1});
    return (r.content.first as TextContent).text;
  }

  test(
    'W1/W2/W4: two hubs at once; same tool name stays apart per hub',
    () async {
      final list = await hubs.available(publisher: 'arche');
      expect(list.map((c) => c.title), ['Arche Mine', 'Arche Team']);

      await hubs.connect(all: true, publisher: 'arche');
      final names = (await hubs.tools()).map((t) => t.name).toList()..sort();
      expect(names, ['arche_mine.svc.echo', 'arche_team.svc.echo']);
      expect(await text('arche_mine.svc.echo'), 'A:{"x":1}');
      expect(await text('arche_team.svc.echo'), 'B:{"x":1}');
    },
  );

  test('callTimeout bounds how long one call waits for its answer', () async {
    nodeA.delay = const Duration(milliseconds: 600);
    await hubs.dispose();
    hubs = HubConnections(
      market: market,
      open: opener(),
      callTimeout: const Duration(milliseconds: 150),
    );
    await hubs.connect(choices: [_choice('A', 'Arche Mine')]);
    await expectLater(
      hubs.call('arche_mine.svc.echo', {'x': 1}),
      throwsA(
        isA<HubConnectionError>().having(
          (e) => e.code,
          'code',
          'hub.call_failed',
        ),
      ),
    );

    await hubs.dispose();
    hubs = HubConnections(
      market: market,
      open: opener(),
      callTimeout: const Duration(seconds: 5),
    );
    await hubs.connect(choices: [_choice('A', 'Arche Mine')]);
    expect(
      await text('arche_mine.svc.echo'),
      'A:{"x":1}',
      reason: 'a longer allowance lets the slow answer through',
    );
  });

  test(
    'a server that stops answering opens a new session; a healthy one is left alone',
    () async {
      await hubs.dispose();
      var silent = false;
      hubs = HubConnections(
        market: market,
        open: opener(),
        keepAlive: const Duration(milliseconds: 60),
        pinger: (client) async {
          if (silent) throw StateError('no answer');
        },
      );
      await hubs.connect(choices: [_choice('A', 'Arche Mine')]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(market.grantSeq['A'], 1, reason: 'answering pings change nothing');

      silent = true;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      silent = false;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        market.grantSeq['A'],
        greaterThan(1),
        reason: 'two silent rounds open a fresh session',
      );
      expect(
        await text('arche_mine.svc.echo'),
        'A:{"x":1}',
        reason: 'and the new session works',
      );
    },
  );

  test(
    'a server that sends nothing for the silence limit gets a new session; without the limit it is left alone',
    () async {
      Future<int> seqAfter(Duration? silence) async {
        await hubs.dispose();
        market = _FakeMarket([_choice('A', 'Arche Mine')]);
        hubs = HubConnections(
          market: market,
          open: opener(),
          clientSetup: HubClientSetup(
            capabilities: const ClientCapabilities(),
            configure: (_) {},
            serverSilence: silence,
          ),
        );
        await hubs.connect(choices: [_choice('A', 'Arche Mine')]);
        await Future<void>.delayed(const Duration(milliseconds: 700));
        return market.grantSeq['A']!;
      }

      expect(await seqAfter(null), 1, reason: 'silence is not watched');
      expect(
        await seqAfter(const Duration(milliseconds: 200)),
        greaterThan(1),
        reason: 'a silent server is opened again',
      );
      expect(
        await text('arche_mine.svc.echo'),
        'A:{"x":1}',
        reason: 'and the new session works',
      );
    },
  );

  test('two hubs with the same title still get distinct namespaces', () async {
    market = _FakeMarket([_choice('A', 'Arche'), _choice('B', 'Arche')]);
    hubs = HubConnections(market: market, open: opener());
    await hubs.connect(all: true);
    final names = (await hubs.tools()).map((t) => t.name).toSet();
    expect(names, {'arche.svc.echo', 'arche_2.svc.echo'});
    expect(await text('arche.svc.echo'), 'A:{"x":1}');
    expect(await text('arche_2.svc.echo'), 'B:{"x":1}');
  });

  test(
    'client capabilities: none by default, the host\'s setup when given',
    () async {
      // Default: nothing is configured, nothing is declared.
      await hubs.connect(all: true);
      expect(
        hubs.links.every((l) => l.state == HubLinkState.connected),
        isTrue,
      );

      final seen = <ClientCapabilities>[];
      await hubs.dispose();
      hubs = HubConnections(
        market: market,
        open: opener(),
        clientSetup: HubClientSetup(
          capabilities: const ClientCapabilities(roots: true),
          configure: (client) => seen.add(client.capabilities),
        ),
      );
      await hubs.connect(all: true);
      expect(seen, hasLength(2), reason: 'one client per connection');
      expect(
        seen.every((c) => c.roots && !c.sampling && !c.elicitation),
        isTrue,
      );
      expect(
        await text('arche_mine.svc.echo'),
        'A:{"x":1}',
        reason: 'a configured client still serves tools',
      );
    },
  );

  test(
    'W3: only the selected hubs expose tools; a call to another is refused',
    () async {
      await hubs.connect(all: true);
      hubs.select(['B']);
      expect((await hubs.tools()).map((t) => t.name), ['arche_team.svc.echo']);
      await expectLater(
        hubs.call('arche_mine.svc.echo', {}),
        throwsA(
          isA<HubConnectionError>().having(
            (e) => e.code,
            'code',
            'hub.not_selected',
          ),
        ),
      );
    },
  );

  test('W5: a refused hub is reported and the rest still connect', () async {
    market.refuse.add('B');
    final links = await hubs.connect(all: true);
    final byId = {for (final l in links) l.listingId: l};
    expect(byId['A']!.state, HubLinkState.connected);
    expect(byId['B']!.state, HubLinkState.failed);
    expect(byId['B']!.error, contains('access_denied'));
    expect((await hubs.tools()).map((t) => t.name), ['arche_mine.svc.echo']);
  });

  test(
    'W6: a dropped session reconnects with a fresh grant; calls recover',
    () async {
      await hubs.connect(choices: [_choice('A', 'Arche Mine')]);
      expect(await text('arche_mine.svc.echo'), 'A:{"x":1}');

      dropA.first.complete(); // the relay lets go
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // The call made during the lapse waits for the new session, then works.
      expect(await text('arche_mine.svc.echo'), 'A:{"x":1}');
      expect(market.connectCalls.length, 2, reason: 'one re-grant, no storm');
      expect(hubs.links.single.state, HubLinkState.connected);
    },
  );

  test(
    'W6: a hub that cannot come back fails the call loudly, not silently',
    () async {
      await hubs.connect(choices: [_choice('A', 'Arche Mine')]);
      market.refuse.add('A');
      dropA.first.complete();
      await expectLater(
        Future<void>.delayed(
          const Duration(milliseconds: 100),
        ).then((_) => hubs.call('arche_mine.svc.echo', {})),
        throwsA(isA<HubConnectionError>()),
      );
      expect(hubs.links.single.state, HubLinkState.failed);
    },
  );

  test(
    'W6: a dropped hub that cannot be reopened is tried again until it comes back',
    () async {
      await hubs.dispose();
      market = _FakeMarket([_choice('A', 'Arche Mine')]);
      hubs = HubConnections(
        market: market,
        open: opener(),
        rejoinBackoff: (_) => const Duration(milliseconds: 40),
      );
      await hubs.connect(choices: [_choice('A', 'Arche Mine')]);
      market.refuse.add('A');
      dropA.first.complete();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(hubs.links.single.state, HubLinkState.failed);
      expect(
        market.connectCalls.length,
        greaterThan(2),
        reason: 'it keeps asking while it is down',
      );
      market.refuse.clear();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(hubs.links.single.state, HubLinkState.connected);
      expect(await text('arche_mine.svc.echo'), 'A:{"x":1}');
    },
  );

  test('the default retry wait stops growing at one minute', () {
    final wait = HubConnections(market: market).rejoinBackoff;
    expect([for (var i = 0; i < 7; i++) wait(i).inSeconds],
        [5, 15, 45, 60, 60, 60, 60]);
  });

  test('a hub that never opened is tried again until it opens', () async {
    await hubs.dispose();
    market = _FakeMarket([_choice('A', 'Arche Mine')])..refuse.add('A');
    hubs = HubConnections(
      market: market,
      open: opener(),
      rejoinBackoff: (_) => const Duration(milliseconds: 20),
    );
    await hubs.connect(choices: [_choice('A', 'Arche Mine')]);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(market.connectCalls.length, greaterThan(1));
    market.refuse.remove('A');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(hubs.linkOf('A')!.state, HubLinkState.connected);
  });

  // A channel the hub still sees open: every session opened and not closed.
  HubChannelOpener countingOpener(List<bool> open, Duration wait) =>
      (grant) async {
        await Future<void>.delayed(wait);
        final (channel, done) = await nodeA.session();
        final i = open.length;
        open.add(true);
        return HubChannel(
          incoming: channel.incoming,
          send: channel.send,
          close: () async => open[i] = false,
          done: done.future,
        );
      };

  test('a disconnect while the hub is still being opened leaves no session '
      'behind', () async {
    await hubs.dispose();
    final open = <bool>[];
    hubs = HubConnections(
      market: market,
      open: countingOpener(open, const Duration(milliseconds: 150)),
    );
    final connecting = hubs.connect(choices: [_choice('A', 'Arche Mine')]);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await hubs.disconnect('A');
    await connecting;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(open, isNotEmpty);
    expect(open.where((o) => o), isEmpty);
  });

  test('two attaches racing on one hub leave exactly one session open',
      () async {
    await hubs.dispose();
    final open = <bool>[];
    hubs = HubConnections(
      market: market,
      open: countingOpener(open, const Duration(milliseconds: 100)),
    );
    final first = hubs.connect(choices: [_choice('A', 'Arche Mine')]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final second = hubs.connect(choices: [_choice('A', 'Arche Mine')]);
    await Future.wait([first, second]);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(open.where((o) => o).length, 1);
    expect(hubs.links.single.state, HubLinkState.connected);
  });

  test('W6: the grant is renewed before it lapses', () async {
    hubs = HubConnections(
      market: market,
      open: opener(),
      renewAfter: const Duration(milliseconds: 80),
    );
    await hubs.connect(choices: [_choice('A', 'Arche Mine')]);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(market.connectCalls.length, greaterThanOrEqualTo(2));
    expect(await text('arche_mine.svc.echo'), 'A:{"x":1}');
  });

  test('disconnect removes one hub and keeps the other', () async {
    await hubs.connect(all: true);
    await hubs.disconnect('A');
    expect((await hubs.tools()).map((t) => t.name), ['arche_team.svc.echo']);
  });

  group('hub token sessions', () {
    test(
      'a session the hub gave a token holder connects and its tools work',
      () async {
        final link = await hubs.connectGranted(
          id: 'hub.one',
          title: 'My App',
          grant:
              () async => const HubGrant(
                sessionId: 'A#1',
                relayUrl: 'wss://relay.test',
                relayToken: 't',
              ),
        );
        expect(link.state, HubLinkState.connected);
        expect(await text('my_app.svc.echo'), 'A:{"x":1}');
      },
    );

    test(
      'a dropped session asks the hub for another, not the market',
      () async {
        var asked = 0;
        await hubs.connectGranted(
          id: 'hub.one',
          title: 'My App',
          grant: () async {
            asked++;
            return HubGrant(
              sessionId: 'A#$asked',
              relayUrl: 'wss://relay.test',
              relayToken: 't',
            );
          },
        );
        dropA.first.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(await text('my_app.svc.echo'), 'A:{"x":1}');
        expect(asked, 2);
        expect(market.connectCalls, isEmpty);
      },
    );

    test(
      'a hub that refuses the new session fails the link with the reason',
      () async {
        var asked = 0;
        await hubs.connectGranted(
          id: 'hub.one',
          title: 'My App',
          grant: () async {
            if (++asked > 1) throw StateError('token revoked');
            return const HubGrant(
              sessionId: 'A#1',
              relayUrl: 'wss://relay.test',
              relayToken: 't',
            );
          },
        );
        dropA.first.complete();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(hubs.linkOf('hub.one')!.state, HubLinkState.failed);
        expect(hubs.linkOf('hub.one')!.error, contains('token revoked'));
      },
    );

    test(
      'the token-only market lists nothing and refuses a market connect',
      () async {
        const none = HubTokenOnlyMarket();
        expect(await none.hubs(), isEmpty);
        final out = await none.connect(listingIds: ['X']);
        expect(out.single.errorCode, 'hub.token_required');
      },
    );
  });
}
