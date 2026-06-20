import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:brain_kernel/mcp_host.dart' as mh;

/// Build a `.mbd/` directory with [files] (relative path → content) and
/// a manifest derived from [manifest]. Returns the absolute mbd path.
String _makeBundle({
  required Map<String, dynamic> manifest,
  required Map<String, String> files,
}) {
  final dir = Directory.systemTemp.createTempSync('vibe_js_dispatch_');
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

/// Look up the registered tool's handler on [boot] and invoke it
/// with [args]. The kernel exposes `toolDefinitions` for catalog
/// inspection but no direct handler lookup, so the test reaches into
/// the MCP server through `boot.callTool`.
Future<mk.KernelToolResult> _callTool(
  mk.KernelServerHost boot,
  String name,
  Map<String, dynamic> args,
) async {
  return boot.callTool(name, args);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HostBundleActivationContext kind:js dispatch', () {
    test('loads .js, registers tool, returns sync result', () async {
      final root = _makeBundle(
        manifest: {
          'manifest': {'id': 'com.test.upper', 'name': 'Upper', 'version': '1'},
          'tools': {
            'tools': [
              {
                'name': 'upper',
                'kind': 'js',
                'target': {'entry': 'tools/upper.js', 'fn': 'upperHandler'},
              },
            ],
          },
        },
        files: {
          'tools/upper.js': r'''
            function upperHandler(args) {
              return { result: (args.text || '').toUpperCase() };
            }
          ''',
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
      addTearDown(ctx.unregisterAll);

      final reg = await ctx.registerTool(bundle.tools!.tools.single);
      expect(reg.ok, isTrue, reason: reg.error ?? 'register failed');
      expect(reg.exposedName, 'upper.upper');

      final result = await _callTool(boot, 'upper.upper', {'text': 'hello'});
      expect(result.isError, isFalse);
      final body = (result.content.single as mk.KernelTextContent).text;
      expect(jsonDecode(body), {'result': 'HELLO'});
    });

    test('async tool reaching for host.fs returns workspace data', () async {
      final root = _makeBundle(
        manifest: {
          'manifest': {
            'id': 'com.test.fsread',
            'name': 'FsRead',
            'version': '1',
          },
          'tools': {
            'tools': [
              {
                'name': 'readReadme',
                'kind': 'js',
                'target': {'entry': 'tools/read_readme.js', 'fn': 'readReadme'},
              },
            ],
          },
          'requires': {
            'builtinAtoms': ['fs'],
          },
        },
        files: {
          'tools/read_readme.js': r'''
            async function readReadme(args) {
              const text = await host.fs.read('docs/readme.md');
              return { length: text.length, text: text };
            }
          ''',
          'docs/readme.md': 'hello world',
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
      addTearDown(ctx.unregisterAll);

      final reg = await ctx.registerTool(bundle.tools!.tools.single);
      expect(reg.ok, isTrue, reason: reg.error ?? 'register failed');

      final result = await _callTool(
        boot,
        'fsread.readReadme',
        const <String, dynamic>{},
      );
      expect(result.isError, isFalse);
      final body = (result.content.single as mk.KernelTextContent).text;
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      expect(decoded['length'], 11);
      expect(decoded['text'], 'hello world');
    });

    test('JS function throwing surfaces as isError CallToolResult', () async {
      final root = _makeBundle(
        manifest: {
          'manifest': {'id': 'com.test.fail', 'name': 'Fail', 'version': '1'},
          'tools': {
            'tools': [
              {
                'name': 'boom',
                'kind': 'js',
                'target': {'entry': 'tools/boom.js', 'fn': 'boom'},
              },
            ],
          },
        },
        files: {
          'tools/boom.js': r'''
            function boom() { throw new Error('intentional'); }
          ''',
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
      addTearDown(ctx.unregisterAll);

      final reg = await ctx.registerTool(bundle.tools!.tools.single);
      expect(reg.ok, isTrue);

      final result = await _callTool(
        boot,
        'fail.boom',
        const <String, dynamic>{},
      );
      expect(result.isError, isTrue);
      final body = (result.content.single as mk.KernelTextContent).text;
      expect(body, contains('intentional'));
    });

    test('missing target.entry rejects registration cleanly', () async {
      final root = _makeBundle(
        manifest: {
          'manifest': {
            'id': 'com.test.broken',
            'name': 'Broken',
            'version': '1',
          },
        },
        files: {},
      );
      final bundle = readBundleAt(root)!;
      final boot = mk.InProcessKernelServerHost();
      final ctx = HostBundleActivationContext(
        boot: boot,
        tabKey: root,
        bundle: bundle,
        exposedShortId: bundle.shortId,
      );
      addTearDown(ctx.unregisterAll);

      const tool = mb.ToolEntry(
        name: 'noEntry',
        kind: mb.ToolKind.js,
        target: {'fn': 'x'},
      );
      final reg = await ctx.registerTool(tool);
      expect(reg.ok, isFalse);
      expect(reg.error, contains('missing target.entry'));
    });
  });
}
