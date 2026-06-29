/// `plugin.*` host install (vendored `plugin_host` recipe). Verifies the
/// surface lands, the `plugin.list`/`register` envelope, platform/bundle
/// guards, and the vendored `PluginHost` bundle-record lifecycle. The live
/// server-mirror path (connect → catalog) is exercised by the Ops dogfood, not
/// here (needs a real endpoint + KernelClientHost).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:appplayer_studio/src/base/install/plugin_install.dart';
import 'package:appplayer_studio/src/base/install/plugin_host/plugin_host.dart';

Map<String, dynamic> _json(mk.KernelToolResult r) =>
    jsonDecode(r.content.whereType<mk.KernelTextContent>().first.text)
        as Map<String, dynamic>;

void main() {
  late mk.InProcessKernelServerHost boot;
  late mk.HostToolRegistry registry;
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('plugin_test_');
    boot = mk.InProcessKernelServerHost();
    registry = mk.HostToolRegistry(
      endpoint: boot,
      attachToDispatcher: (_, __) {},
      detachFromDispatcher: (_) {},
    );
    registerPluginTools(
      registry,
      clientHost: null,
      storePath: '${tmp.path}/plugins.json',
    );
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('plugin.* surface lands on the registry', () {
    final names = boot.toolDefinitions.map((t) => t.name).toSet();
    expect(
      names,
      containsAll(<String>['plugin.register', 'plugin.unregister', 'plugin.list']),
    );
  });

  test('plugin.list is empty initially', () async {
    final r = await boot.callTool('plugin.list', const <String, dynamic>{});
    expect(r.isError, isFalse);
    expect(_json(r)['plugins'], isEmpty);
  });

  test('bundle kind is rejected here (activates via bundle install)', () async {
    final r = await boot.callTool('plugin.register', const <String, dynamic>{
      'id': 'b',
      'kind': 'bundle',
    });
    expect(r.isError, isTrue);
    expect(_json(r)['code'], 'plugin.bundle_unwired');
  });

  test('server without a clientHost errors gracefully (no crash)', () async {
    final r = await boot.callTool('plugin.register', const <String, dynamic>{
      'id': 's',
      'kind': 'server',
      'endpoint': 'http://127.0.0.1:1/mcp',
    });
    expect(r.isError, isTrue);
  });

  test('register requires id + kind', () async {
    final r = await boot.callTool('plugin.register', const <String, dynamic>{
      'kind': 'server',
    });
    expect(r.isError, isTrue);
  });

  group('vendored PluginHost (bundle lifecycle, no clientHost)', () {
    test('registerBundle records `<id>.<tool>` + unregister tears down',
        () async {
      final host = PluginHost(registry);
      final reg = host.registerBundle(
        const PluginSource(id: 'demo', kind: PluginKind.bundle),
        toolRawNames: <String>['a', 'b'],
      );
      expect(reg.exposedNames, <String>['demo.a', 'demo.b']);
      expect(host.plugin('demo'), isNotNull);
      expect(host.plugins, hasLength(1));
      await host.unregister('demo');
      expect(host.plugin('demo'), isNull);
      expect(host.plugins, isEmpty);
    });

    test('PluginSource.isNetwork reflects the transport', () {
      expect(
        const PluginSource(
          id: 'n',
          kind: PluginKind.hub,
          transport: mk.KernelTransportKind.streamableHttp,
        ).isNetwork,
        isTrue,
      );
      expect(
        const PluginSource(id: 'l', kind: PluginKind.server).isNetwork,
        isFalse,
      );
    });
  });

  group('bundle plugin path (injected activate/deactivate closures)', () {
    late mk.InProcessKernelServerHost boot2;
    late mk.HostToolRegistry registry2;
    late Directory tmp2;
    late List<String> activated;
    late List<String> deactivated;

    setUp(() async {
      tmp2 = await Directory.systemTemp.createTemp('plugin_bundle_test_');
      boot2 = mk.InProcessKernelServerHost();
      registry2 = mk.HostToolRegistry(
        endpoint: boot2,
        attachToDispatcher: (_, __) {},
        detachFromDispatcher: (_) {},
      );
      activated = <String>[];
      deactivated = <String>[];
      registerPluginTools(
        registry2,
        storePath: '${tmp2.path}/plugins.json',
        activateBundle: (source) async {
          activated.add(source.id);
          return <String>['toolA', 'toolB'];
        },
        deactivateBundle: (id) async => deactivated.add(id),
      );
    });

    tearDown(() async {
      if (tmp2.existsSync()) await tmp2.delete(recursive: true);
    });

    test('register kind:bundle activates + records `<id>.<tool>`', () async {
      final r = await boot2.callTool('plugin.register', const <String, dynamic>{
        'id': 'mybundle',
        'kind': 'bundle',
        'endpoint': '/path/to/my.mbd',
      });
      expect(r.isError, isFalse);
      final out = _json(r);
      expect(out['ok'], true);
      expect(out['tools'], <String>['mybundle.toolA', 'mybundle.toolB']);
      expect(activated, <String>['mybundle']);

      final list = _json(await boot2.callTool('plugin.list', const {}));
      expect((list['plugins'] as List).single['id'], 'mybundle');
    });

    test('unregister tears the bundle activation down', () async {
      await boot2.callTool('plugin.register', const <String, dynamic>{
        'id': 'mybundle',
        'kind': 'bundle',
        'endpoint': '/path/to/my.mbd',
      });
      final r = await boot2.callTool(
        'plugin.unregister',
        const <String, dynamic>{'id': 'mybundle'},
      );
      expect(r.isError, isFalse);
      expect(deactivated, <String>['mybundle']);
      final list = _json(await boot2.callTool('plugin.list', const {}));
      expect(list['plugins'], isEmpty);
    });
  });
}
