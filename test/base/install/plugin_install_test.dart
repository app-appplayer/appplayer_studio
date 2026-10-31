/// `plugin.*` host install (vendored `plugin_host` recipe, platform spec 29).
/// Covers the surface, the approval and consent rules, secrets kept out of the
/// stored file, and a stored registration that cannot be restored staying
/// listed with its reason. The server mirror uses a fake client host.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_secure/appplayer_secure.dart' show SecureStorage;
import 'package:flutter_test/flutter_test.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:appplayer_studio/src/base/install/host_approval.dart';
import 'package:appplayer_studio/src/base/install/plugin_install.dart';
import 'package:appplayer_studio/src/base/install/plugin_host/plugin_host.dart';

Map<String, dynamic> _json(mk.KernelToolResult r) =>
    jsonDecode(r.content.whereType<mk.KernelTextContent>().first.text)
        as Map<String, dynamic>;

class _FakeConn implements mk.KernelClientConnection {
  _FakeConn(this.id);
  @override
  final String id;
  bool open = true;

  @override
  bool get isConnected => open;
  @override
  Future<void> subscribeResource(String uri) async {}
  @override
  Future<void> unsubscribeResource(String uri) async {}
  @override
  Stream<String> get resourceUpdates => const Stream<String>.empty();
  @override
  Future<List<mk.KernelToolDescriptor>> listTools() async => [
    for (final n in ['check', 'fix'])
      mk.KernelToolDescriptor(
        name: n,
        description: 'Tool $n.',
        inputSchema: const {'type': 'object'},
      ),
  ];
  @override
  Future<mk.KernelToolResult> callTool(
    String name,
    Map<String, dynamic> args,
  ) async => mk.KernelToolResult(
    content: [
      mk.KernelTextContent(text: jsonEncode({'echo': name})),
    ],
  );
  @override
  Future<List<mk.KernelResourceDescriptor>> listResources() async => const [];
  @override
  Future<mk.KernelReadResourceResult> readResource(String uri) async =>
      throw UnimplementedError();
  @override
  Future<void> close() async => open = false;
}

class _FakeClientHost implements mk.KernelClientHost {
  final List<Map<String, dynamic>> connects = <Map<String, dynamic>>[];
  final List<_FakeConn> conns = <_FakeConn>[];
  bool refuse = false;

  @override
  Future<mk.KernelClientConnection> connect({
    required String id,
    required mk.KernelTransportKind transport,
    String? endpoint,
    Map<String, dynamic>? options,
  }) async {
    if (refuse) throw StateError('connection refused');
    connects.add(<String, dynamic>{
      'id': id,
      'transport': transport.name,
      'endpoint': endpoint,
      'options': options,
    });
    final c = _FakeConn(id);
    conns.add(c);
    return c;
  }

  @override
  Iterable<mk.KernelClientConnection> get connections => conns;
  @override
  Future<void> shutdown() async {}
}

class _MemVault implements SecureStorage {
  final Map<String, String> data = <String, String>{};
  @override
  Future<String?> read(String key, {String namespace = 'default'}) async =>
      data['$namespace/$key'];
  @override
  Future<void> write(
    String key,
    String value, {
    String namespace = 'default',
  }) async => data['$namespace/$key'] = value;
  @override
  Future<void> delete(String key, {String namespace = 'default'}) async =>
      data.remove('$namespace/$key');
  @override
  Future<bool> exists(String key, {String namespace = 'default'}) async =>
      data.containsKey('$namespace/$key');
  @override
  Future<void> wipeNamespace(String namespacePrefix) async {}
  @override
  Future<void> wipeAll() async => data.clear();
  @override
  Future<List<String>> listKeys({
    String namespace = 'default',
    String? prefix,
  }) async => const <String>[];
}

void main() {
  late Directory tmp;
  late String store;
  late List<ApprovalRequest> asked;
  late bool answer;

  HostApprover approver() => HostApprover(
    ask: (r) async {
      asked.add(r);
      return answer;
    },
    approver: 'tester',
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('plugin_test_');
    store = '${tmp.path}/plugins.json';
    asked = <ApprovalRequest>[];
    answer = true;
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// A fresh host over the same store file — a boot.
  ({mk.InProcessKernelServerHost boot, _FakeClientHost client}) boot({
    HostApprover? ask,
    bool preApproved = false,
    bool adopt = false,
    SecureStorage? vault,
    ActivateBundlePlugin? activateBundle,
    DeactivateBundlePlugin? deactivateBundle,
    _FakeClientHost? client,
  }) {
    final b = mk.InProcessKernelServerHost();
    final registry = mk.HostToolRegistry(
      endpoint: b,
      attachToDispatcher: (_, _) {},
      detachFromDispatcher: (_) {},
    );
    final host = client ?? _FakeClientHost();
    registerPluginTools(
      registry,
      clientHost: host,
      storePath: store,
      approver: ask,
      preApproved: preApproved,
      adoptUnconsented: adopt,
      vault: vault,
      activateBundle: activateBundle,
      deactivateBundle: deactivateBundle,
    );
    return (boot: b, client: host);
  }

  Future<mk.KernelToolResult> register(
    mk.InProcessKernelServerHost b,
    Map<String, dynamic> args,
  ) => b.callTool('plugin.register', args);

  Future<Map<String, dynamic>> list(mk.InProcessKernelServerHost b) async =>
      _json(await b.callTool('plugin.list', const <String, dynamic>{}));

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  const stdio = <String, dynamic>{
    'id': 'kicad',
    'kind': 'server',
    'transport': 'stdio',
    'options': <String, dynamic>{
      'command': 'python3',
      'args': <String>['/x/server.py'],
    },
  };

  test('plugin.* surface lands on the registry', () {
    final b = boot().boot;
    final names = b.toolDefinitions.map((t) => t.name).toSet();
    expect(
      names,
      containsAll(<String>[
        'plugin.register',
        'plugin.unregister',
        'plugin.reconnect',
        'plugin.list',
      ]),
    );
  });

  test('a host with nobody to ask refuses to register', () async {
    final b = boot().boot;
    final r = await register(b, stdio);
    expect(r.isError, isTrue);
    expect(_json(r)['code'], 'plugin.not_approved');
    expect(File(store).existsSync(), isFalse);
  });

  test(
    'registering asks once with the whole command and saves the consent',
    () async {
      final c = boot(ask: approver());
      final r = await register(c.boot, <String, dynamic>{
        ...stdio,
        'tools': <String>['check'],
      });
      expect(r.isError, isFalse, reason: '${_json(r)}');
      expect(_json(r)['tools'], <String>['kicad.check']);
      expect(asked, hasLength(1));
      expect(asked.single.kind, 'plugin');
      expect(asked.single.summary, contains('python3 /x/server.py'));
      expect(asked.single.summary, contains('only check'));
      final saved = jsonDecode(File(store).readAsStringSync()) as List;
      expect((saved.single['consent'] as Map)['by'], 'tester');
    },
  );

  test('a refused registration connects and saves nothing', () async {
    answer = false;
    final c = boot(ask: approver());
    final r = await register(c.boot, stdio);
    expect(_json(r)['code'], 'plugin.not_approved');
    expect(c.client.connects, isEmpty);
    expect(File(store).existsSync(), isFalse);
  });

  test('unregistering is not asked', () async {
    final c = boot(ask: approver());
    await register(c.boot, stdio);
    asked.clear();
    final r = await c.boot.callTool('plugin.unregister', {'id': 'kicad'});
    expect(r.isError, isFalse);
    expect(asked, isEmpty);
    expect((await list(c.boot))['plugins'], isEmpty);
  });

  test('boot restores a source whose consent still matches', () async {
    await register(boot(ask: approver()).boot, stdio);
    final again = boot(ask: approver());
    await settle();
    final plugin = (await list(again.boot))['plugins'].single;
    expect(plugin['status'], 'connected');
    expect(plugin['tools'], <String>['kicad.check', 'kicad.fix']);
    expect(asked, hasLength(1), reason: 'restore does not ask again');
  });

  test(
    'a changed command is not attached at boot: not-approved, listed',
    () async {
      await register(boot(ask: approver()).boot, stdio);
      final saved = jsonDecode(File(store).readAsStringSync()) as List;
      (saved.single['options']['args'] as List)[0] = '/y/other.py';
      File(store).writeAsStringSync(jsonEncode(saved));
      final again = boot(ask: approver());
      await settle();
      final plugin = (await list(again.boot))['plugins'].single;
      expect(plugin['status'], 'unavailable');
      expect(plugin['unavailable']['wire'], 'not-approved');
      expect(again.client.connects, isEmpty);
    },
  );

  test(
    'a stored source with no consent is not attached unless pre-approved',
    () async {
      File(store).writeAsStringSync(
        jsonEncode([
          {...stdio, 'transport': 'stdio'},
        ]),
      );
      final strict = boot(ask: approver());
      await settle();
      expect(
        (await list(strict.boot))['plugins'].single['unavailable']['wire'],
        'not-approved',
      );
      final lenient = boot(preApproved: true);
      await settle();
      expect(
        (await list(lenient.boot))['plugins'].single['status'],
        'connected',
      );
    },
  );

  test('a restore that fails stays listed with the reason', () async {
    await register(boot(ask: approver()).boot, stdio);
    final down = _FakeClientHost()..refuse = true;
    final again = boot(ask: approver(), client: down);
    await settle();
    final plugin = (await list(again.boot))['plugins'].single;
    expect(plugin['unavailable']['wire'], 'unreachable');
    expect(plugin['unavailable']['detail'], contains('connection refused'));
    expect(File(store).readAsStringSync(), contains('kicad'));
  });

  group('plugin.reconnect', () {
    test('brings a plugin that was down back, without asking', () async {
      await register(boot(ask: approver()).boot, stdio);
      final down = _FakeClientHost()..refuse = true;
      final again = boot(ask: approver(), client: down);
      await settle();
      expect(
        (await list(again.boot))['plugins'].single['status'],
        'unavailable',
      );
      asked.clear();
      down.refuse = false;
      final r = _json(
        await again.boot.callTool('plugin.reconnect', {'id': 'kicad'}),
      );
      expect(r['status'], 'connected');
      expect(r['tools'], <String>['kicad.check', 'kicad.fix']);
      expect(asked, isEmpty);
      expect((await list(again.boot))['plugins'].single['status'], 'connected');
    });

    test(
      'a registration whose approval no longer matches is not attached',
      () async {
        await register(boot(ask: approver()).boot, stdio);
        final saved = jsonDecode(File(store).readAsStringSync()) as List;
        (saved.single['options']['args'] as List)[0] = '/y/other.py';
        File(store).writeAsStringSync(jsonEncode(saved));
        final again = boot(ask: approver());
        await settle();
        final r = _json(
          await again.boot.callTool('plugin.reconnect', {'id': 'kicad'}),
        );
        expect(r['ok'], isFalse);
        expect(r['unavailable']['wire'], 'not-approved');
        expect(again.client.connects, isEmpty);
      },
    );

    test('an id that is not registered is plugin.bad_input', () async {
      final r = await boot(
        ask: approver(),
      ).boot.callTool('plugin.reconnect', {'id': 'nope'});
      expect(_json(r)['code'], 'plugin.bad_input');
    });
  });

  group('registrations stored before consents existed (adoptUnconsented)', () {
    Future<void> legacy(String command) async {
      File(store).writeAsStringSync(
        jsonEncode([
          {
            'id': 'kicad',
            'kind': 'server',
            'transport': 'stdio',
            'options': {
              'command': command,
              'args': ['/x/server.py'],
            },
          },
        ]),
      );
    }

    test('are attached once and given a consent on record', () async {
      await legacy('python3');
      final c = boot(adopt: true);
      await settle();
      final p = (await list(c.boot))['plugins'].single;
      expect(p['status'], 'connected');
      expect(
        File(store).readAsStringSync(),
        contains('adopted-earlier-registration'),
      );
    });

    test('a command changed afterwards is no longer covered', () async {
      await legacy('python3');
      boot(adopt: true);
      await settle();
      final saved = jsonDecode(File(store).readAsStringSync()) as List;
      final entry = saved.single as Map;
      (entry['options'] as Map)['command'] = 'evil';
      File(store).writeAsStringSync(jsonEncode(saved));
      final c = boot(adopt: true);
      await settle();
      final p = (await list(c.boot))['plugins'].single;
      expect(p['unavailable']['wire'], 'not-approved');
    });

    test('without the policy they stay unapproved', () async {
      await legacy('python3');
      final c = boot();
      await settle();
      final p = (await list(c.boot))['plugins'].single;
      expect(p['unavailable']['wire'], 'not-approved');
    });
  });

  test('a missing bundle at boot is listed as bundle-missing', () async {
    final first = boot(
      ask: approver(),
      activateBundle: (s) async => <String>['t'],
    );
    final r = await register(first.boot, {
      'id': 'notes',
      'kind': 'bundle',
      'endpoint': '/gone.mbd',
    });
    expect(r.isError, isFalse, reason: '${_json(r)}');
    final again = boot(
      ask: approver(),
      activateBundle: (s) async => throw StateError('no such bundle'),
    );
    await settle();
    final plugin = (await list(again.boot))['plugins'].single;
    expect(plugin['unavailable']['wire'], 'bundle-missing');
  });

  test(
    'bundle kind without activation wired is plugin.bundle_unwired',
    () async {
      final r = await register(boot(ask: approver()).boot, {
        'id': 'b',
        'kind': 'bundle',
        'endpoint': '/p.mbd',
      });
      expect(_json(r)['code'], 'plugin.bundle_unwired');
      expect(asked, isEmpty, reason: 'refused before anybody is asked');
    },
  );

  group('catalog entries (PLG-001, 002, 007)', () {
    const net = <String, dynamic>{
      'id': 'svc',
      'kind': 'server',
      'transport': 'streamableHttp',
      'endpoint': 'https://tools.example/mcp',
    };

    test(
      'a network server lands as <id>.<tool> on the endpoint and routes',
      () async {
        final c = boot(ask: approver());
        final r = await register(c.boot, net);
        expect(r.isError, isFalse, reason: '${_json(r)}');
        expect(_json(r)['tools'], <String>['svc.check', 'svc.fix']);
        final names = c.boot.toolDefinitions.map((t) => t.name).toSet();
        expect(names, containsAll(<String>['svc.check', 'svc.fix']));
        final called = await c.boot.callTool('svc.check', <String, dynamic>{});
        expect(called.isError, isNot(true));
        expect(_json(called), {'echo': 'check'});
      },
    );

    test('an allow-list lifts only those tools', () async {
      final c = boot(ask: approver());
      final r = await register(c.boot, {
        ...net,
        'tools': <String>['fix'],
      });
      expect(_json(r)['tools'], <String>['svc.fix']);
      final names = c.boot.toolDefinitions.map((t) => t.name).toSet();
      expect(names, contains('svc.fix'));
      expect(names, isNot(contains('svc.check')));
    });

    test('a tool named destructive is held back until approved', () async {
      final c = boot(ask: approver());
      await register(c.boot, {
        ...net,
        'destructiveTools': <String>['fix'],
      });
      final blocked = await c.boot.callTool('svc.fix', <String, dynamic>{});
      expect(blocked.isError, isTrue);
      final open = await c.boot.callTool('svc.check', <String, dynamic>{});
      expect(open.isError, isNot(true));
    });
  });

  group('bundle plugins (PLG-010..012)', () {
    test(
      'the tools take the plugin id as prefix and unregister tears down',
      () async {
        final activated = <String>[];
        final deactivated = <String>[];
        final c = boot(
          ask: approver(),
          activateBundle: (s) async {
            activated.add(s.id);
            return <String>['note'];
          },
          deactivateBundle: (id) async => deactivated.add(id),
        );
        final r = await register(c.boot, {
          'id': 'notes',
          'kind': 'bundle',
          'endpoint': '/p.mbd',
        });
        expect(r.isError, isFalse, reason: '${_json(r)}');
        expect(activated, <String>['notes']);
        expect(_json(r)['tools'], <String>['notes.note']);
        final un = await c.boot.callTool('plugin.unregister', {'id': 'notes'});
        expect(un.isError, isFalse, reason: '${_json(un)}');
        expect(deactivated, <String>['notes']);
        expect((await list(c.boot))['plugins'], isEmpty);
      },
    );
  });

  test('bad ids and taken prefixes are refused before asking', () async {
    final c = boot(ask: approver());
    for (final id in ['a.b', ' a']) {
      final r = await register(c.boot, {...stdio, 'id': id});
      expect(_json(r)['code'], 'plugin.bad_input');
    }
    final taken = await register(c.boot, {...stdio, 'id': 'plugin'});
    expect(_json(taken)['code'], 'plugin.id_taken');
    expect(asked, isEmpty);
  });

  test('registering the same id again replaces it', () async {
    final c = boot(ask: approver());
    await register(c.boot, stdio);
    await register(c.boot, {
      ...stdio,
      'tools': <String>['fix'],
    });
    final plugins = (await list(c.boot))['plugins'] as List;
    expect(plugins, hasLength(1));
    expect(plugins.single['tools'], <String>['kicad.fix']);
  });

  test('a hub with a ref and no door is plugin.market_unavailable', () async {
    final r = await register(boot(ask: approver()).boot, {
      'id': 'svc',
      'kind': 'hub',
      'ref': 'listing-1',
    });
    expect(_json(r)['code'], 'plugin.market_unavailable');
    expect(asked, isEmpty);
  });

  test(
    'a market: reference with an address beside it still needs the door',
    () async {
      final c = boot(ask: approver());
      final r = await register(c.boot, {
        'id': 'svc',
        'kind': 'hub',
        'ref': 'market:listing-1',
        'endpoint': 'https://typed-by-a-person.example/mcp',
      });
      expect(_json(r)['code'], 'plugin.market_unavailable');
      expect(asked, isEmpty);
      expect(
        c.client.connects,
        isEmpty,
        reason: 'the typed address is not used',
      );
      expect(File(store).existsSync(), isFalse);
    },
  );

  group('secrets', () {
    test('an inline secret is refused and points to the vault', () async {
      final r = await register(boot(ask: approver()).boot, {
        ...stdio,
        'options': {
          'command': 'python3',
          'env': {'API_KEY': 'plain-value'},
        },
      });
      expect(_json(r)['code'], 'plugin.bad_input');
      expect(jsonEncode(_json(r)), isNot(contains('plain-value')));
    });

    test('credentialRefs are resolved for the connection only', () async {
      final vault = _MemVault();
      await vault.write(
        'kicad-key',
        'S3CRET',
        namespace: 'appplayer.credentials',
      );
      final c = boot(ask: approver(), vault: vault);
      final r = await register(c.boot, {
        'id': 'svc',
        'kind': 'server',
        'transport': 'streamableHttp',
        'endpoint': 'https://tools.example/mcp',
        'options': {
          'credentialRefs': {'headers.X-Api-Key': 'kicad-key'},
        },
      });
      expect(r.isError, isFalse, reason: '${_json(r)}');
      expect((c.client.connects.single['options'] as Map)['headers'], {
        'X-Api-Key': 'S3CRET',
      });
      final onDisk = File(store).readAsStringSync();
      expect(onDisk, isNot(contains('S3CRET')));
      expect(onDisk, contains('kicad-key'));
      expect(asked.single.summary, isNot(contains('S3CRET')));
      expect(jsonEncode(await list(c.boot)), isNot(contains('S3CRET')));
    });

    test('a stdio env reaches the program; vault refs fill env.* for the '
        'connection only', () async {
      final vault = _MemVault();
      await vault.write(
        'kicad-key',
        'S3CRET',
        namespace: 'appplayer.credentials',
      );
      final c = boot(ask: approver(), vault: vault);
      final r = await register(c.boot, {
        ...stdio,
        'options': {
          'command': 'python3',
          'args': ['/x/server.py'],
          'env': {'KICAD_REPORT_DIR': '/tmp/reports'},
          'credentialRefs': {'env.KICAD_MCP_TOKEN': 'kicad-key'},
        },
      });
      expect(r.isError, isNot(true), reason: '${_json(r)}');
      expect((c.client.connects.single['options'] as Map)['env'], {
        'KICAD_REPORT_DIR': '/tmp/reports',
        'KICAD_MCP_TOKEN': 'S3CRET',
      });
      final onDisk = File(store).readAsStringSync();
      expect(onDisk, isNot(contains('S3CRET')));
      expect(onDisk, contains('kicad-key'));
      expect(asked.single.summary, contains('KICAD_MCP_TOKEN'));
      expect(asked.single.summary, isNot(contains('S3CRET')));
      expect(jsonEncode(await list(c.boot)), isNot(contains('S3CRET')));
    });

    test('an env that is not a map of strings, or on a network plugin, is '
        'refused', () async {
      final bad = await register(boot(ask: approver()).boot, {
        ...stdio,
        'options': {
          'command': 'python3',
          'env': {'N': 1},
        },
      });
      expect(_json(bad)['code'], 'plugin.bad_input');
      final net = await register(boot(ask: approver()).boot, {
        'id': 'svc',
        'kind': 'server',
        'transport': 'streamableHttp',
        'endpoint': 'https://tools.example/mcp',
        'options': {
          'env': {'A': 'b'},
        },
      });
      expect(_json(net)['code'], 'plugin.bad_input');
      expect(asked, isEmpty);
    });

    test('a ref that is not in the vault is refused before asking', () async {
      final r = await register(boot(ask: approver(), vault: _MemVault()).boot, {
        ...stdio,
        'options': {
          'command': 'python3',
          'credentialRefs': {'headers.X-Api-Key': 'missing'},
        },
      });
      expect(_json(r)['code'], 'plugin.bad_input');
      expect(jsonEncode(_json(r)), contains('not in the vault'));
      expect(asked, isEmpty);
    });
  });

  group('vendored PluginHost', () {
    test(
      'registerBundle records `<id>.<tool>` + unregister tears down',
      () async {
        final b = mk.InProcessKernelServerHost();
        final registry = mk.HostToolRegistry(
          endpoint: b,
          attachToDispatcher: (_, _) {},
          detachFromDispatcher: (_) {},
        );
        final host = PluginHost(registry);
        final reg = host.registerBundle(
          const PluginSource(id: 'demo', kind: PluginKind.bundle),
          toolRawNames: <String>['a', 'b'],
        );
        expect(reg.exposedNames, <String>['demo.a', 'demo.b']);
        await host.unregister('demo');
        expect(host.plugins, isEmpty);
      },
    );
  });
}
