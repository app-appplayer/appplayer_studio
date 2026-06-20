import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:brain_kernel/mcp_host.dart' as mh;

String _makeBundle({
  required Map<String, dynamic> manifest,
  Map<String, String> files = const {},
}) {
  final dir = Directory.systemTemp.createTempSync('vibe_gate_');
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

mk.KernelToolResult _stubResult([String text = 'ok']) {
  return mk.KernelToolResult(
    content: <mk.KernelContent>[mk.KernelTextContent(text: text)],
    isError: false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HostBundleActivationContext.validateBuiltinTools', () {
    test('passes when bundle declares no requires', () {
      final root = _makeBundle(
        manifest: {
          'manifest': {'id': 'com.test.no_req', 'name': 'X', 'version': '1'},
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

      expect(ctx.validateBuiltinTools(), isTrue);
      expect(ctx.missingBuiltinTools, isEmpty);
    });

    test('passes when every required tool is registered on the host', () {
      final root = _makeBundle(
        manifest: {
          'manifest': {'id': 'com.test.allp', 'name': 'X', 'version': '1'},
          'requires': {
            'builtinTools': ['studio.search.query', 'studio.fs.read'],
          },
        },
      );
      final bundle = readBundleAt(root)!;
      final boot =
          mk.InProcessKernelServerHost()
            ..addTool(
              name: 'studio.search.query',
              description: 'stub',
              inputSchema: const {'type': 'object', 'properties': {}},
              handler: (args) async => _stubResult(),
            )
            ..addTool(
              name: 'studio.fs.read',
              description: 'stub',
              inputSchema: const {'type': 'object', 'properties': {}},
              handler: (args) async => _stubResult(),
            );
      final ctx = HostBundleActivationContext(
        boot: boot,
        tabKey: root,
        bundle: bundle,
        exposedShortId: bundle.shortId,
      );
      addTearDown(ctx.unregisterAll);

      expect(ctx.validateBuiltinTools(), isTrue);
      expect(ctx.missingBuiltinTools, isEmpty);
    });

    test('reports missing tools without false positives', () {
      final root = _makeBundle(
        manifest: {
          'manifest': {'id': 'com.test.miss', 'name': 'X', 'version': '1'},
          'requires': {
            'builtinTools': [
              'studio.search.query',
              'studio.fs.read',
              'studio.kb.snapshot',
            ],
          },
        },
      );
      final bundle = readBundleAt(root)!;
      final boot =
          mk.InProcessKernelServerHost()..addTool(
            name: 'studio.search.query',
            description: 'stub',
            inputSchema: const {'type': 'object', 'properties': {}},
            handler: (args) async => _stubResult(),
          );
      final ctx = HostBundleActivationContext(
        boot: boot,
        tabKey: root,
        bundle: bundle,
        exposedShortId: bundle.shortId,
      );
      addTearDown(ctx.unregisterAll);

      expect(ctx.validateBuiltinTools(), isFalse);
      expect(ctx.missingBuiltinTools, ['studio.fs.read', 'studio.kb.snapshot']);
    });

    test('re-validation picks up tools registered after the first call', () {
      final root = _makeBundle(
        manifest: {
          'manifest': {'id': 'com.test.late', 'name': 'X', 'version': '1'},
          'requires': {
            'builtinTools': ['studio.late.tool'],
          },
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

      expect(ctx.validateBuiltinTools(), isFalse);
      expect(ctx.missingBuiltinTools, ['studio.late.tool']);

      boot.addTool(
        name: 'studio.late.tool',
        description: 'stub',
        inputSchema: const {'type': 'object', 'properties': {}},
        handler: (args) async => _stubResult(),
      );

      expect(ctx.validateBuiltinTools(), isTrue);
      expect(ctx.missingBuiltinTools, isEmpty);
    });
  });
}
