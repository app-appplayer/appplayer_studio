/// `mcp.discover_boards` + `mcp.connect_ble_board` — the Studio wiring over
/// the vendored device_discovery (spec 17) and ble_transport (spec 16)
/// recipes. Scanners/probe/radio are driven through their injectable seams
/// (fake subclasses + FakeBleLink), and the BLE connect runs the WHOLE path
/// end to end against a real mcp_server simulated board — no hardware.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:appplayer_studio/base.dart' show registerDiscoveryTools;
import 'package:appplayer_studio/src/base/bridge/ble_transport/ble_transport.dart';
import 'package:appplayer_studio/src/base/bridge/device_discovery/device_discovery.dart'
    hide NewlineJsonFramer;
import 'package:brain_kernel/brain_kernel.dart' as fb;
import 'package:brain_kernel/mcp_host.dart' show McpClientKernelHost;
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart' show ClientTransport;
import 'package:mcp_server/mcp_server.dart' as srv;

import 'fake_ble_link.dart';

/// mDNS scanner fake — emits a scripted candidate list.
class _FakeMdnsScanner extends MdnsBoardScanner {
  _FakeMdnsScanner(this.candidates);
  final List<MdnsBoardCandidate> candidates;

  @override
  Stream<MdnsBoardCandidate> scan({
    Duration timeout = const Duration(seconds: 5),
    Duration recordTimeout = const Duration(seconds: 2),
  }) =>
      Stream.fromIterable(candidates);
}

/// BLE scanner fake — emits a scripted candidate list (with repeats).
class _FakeBleScanner extends BleBoardScanner {
  _FakeBleScanner(this.candidates);
  final List<BleBoardCandidate> candidates;

  @override
  Stream<BleBoardCandidate> scan({
    Duration timeout = const Duration(seconds: 15),
  }) =>
      Stream.fromIterable(candidates);
}

MdnsBoardCandidate _cand(String name, String proto, {int port = 6270}) =>
    MdnsBoardCandidate(
      host: '192.168.0.10',
      port: port,
      instanceName: name,
      txt: MdnsTxt.parse('proto=$proto\nid=acme.$name\nv=0.1.0'),
    );

/// Capture-only registry: records exposed names + handlers so tests invoke
/// tools directly (same pattern as extension_connect_tool_test).
({fb.HostToolRegistry registry, Map<String, fb.KernelToolHandler> handlers})
    _captureRegistry(fb.KernelApp app, String label) {
  final handlers = <String, fb.KernelToolHandler>{};
  final endpoint = app.addEndpoint(label: label, appName: label);
  endpoint.server.register();
  final registry = fb.HostToolRegistry(
    endpoint: endpoint.server,
    attachToDispatcher: (name, handler) => handlers[name] = handler,
    detachFromDispatcher: (_) {},
  );
  return (registry: registry, handlers: handlers);
}

Future<Map<String, dynamic>> _call(
  fb.KernelToolHandler handler,
  Map<String, dynamic> args,
) async {
  final result = await handler(args);
  final text = (result.content.first as fb.KernelTextContent).text;
  return jsonDecode(text) as Map<String, dynamic>;
}

/// Board side of the fake radio — a real mcp_server whose byte pipe is the
/// FakeBleLink (RX writes reassembled by the recipe framer; responses
/// notified back chunked at the ATT MTU-23 floor).
class _BoardFakeBleLink extends FakeBleLink {
  void Function(List<int> chunk)? onWrite;

  @override
  Future<void> writeRxChunk(List<int> chunk) async {
    await super.writeRxChunk(chunk);
    onWrite?.call(List<int>.from(chunk));
  }
}

class _FakeBleBoardTransport implements srv.ServerTransport {
  _FakeBleBoardTransport(this._link) {
    final framer = NewlineJsonFramer(
      onMessage: _messages.add,
      onError: _messages.addError,
    );
    _link.onWrite = framer.feed;
  }

  static const int _notifyChunkSize = bleDefaultAttMtu - bleAttHeaderOverhead;

  final _BoardFakeBleLink _link;
  final _messages = StreamController<dynamic>.broadcast();
  final _closed = Completer<void>();

  @override
  Stream<dynamic> get onMessage => _messages.stream;

  @override
  Future<void> get onClose => _closed.future;

  @override
  void send(dynamic message) {
    final frame = NewlineJsonFramer.encodeFrame(message);
    for (var offset = 0; offset < frame.length; offset += _notifyChunkSize) {
      final end = math.min(offset + _notifyChunkSize, frame.length);
      _link.notifyBytes(frame.sublist(offset, end));
    }
  }

  @override
  void close() {
    if (!_closed.isCompleted) _closed.complete();
    if (!_messages.isClosed) _messages.close();
    _link.dropConnection();
  }
}

/// One accepted TCP socket as an mcp_server transport — newline JSON-RPC
/// both ways (the board wire), one instance per connection.
class _SocketBoardTransport implements srv.ServerTransport {
  _SocketBoardTransport(this._socket) {
    final framer = NewlineJsonFramer(
      onMessage: _messages.add,
      onError: _messages.addError,
    );
    _socket.listen(
      framer.feed,
      onDone: close,
      onError: (Object _) => close(),
    );
  }

  final Socket _socket;
  final _messages = StreamController<dynamic>.broadcast();
  final _closed = Completer<void>();

  @override
  Stream<dynamic> get onMessage => _messages.stream;

  @override
  Future<void> get onClose => _closed.future;

  @override
  void send(dynamic message) {
    _socket.add(NewlineJsonFramer.encodeFrame(message));
  }

  @override
  void close() {
    if (!_closed.isCompleted) _closed.complete();
    if (!_messages.isClosed) _messages.close();
    _socket.destroy();
  }
}

void main() {
  late Directory tmpDir;
  late fb.KernelApp app;
  late McpClientKernelHost clientHost;

  setUpAll(() async {
    tmpDir = Directory.systemTemp.createTempSync('vibe_studio_disc_');
    clientHost = McpClientKernelHost();
    app = await fb.KernelApp.boot(
      workspaceId: 'vibe_studio_disc_test',
      kvStorage: fb.KvStoragePortAdapter(rootDir: tmpDir.path),
      bundleRegistryStorageDir: tmpDir.path,
      clientHost: clientHost,
    );
  });

  tearDownAll(() async {
    await clientHost.shutdown();
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {
      /* best-effort cleanup */
    }
  });

  test('registers both discovery tools under mcp.*', () {
    final cap = _captureRegistry(app, 'disc-reg');
    final discovery = registerDiscoveryTools(cap.registry, clientHost);
    expect(
      discovery.toolNames,
      containsAll(<String>['mcp.discover_boards', 'mcp.connect_ble_board']),
    );
    expect(cap.handlers.keys, containsAll(discovery.toolNames));
  });

  test(
      'mdns discover: probe-confirmed candidates reported, probe failures '
      'and unknown proto dropped, http reported unprobed', () async {
    final cap2 = _captureRegistry(app, 'disc-mdns');
    registerDiscoveryTools(
      cap2.registry,
      clientHost,
      mdnsScanner: _FakeMdnsScanner([
        _cand('good', 'ndjson'),
        _cand('dead', 'ndjson', port: 6271),
        _cand('httpnode', 'http'),
        _cand('weird', 'gopher'),
      ]),
      // Probes run in candidate order ('good' then 'dead'); building the
      // transport would open a real socket, so the fake never calls it.
      probe: () {
        var probes = 0;
        return ({
          required FutureOr<ClientTransport> Function() buildTransport,
          Duration timeout = const Duration(seconds: 10),
          String clientName = '',
          String clientVersion = '',
        }) async {
          probes++;
          if (probes > 1) return null; // 'dead' fails Stage 2
          return const BoardIdentity(
            id: 'acme.good',
            name: 'Good Board',
            version: '0.1.0',
            entryPoint: 'ui://app',
          );
        };
      }(),
    );
    final out = await _call(
      cap2.handlers['mcp.discover_boards']!,
      const {'source': 'mdns'},
    );
    expect(out['ok'], isTrue);
    expect(out['count'], 2);
    final candidates = (out['candidates'] as List).cast<Map>();
    final confirmed =
        candidates.singleWhere((c) => c['proto'] == 'ndjson');
    expect(confirmed['probed'], isTrue);
    expect(confirmed['name'], 'Good Board');
    expect(confirmed['id'], 'acme.good');
    expect(confirmed['entryPoint'], 'ui://app');
    expect(
      (confirmed['connectHint'] as Map)['tool'],
      'mcp.connect_extension',
    );
    final http = candidates.singleWhere((c) => c['proto'] == 'http');
    expect(http['probed'], isFalse);
    // 'dead' (probe fail) and 'weird' (unknown proto) are absent.
    expect(candidates.map((c) => c['instanceName']),
        isNot(contains('dead')));
    expect(candidates.map((c) => c['instanceName']),
        isNot(contains('weird')));
  });

  test('ble discover: dedupes by deviceId and hands the connect hint',
      () async {
    final cap = _captureRegistry(app, 'disc-ble');
    registerDiscoveryTools(
      cap.registry,
      clientHost,
      bleScanner: _FakeBleScanner(const [
        BleBoardCandidate(deviceId: 'dev-1', localName: 'Board A', rssi: -40),
        BleBoardCandidate(deviceId: 'dev-1', localName: 'Board A', rssi: -42),
        BleBoardCandidate(deviceId: 'dev-2', localName: '', rssi: 0),
      ]),
    );
    final out = await _call(
      cap.handlers['mcp.discover_boards']!,
      const {'source': 'ble'},
    );
    expect(out['ok'], isTrue);
    expect(out['count'], 2);
    final first = (out['candidates'] as List).first as Map;
    expect(first['deviceId'], 'dev-1');
    expect((first['connectHint'] as Map)['tool'], 'mcp.connect_ble_board');
  });

  test('usb discover: every port probed, only confirmed boards surface',
      () async {
    final cap = _captureRegistry(app, 'disc-usb');
    var probes = 0;
    registerDiscoveryTools(
      cap.registry,
      clientHost,
      enumerateSerialPorts: () => const [
        (portName: '/dev/cu.usbmodem1', description: 'Board'),
        (portName: '/dev/cu.usbserial7', description: 'GPS puck'),
      ],
      probe: ({
        required FutureOr<ClientTransport> Function() buildTransport,
        Duration timeout = const Duration(seconds: 10),
        String clientName = '',
        String clientVersion = '',
      }) async {
        probes++;
        if (probes > 1) return null; // second port is not a board
        return const BoardIdentity(
          id: 'acme.usb',
          name: 'USB Board',
          version: '1.0.0',
        );
      },
    );
    final out = await _call(
      cap.handlers['mcp.discover_boards']!,
      const {'source': 'usb'},
    );
    expect(out['ok'], isTrue);
    expect(out['count'], 1);
    expect(probes, 2, reason: 'every enumerated port gets a probe');
    final c = (out['candidates'] as List).single as Map;
    expect(c['portName'], '/dev/cu.usbmodem1');
    expect(c['id'], 'acme.usb');
    final hint = c['connectHint'] as Map;
    expect(hint['transport'], 'serial');
    expect((hint['options'] as Map)['port'], '/dev/cu.usbmodem1');
  });

  test('directory discover: unconfigured errors actionably; configured '
      'probe-confirms tcp and reports http unprobed', () async {
    final bare = _captureRegistry(app, 'disc-dir0');
    registerDiscoveryTools(bare.registry, clientHost);
    final err = await _call(
      bare.handlers['mcp.discover_boards']!,
      const {'source': 'directory'},
    );
    expect(err['ok'], isFalse);
    expect(err['error'], contains('Settings'));

    final cap = _captureRegistry(app, 'disc-dir');
    registerDiscoveryTools(
      cap.registry,
      clientHost,
      directoryConfig: () =>
          const DirectoryConfig(host: 'ldap.test', baseDN: 'dc=test'),
      directoryScanner: DirectoryBoardScanner(
        search: (config) async => [
          {
            'labeledURI': ['tcp://10.0.0.5:6270 lab board'],
            'cn': ['lab-board'],
          },
          {
            'labeledURI': ['https://mcp.example.org/mcp cloud node'],
            'cn': ['cloud-node'],
          },
          {
            'labeledURI': ['mailto:ops@example.org'],
            'cn': ['not-a-board'],
          },
        ],
      ),
      probe: ({
        required FutureOr<ClientTransport> Function() buildTransport,
        Duration timeout = const Duration(seconds: 10),
        String clientName = '',
        String clientVersion = '',
      }) async =>
          const BoardIdentity(
            id: 'acme.lab',
            name: 'Lab Board',
            version: '2.0.0',
          ),
    );
    final out = await _call(
      cap.handlers['mcp.discover_boards']!,
      const {'source': 'directory'},
    );
    expect(out['ok'], isTrue);
    expect(out['count'], 2);
    final candidates = (out['candidates'] as List).cast<Map>();
    final tcp = candidates.singleWhere((c) => c['probed'] == true);
    expect(tcp['id'], 'acme.lab');
    expect((tcp['connectHint'] as Map)['transport'], 'tcp');
    expect(
      ((tcp['connectHint'] as Map)['options'] as Map)['host'],
      '10.0.0.5',
    );
    final http = candidates.singleWhere((c) => c['probed'] == false);
    expect(http['endpoint'], 'https://mcp.example.org/mcp');
    expect(candidates.map((c) => c['name']), isNot(contains('not-a-board')));
  });

  test(
      'sweep: enabled sources scanned, auto-connect lands the confirmed '
      'board in the kernel registry (REAL probe + REAL tcp board), rerun '
      'skips the live connection', () async {
    // A real board that accepts SEQUENTIAL connections (probe closes, the
    // auto-connect opens a fresh socket — exactly the production flow a
    // conforming node handles; mcp_bridge's TcpServerTransport is
    // single-connection, so the test board runs its own accept loop with
    // one mcp_server per accepted socket).
    final listener = await ServerSocket.bind('localhost', 0);
    final boardPort = listener.port;
    final boardSub = listener.listen((socket) {
      final board = srv.Server(
        name: 'sweep-board',
        version: '1.0.0',
        capabilities:
            srv.ServerCapabilities.simple(tools: true, resources: true),
      );
      board.addTool(
        name: 'led.set',
        description: 'set the on-board LED',
        inputSchema: const {'type': 'object'},
        handler: (args) async =>
            const srv.CallToolResult(content: [srv.TextContent(text: 'ok')]),
      );
      board.addResource(
        uri: 'bundle://manifest.json',
        name: 'manifest',
        description: 'board manifest',
        mimeType: 'application/json',
        handler: (uri, params) async => srv.ReadResourceResult(contents: [
          srv.ResourceContentInfo(
            uri: uri,
            mimeType: 'application/json',
            text: jsonEncode({
              'manifest': {
                'id': 'acme.sweep',
                'name': 'Sweep Board',
                'version': '1.0.0',
                'entryPoint': 'ui://app',
              },
            }),
          ),
        ]),
      );
      board.connect(_SocketBoardTransport(socket));
    });
    addTearDown(() async {
      await boardSub.cancel();
      await listener.close();
    });

    final cap = _captureRegistry(app, 'disc-sweep');
    final discovery = registerDiscoveryTools(
      cap.registry,
      clientHost,
      // Stage 1 faked (mDNS multicast is environment-dependent in tests);
      // Stage 2 probe + connect run REAL against the board above.
      mdnsScanner: _FakeMdnsScanner([
        MdnsBoardCandidate(
          host: 'localhost',
          port: boardPort,
          instanceName: 'sweep-board',
          txt: MdnsTxt.parse('proto=ndjson\nid=acme.sweep\nv=1.0.0'),
        ),
      ]),
    );
    final report = await discovery.sweep(
      usb: false,
      mdns: true,
      directory: false,
      autoConnect: true,
    );
    expect(report['candidates'], 1);
    expect(report['connected'], ['board:acme.sweep']);
    expect(report['errors'], isEmpty);
    final conn = clientHost.connections
        .singleWhere((c) => c.id == 'board:acme.sweep');
    expect(conn.isConnected, isTrue);
    final tools = await conn.listTools();
    expect(tools.map((t) => t.name), contains('led.set'));

    // Second sweep: the live connection is left alone, not reconnected.
    final again = await discovery.sweep(
      usb: false,
      mdns: true,
      directory: false,
      autoConnect: true,
    );
    expect(again['connected'], isEmpty);
    expect(again['skipped'], ['board:acme.sweep']);
  });

  test(
      'connect_ble_board: full spec-16 path to a simulated mcp_server board '
      '(MTU-23 chunking) lands in the kernel registry and is driveable',
      () async {
    final link = _BoardFakeBleLink()..negotiatedMtu = bleDefaultAttMtu;
    final board = srv.Server(
      name: 'ble-board-sim',
      version: '1.0.0',
      capabilities:
          srv.ServerCapabilities.simple(tools: true, resources: true),
    );
    board.addTool(
      name: 'led.set',
      description: 'set the on-board LED',
      inputSchema: const {'type': 'object'},
      handler: (args) async =>
          const srv.CallToolResult(content: [srv.TextContent(text: 'ok')]),
    );
    board.connect(_FakeBleBoardTransport(link));

    final cap = _captureRegistry(app, 'disc-connect');
    registerDiscoveryTools(
      cap.registry,
      clientHost,
      bleLinkFor: (deviceId) => link,
    );
    final out = await _call(
      cap.handlers['mcp.connect_ble_board']!,
      const {'deviceId': 'fake-board'},
    );
    expect(out['ok'], isTrue);
    expect(out['id'], 'ble:fake-board');
    expect(out['connected'], isTrue);

    // The connection is in the kernel client-host registry → the standard
    // mcp.* drive path reaches the board.
    final conn = clientHost.connections
        .singleWhere((c) => c.id == 'ble:fake-board');
    final tools = await conn.listTools();
    expect(tools.map((t) => t.name), contains('led.set'));
    final result = await conn.callTool('led.set', const {});
    expect(result.isError ?? false, isFalse);
  });

  test(
      'connectCandidate: a tcp candidate connects through the extension seam '
      'under board:<id> and is driveable (REAL tcp board)', () async {
    final listener = await ServerSocket.bind('localhost', 0);
    final boardPort = listener.port;
    final boardSub = listener.listen((socket) {
      final board = srv.Server(
        name: 'cc-tcp-board',
        version: '1.0.0',
        capabilities: srv.ServerCapabilities.simple(tools: true),
      );
      board.addTool(
        name: 'led.set',
        description: 'set the on-board LED',
        inputSchema: const {'type': 'object'},
        handler: (args) async =>
            const srv.CallToolResult(content: [srv.TextContent(text: 'ok')]),
      );
      board.connect(_SocketBoardTransport(socket));
    });
    addTearDown(() async {
      await boardSub.cancel();
      await listener.close();
    });

    final cap = _captureRegistry(app, 'cc-tcp');
    final discovery = registerDiscoveryTools(cap.registry, clientHost);
    final id = await discovery.connectCandidate(<String, dynamic>{
      'source': 'mdns',
      'id': 'acme.cc',
      'connectHint': <String, dynamic>{
        'tool': 'mcp.connect_extension',
        'transport': 'tcp',
        'options': <String, dynamic>{'host': 'localhost', 'port': boardPort},
      },
    });
    expect(id, 'board:acme.cc');
    final conn =
        clientHost.connections.singleWhere((c) => c.id == 'board:acme.cc');
    expect(conn.isConnected, isTrue);
    final tools = await conn.listTools();
    expect(tools.map((t) => t.name), contains('led.set'));
  });

  test(
      'connectCandidate: a ble candidate connects through the GATT seam under '
      'ble:<deviceId> (simulated mcp_server board)', () async {
    final link = _BoardFakeBleLink()..negotiatedMtu = bleDefaultAttMtu;
    final board = srv.Server(
      name: 'cc-ble-board',
      version: '1.0.0',
      capabilities: srv.ServerCapabilities.simple(tools: true),
    );
    board.addTool(
      name: 'led.set',
      description: 'set the on-board LED',
      inputSchema: const {'type': 'object'},
      handler: (args) async =>
          const srv.CallToolResult(content: [srv.TextContent(text: 'ok')]),
    );
    board.connect(_FakeBleBoardTransport(link));

    final cap = _captureRegistry(app, 'cc-ble');
    final discovery = registerDiscoveryTools(
      cap.registry,
      clientHost,
      bleLinkFor: (_) => link,
    );
    final id = await discovery.connectCandidate(<String, dynamic>{
      'source': 'ble',
      'deviceId': 'cc-dev',
      'connectHint': <String, dynamic>{
        'tool': 'mcp.connect_ble_board',
        'deviceId': 'cc-dev',
      },
    });
    expect(id, 'ble:cc-dev');
    final conn =
        clientHost.connections.singleWhere((c) => c.id == 'ble:cc-dev');
    final tools = await conn.listTools();
    expect(tools.map((t) => t.name), contains('led.set'));
  });

  test(
      'connectCandidate: a candidate without a connectHint is rejected '
      '(http nodes attach by endpoint instead)', () async {
    final cap = _captureRegistry(app, 'cc-nohint');
    final discovery = registerDiscoveryTools(cap.registry, clientHost);
    await expectLater(
      discovery.connectCandidate(<String, dynamic>{
        'source': 'mdns',
        'proto': 'http',
        'host': '10.0.0.9',
        'port': 8080,
      }),
      throwsA(isA<StateError>()),
    );
  });
}
