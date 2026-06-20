import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:brain_kernel/mcp_host.dart' as mh;

/// Tear-down verification — Phase 5.7. Confirms that
/// `HostBundleActivationContext.unregisterAll` reclaims every
/// resource the activation pipeline allocates: registered MCP tools,
/// the lazy JS runtime, the closed flag. Re-activation works after
/// tear-down.
///
/// Agent / external-MCP tear-down paths are exercised in their own
/// suites (mcp dispatch + agent host tests); covering them here would
/// require a live `AgentHost.shared` (memory
/// `feedback_flowbrain_widget_test`) which adds Timer.periodic
/// concerns the tear-down test doesn't need.

String _makeBundle({
  required Map<String, dynamic> manifest,
  Map<String, String> files = const {},
}) {
  final dir = Directory.systemTemp.createTempSync('vibe_teardown_');
  for (final entry in files.entries) {
    final f = File(p.join(dir.path, entry.key));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(entry.value);
  }
  File(
    p.join(dir.path, 'manifest.json'),
  ).writeAsStringSync(jsonEncode(manifest));
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir.path;
}

mb.McpBundle _jsBundleWithShout(String root) {
  return readBundleAt(
    _makeBundle(
      manifest: {
        'manifest': {
          'id': 'com.test.teardown',
          'name': 'Teardown',
          'version': '1',
        },
        'tools': {
          'tools': [
            {
              'name': 'shout',
              'kind': 'js',
              'target': {'entry': 'tools/shout.js', 'fn': 'shout'},
            },
          ],
        },
      },
      files: {
        'tools/shout.js': r'''
        function shout(args) { return { result: (args.text || '').toUpperCase() }; }
      ''',
      },
    ),
  )!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HostBundleActivationContext.unregisterAll', () {
    test('removes registered MCP tools from the host server', () async {
      final bundle = _jsBundleWithShout('shout');
      final boot = mk.InProcessKernelServerHost();
      final ctx = HostBundleActivationContext(
        boot: boot,
        tabKey: bundle.directory!,
        bundle: bundle,
        exposedShortId: bundle.shortId,
      );

      final reg = await ctx.registerTool(bundle.tools!.tools.single);
      expect(reg.ok, isTrue);
      expect(boot.toolScopes.keys, contains('teardown.shout'));

      await ctx.unregisterAll();
      expect(boot.toolScopes.keys, isNot(contains('teardown.shout')));
    });

    test('isClosed flips on first call, second call is a no-op', () async {
      final bundle = _jsBundleWithShout('isclosed');
      final boot = mk.InProcessKernelServerHost();
      final ctx = HostBundleActivationContext(
        boot: boot,
        tabKey: bundle.directory!,
        bundle: bundle,
        exposedShortId: bundle.shortId,
      );

      expect(ctx.isClosed, isFalse);
      await ctx.unregisterAll();
      expect(ctx.isClosed, isTrue);

      // Repeated tear-down throws no exception and doesn't observably
      // change state. Just confirms idempotence.
      await ctx.unregisterAll();
      expect(ctx.isClosed, isTrue);
    });

    test(
      'registerTool on a closed context errors without side-effects',
      () async {
        final bundle = _jsBundleWithShout('closed_reg');
        final boot = mk.InProcessKernelServerHost();
        final ctx = HostBundleActivationContext(
          boot: boot,
          tabKey: bundle.directory!,
          bundle: bundle,
          exposedShortId: bundle.shortId,
        );
        await ctx.unregisterAll();

        final reg = await ctx.registerTool(bundle.tools!.tools.single);
        expect(reg.ok, isFalse);
        expect(reg.error, contains('closed'));
        expect(boot.toolScopes.keys, isNot(contains('teardown.shout')));
      },
    );

    test('tear-down with no tools / no JS runtime is safe', () async {
      final root = _makeBundle(
        manifest: {
          'manifest': {'id': 'com.test.bare', 'name': 'Bare', 'version': '1'},
        },
      );
      final bundle = readBundleAt(root)!;
      final boot = mk.InProcessKernelServerHost();
      final ctx = HostBundleActivationContext(
        boot: boot,
        tabKey: root,
        bundle: bundle,
        exposedShortId: bundle.shortId,
      );

      // No registerTool / registerAgent call — context is "fresh".
      // unregisterAll must still complete without throwing or
      // touching never-allocated resources.
      await ctx.unregisterAll();
      expect(ctx.isClosed, isTrue);
    });

    test('re-activating the same bundle after tear-down works', () async {
      final root = _makeBundle(
        manifest: {
          'manifest': {
            'id': 'com.test.recycle',
            'name': 'Recycle',
            'version': '1',
          },
          'tools': {
            'tools': [
              {
                'name': 'shout',
                'kind': 'js',
                'target': {'entry': 'tools/shout.js', 'fn': 'shout'},
              },
            ],
          },
        },
        files: {
          'tools/shout.js':
              'function shout(args) { return {result: (args.text || "").toUpperCase()}; }',
        },
      );
      final bundle = readBundleAt(root)!;
      final boot = mk.InProcessKernelServerHost();

      // First activation cycle.
      final ctx1 = HostBundleActivationContext(
        boot: boot,
        tabKey: root,
        bundle: bundle,
        exposedShortId: bundle.shortId,
      );
      final reg1 = await ctx1.registerTool(bundle.tools!.tools.single);
      expect(reg1.ok, isTrue);
      final result1 = await boot.callTool('recycle.shout', const {
        'text': 'first',
      });
      expect(
        jsonDecode((result1.content.single as mk.KernelTextContent).text),
        {'result': 'FIRST'},
      );
      await ctx1.unregisterAll();
      expect(boot.toolScopes.keys, isNot(contains('recycle.shout')));

      // Second activation cycle on the same bundle / same boot.
      // No global state from ctx1 should leak.
      final ctx2 = HostBundleActivationContext(
        boot: boot,
        tabKey: root,
        bundle: bundle,
        exposedShortId: bundle.shortId,
      );
      addTearDown(ctx2.unregisterAll);
      final reg2 = await ctx2.registerTool(bundle.tools!.tools.single);
      expect(reg2.ok, isTrue);
      final result2 = await boot.callTool('recycle.shout', const {
        'text': 'second',
      });
      expect(
        jsonDecode((result2.content.single as mk.KernelTextContent).text),
        {'result': 'SECOND'},
      );
    });
  });
}
