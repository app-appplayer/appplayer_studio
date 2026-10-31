import 'dart:async';
import 'dart:convert';

import 'package:appplayer_studio/src/base/install/gateway_node/gateway_node.dart';
import 'package:mcp_gateway/mcp_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/market_tokens.dart';

/// The hub caller rule (marketplace DDD 09 §8-4) on the node side: the token on
/// a session's `open` is verified once and bound; a session without a verified
/// caller is never served. Mirrors the server app runtime's hub node.
void main() {
  late TestMarket market;
  setUp(() async => market = await TestMarket.create());

  group('marketHubCallerVerifier', () {
    test('accepts the market token for this node and carries plan · features',
        () async {
      final verify = market.verifier('node-1');
      final c = await verify(await market.token(nodeId: 'node-1', claims: {
        'lst': 'listing-9',
        'iid': 'inst-3',
        'plan': 'pro',
        'ent': {'seats': 5, 'export': true},
      }));
      expect(c, isNotNull);
      expect(c!.subject, 'alice');
      expect(c.listingId, 'listing-9');
      expect(c.instanceId, 'inst-3');
      expect(c.planId, 'pro');
      expect(c.features, {'seats': 5, 'export': true});
    });

    test('a token without a plan has no plan', () async {
      final c = await market.verifier('node-1')(
          await market.token(nodeId: 'node-1'));
      expect(c!.planId, isNull);
      expect(c.features, isEmpty);
    });

    test('refuses another node', () async {
      expect(
          await market.verifier('node-1')(await market.token(nodeId: 'node-2')),
          isNull);
    });

    test('refuses another audience', () async {
      final t = await market.token(
          nodeId: 'node-1', claims: {'aud': 'instance-7'});
      expect(await market.verifier('node-1')(t), isNull);
    });

    test('refuses an expired token', () async {
      final t =
          await market.token(nodeId: 'node-1', ttl: const Duration(seconds: -1));
      expect(await market.verifier('node-1')(t), isNull);
    });

    test('refuses a token signed by someone else', () async {
      final other = await TestMarket.create();
      expect(
          await market.verifier('node-1')(await other.token(nodeId: 'node-1')),
          isNull);
    });

    test('refuses a tampered payload', () async {
      final t = await market.token(nodeId: 'node-1');
      final parts = t.split('.');
      final claims = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map;
      claims['sub'] = 'mallory';
      final forged = [
        parts[0],
        base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', ''),
        parts[2],
      ].join('.');
      expect(await market.verifier('node-1')(forged), isNull);
    });

    test('refuses a non-EdDSA header even with a valid signature', () async {
      final t = await market.token(nodeId: 'node-1', alg: 'none');
      expect(await market.verifier('node-1')(t), isNull);
    });

    test('refuses garbage', () async {
      final verify = market.verifier('node-1');
      expect(await verify(''), isNull);
      expect(await verify('a.b'), isNull);
      expect(await verify('!!.??.**'), isNull);
    });

    test('a key that is not a public key fails at construction', () {
      expect(
          () => marketHubCallerVerifier(publicKeyPem: 'nope', nodeId: 'n'),
          throwsArgumentError);
    });
  });

  group('HubRelayNodeServer session gate', () {
    late GatewayRuntime runtime;
    late StreamController<Map<String, dynamic>> toNode;
    late StreamController<Map<String, dynamic>> fromNode;
    late HubRelayNodeServer node;
    late DateTime clock;
    late HubCallerVerifier verifyImpl;

    setUp(() async {
      runtime = GatewayRuntime(GatewayConfig());
      await runtime.start();
      final provider = await exposeThroughGateway(
        runtime: runtime,
        registration: ProviderRegistration(
          providerId: 'svc',
          schemaVersion: 1,
          schema:
              ProviderSchemaBody(tools: const [ToolDefinition(name: 'echo')]),
        ),
        onToolCall: (d) async => DispatchResult(content: [
          {'type': 'text', 'text': 'ok'}
        ]),
      );
      unawaited(provider.startPollLoop());
      toNode = StreamController<Map<String, dynamic>>.broadcast();
      fromNode = StreamController<Map<String, dynamic>>.broadcast();
      clock = DateTime.now();
      verifyImpl = market.verifier('node-1');
      node = HubRelayNodeServer(
        runtime: runtime,
        incoming: toNode.stream,
        send: (env) async => fromNode.add(env),
        verifyCaller: (t) => verifyImpl(t),
        now: () => clock,
      );
      await node.start();
      addTearDown(() async {
        await node.stop();
        await provider.unregister();
        await toNode.close();
        await fromNode.close();
        await runtime.dispose();
      });
    });

    /// Send one tools/list on [sid]; returns the inner reply frame.
    Future<Map<String, dynamic>> ask(String sid) async {
      final f = fromNode.stream
          .firstWhere((e) => e['sessionId'] == sid)
          .timeout(const Duration(seconds: 2));
      toNode.add({
        'type': 'frame',
        'sessionId': sid,
        'frame': jsonEncode(
            {'k': 'req', 'id': 1, 'method': 'tools/list', 'params': const {}}),
      });
      return (jsonDecode((await f)['frame'] as String) as Map)
          .cast<String, dynamic>();
    }

    Future<void> open(String sid, String? caller) async {
      toNode.add({
        'type': 'open',
        'sessionId': sid,
        if (caller != null) 'caller': caller,
      });
    }

    test('a verified session is served and exposes its caller', () async {
      await open('s', await market.token(nodeId: 'node-1', claims: {'plan': 'pro'}));
      final r = await ask('s');
      expect(r['ok'], isTrue);
      expect(node.callerOf('s')!.planId, 'pro');
    });

    test('a frame right behind its open waits for the verdict', () async {
      // No settling between open and frame — the relay drains waiting frames
      // immediately after `open`, and they must not race the verification.
      final token = await market.token(nodeId: 'node-1');
      await open('s', token);
      expect((await ask('s'))['ok'], isTrue);
    });

    test('a session that was never opened is refused', () async {
      final r = await ask('ghost');
      expect(r['ok'], isFalse);
      expect(r['result']['error'], 'session has no verified caller');
      expect(node.sessions, isEmpty);
    });

    test('an open without a caller opens nothing', () async {
      await open('s', null);
      expect((await ask('s'))['ok'], isFalse);
      expect(node.callerOf('s'), isNull);
    });

    test('an open with a caller for another node opens nothing', () async {
      await open('s', await market.token(nodeId: 'node-2'));
      expect((await ask('s'))['ok'], isFalse);
    });

    test('a session whose caller expires is refused and dropped', () async {
      await open('s',
          await market.token(nodeId: 'node-1', ttl: const Duration(minutes: 1)));
      expect((await ask('s'))['ok'], isTrue);
      clock = clock.add(const Duration(minutes: 2));
      final r = await ask('s');
      expect(r['ok'], isFalse);
      expect(r['result']['error'], 'session caller expired');
      expect(node.sessions, isEmpty);
    });

    test('close ends the session — later frames are refused', () async {
      await open('s', await market.token(nodeId: 'node-1'));
      expect((await ask('s'))['ok'], isTrue);
      toNode.add({'type': 'close', 'sessionId': 's'});
      await until(() => node.sessions.isEmpty);
      expect((await ask('s'))['ok'], isFalse);
    });

    test('a close that lands while the open is verifying wins', () async {
      // Hold the verdict until the close has been handled.
      final release = Completer<void>();
      final real = verifyImpl;
      verifyImpl = (t) async {
        await release.future;
        return real(t);
      };
      await open('s', await market.token(nodeId: 'node-1'));
      toNode.add({'type': 'close', 'sessionId': 's'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(node.callerOf('s'), isNull);
      expect(node.sessions, isEmpty);
      expect((await ask('s'))['ok'], isFalse);
    });

    test('a verifier that throws refuses the session and the node lives on',
        () async {
      verifyImpl = (_) async => throw StateError('key store unreachable');
      await open('s', 'anything');
      expect((await ask('s'))['ok'], isFalse);
      verifyImpl = market.verifier('node-1');
      await open('t', await market.token(nodeId: 'node-1'));
      expect((await ask('t'))['ok'], isTrue);
    });

    test('sessions are bound separately', () async {
      await open('a', await market.token(nodeId: 'node-1', sub: 'alice'));
      await open('b', await market.token(nodeId: 'node-1', sub: 'bob'));
      await ask('a');
      await ask('b');
      expect(node.callerOf('a')!.subject, 'alice');
      expect(node.callerOf('b')!.subject, 'bob');
    });
  });
}
