/// `BundleSessionBridge` external-endpoint alias tests. The bridge
/// publishes `bk.<bundleId>.<facade>.<verb>` aliases on every
/// non-master session open and withdraws them on close. Verified
/// without a real `ServerBootstrap` by passing capture callbacks
/// in for `serverAdapter` / `serverAdapterRemove`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:appplayer_studio/base.dart';

void main() {
  late List<BridgeToolDef> published;
  late List<String> withdrawn;
  late BundleSessionBridge bridge;

  setUp(() {
    SessionRegistry.instance.clearForTesting();
    DispatchContext.instance.resetForTesting();
    published = <BridgeToolDef>[];
    withdrawn = <String>[];
    bridge = BundleSessionBridge(
      serverAdapter: published.add,
      serverAdapterRemove: withdrawn.add,
    );
  });
  tearDown(() {
    SessionRegistry.instance.clearForTesting();
    DispatchContext.instance.resetForTesting();
  });

  mk.BundleActivation _activation(String bundleId) => mk.BundleActivation(
    system: mk.KnowledgeSystem.stub(),
    bundleId: bundleId,
  );

  group('alias publication', () {
    test('opening a non-master session publishes per-bundle aliases', () async {
      bridge.registerTool(
        name: 'bk.fact.write',
        handler: (_) async => mk.KernelToolResult(content: const []),
      );
      bridge.registerTool(
        name: 'bk.skill.execute',
        handler: (_) async => mk.KernelToolResult(content: const []),
      );
      // Pre-session, canonical names are NOT mirrored onto the
      // serverAdapter — the bridge keeps them in its in-process
      // registry and only publishes bundleId-prefixed aliases when
      // sessions open (brain_kernel 2026-05-26 policy).
      expect(published, isEmpty);

      final session = bridge.openSession(_activation('app_a'));

      // Two new aliases land.
      final aliases =
          published
              .map((d) => d.name)
              .where((n) => n.startsWith('bk.app_a.'))
              .toList();
      expect(
        aliases,
        containsAll(<String>['bk.app_a.fact.write', 'bk.app_a.skill.execute']),
      );

      await bridge.closeSession(session);

      // Only the aliases were exposed → only the aliases get withdrawn.
      expect(
        withdrawn,
        containsAll(<String>['bk.app_a.fact.write', 'bk.app_a.skill.execute']),
      );
    });

    test('master session skips alias publication', () {
      bridge.registerTool(
        name: 'bk.fact.write',
        handler: (_) async => mk.KernelToolResult(content: const []),
      );
      bridge.openSession(_activation('host'), master: true);
      expect(
        published.map((d) => d.name).where((n) => n.startsWith('bk.host.')),
        isEmpty,
      );
    });

    test('non-bk tool registration throws ArgumentError', () {
      final session = bridge.openSession(_activation('app_a'));
      // brain_kernel 2026-05-26 — bridge.registerTool is reserved
      // for knowledge tools (`bk.<facade>.<verb>`). General domain or
      // host tools must go through `HostToolRegistry` or be wired
      // straight onto the dispatcher / endpoint.
      expect(
        () => bridge.registerTool(
          name: 'studio.chrome.toggle',
          handler: (_) async => mk.KernelToolResult(content: const []),
        ),
        throwsArgumentError,
      );
      bridge.closeSession(session);
    });

    test(
      'registerTool after openSession publishes alias retroactively',
      () async {
        final session = bridge.openSession(_activation('app_a'));
        bridge.registerTool(
          name: 'bk.fact.write',
          handler: (_) async => mk.KernelToolResult(content: const []),
        );
        expect(published.any((d) => d.name == 'bk.app_a.fact.write'), isTrue);
        await bridge.closeSession(session);
      },
    );

    test('unregisterTool withdraws every active session alias', () async {
      bridge.registerTool(
        name: 'bk.fact.write',
        handler: (_) async => mk.KernelToolResult(content: const []),
      );
      final sa = bridge.openSession(_activation('app_a'));
      final sb = bridge.openSession(_activation('app_b'));
      bridge.unregisterTool('bk.fact.write');
      expect(
        withdrawn,
        containsAll(<String>['bk.app_a.fact.write', 'bk.app_b.fact.write']),
      );
      await bridge.closeSession(sa);
      await bridge.closeSession(sb);
    });

    test('alias handler dispatches inside session zone', () async {
      String? capturedBundleId;
      bridge.registerTool(
        name: 'bk.fact.write',
        handler: (_) async {
          capturedBundleId = DispatchContext.instance.currentBundleId;
          return mk.KernelToolResult(content: const []);
        },
      );
      final session = bridge.openSession(_activation('app_a'));
      final aliasDef = published.firstWhere(
        (d) => d.name == 'bk.app_a.fact.write',
      );
      await aliasDef.handler(const <String, dynamic>{});
      expect(capturedBundleId, 'app_a');
      await bridge.closeSession(session);
    });
  });

  group('resource publication', () {
    late List<Map<String, dynamic>> publishedResources;
    late List<String> withdrawnResources;
    late BundleSessionBridge resBridge;

    setUp(() {
      SessionRegistry.instance.clearForTesting();
      DispatchContext.instance.resetForTesting();
      publishedResources = <Map<String, dynamic>>[];
      withdrawnResources = <String>[];
      resBridge = BundleSessionBridge(
        resourceServerAdapter: (uri, name, description, mimeType, handler) {
          publishedResources.add(<String, dynamic>{
            'uri': uri,
            'name': name,
            'description': description,
            'mimeType': mimeType,
          });
        },
        resourceServerAdapterRemove: withdrawnResources.add,
      );
    });
    tearDown(() {
      SessionRegistry.instance.clearForTesting();
      DispatchContext.instance.resetForTesting();
    });

    test(
      'registerResource — dual-write to in-process map + serverAdapter',
      () async {
        resBridge.registerResource(
          'kb://fact/app_a.foo',
          (_) async => <String, dynamic>{'id': 'app_a.foo', 'value': 42},
          name: 'foo',
          description: 'sample',
          mimeType: 'application/json',
        );
        // serverAdapter received the URI + metadata.
        expect(publishedResources, hasLength(1));
        expect(publishedResources.first['uri'], 'kb://fact/app_a.foo');
        expect(publishedResources.first['name'], 'foo');
        expect(publishedResources.first['mimeType'], 'application/json');
        // in-process readResource resolves the same handler.
        final v = await resBridge.readResource('kb://fact/app_a.foo');
        expect(v, isA<Map<String, dynamic>>());
        expect((v as Map<String, dynamic>)['value'], 42);
      },
    );

    test(
      'unregisterResource — both in-process + serverAdapter remove',
      () async {
        resBridge.registerResource(
          'kb://fact/app_a.foo',
          (_) async => <String, dynamic>{'id': 'app_a.foo'},
        );
        final removed = resBridge.unregisterResource('kb://fact/app_a.foo');
        expect(removed, isTrue);
        expect(withdrawnResources, contains('kb://fact/app_a.foo'));
        // in-process readResource falls through to systemResolver
        // (null here) — returns null.
        final v = await resBridge.readResource('kb://fact/app_a.foo');
        expect(v, isNull);
      },
    );
  });
}
