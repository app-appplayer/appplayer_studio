/// Hub node host (expose direction): registers once, goes online on the relay,
/// serves the host's tools only to market-vouched callers, honours the host
/// policy, survives a dropped relay, rotates an expiring token. The relay is
/// played by the test over the real node envelope; the gateway runtime and the
/// caller verification are real.
library;

import 'dart:async';
import 'dart:convert';

import 'package:appplayer_studio/src/base/install/gateway_node/gateway_node.dart';
import 'package:appplayer_studio/src/base/install/hub_node_host.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_gateway/mcp_gateway.dart';

import 'gateway_node/support/market_tokens.dart';

/// JWK `x` (base64url raw key) of an SPKI PEM public key.
String _xOfPem(String pem) {
  final body =
      pem.replaceAll(RegExp(r'-----.*-----'), '').replaceAll(RegExp(r'\s'), '');
  final der = base64.decode(body);
  return base64Url.encode(der.sublist(der.length - 32)).replaceAll('=', '');
}

/// A market whose tokens carry a `kid`, to exercise key selection.
class _KidMarket {
  _KidMarket._(this.kid, this._kp, this.x);
  final String kid;
  final SimpleKeyPair _kp;
  final String x;

  static Future<_KidMarket> create(String kid) async {
    final kp = await Ed25519().newKeyPair();
    final pub = await kp.extractPublicKey();
    return _KidMarket._(
        kid, kp, base64Url.encode(pub.bytes).replaceAll('=', ''));
  }

  HubCallerKey get key => HubCallerKey(kid: kid, x: x);

  Future<String> token(String nodeId, {String sub = 'alice', bool withKid = true}) async {
    String part(Object o) =>
        base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final input = '${part({'alg': 'EdDSA', 'typ': 'JWT', if (withKid) 'kid': kid})}.'
        '${part({'sub': sub, 'aud': hubCallerAudience, 'nid': nodeId, 'iat': now, 'exp': now + 1800})}';
    final sig = await Ed25519().sign(utf8.encode(input), keyPair: _kp);
    return '$input.${base64Url.encode(sig.bytes).replaceAll('=', '')}';
  }
}

class _Port implements HubNodePort {
  _Port(this.pem);
  final String pem;
  int registers = 0, rotates = 0, keyFetches = 0;
  List<HubCallerKey>? keysOverride;
  final List<String> removed = [];

  @override
  Future<HubNodeRegistration> register() async {
    registers++;
    return const HubNodeRegistration(
        id: 'node-1',
        relayToken: 'tok-1',
        relayTokenExpiresAt: 0,
        relayUrl: 'wss://relay.test');
  }

  @override
  Future<HubNodeRegistration> rotate(HubNodeRegistration c) async {
    rotates++;
    return HubNodeRegistration(
        id: c.id,
        relayToken: 'tok-rotated',
        relayTokenExpiresAt: 0,
        relayUrl: c.relayUrl);
  }

  @override
  Future<void> remove(String nodeId) async => removed.add(nodeId);


  @override
  Future<List<HubCallerKey>> callerKeys() async {
    keyFetches++;
    return keysOverride ?? [HubCallerKey(kid: 'k1', x: _xOfPem(pem))];
  }
}

class _Store implements HubNodeStore {
  HubNodeRegistration? value;
  @override
  Future<HubNodeRegistration?> load() async => value;
  @override
  Future<void> save(HubNodeRegistration r) async => value = r;
  @override
  Future<void> clear() async => value = null;
}

class _Surface implements LocalToolSurface {
  final List<(String, Map<String, dynamic>)> calls = [];
  @override
  Future<List<ToolDefinition>> list() async => const [
        ToolDefinition(name: 'echo', description: 'echoes'),
        ToolDefinition(name: 'wipe', description: 'dangerous'),
      ];
  @override
  Future<DispatchResult> call(String name, Map<String, dynamic> arguments) async {
    calls.add((name, arguments));
    return DispatchResult(content: [
      {'type': 'text', 'text': '$name:${jsonEncode(arguments)}'}
    ]);
  }
}

/// The relay as the test plays it: envelopes in, envelopes out.
class _Relay {
  final List<StreamController<Map<String, dynamic>>> toNode = [];
  final List<StreamController<Map<String, dynamic>>> fromNode = [];
  final List<Completer<void>> done = [];
  final List<String> openedWith = [];
  bool failNext = false;

  Future<HubNodeChannel> open(HubNodeRegistration r) async {
    if (failNext) {
      failNext = false;
      throw StateError('relay unreachable');
    }
    openedWith.add(r.relayToken);
    final to = StreamController<Map<String, dynamic>>.broadcast();
    final from = StreamController<Map<String, dynamic>>.broadcast();
    final d = Completer<void>();
    toNode.add(to);
    fromNode.add(from);
    done.add(d);
    return HubNodeChannel(
      envelopes: to.stream,
      send: (e) async => from.add(e),
      close: () async {},
      done: d.future,
    );
  }

  StreamController<Map<String, dynamic>> get to => toNode.last;
  StreamController<Map<String, dynamic>> get from => fromNode.last;

  Future<Map<String, dynamic>> ask(
      String sid, int id, String method, Map<String, dynamic> params) {
    final reply = from.stream.first.timeout(const Duration(seconds: 3));
    to.add({
      'type': 'frame',
      'sessionId': sid,
      'frame': jsonEncode({
        HubWire.kind: HubWire.req,
        HubWire.id: id,
        'method': method,
        'params': params,
      }),
    });
    return reply.then((env) =>
        (jsonDecode(env['frame'] as String) as Map).cast<String, dynamic>());
  }
}

String _text(Map<String, dynamic> res) {
  final content = (res[HubWire.result] as Map)['content'] as List;
  return (content.first as Map)['text'] as String;
}

void main() {
  late TestMarket market;
  late _Port port;
  late _Store store;
  late _Surface surface;
  late _Relay relay;
  HubNodeHost? host;

  HubNodeHost build({HubNodePolicy policy = const HubNodePolicy()}) =>
      host = HubNodeHost(
        port: port,
        store: store,
        tools: surface,
        policy: policy,
        open: relay.open,
        backoffStart: const Duration(milliseconds: 10),
        backoffMax: const Duration(milliseconds: 40),
      );

  setUp(() async {
    market = await TestMarket.create();
    port = _Port(market.publicKeyPem);
    store = _Store();
    surface = _Surface();
    relay = _Relay();
  });

  tearDown(() async => host?.dispose());

  Future<void> openSession(String sid, {String? sub, Duration? ttl}) async {
    final token = await market.token(
        nodeId: 'node-1', sub: sub ?? 'alice', ttl: ttl ?? const Duration(minutes: 30));
    relay.to.add({'type': 'open', 'sessionId': sid, 'caller': token});
    await until(() => host!.sessions.contains(sid));
  }

  test('start registers once, lists the node, and goes online', () async {
    final h = build();
    await h.start();
    expect(h.state, HubNodeState.online);
    expect(h.nodeId, 'node-1');
    expect(port.registers, 1);
    expect(relay.openedWith, ['tok-1']);

    await h.stop();
    expect(h.state, HubNodeState.stopped);
    final again = build();
    await again.start();
    expect(port.registers, 1, reason: 'the stored registration is reused');
  });

  test('a market-vouched caller lists and calls the host tools', () async {
    final h = build();
    await h.start();
    await openSession('s1');
    expect(h.callerOf('s1')!.subject, 'alice');

    final list = await relay.ask('s1', 1, 'tools/list', {});
    final names = ((list[HubWire.result] as Map)['tools'] as List)
        .map((t) => (t as Map)['name'])
        .toList();
    expect(names, containsAll(['host.echo', 'host.wipe']));

    final call = await relay.ask(
        's1', 2, 'tools/call', {'name': 'host.echo', 'arguments': {'n': 1}});
    expect(_text(call), 'echo:{"n":1}');
    expect(surface.calls.single.$1, 'echo');
  });

  test('a session without a verified caller is refused, nothing runs',
      () async {
    final h = build();
    await h.start();
    relay.to.add({'type': 'open', 'sessionId': 'bad', 'caller': 'not-a-token'});
    final res = await relay.ask(
        'bad', 1, 'tools/call', {'name': 'host.echo', 'arguments': {}});
    expect(res[HubWire.ok], isFalse);
    expect(surface.calls, isEmpty);

    // A token minted for another node is not this node's.
    final other = await market.token(nodeId: 'node-2');
    relay.to.add({'type': 'open', 'sessionId': 'other', 'caller': other});
    final res2 = await relay.ask(
        'other', 1, 'tools/call', {'name': 'host.echo', 'arguments': {}});
    expect(res2[HubWire.ok], isFalse);
    expect(surface.calls, isEmpty);
  });

  test('denied tools are neither listed nor callable', () async {
    final h = build(policy: const HubNodePolicy(denied: {'wipe'}));
    await h.start();
    await openSession('s1');
    final list = await relay.ask('s1', 1, 'tools/list', {});
    final names = ((list[HubWire.result] as Map)['tools'] as List)
        .map((t) => (t as Map)['name'])
        .toList();
    expect(names, ['host.echo']);
    final call = await relay.ask(
        's1', 2, 'tools/call', {'name': 'host.wipe', 'arguments': {}});
    expect(surface.calls, isEmpty);
    expect(jsonEncode(call), isNot(contains('wipe:')));
  });

  test('the host approval gate decides per call; refusal runs nothing',
      () async {
    final asked = <String>[];
    final h = build(
      policy: HubNodePolicy(approve: (caller, tool, args) async {
        asked.add('${caller.subject}:$tool');
        return tool == 'echo';
      }),
    );
    await h.start();
    await openSession('s1', sub: 'bob');
    final ok = await relay.ask(
        's1', 1, 'tools/call', {'name': 'host.echo', 'arguments': {'a': 1}});
    expect(_text(ok), 'echo:{"a":1}');
    final no = await relay.ask(
        's1', 2, 'tools/call', {'name': 'host.wipe', 'arguments': {}});
    expect(jsonEncode(no), contains('not approved'));
    expect(asked, ['bob:echo', 'bob:wipe']);
    expect(surface.calls.map((c) => c.$1), ['echo']);
  });

  test('a dropped relay reconnects on its own and serves again', () async {
    final h = build();
    await h.start();
    relay.failNext = true; // the first retry also fails, then it recovers
    relay.done.last.complete();
    await until(() => relay.toNode.length == 2 && h.state == HubNodeState.online,
        timeout: const Duration(seconds: 3));
    await openSession('s2');
    final call = await relay.ask(
        's2', 1, 'tools/call', {'name': 'host.echo', 'arguments': {'k': 2}});
    expect(_text(call), 'echo:{"k":2}');
  });

  test('a relay that keeps closing right after it opens is dialed ever slower',
      () async {
    final h = build();
    await h.start();
    final t0 = DateTime.now();
    for (var i = 0; i < 5; i++) {
      final n = relay.toNode.length;
      relay.done.last.complete();
      await until(() => relay.toNode.length == n + 1,
          timeout: const Duration(seconds: 3));
    }
    // Waits grow 10, 20, 40, 40, 40 ms; starting over each time would be ~0.
    expect(DateTime.now().difference(t0).inMilliseconds, greaterThan(120));
  });

  test('a token about to expire is rotated before dialing', () async {
    store.value = HubNodeRegistration(
        id: 'node-1',
        relayToken: 'old',
        relayTokenExpiresAt:
            DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch,
        relayUrl: 'wss://relay.test');
    final h = build();
    await h.start();
    expect(port.rotates, 1);
    expect(port.registers, 0);
    expect(relay.openedWith, ['tok-rotated']);
    expect(store.value!.relayToken, 'tok-rotated');
  });

  test('unregister removes the node from the market and forgets it', () async {
    final h = build();
    await h.start();
    await h.unregister();
    expect(port.removed, ['node-1']);
    expect(store.value, isNull);
    expect(h.state, HubNodeState.stopped);
  });

  test('a token with a kid is checked against the key of that kid', () async {
    final a = await _KidMarket.create('kid-a');
    final b = await _KidMarket.create('kid-b');
    port.keysOverride = [a.key, b.key];
    final h = build();
    await h.start();
    relay.to.add({'type': 'open', 'sessionId': 'sa', 'caller': await a.token('node-1', sub: 'ann')});
    relay.to.add({'type': 'open', 'sessionId': 'sb', 'caller': await b.token('node-1', sub: 'ben')});
    await until(() => h.sessions.length == 2);
    expect(h.callerOf('sa')!.subject, 'ann');
    expect(h.callerOf('sb')!.subject, 'ben');
  });

  test('a key rotation is picked up: an unknown kid refetches the list once',
      () async {
    final old = await _KidMarket.create('kid-old');
    final fresh = await _KidMarket.create('kid-new');
    port.keysOverride = [old.key];
    var now = DateTime.now();
    final h = HubNodeHost(
      port: port,
      store: store,
      tools: surface,
      open: relay.open,
      now: () => now,
    );
    host = h;
    await h.start();
    final fetchesAtStart = port.keyFetches;

    port.keysOverride = [old.key, fresh.key]; // the market rotated
    now = now.add(const Duration(minutes: 1)); // past the refetch interval
    relay.to.add({'type': 'open', 'sessionId': 'sn', 'caller': await fresh.token('node-1')});
    await until(() => h.sessions.contains('sn'));
    expect(port.keyFetches, fetchesAtStart + 1);
  });

  test('garbage tokens cannot make the node hammer the market', () async {
    final a = await _KidMarket.create('kid-a');
    port.keysOverride = [a.key];
    final h = build();
    await h.start();
    final fetches = port.keyFetches;
    final stranger = await _KidMarket.create('kid-x');
    for (var i = 0; i < 5; i++) {
      relay.to.add({
        'type': 'open',
        'sessionId': 'g$i',
        'caller': await stranger.token('node-1'),
      });
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(h.sessions, isEmpty);
    expect(port.keyFetches - fetches, lessThanOrEqualTo(1));
  });

  test('a token signed by another key under a known kid is refused', () async {
    final a = await _KidMarket.create('kid-a');
    final impostor = await _KidMarket.create('kid-a'); // same kid, other key
    port.keysOverride = [a.key];
    final h = build();
    await h.start();
    relay.to.add({'type': 'open', 'sessionId': 'imp', 'caller': await impostor.token('node-1')});
    final res = await relay.ask('imp', 1, 'tools/call', {'name': 'host.echo', 'arguments': {}});
    expect(res[HubWire.ok], isFalse);
    expect(surface.calls, isEmpty);
  });

  test('no published key means the node refuses to open', () async {
    port.keysOverride = const [];
    final h = build();
    await expectLater(h.start(), throwsA(isA<Object>()));
    expect(h.state, HubNodeState.failed);
    expect(relay.openedWith, isEmpty);
  });

  test('a JWK x becomes the PEM the verifier accepts', () async {
    final pem = market.publicKeyPem;
    final body = pem
        .replaceAll(RegExp(r'-----.*-----'), '')
        .replaceAll(RegExp(r'\s'), '');
    final der = base64.decode(body);
    final x = base64Url.encode(der.sublist(der.length - 32)).replaceAll('=', '');
    final rebuilt = ed25519PemFromJwkX(x);
    final verify = marketHubCallerVerifier(publicKeyPem: rebuilt, nodeId: 'n');
    final caller = await verify(await market.token(nodeId: 'n', sub: 'carol'));
    expect(caller!.subject, 'carol');
    expect(() => ed25519PemFromJwkX('AAAA'), throwsArgumentError);
  });
}
