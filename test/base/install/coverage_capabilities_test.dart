/// `registerCoverageCapabilities` — verifies the host wiring for the
/// capability-coverage tool packs (canvas / kv / analysis / datastore fs+db)
/// adopted through the vendored `capability_tools` recipe.
///
/// This tests the *host's wiring choices*, not the recipe/package internals
/// (those have their own suites): that the five packs land on the shared
/// `HostToolRegistry` under the expected `<id>.*` namespaces, and that the
/// host-configured datastore policy + fs jail behave — path-escape rejection,
/// the destructive `fs.remove` commit gate, and an fs/db round-trip.
///
/// Mirrors the `mk.InProcessKernelServerHost` + `HostToolRegistry` pattern the
/// app uses at boot, so the test exercises exactly the registration path
/// `VibeStudioHostApp.registerMcpTools` runs.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:appplayer_studio/src/base/install/coverage_capabilities.dart';

// Decode the JSON envelope from a tool result's first text content item.
Map<String, dynamic> _json(mk.KernelToolResult r) {
  final text = r.content.whereType<mk.KernelTextContent>().first.text;
  return jsonDecode(text) as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late mk.InProcessKernelServerHost boot;
  late CoverageCapabilities coverage;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('coverage_caps_test_');
    boot = mk.InProcessKernelServerHost();
    // Same construction as VibeStudioHostApp: one shared registry, dispatcher
    // hooks are no-ops because registerExposed also calls boot.addTool.
    final registry = mk.HostToolRegistry(
      endpoint: boot,
      attachToDispatcher: (_, __) {},
      detachFromDispatcher: (_) {},
    );
    coverage = registerCoverageCapabilities(registry, capRoot: tmp.path);
    // db.* serves once the sqlite source has opened.
    await coverage.ready;
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('surface', () {
    test('exposes all five packs under <id>.* namespaces', () {
      final names = boot.toolDefinitions.map((t) => t.name).toSet();
      // Representative verbs per pack (full lists are covered by the recipe).
      expect(names, containsAll(<String>['fs.read', 'fs.write', 'fs.remove']));
      expect(names, containsAll(<String>['db.query', 'db.exec', 'db.tx']));
      expect(
        names,
        containsAll(<String>['canvas.cdl_to_json', 'canvas.validate_cdl']),
      );
      expect(names, containsAll(<String>['kv.set', 'kv.get']));
      expect(names, contains('analysis.run'));
    });

    test('reported tool names match what landed on the registry', () {
      final landed = boot.toolDefinitions.map((t) => t.name).toSet();
      for (final n in coverage.toolNames) {
        expect(landed, contains(n), reason: '$n reported but not registered');
      }
      // One name per pack at minimum (canvas 3 + kv ≥4 + analysis 3 + fs + db).
      expect(coverage.toolNames.length, greaterThanOrEqualTo(20));
    });
  });

  group('datastore fs — jail + policy', () {
    test('write → read round-trip within the config root', () async {
      final w = await boot.callTool('fs.write', <String, dynamic>{
        'path': 'sub/note.txt',
        'text': 'hello coverage',
      });
      expect(w.isError, isFalse);
      expect(_json(w)['ok'], isTrue);

      final r = await boot.callTool('fs.read', <String, dynamic>{
        'path': 'sub/note.txt',
      });
      expect(_json(r)['text'], 'hello coverage');
    });

    test('path escaping the root is rejected', () async {
      final r = await boot.callTool('fs.read', <String, dynamic>{
        'path': '../../../../../../etc/passwd',
      });
      expect(r.isError, isTrue);
      expect(_json(r)['error'].toString(), contains('escapes allowed root'));
    });

    test(
      'fs.remove is gated behind an explicit commit (destructive)',
      () async {
        await boot.callTool('fs.write', <String, dynamic>{
          'path': 'gone.txt',
          'text': 'x',
        });
        final r = await boot.callTool('fs.remove', <String, dynamic>{
          'path': 'gone.txt',
        });
        expect(r.isError, isTrue);
        expect(_json(r)['code'], 'needs_commit');
        // The file survives the gated (uncommitted) remove.
        final back = await boot.callTool('fs.read', <String, dynamic>{
          'path': 'gone.txt',
        });
        expect(_json(back)['text'], 'x');
      },
    );
  });

  group('datastore db — sqlite source', () {
    test('exec (CREATE/INSERT) → query (SELECT) round-trip', () async {
      final create = await boot.callTool('db.exec', <String, dynamic>{
        'statement': 'CREATE TABLE t(id INTEGER PRIMARY KEY, n TEXT)',
      });
      expect(create.isError, isFalse);

      final ins = await boot.callTool('db.exec', <String, dynamic>{
        'statement': 'INSERT INTO t(n) VALUES(?)',
        'params': <Object?>['alpha'],
      });
      expect(_json(ins)['affected'], 1);

      final sel = await boot.callTool('db.query', <String, dynamic>{
        'statement': 'SELECT n FROM t',
      });
      final rows = _json(sel)['rows'] as List;
      expect(rows.single['n'], 'alpha');
    });
  });

  group('kv', () {
    test('set → get round-trip', () async {
      await boot.callTool('kv.set', <String, dynamic>{
        'key': 'k1',
        'value': 'v1',
      });
      final g = await boot.callTool('kv.get', <String, dynamic>{'key': 'k1'});
      expect(_json(g)['value'], 'v1');
    });
  });
}
