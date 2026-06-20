/// Host-bridge surface tests — exercises `JsToolRuntime.attachHostBridge`
/// (superseded `JsHostBridge` class from the pre-isolate era). Coverage:
/// - `allowedAtoms` gates which `host.<key>` surfaces appear
/// - atom calls round-trip through the worker isolate
/// - `FsAtom` rejects path traversal escaping the bundle root
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart';

import 'atoms/_test_atoms.dart';

String _makeRoot(Map<String, String> files) {
  final dir = Directory.systemTemp.createTempSync('vibe_bridge_');
  for (final entry in files.entries) {
    final f = File(p.join(dir.path, entry.key));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(entry.value);
  }
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('JsToolRuntime.attachHostBridge', () {
    test('allowedAtoms gates which host.<key> surfaces appear', () async {
      final rt = JsToolRuntime();
      await rt.attachHostBridge(
        atoms: [FsAtom(bundleRoot: '/tmp'), EchoAtom()],
        allowedAtoms: const ['fs'],
      );

      final hasFs = await rt.evaluateAsync(
        "Promise.resolve(typeof host.fs === 'object')",
      );
      final hasEcho = await rt.evaluateAsync(
        "Promise.resolve(typeof host.echo === 'undefined')",
      );
      expect(hasFs.stringResult, 'true');
      expect(hasEcho.stringResult, 'true');
    });

    test('round-trips an atom call', () async {
      final rt = JsToolRuntime();
      await rt.attachHostBridge(
        atoms: [EchoAtom()],
        allowedAtoms: const ['echo'],
      );

      final result = await rt.evaluateAsync(
        'host.echo.shout("hello").then(function(v) { return v; })',
      );
      expect(result.stringResult, '"HELLO"');
    });

    test('FsAtom reads + lists files inside the bundle root', () async {
      final root = _makeRoot({
        'manifest.json': '{}',
        'tools/upper.js': 'function upper(){}',
        'docs/readme.md': 'hi',
      });
      final rt = JsToolRuntime();
      await rt.attachHostBridge(
        atoms: [FsAtom(bundleRoot: root)],
        allowedAtoms: const ['fs'],
      );

      final readResult = await rt.evaluateAsync(
        'host.fs.read("docs/readme.md").then(function(v) { return v; })',
      );
      expect(readResult.stringResult, '"hi"');

      final listResult = await rt.evaluateAsync(
        'host.fs.list(".").then(function(v) { return v; })',
      );
      expect(listResult.stringResult, '["docs","manifest.json","tools"]');

      final existsResult = await rt.evaluateAsync(
        'host.fs.exists("manifest.json").then(function(v) { return v; })',
      );
      expect(existsResult.stringResult, 'true');
    });

    test('FsAtom rejects path traversal escaping the bundle root', () async {
      final root = _makeRoot({'manifest.json': '{}'});
      final rt = JsToolRuntime();
      await rt.attachHostBridge(
        atoms: [FsAtom(bundleRoot: root)],
        allowedAtoms: const ['fs'],
      );

      final result = await rt.evaluateAsync('''
        host.fs.read("../escape.txt")
          .then(function(v) { return { ok: true, value: v }; })
          .catch(function(e) { return { ok: false, message: e.message }; });
      ''');
      expect(result.stringResult, contains('escapes bundle root'));
      expect(result.stringResult, contains('"ok":false'));
    });
  });
}
