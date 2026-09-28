/// `registerBrowserCapability` — verifies the host wiring for the `browser.*`
/// capability (the 9 mcp_browser ops + the interactive auth pair).
///
/// This tests the *host's registration choices*, not the mcp_browser engine
/// (that has its own suite and needs a live Chromium): that the 9 scraping ops
/// land on the shared [HostToolRegistry] under `browser.*`, that the
/// `open_login` / `auth_capture` pair is exposed only when a sealer + root are
/// supplied, and that with no Chromium path configured every op answers with
/// the `browser.disabled` envelope rather than throwing.
///
/// Mirrors the `mk.InProcessKernelServerHost` + `HostToolRegistry` pattern the
/// app runs at boot (`VibeStudioHostApp.registerMcpTools`), so the test
/// exercises exactly the registration path production uses. The live login /
/// capture / re-inject chain is an interactive flow verified by host dogfood.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_secure/appplayer_secure.dart'
    show AtRestSealer, InMemorySecureStorage;
import 'package:flutter_test/flutter_test.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:appplayer_studio/src/base/install/browser_capability.dart';

// Decode the JSON envelope from a tool result's first text content item.
Map<String, dynamic> _json(mk.KernelToolResult r) {
  final text = r.content.whereType<mk.KernelTextContent>().first.text;
  return jsonDecode(text) as Map<String, dynamic>;
}

mk.HostToolRegistry _registry(mk.InProcessKernelServerHost boot) =>
    mk.HostToolRegistry(
      endpoint: boot,
      attachToDispatcher: (_, _) {},
      detachFromDispatcher: (_) {},
    );

/// The exposed names for the 9 first-class scraping ops.
const _scrapingNames = <String>[
  'browser.page_view',
  'browser.page_audit_role',
  'browser.web_search',
  'browser.extract',
  'browser.crawl',
  'browser.monitor',
  'browser.submit_form',
  'browser.download',
  'browser.page_compare_actors',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late mk.InProcessKernelServerHost boot;

  setUp(() {
    boot = mk.InProcessKernelServerHost();
  });

  group('surface — no auth configured', () {
    test('exposes exactly the 9 scraping ops, no auth pair', () {
      final exposed = registerBrowserCapability(
        registry: _registry(boot),
        chromiumPath: () => null,
      );
      // Reported names match what landed on the registry.
      final landed = boot.toolDefinitions.map((t) => t.name).toSet();
      for (final n in exposed) {
        expect(landed, contains(n), reason: '$n reported but not registered');
      }
      expect(exposed.toSet(), containsAll(_scrapingNames));
      expect(exposed.length, 9, reason: 'no open_login/auth_capture w/o sealer');
      expect(exposed, isNot(contains('browser.open_login')));
      expect(exposed, isNot(contains('browser.auth_capture')));
    });
  });

  group('surface — auth configured (sealer + root)', () {
    test('adds open_login + auth_capture to the 9 scraping ops', () async {
      final root = await Directory.systemTemp.createTemp('browser_cap_surface');
      addTearDown(() async {
        if (root.existsSync()) await root.delete(recursive: true);
      });
      final exposed = registerBrowserCapability(
        registry: _registry(boot),
        chromiumPath: () => null,
        authSealer: AtRestSealer(storage: InMemorySecureStorage()),
        authRoot: () => root.path,
      );
      expect(exposed.toSet(), containsAll(_scrapingNames));
      expect(exposed, contains('browser.open_login'));
      expect(exposed, contains('browser.auth_capture'));
      expect(exposed.length, 11);
      final landed = boot.toolDefinitions.map((t) => t.name).toSet();
      expect(landed, containsAll(exposed));
    });

    test('open_login requires a url; auth_capture requires member/system/ctx',
        () {
      registerBrowserCapability(
        registry: _registry(boot),
        chromiumPath: () => null,
        authSealer: AtRestSealer(storage: InMemorySecureStorage()),
        authRoot: () => Directory.systemTemp.path,
      );
      final byName = {for (final t in boot.toolDefinitions) t.name: t};
      final login = byName['browser.open_login']!.inputSchema;
      expect((login['required'] as List), contains('url'));
      final cap = byName['browser.auth_capture']!.inputSchema;
      expect(
        (cap['required'] as List),
        containsAll(<String>['member', 'system', 'contextId']),
      );
    });
  });

  group('disabled fallback — no Chromium path', () {
    setUp(() {
      registerBrowserCapability(
        registry: _registry(boot),
        chromiumPath: () => null,
      );
    });

    test('every scraping op answers browser.disabled, not a throw', () async {
      for (final name in _scrapingNames) {
        final r = await boot.callTool(name, <String, dynamic>{});
        expect(r.isError, isTrue, reason: '$name should be an error envelope');
        final env = _json(r);
        expect(env['ok'], isFalse, reason: name);
        expect(env['code'], 'browser.disabled', reason: name);
      }
    });

    test('an empty-string path is treated as disabled too', () async {
      final boot2 = mk.InProcessKernelServerHost();
      registerBrowserCapability(
        registry: _registry(boot2),
        chromiumPath: () => '',
      );
      final r = await boot2.callTool('browser.page_view', <String, dynamic>{});
      expect(_json(r)['code'], 'browser.disabled');
    });
  });
}
