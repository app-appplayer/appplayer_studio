import 'dart:async';

import 'package:appplayer_studio/src/base/install/gateway_node/gateway_node.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:mcp_gateway/mcp_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/market_tokens.dart';

/// A board-like MCP server spoken to over a REAL `mcp_client` Client. Answers
/// the wire the way a device does, records what it was asked, and can push
/// notifications.
class _Board implements ClientTransport {
  final StreamController<dynamic> _out = StreamController<dynamic>.broadcast();
  final Completer<void> _closed = Completer<void>();

  List<String> tools = ['led.set'];
  final List<String> subscribed = [];
  final List<String> unsubscribed = [];
  final List<Map<String, dynamic>> calls = [];

  @override
  Stream<dynamic> get onMessage => _out.stream;

  @override
  Future<void> get onClose => _closed.future;

  void notify(String method, Map<String, dynamic> params) =>
      _out.add({'jsonrpc': '2.0', 'method': method, 'params': params});

  @override
  void send(dynamic message) {
    final m = (message as Map).cast<String, dynamic>();
    final id = m['id'];
    if (id == null) return;
    final params = (m['params'] as Map?)?.cast<String, dynamic>() ?? const {};
    Object? result;
    switch (m['method']) {
      case 'initialize':
        result = {
          'protocolVersion': '2025-03-26',
          'serverInfo': {'name': 'board', 'version': '1.0.0'},
          'capabilities': {
            'tools': {'listChanged': true},
            'resources': {'subscribe': true, 'listChanged': true},
            'prompts': {},
          },
        };
      case 'tools/list':
        result = {
          'tools': [
            for (final t in tools)
              {'name': t, 'inputSchema': {'type': 'object'}},
          ],
        };
      case 'tools/call':
        calls.add(params);
        result = {
          'content': [
            {'type': 'text', 'text': 'did ${params['name']}'},
          ],
        };
      case 'resources/list':
        result = {
          'resources': [
            {'uri': 'ui://app', 'name': 'app'},
            {'uri': 'board://temp', 'name': 'temp'},
          ],
        };
      case 'resources/templates/list':
        result = {'resourceTemplates': []};
      case 'resources/read':
        result = {
          'contents': [
            {'uri': params['uri'], 'mimeType': 'application/json', 'text': '{"t":21}'},
          ],
        };
      case 'resources/subscribe':
        subscribed.add(params['uri'] as String);
        result = {};
      case 'resources/unsubscribe':
        unsubscribed.add(params['uri'] as String);
        result = {};
      case 'prompts/list':
        result = {'prompts': []};
      default:
        result = {};
    }
    scheduleMicrotask(
        () => _out.add({'jsonrpc': '2.0', 'id': id, 'result': result}));
  }

  @override
  void close() {
    if (!_closed.isCompleted) _closed.complete();
  }
}

/// What the lending device already has on that connection: its own listeners
/// and subscriptions, shared through one fan-out and one count — the shape
/// brain_kernel's `SharedClientNotifications` / `SharedResourceSubscriptions`
/// give the hosts.
class _Shared {
  _Shared(this.client);
  final Client client;
  final Map<String, List<Future<void> Function(Map<String, dynamic>)>> _byMethod = {};
  final Map<String, int> _counts = {};

  void Function() listen(
      String method, Future<void> Function(Map<String, dynamic>) handler) {
    final list = _byMethod.putIfAbsent(method, () {
      client.onNotification(method, (params) async {
        for (final h in List.of(_byMethod[method]!)) {
          await h(params);
        }
      });
      return [];
    });
    list.add(handler);
    return () => list.remove(handler);
  }

  Future<void> subscribe(String uri) async {
    final n = (_counts[uri] ?? 0) + 1;
    _counts[uri] = n;
    if (n == 1) await client.subscribeResource(uri);
  }

  Future<void> unsubscribe(String uri) async {
    final n = _counts[uri] ?? 0;
    if (n <= 1) {
      _counts.remove(uri);
      await client.unsubscribeResource(uri);
    } else {
      _counts[uri] = n - 1;
    }
  }
}

class _Rig {
  late GatewayRuntime runtime;
  late _Board board;
  late Client held;
  late _Shared shared;
  late ExposedConnection exposed;
  late PeerNodeLink node;
  late Client borrower;
  final List<Map<String, dynamic>> borrowerUpdates = [];

  Future<void> open() async {
    board = _Board();
    held = Client(name: 'a', version: '1.0.0');
    await held.connect(board);
    shared = _Shared(held);

    runtime = GatewayRuntime(GatewayConfig());
    await runtime.start();
    exposed = await ExposedConnection.expose(
      runtime: runtime,
      providerId: 'lamp',
      client: held,
      listen: shared.listen,
      subscribe: shared.subscribe,
      unsubscribe: shared.unsubscribe,
    );

    final market = await TestMarket.create();
    node = PeerNodeLink(runtime: runtime, verifyCaller: market.verifier('peer-node'));
    await node.start();
    final toNode = StreamController<Map<String, dynamic>>.broadcast();
    final toClient = StreamController<String>.broadcast();
    node.attachRelay(toNode.stream, (env) async => toClient.add(env['frame'] as String));
    toNode.add({
      'type': 'open',
      'sessionId': 's1',
      'caller': await market.token(nodeId: 'peer-node'),
    });
    final link = PeerSessionLink(
      relayIncoming: toClient.stream,
      relaySend: (t) =>
          toNode.add({'type': 'frame', 'sessionId': 's1', 'frame': t}),
    );
    final consumer = HubGatewayConsumer(
        incoming: link.incoming, send: link.send, target: 'lamp')
      ..start();
    final transport = HubConsumerTransport(consumer)..forwardEvents();
    borrower = Client(name: 'b', version: '1.0.0');
    await borrower.connect(transport);
    borrower.onNotification('notifications/resources/updated', (p) {
      borrowerUpdates.add(p);
    });
  }

  Future<void> dispose() async {
    borrower.disconnect();
    await exposed.close();
    await node.stop();
    await runtime.dispose();
    held.disconnect();
  }
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  test('the borrowing side lists, calls and reads what the held connection serves',
      () async {
    final rig = _Rig();
    await rig.open();
    addTearDown(rig.dispose);

    expect((await rig.borrower.listTools()).map((t) => t.name), ['led.set']);
    final call = await rig.borrower.callTool('led.set', {'on': true});
    expect((call.content.first as TextContent).text, 'did led.set');
    expect(rig.board.calls.single['arguments'], {'on': true},
        reason: 'the board got the original name and arguments');

    final read = await rig.borrower.readResource('ui://app');
    expect(read.contents.single.text, '{"t":21}');
  });

  test('a resource update reaches the borrower without taking it from the lender',
      () async {
    final rig = _Rig();
    await rig.open();
    addTearDown(rig.dispose);

    final atLender = <Map<String, dynamic>>[];
    rig.shared.listen('notifications/resources/updated', (p) async => atLender.add(p));

    await rig.borrower.subscribeResource('board://temp');
    expect(rig.board.subscribed, ['board://temp']);

    rig.board.notify('notifications/resources/updated', {'uri': 'board://temp'});
    await _settle();
    expect(rig.borrowerUpdates.single['uri'], 'board://temp');
    expect(atLender.single['uri'], 'board://temp',
        reason: "the lending device's own listener still hears it");
  });

  test("releasing the borrower's subscription keeps the lender's own", () async {
    final rig = _Rig();
    await rig.open();
    addTearDown(rig.dispose);

    await rig.shared.subscribe('board://temp'); // the lender's open app
    await rig.borrower.subscribeResource('board://temp');
    await rig.borrower.unsubscribeResource('board://temp');
    await _settle();
    expect(rig.board.unsubscribed, isEmpty,
        reason: 'one subscriber is still on the board');
  });

  test('a tool the board adds shows up on the borrower after list_changed',
      () async {
    final rig = _Rig();
    await rig.open();
    addTearDown(rig.dispose);

    rig.board.tools = ['led.set', 'led.blink'];
    rig.board.notify('notifications/tools/list_changed', const {});
    await _settle();
    expect((await rig.borrower.listTools()).map((t) => t.name),
        containsAll(['led.set', 'led.blink']));
  });

  test('closing the offer ends the provider and releases what it held',
      () async {
    final rig = _Rig();
    await rig.open();
    addTearDown(rig.dispose);

    await rig.borrower.subscribeResource('board://temp');
    await rig.exposed.close();
    expect(rig.board.unsubscribed, ['board://temp']);
    expect(await rig.borrower.listTools(), isEmpty);
  });
}
