/// `kind: mcp` bundle tools open their connection in the kernel's outbound
/// client host (bundle spec 04_Tools §4.5): one connection per server per
/// bundle, reused across calls and tools, closed with the bundle.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/base.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeConnection implements mk.KernelClientConnection {
  _FakeConnection(this.id, this.host);

  @override
  final String id;
  final _FakeClientHost host;
  bool open = true;
  final List<String> called = <String>[];

  @override
  bool get isConnected => open;

  @override
  Future<mk.KernelToolResult> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    called.add(name);
    return mk.KernelToolResult(
      content: <mk.KernelContent>[
        mk.KernelTextContent(text: jsonEncode({'tool': name, 'args': args})),
      ],
      isError: false,
    );
  }

  @override
  Future<void> close() async {
    open = false;
    host._connections.remove(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClientHost implements mk.KernelClientHost {
  final Map<String, _FakeConnection> _connections = <String, _FakeConnection>{};
  final List<
    ({
      String id,
      mk.KernelTransportKind transport,
      String? endpoint,
      Map<String, dynamic>? options,
    })
  >
  dials = [];

  @override
  Future<mk.KernelClientConnection> connect({
    required String id,
    required mk.KernelTransportKind transport,
    String? endpoint,
    Map<String, dynamic>? options,
  }) async {
    final existing = _connections[id];
    if (existing != null && existing.isConnected) return existing;
    dials.add((
      id: id,
      transport: transport,
      endpoint: endpoint,
      options: options,
    ));
    return _connections[id] = _FakeConnection(id, this);
  }

  @override
  Iterable<mk.KernelClientConnection> get connections => _connections.values;

  @override
  Future<void> shutdown() async => _connections.clear();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _bundleDir(List<Map<String, dynamic>> tools) {
  final dir = Directory.systemTemp.createTempSync('vibe_mcp_tool_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  File(p.join(dir.path, 'manifest.json')).writeAsStringSync(
    jsonEncode({
      'manifest': {'id': 'com.test.remote', 'name': 'Remote', 'version': '1'},
      'tools': {'tools': tools},
    }),
  );
  return dir.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('two calls and two tools on one server share one connection; '
      'closing the bundle closes it', () async {
    final root = _bundleDir([
      {
        'name': 'search',
        'kind': 'mcp',
        'target': {'transport': 'http', 'url': 'https://mcp.example.com'},
      },
      {
        'name': 'lookup',
        'kind': 'mcp',
        'target': {
          'transport': 'http',
          'url': 'https://mcp.example.com',
          'tool': 'remote_lookup',
        },
      },
    ]);
    final bundle = readBundleAt(root)!;
    final boot = mk.InProcessKernelServerHost();
    final clients = _FakeClientHost();
    final ctx = HostBundleActivationContext(
      boot: boot,
      tabKey: root,
      bundle: bundle,
      exposedShortId: bundle.shortId,
      clientHost: () => clients,
    );
    for (final t in bundle.tools!.tools) {
      expect((await ctx.registerTool(t)).ok, isTrue);
    }

    final a = await boot.callTool('${ctx.exposedShortId}.search', {'q': 1});
    final b = await boot.callTool('${ctx.exposedShortId}.search', {'q': 2});
    final c = await boot.callTool('${ctx.exposedShortId}.lookup', {'q': 3});
    for (final r in [a, b, c]) {
      expect(
        r.isError,
        isFalse,
        reason: (r.content.single as mk.KernelTextContent).text,
      );
    }

    expect(clients.dials, hasLength(1), reason: 'one connection per server');
    expect(
      clients.dials.single.id,
      'bundle:com.test.remote:https://mcp.example.com',
    );
    expect(
      clients.dials.single.transport,
      mk.KernelTransportKind.streamableHttp,
    );
    expect(clients.connections, hasLength(1));
    final conn = clients.connections.single as _FakeConnection;
    expect(conn.called, [
      'search',
      'search',
      'remote_lookup',
    ], reason: 'target.tool wins over the entry name');

    await ctx.unregisterAll();
    expect(clients.connections, isEmpty, reason: 'closed with the bundle');
  });

  test('stdio targets dial the command through the client host', () async {
    final root = _bundleDir([
      {
        'name': 'local',
        'kind': 'mcp',
        'target': {
          'transport': 'stdio',
          'command': 'my-server',
          'args': ['--flag'],
        },
      },
    ]);
    final bundle = readBundleAt(root)!;
    final boot = mk.InProcessKernelServerHost();
    final clients = _FakeClientHost();
    final ctx = HostBundleActivationContext(
      boot: boot,
      tabKey: root,
      bundle: bundle,
      exposedShortId: bundle.shortId,
      clientHost: () => clients,
    );
    addTearDown(ctx.unregisterAll);
    await ctx.registerTool(bundle.tools!.tools.single);

    final r = await boot.callTool('${ctx.exposedShortId}.local', {});
    expect(r.isError, isFalse);
    final dial = clients.dials.single;
    expect(dial.transport, mk.KernelTransportKind.stdio);
    expect(dial.options, {
      'command': 'my-server',
      'args': ['--flag'],
    });
  });

  test('a host without a client host answers why, tool stays listed', () async {
    final root = _bundleDir([
      {
        'name': 'search',
        'kind': 'mcp',
        'target': {'transport': 'http', 'url': 'https://mcp.example.com'},
      },
    ]);
    final bundle = readBundleAt(root)!;
    final boot = mk.InProcessKernelServerHost();
    final ctx = HostBundleActivationContext(
      boot: boot,
      tabKey: root,
      bundle: bundle,
      exposedShortId: bundle.shortId,
    );
    addTearDown(ctx.unregisterAll);
    expect((await ctx.registerTool(bundle.tools!.tools.single)).ok, isTrue);
    final r = await boot.callTool('${ctx.exposedShortId}.search', {});
    expect(r.isError, isTrue);
    expect(
      (r.content.single as mk.KernelTextContent).text,
      contains('no outbound MCP client'),
    );
  });

  test(
    'a stdio tool whose args name a file the bundle ships is not started',
    () async {
      final root = _bundleDir([
        {
          'name': 'run',
          'kind': 'mcp',
          'target': {
            'transport': 'stdio',
            'command': 'python3',
            'args': [r'${__dirname}/server.py'],
          },
        },
        {
          'name': 'plain',
          'kind': 'mcp',
          'target': {
            'transport': 'stdio',
            'command': 'python3',
            'args': ['/opt/server.py'],
          },
        },
      ]);
      final bundle = readBundleAt(root)!;
      final boot = mk.InProcessKernelServerHost();
      final clients = _FakeClientHost();
      final ctx = HostBundleActivationContext(
        boot: boot,
        tabKey: root,
        bundle: bundle,
        exposedShortId: bundle.shortId,
        clientHost: () => clients,
      );
      for (final t in bundle.tools!.tools) {
        expect((await ctx.registerTool(t)).ok, isTrue);
      }
      final refused = await boot.callTool('${ctx.exposedShortId}.run', {});
      expect(refused.isError, isTrue);
      expect(clients.dials, isEmpty, reason: 'nothing was started');
      final ok = await boot.callTool('${ctx.exposedShortId}.plain', {});
      expect(ok.isError, isFalse);
      expect(clients.dials.single.options!['args'], ['/opt/server.py']);
    },
  );

  group('destructiveHint on a bundle tool (spec 29 6)', () {
    Future<
      ({
        mk.InProcessKernelServerHost boot,
        HostBundleActivationContext ctx,
        _FakeClientHost clients,
        ChromeBridge bridge,
      })
    >
    rig(Map<String, dynamic> annotations, {bool withBridge = true}) async {
      final root = _bundleDir([
        {
          'name': 'wipe',
          'kind': 'mcp',
          'annotations': annotations,
          'target': {'transport': 'http', 'url': 'https://mcp.example.com'},
        },
      ]);
      final bundle = readBundleAt(root)!;
      final boot = mk.InProcessKernelServerHost();
      final clients = _FakeClientHost();
      final bridge = ChromeBridge();
      final ctx = HostBundleActivationContext(
        boot: boot,
        tabKey: root,
        bundle: bundle,
        exposedShortId: bundle.shortId,
        clientHost: () => clients,
        chromeBridge: withBridge ? bridge : null,
      );
      for (final t in bundle.tools!.tools) {
        expect((await ctx.registerTool(t)).ok, isTrue);
      }
      return (boot: boot, ctx: ctx, clients: clients, bridge: bridge);
    }

    test('Deny stops the call, Allow lets it through, each is asked', () async {
      final r = await rig({'destructiveHint': true});
      final asked = <String>[];
      var pick = 0;
      r.bridge.prompt = ({required question, options}) async {
        asked.add(question);
        expect(options, ['Deny', 'Allow']);
        return pick;
      };
      final name = '${r.ctx.exposedShortId}.wipe';
      final denied = await r.boot.callTool(name, {});
      expect(denied.isError, isTrue);
      expect(r.clients.dials, isEmpty);
      pick = 1;
      final allowed = await r.boot.callTool(name, {});
      expect(allowed.isError, isFalse);
      expect(asked, hasLength(2));
      expect(r.clients.dials, hasLength(1));
    });

    test('a host that cannot ask does not run the tool', () async {
      final r = await rig({'destructiveHint': true});
      final out = await r.boot.callTool('${r.ctx.exposedShortId}.wipe', {});
      expect(out.isError, isTrue);
      expect(r.clients.dials, isEmpty);
    });

    test('readOnlyHint or none adds no question', () async {
      for (final a in [
        {'readOnlyHint': true},
        <String, dynamic>{},
      ]) {
        final r = await rig(a);
        r.bridge.prompt = ({required question, options}) async {
          fail('asked about a tool that is not marked destructive');
        };
        final out = await r.boot.callTool('${r.ctx.exposedShortId}.wipe', {});
        expect(out.isError, isFalse);
      }
    });
  });
}
