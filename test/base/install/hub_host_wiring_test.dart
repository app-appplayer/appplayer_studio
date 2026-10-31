/// `mountHub` end to end against a fake market over HTTP: the host mounts the
/// hub for a signed-in account, exposes itself as a node, and a hub caller the
/// "market" vouched for drives a host tool through the relay envelope.
library;

import 'dart:async';
import 'dart:convert';

import 'package:appplayer_secure/appplayer_secure.dart'
    show InMemorySecureStorage;
import 'package:appplayer_studio/src/base/install/gateway_node/gateway_node.dart';
import 'package:appplayer_studio/src/base/install/hub_capability.dart';
import 'package:appplayer_studio/src/base/install/hub_connections.dart'
    show HubConnectionError;
import 'package:appplayer_studio/src/base/install/hub_host_wiring.dart';
import 'package:appplayer_studio/src/base/install/hub_node_host.dart';
import 'package:appplayer_studio/src/base/install/hub_space.dart'
    show kArcheListingId;
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import 'gateway_node/support/market_tokens.dart';

void main() {
  test(
    'mountHub: register → list → online → a vouched caller runs a host tool',
    () async {
      final market = await TestMarket.create();
      final requests = <String>[];
      final client = http_testing.MockClient((req) async {
        requests.add('${req.method} ${req.url.path}');
        if (req.url.path != '/market/hub/caller-jwks') {
          expect(req.headers['authorization'], 'Bearer USER');
        }
        if (req.method == 'POST' && req.url.path == '/hub/nodes') {
          return http.Response(
            jsonEncode({
              'id': 'node-9',
              'status': 'registered',
              'relayToken': 'rt',
              'relayTokenExpiresAt': 0,
              'relayUrl': 'wss://relay.test',
            }),
            200,
          );
        }
        if (req.method == 'GET' && req.url.path == '/market/hub/caller-jwks') {
          final body = market.publicKeyPem
              .replaceAll(RegExp(r'-----.*-----'), '')
              .replaceAll(RegExp(r'\s'), '');
          final der = base64.decode(body);
          final x = base64Url
              .encode(der.sublist(der.length - 32))
              .replaceAll('=', '');
          return http.Response(
            jsonEncode({
              'keys': [
                {
                  'kid': 'k1',
                  'kty': 'OKP',
                  'crv': 'Ed25519',
                  'alg': 'EdDSA',
                  'x': x,
                },
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });

      final boot = mk.InProcessKernelServerHost();
      boot.addTool(
        name: 'studio.ping',
        description: 'pong',
        inputSchema: const {'type': 'object'},
        handler:
            (a) async => mk.KernelToolResult(
              content: [mk.KernelTextContent(text: 'pong:${a['v']}')],
            ),
      );
      final storage = InMemorySecureStorage();

      final toNode = StreamController<Map<String, dynamic>>.broadcast();
      final fromNode = StreamController<Map<String, dynamic>>.broadcast();
      final hub = mountHub(
        boot: boot,
        baseUrl: 'https://m.test',
        token: () async => 'USER',
        accountId: 'u1',
        storage: storage,
        client: client,
      );
      addTearDown(() async {
        await hub.dispose();
        await toNode.close();
        await fromNode.close();
      });

      // Swap the relay socket for the test's envelope pipe.
      final node = HubNodeHost(
        port: HttpHubNodePort(
          baseUrl: 'https://m.test',
          hubBaseUrl: 'https://m.test',
          token: () async => 'USER',
          client: client,
        ),
        store: SecureHubNodeStore(storage, 'u1'),
        tools: KernelHostToolSurface(boot, exclude: kHubRemoteExcluded),
        open:
            (reg) async => HubNodeChannel(
              envelopes: toNode.stream,
              send: (e) async => fromNode.add(e),
              close: () async {},
              done: Completer<void>().future,
            ),
      );
      addTearDown(node.dispose);

      await node.start();
      expect(requests, ['POST /hub/nodes', 'GET /market/hub/caller-jwks']);
      expect(node.state, HubNodeState.online);
      expect((await SecureHubNodeStore(storage, 'u1').load())!.id, 'node-9');

      final token = await market.token(nodeId: 'node-9', sub: 'u1');
      toNode.add({'type': 'open', 'sessionId': 's', 'caller': token});
      await until(() => node.sessions.contains('s'));
      final reply = fromNode.stream.first.timeout(const Duration(seconds: 3));
      toNode.add({
        'type': 'frame',
        'sessionId': 's',
        'frame': jsonEncode({
          HubWire.kind: HubWire.req,
          HubWire.id: 1,
          'method': 'tools/call',
          'params': {
            'name': 'host.studio.ping',
            'arguments': {'v': 5},
          },
        }),
      });
      final res = (jsonDecode((await reply)['frame'] as String) as Map);
      final content = (res[HubWire.result] as Map)['content'] as List;
      expect((content.first as Map)['text'], 'pong:5');

      // The hub's own node controls never leave the machine.
      final names = (await KernelHostToolSurface(
            boot,
            exclude: kHubRemoteExcluded,
          ).list())
          .map((d) => d.name);
      expect(names, isNot(contains('hub.node_remove')));
    },
  );

  test('a different account does not inherit the stored node', () async {
    final storage = InMemorySecureStorage();
    await SecureHubNodeStore(storage, 'u1').save(
      const HubNodeRegistration(
        id: 'n',
        relayToken: 't',
        relayTokenExpiresAt: 0,
        relayUrl: 'wss://r',
      ),
    );
    expect(await SecureHubNodeStore(storage, 'u2').load(), isNull);
  });

  group('join on sign-in', () {
    HubHost mount(http.Client c) => mountHub(
      boot: mk.InProcessKernelServerHost(),
      baseUrl: 'https://m.test',
      token: () async => 'USER',
      accountId: 'u1',
      storage: InMemorySecureStorage(),
      client: c,
    );

    test(
      'an unregistered developer account keeps the reason, no throw',
      () async {
        final hub = mount(
          http_testing.MockClient((req) async {
            if (req.url.path == '/market/me/workspaces') {
              return http.Response(jsonEncode({'workspaces': []}), 200);
            }
            if (req.url.path == '/market/me/items') {
              return http.Response(
                jsonEncode({
                  'items': [
                    {
                      'listingId': kArcheListingId,
                      'title': 'Arche',
                      'hub': {'control': 'https://m.test', 'relay': 'wss://r'},
                    },
                  ],
                }),
                200,
              );
            }
            return http.Response(
              jsonEncode({'error': 'register as a developer first'}),
              403,
            );
          }),
        );
        addTearDown(hub.dispose);
        final out = await hub.join();
        expect(out.nodeStarted, isFalse);
        expect(out.error, contains('register as a developer first'));
        expect(hub.node.state, HubNodeState.failed);
      },
    );

    test(
      'a market that refuses the hub list keeps the reason, no throw',
      () async {
        final hub = mount(
          http_testing.MockClient(
            (req) async => http.Response(
              jsonEncode({'error': 'register as a developer first'}),
              403,
            ),
          ),
        );
        addTearDown(hub.dispose);
        final out = await hub.join();
        expect(out.nodeStarted, isFalse);
        expect(out.error, contains('register as a developer first'));
      },
    );
  });

  test(
    'the hub address is asked of the market once, then used for /hub/nodes',
    () async {
      final seen = <String>[];
      final client = http_testing.MockClient((req) async {
        seen.add('${req.method} ${req.url}');
        if (req.url.path == '/market/me/hub') {
          return http.Response(
            jsonEncode({
              'hub': {'control': 'https://m.test', 'relay': 'wss://r'},
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'error': 'stop'}), 500);
      });
      final port = HttpHubNodePort(
        baseUrl: 'https://m.test',
        token: () async => 'USER',
        client: client,
      );
      for (var i = 0; i < 2; i++) {
        await expectLater(port.register(), throwsA(isA<HubConnectionError>()));
      }
      expect(seen, [
        'GET https://m.test/market/me/hub',
        'POST https://m.test/hub/nodes',
        'POST https://m.test/hub/nodes',
      ]);
    },
  );

  test('the market login and App Check go to the market origin only', () async {
    final seen = <String, String?>{};
    final client = http_testing.MockClient((req) async {
      seen['${req.method} ${req.url}'] = req.headers['X-Firebase-AppCheck'];
      return http.Response(jsonEncode({'error': 'stop'}), 500);
    });
    for (final root in <String?>[null, 'https://other.hub']) {
      final port = HttpHubNodePort(
        baseUrl: 'https://m.test',
        hubBaseUrl: root,
        token: () async => 'USER',
        appCheckToken: () async => 'AC',
        client: client,
      );
      await expectLater(port.register(), throwsA(isA<HubConnectionError>()));
    }
    expect(seen['GET https://m.test/market/me/hub'], 'AC');
    // A foreign control address gets no request at all.
    expect(seen.keys.where((k) => k.contains('other.hub')), isEmpty);
  });

  test('the hub the market names for the account gets the login, though its '
      'origin differs from the API root', () async {
    final sent = <String, Map<String, String>>{};
    final client = http_testing.MockClient((req) async {
      sent['${req.method} ${req.url}'] = req.headers;
      if (req.url.path == '/market/me/hub') {
        return http.Response(
          jsonEncode({
            'hub': {'control': 'https://hub.m.test', 'relay': 'wss://r.m.test'},
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'id': 'n1',
          'relayToken': 'rt',
          'relayTokenExpiresAt': 0,
          'relayUrl': 'wss://r.m.test',
        }),
        200,
      );
    });
    final port = HttpHubNodePort(
      baseUrl: 'https://m.test',
      token: () async => 'USER',
      appCheckToken: () async => 'AC',
      client: client,
    );
    final reg = await port.register();
    expect(reg.id, 'n1');
    final call = sent['POST https://hub.m.test/hub/nodes']!;
    expect(call['authorization'] ?? call['Authorization'], 'Bearer USER');
    // App Check belongs to the market's API origin only.
    expect(
      call.keys.map((k) => k.toLowerCase()),
      isNot(contains('x-firebase-appcheck')),
    );
  });

  test(
    'a hub address that did not come from the market still gets nothing',
    () async {
      final seen = <String>[];
      final client = http_testing.MockClient((req) async {
        seen.add('${req.method} ${req.url}');
        if (req.url.path == '/market/me/hub') {
          return http.Response(
            jsonEncode({
              'hub': {'control': 'https://hub.m.test', 'relay': 'wss://r'},
            }),
            200,
          );
        }
        return http.Response('{}', 500);
      });
      // The market named hub.m.test; a service hub item points elsewhere.
      final port = HttpHubNodePort(
        baseUrl: 'https://m.test',
        hubBaseUrl: 'https://service.example',
        token: () async => 'USER',
        client: client,
      );
      await expectLater(port.register(), throwsA(isA<HubConnectionError>()));
      expect(seen.where((s) => s.contains('service.example')), isEmpty);
    },
  );

  test('the node lets in only the account owner', () async {
    final market = await TestMarket.create();
    final storage = InMemorySecureStorage();
    await SecureHubNodeStore(storage, 'owner').save(
      const HubNodeRegistration(
        id: 'n1',
        relayToken: 'rt',
        relayTokenExpiresAt: 0,
        relayUrl: 'wss://r',
      ),
    );
    final client = http_testing.MockClient((req) async {
      if (req.url.path == '/market/hub/caller-jwks') {
        final body = market.publicKeyPem
            .replaceAll(RegExp(r'-----.*-----'), '')
            .replaceAll(RegExp(r'\s'), '');
        final der = base64.decode(body);
        final x = base64Url
            .encode(der.sublist(der.length - 32))
            .replaceAll('=', '');
        return http.Response(
          jsonEncode({
            'keys': [
              {
                'kid': 'k1',
                'kty': 'OKP',
                'crv': 'Ed25519',
                'alg': 'EdDSA',
                'x': x,
              },
            ],
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });
    final toNode = StreamController<Map<String, dynamic>>.broadcast();
    final node = HubNodeHost(
      port: HttpHubNodePort(
        baseUrl: 'https://m.test',
        hubBaseUrl: 'https://m.test',
        token: () async => 'USER',
        client: client,
      ),
      store: SecureHubNodeStore(storage, 'owner'),
      tools: KernelHostToolSurface(mk.InProcessKernelServerHost()),
      ownerSubject: 'owner',
      open:
          (reg) async => HubNodeChannel(
            envelopes: toNode.stream,
            send: (e) async {},
            close: () async {},
            done: Completer<void>().future,
          ),
    );
    addTearDown(() async {
      await node.dispose();
      await toNode.close();
    });
    await node.start();
    toNode.add({
      'type': 'open',
      'sessionId': 'stranger',
      'caller': await market.token(nodeId: 'n1', sub: 'someone-else'),
    });
    toNode.add({
      'type': 'open',
      'sessionId': 'mine',
      'caller': await market.token(nodeId: 'n1', sub: 'owner'),
    });
    await until(() => node.sessions.contains('mine'));
    expect(node.sessions, isNot(contains('stranger')));
  });
}
