/// The hub space: Arche plus market hubs, each with its own node on its own
/// control address. Nothing here talks to a network — the market doors and the
/// relay are played by the test.
library;

import 'dart:async';
import 'dart:convert';

import 'package:appplayer_studio/src/base/install/hub_apps.dart';
import 'package:appplayer_studio/src/base/install/hub_connections.dart';
import 'package:appplayer_studio/src/base/install/hub_node_host.dart';
import 'package:appplayer_studio/src/base/install/hub_space.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mcp_gateway/mcp_gateway.dart';

HubItem _item(String id) => HubItem(
    listingId: id,
    title: 'Hub $id',
    control: 'https://$id.control',
    relay: 'wss://$id.relay');

class _Items implements HubItemsPort {
  final List<HubItem> catalogItems = [_item(kArcheListingId), _item('A'), _Item2.b];
  final List<HubItem> mine = [];
  final List<String> hidden = [];
  @override
  Future<List<HubItem>> catalog() async => List.of(catalogItems);
  @override
  Future<List<HubItem>> installed() async => List.of(mine);
  @override
  Future<void> install(String id) async =>
      mine.add(catalogItems.firstWhere((h) => h.listingId == id));
  @override
  Future<void> hide(String id) async {
    hidden.add(id);
    mine.removeWhere((h) => h.listingId == id);
  }
}

class _Item2 {
  static final b = _item('B');
}

class _Port implements HubNodePort {
  _Port(this.name, this.log);
  final String name;
  final List<String> log;
  @override
  Future<HubNodeRegistration> register() async {
    log.add('register $name');
    return HubNodeRegistration(
        id: 'node-$name',
        relayToken: 't',
        relayTokenExpiresAt: 0,
        relayUrl: 'wss://relay');
  }

  @override
  Future<HubNodeRegistration> rotate(HubNodeRegistration c) async => c;
  @override
  Future<void> remove(String nodeId) async => log.add('remove $nodeId');
  @override
  Future<List<HubCallerKey>> callerKeys() async => [
        HubCallerKey(
            kid: 'k',
            x: base64Url.encode(List<int>.filled(32, 7)).replaceAll('=', '')),
      ];
}

class _ListPort extends _Port implements HubNodeDirectory {
  _ListPort(super.name, super.log);
  final released = <String>[];
  final beats = <String, int>{};
  @override
  Future<List<HubNodeInfo>> list() async => [
        const HubNodeInfo(
            id: 'n1', state: HubNodeLinkState.connected, hint: 'Desk', deployment: 'local'),
        const HubNodeInfo(id: 'n2', state: HubNodeLinkState.disconnected),
        const HubNodeInfo(id: 'n3', state: HubNodeLinkState.closed),
      ];
  @override
  Future<void> release(String nodeId) async => released.add(nodeId);
  @override
  Future<void> setHeartbeat(String nodeId, int seconds) async =>
      beats[nodeId] = seconds;
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

class _Attach implements HubAttachStore {
  Set<String>? value;
  @override
  Future<Set<String>?> load() async => value;
  @override
  Future<void> save(Set<String> ids) async => value = {...ids};
}

class _Apps implements HubAppStore {
  final Map<String, HubApp> rows = {};
  final Map<String, String> tokens = {};
  @override
  Future<List<HubApp>> apps() async => rows.values.toList();
  @override
  Future<void> save(HubApp app, String token) async {
    rows[app.id] = app;
    tokens[app.id] = token;
  }

  @override
  Future<String?> token(String id) async => tokens[id];
  @override
  Future<void> forget(String id) async {
    rows.remove(id);
    tokens.remove(id);
  }
}

/// A hub's door: lets in the tokens it was told of while their server is on.
class _Door implements HubEntryPort {
  final Set<String> good = {};
  bool online = true;
  final List<String> asked = [];
  @override
  Future<HubGrant> enter(String control, String token) async {
    asked.add('$control $token');
    if (!good.contains(token)) throw const HubEntryRefused(401, 'invalid_token');
    if (!online) throw const HubEntryRefused(503, 'provider_offline', -33003);
    return const HubGrant(
        sessionId: 'S', relayUrl: 'wss://relay', relayToken: 'R');
  }
}

class _Surface implements LocalToolSurface {
  @override
  Future<List<ToolDefinition>> list() async => const [];
  @override
  Future<DispatchResult> call(String name, Map<String, dynamic> arguments) async =>
      DispatchResult(content: const []);
}

HubNodeHost _node(String name, List<String> log) => HubNodeHost(
      port: _Port(name, log),
      store: _Store(),
      tools: _Surface(),
      open: (r) async => HubNodeChannel(
        envelopes: const Stream<Map<String, dynamic>>.empty(),
        send: (e) async {},
        close: () async {},
        done: Completer<void>().future,
      ),
    );

void main() {
  late List<String> log;
  late _Items items;
  late _Attach attach;
  late HubSpace space;

  HubSpace build() => HubSpace(
        items: items,
        arche: _node('arche', log),
        nodeFor: (item) => _node(item.listingId, log),
        attachStore: attach,
      );

  setUp(() {
    log = [];
    items = _Items()..mine.addAll([_item(kArcheListingId), _item('A')]);
    attach = _Attach();
    space = build();
  });
  tearDown(() => space.dispose());

  test('first start: installed Arche is attached by default, other installed hubs are listed detached',
      () async {
    await space.restore();
    final e = {for (final x in space.entries) x.id: x};
    expect(e.keys, ['arche', 'A']);
    expect(e['arche']!.isArche, isTrue);
    expect(e['A']!.isArche, isFalse);
    expect(e['arche']!.state, HubNodeState.online);
    expect(e['A']!.state, HubNodeState.stopped);
    expect(log, ['register arche']);
  });

  test('attach puts the machine on that hub and the choice survives a restart',
      () async {
    await space.restore();
    await space.attach('A');
    expect(space.entries.last.state, HubNodeState.online);
    expect(space.entries.last.nodeId, 'node-A');
    expect(attach.value, {'arche', 'A'});

    final again = build();
    addTearDown(again.dispose);
    await again.restore();
    expect(again.entries.map((e) => e.state),
        [HubNodeState.online, HubNodeState.online]);
  });

  test('detach is remembered: the next start leaves that hub offline', () async {
    await space.restore();
    await space.detach('arche');
    expect(space.entries.first.state, HubNodeState.stopped);
    final again = build();
    addTearDown(again.dispose);
    await again.restore();
    expect(again.entries.first.state, HubNodeState.stopped);
  });

  test('install adds a detached entry; find leaves out what is installed',
      () async {
    await space.restore();
    expect((await space.find()).map((h) => h.listingId), ['B']);
    await space.install('B');
    expect(space.entries.map((e) => e.id), ['arche', 'A', 'B']);
    expect(space.entries.last.state, HubNodeState.stopped);
    expect(await space.find(), isEmpty);
  });

  test('hide takes the node off the market and drops the entry', () async {
    await space.restore();
    await space.attach('A');
    await space.hide('A');
    expect(log, contains('remove node-A'));
    expect(items.hidden, ['A']);
    expect(space.entries.map((e) => e.id), ['arche']);
    expect(attach.value, {'arche'});
  });

  test('Arche is a market item: absent until installed, then it comes up',
      () async {
    items.mine.removeWhere((h) => h.listingId == kArcheListingId);
    await space.restore();
    expect(space.entries.map((e) => e.id), ['A']);
    expect(log, isEmpty);
    await expectLater(space.attach('arche'), throwsA(isA<HubConnectionError>()));
    expect((await space.find()).map((h) => h.listingId),
        [kArcheListingId, 'B']);
    await space.install(kArcheListingId);
    final arche = space.entries.first;
    expect(arche.id, 'arche');
    expect(arche.isArche, isTrue);
    expect(arche.state, HubNodeState.online);
  });

  test('removing Arche takes it offline and off the list', () async {
    await space.restore();
    await space.hide('arche');
    expect(items.hidden, [kArcheListingId]);
    expect(space.entries.map((e) => e.id), ['A']);
  });

  test('a hub that fails to come up keeps its reason and does not block others',
      () async {
    final failing = HubSpace(
      items: items,
      arche: _node('arche', log),
      nodeFor: (item) => HubNodeHost(
        port: _Port(item.listingId, log),
        store: _Store(),
        tools: _Surface(),
        open: (r) async => throw StateError('relay down'),
        backoffStart: const Duration(hours: 1),
      ),
      attachStore: attach..value = {'arche', 'A'},
    );
    addTearDown(failing.dispose);
    await failing.restore();
    final e = {for (final x in failing.entries) x.id: x};
    expect(e['arche']!.state, HubNodeState.online);
    expect(e['A']!.state, HubNodeState.reconnecting);
    expect(e['A']!.error, contains('relay down'));
  });

  test('HttpHubItemsPort reads hub items from either envelope and sends App Check',
      () async {
    final seen = <String>[];
    final client = http_testing.MockClient((req) async {
      seen.add('${req.method} ${req.url.path}?${req.url.query} '
          '${req.headers['X-Firebase-AppCheck']} '
          '${req.headers['X-AppPlayer-Workspace']}');
      if (req.url.path == '/market/catalog') {
        return http.Response(
            jsonEncode({
              'items': [
                {
                  'listingId': 'H1',
                  'title': 'One',
                  'type': 'hub',
                  'hub': {'control': 'https://c', 'relay': 'wss://r'}
                },
                {'listingId': 'X', 'title': 'not a hub'},
              ]
            }),
            200);
      }
      if (req.url.path == '/market/me/items') {
        return http.Response(
            jsonEncode({
              'items': [
                {
                  'listingId': 'H2',
                  'title': 'Two',
                  'hub': {'control': 'https://c2', 'relay': 'wss://r2'}
                }
              ]
            }),
            200);
      }
      return http.Response('{}', 200);
    });
    final port = HttpHubItemsPort(
        baseUrl: 'https://m.test',
        token: () async => 'U',
        appCheckToken: () async => 'AC',
        workspace: () async => 'W1',
        client: client);
    expect((await port.catalog()).map((h) => h.listingId), ['H1']);
    expect((await port.installed()).single.control, 'https://c2');
    await port.install('H1');
    await port.hide('H1');
    expect(seen, [
      'GET /market/catalog?type=hub AC W1',
      'GET /market/me/items?type=hub AC W1',
      'POST /market/purchase? AC W1',
      'POST /market/me/items/H1/visibility? AC W1',
    ]);
  });

  group('workspace header', () {
    Future<List<String?>> run(Object workspacesBody) async {
      final headers = <String?>[];
      var asked = 0;
      final client = http_testing.MockClient((req) async {
        if (req.url.path == '/market/me/workspaces') {
          asked++;
          return http.Response(jsonEncode(workspacesBody), 200);
        }
        headers.add(req.headers['X-AppPlayer-Workspace']);
        return http.Response(jsonEncode({'items': []}), 200);
      });
      final port = HttpHubItemsPort(
          baseUrl: 'https://m.test', token: () async => 'U', client: client);
      await port.installed();
      await port.installed();
      expect(asked, 1, reason: 'the workspace is asked of the market once');
      return headers;
    }

    test('an account without a workspace sends no header (personal place)',
        () async {
      expect(await run({'workspaces': []}), [null, null]);
    });

    test('a member sends its workspace id', () async {
      expect(
          await run({
            'workspaces': [
              {'id': 'w_1'},
              {'id': 'w_2'}
            ]
          }),
          ['w_1', 'w_1']);
    });
  });

  test('the hub reports its nodes as connected, not connected or closed; one can be released',
      () async {
    final port = _ListPort('A', log);
    final sp = HubSpace(
      items: items,
      arche: _node('arche', log),
      nodeFor: (item) => HubNodeHost(
        port: port,
        store: _Store(),
        tools: _Surface(),
        open: (r) async => HubNodeChannel(
          envelopes: const Stream<Map<String, dynamic>>.empty(),
          send: (e) async {},
          close: () async {},
          done: Completer<void>().future,
        ),
      ),
      attachStore: attach,
    );
    addTearDown(sp.dispose);
    await sp.restore();
    final nodes = await sp.nodesOf('A');
    expect(nodes.map((n) => n.state), [
      HubNodeLinkState.connected,
      HubNodeLinkState.disconnected,
      HubNodeLinkState.closed,
    ]);
    expect(nodes.first.hint, 'Desk');
    await sp.releaseNode('A', 'n2');
    expect(port.released, ['n2']);
  });

  group('Hub token apps', () {
    late _Apps store;
    late _Door door;
    final plain = <bool>[];
    final sent = <Map<String, dynamic>>[];
    late StreamController<Map<String, dynamic>> incoming;

    HubChannel channel() => HubChannel(
          incoming: incoming.stream,
          send: (m) async {
            sent.add(m);
            final id = m['id'];
            if (id == null) return;
            incoming.add(switch (m['method']) {
              'initialize' => {
                  'jsonrpc': '2.0',
                  'id': id,
                  'result': {
                    'protocolVersion': '2025-03-26',
                    'capabilities': {'tools': {'listChanged': false}},
                    'serverInfo': {'name': 'arche', 'version': '1'},
                  },
                },
              _ => {
                  'jsonrpc': '2.0',
                  'id': id,
                  'result': {
                    'tools': [
                      {
                        'name': 'arche_projects_list',
                        'description': 'x',
                        'inputSchema': {'type': 'object'},
                      }
                    ],
                  },
                },
            });
          },
          close: () async {},
          done: Completer<void>().future,
        );

    setUp(() {
      store = _Apps();
      door = _Door()..good.add('hst_one.secret');
      plain.clear();
      sent.clear();
      incoming = StreamController<Map<String, dynamic>>.broadcast();
    });

    HubSpace withApps() {
      final conns = HubConnections(
        market: _NoMarket(),
        open: (g) async {
          plain.add(g.plainMcp);
          return channel();
        },
        handshakeTimeout: const Duration(seconds: 2),
      );
      final sp = HubSpace(
        items: items,
        arche: _node('arche', log),
        nodeFor: (item) => _node(item.listingId, log),
        attachStore: attach,
        apps: HubApps(store: store, entry: door),
        appTools: conns,
      );
      addTearDown(() async {
        sp.dispose();
        await conns.dispose();
        await incoming.close();
      });
      return sp;
    }

    test('an app added before the installed list was read still finds its hub',
        () async {
      final sp = withApps();
      final added = await sp.addApp('arche', '', 'hst_one.secret');
      expect(added.reached, isTrue);
      expect(sp.entries.first.apps.single.connected, isTrue);
    });

    test('Arche is opened with a hub token over plain MCP; the token stays out of the entry',
        () async {
      final sp = withApps();
      await sp.restore();
      final added = await sp.addApp('arche', '', 'hst_one.secret');
      expect(added.reached, isTrue);
      final app = sp.entries.first.apps.single;
      expect(app.connected, isTrue);
      expect(app.toolNames, ['arche_projects_list']);
      expect(plain, [true]);
      expect(sent.every((m) => m['jsonrpc'] == '2.0'), isTrue);
      expect(sp.entries.first.toString(), isNot(contains('secret')));
      expect(store.tokens['hub.one'], 'hst_one.secret');
      // The door was asked at the hub's own control address.
      expect(door.asked, ['https://$kArcheListingId.control hst_one.secret']);
    });

    test('another hub speaks the hub wire', () async {
      final sp = withApps();
      await sp.restore();
      await sp.addApp('A', 'Mine', 'hst_one.secret').catchError(
          (Object _) => HubAppAdded(
              const HubApp(id: 'x', hubId: 'A', control: '', name: ''), null));
      expect(plain, [false]);
    });

    test('a wrong token is refused and nothing is kept', () async {
      final sp = withApps();
      await sp.restore();
      await expectLater(sp.addApp('arche', '', 'hst_two.nope'),
          throwsA(isA<HubEntryRefused>()));
      expect(store.rows, isEmpty);
      expect(sp.entries.first.apps, isEmpty);
    });

    test('something that is not a hub token is refused before the hub is asked',
        () async {
      final sp = withApps();
      await sp.restore();
      await expectLater(
          sp.addApp('arche', '', 'arche_mcp.abc'), throwsA(isA<FormatException>()));
      expect(door.asked, isEmpty);
    });

    test('a good token whose server is off the hub is kept and opens once it is on',
        () async {
      final sp = withApps();
      await sp.restore();
      door.online = false;
      final added = await sp.addApp('arche', '', 'hst_one.secret');
      expect(added.reached, isFalse);
      var app = sp.entries.first.apps.single;
      expect(app.connected, isFalse);
      expect(app.reason, HubEntryReason.offline);
      expect(store.rows, isNotEmpty);
      door.online = true;
      await sp.openApp('hub.one');
      app = sp.entries.first.apps.single;
      expect(app.connected, isTrue);
      expect(app.reason, isNull);
    });

    test('a saved app is opened again on the next start', () async {
      final first = withApps();
      await first.restore();
      await first.addApp('arche', '', 'hst_one.secret');
      final again = withApps();
      await again.restore();
      expect(again.entries.first.apps.single.connected, isTrue);
    });

    test('a refused new token leaves the old one; an accepted one replaces it',
        () async {
      final sp = withApps();
      await sp.restore();
      await sp.addApp('arche', 'Arche', 'hst_one.secret');
      await expectLater(sp.changeAppToken('hub.one', 'hst_two.bad'),
          throwsA(isA<HubEntryRefused>()));
      expect(store.rows.keys, ['hub.one']);
      door.good.add('hst_two.fine');
      await sp.changeAppToken('hub.one', 'hst_two.fine');
      expect(store.rows.keys, ['hub.two']);
      expect(store.tokens.containsKey('hub.one'), isFalse);
      expect(sp.entries.first.apps.single.app.id, 'hub.two');
    });

    test('removing an app closes it and forgets its token', () async {
      final sp = withApps();
      await sp.restore();
      await sp.addApp('arche', '', 'hst_one.secret');
      await sp.removeApp('hub.one');
      expect(sp.entries.first.apps, isEmpty);
      expect(store.tokens, isEmpty);
    });

    test('removing the hub removes its apps', () async {
      final sp = withApps();
      await sp.restore();
      await sp.addApp('arche', '', 'hst_one.secret');
      await sp.hide('arche');
      expect(store.rows, isEmpty);
    });

    test('the hub door: token only, no login; its refusals are told apart',
        () async {
      final seen = <http.Request>[];
      var plan = 'ok';
      final port = HttpHubEntryPort(
          client: http_testing.MockClient((req) async {
        seen.add(req);
        return switch (plan) {
          'ok' => http.Response(
              jsonEncode({
                'sessionId': 'S',
                'relayUrl': 'wss://r',
                'relayToken': 'T',
                'status': 'open'
              }),
              200),
          'offline' => http.Response(
              jsonEncode({
                'error': {'code': 'provider_offline', 'gatewayCode': -33003}
              }),
              503),
          'closed' => http.Response(
              jsonEncode({
                'error': {'code': 'not_found', 'gatewayCode': -33001}
              }),
              404),
          _ => http.Response(jsonEncode({'error': {'code': 'invalid_token'}}), 401),
        };
      }));
      final grant = await port.enter('https://hub.test/', 'hst_a.b');
      expect(grant.sessionId, 'S');
      final req = seen.single;
      expect(req.url.toString(), 'https://hub.test/hub/sessions');
      expect(req.headers.containsKey('authorization'), isFalse);
      final body = jsonDecode(req.body) as Map;
      expect(body['token'], 'hst_a.b');
      expect(body['policy'], {'mode': 'unlimited'});
      plan = 'offline';
      await expectLater(
          port.enter('https://hub.test', 'hst_a.b'),
          throwsA(isA<HubEntryRefused>()
              .having((e) => e.reason, 'reason', HubEntryReason.offline)));
      plan = 'closed';
      await expectLater(
          port.enter('https://hub.test', 'hst_a.b'),
          throwsA(isA<HubEntryRefused>()
              .having((e) => e.reason, 'reason', HubEntryReason.gone)));
      plan = 'bad';
      await expectLater(
          port.enter('https://hub.test', 'hst_a.b'),
          throwsA(isA<HubEntryRefused>()
              .having((e) => e.reason, 'reason', HubEntryReason.tokenBad)));
    });
  });
}

class _NoMarket implements HubMarketPort {
  @override
  Future<List<HubChoice>> hubs({String? publisher}) async => const [];
  @override
  Future<List<HubConnectOutcome>> connect(
          {List<String>? listingIds, bool all = false, String? publisher}) async =>
      const [];
}
