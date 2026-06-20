import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart';

/// Build a `.mbd/` directory with [manifestJson] (already JSON-encoded
/// or a plain Map). Returns the absolute mbd path. Auto-deletes via
/// [addTearDown].
String _makeMbd(Map<String, dynamic> manifestJson) {
  final dir = Directory.systemTemp.createTempSync('vibe_bm_test_');
  final manifestFile = File(p.join(dir.path, 'manifest.json'));
  manifestFile.writeAsStringSync(jsonEncode(manifestJson));
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir.path;
}

void main() {
  group('readBundleAt', () {
    test('sets directory to the absolute mbd path', () {
      final mbd = _makeMbd({
        'manifest': {
          'id': 'com.example.basic',
          'name': 'Basic',
          'version': '1',
        },
      });
      final b = readBundleAt(mbd)!;
      expect(b.directory, p.absolute(mbd));
    });

    test('tolerates flat manifest shape (no `manifest:` envelope)', () {
      final mbd = _makeMbd({'id': 'com.example.flat', 'name': 'Flat'});
      final b = readBundleAt(mbd)!;
      expect(b.bundleId, 'com.example.flat');
    });

    test('returns null when manifest.json is missing', () {
      final dir = Directory.systemTemp.createTempSync('vibe_bm_empty_');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(readBundleAt(dir.path), isNull);
    });

    test('returns null when id is missing', () {
      final mbd = _makeMbd({
        'manifest': {'name': 'no id'},
      });
      expect(readBundleAt(mbd), isNull);
    });

    test('parses requires section when present', () {
      final mbd = _makeMbd({
        'manifest': {'id': 'com.example.uses', 'name': 'X', 'version': '1'},
        'requires': {
          'builtinTools': ['studio.fs.read', 'studio.search.query'],
          'builtinAtoms': ['fs', 'http'],
        },
      });
      final b = readBundleAt(mbd)!;
      expect(b.requires!.builtinTools, [
        'studio.fs.read',
        'studio.search.query',
      ]);
      expect(b.requires!.builtinAtoms, ['fs', 'http']);
    });

    test('parses tools section when present', () {
      final mbd = _makeMbd({
        'manifest': {'id': 'com.example.t', 'name': 'X', 'version': '1'},
        'tools': {
          'tools': [
            {
              'name': 'shout',
              'kind': 'js',
              'target': {'entry': 'tools/shout.js', 'fn': 'shout'},
            },
          ],
        },
      });
      final b = readBundleAt(mbd)!;
      expect(b.tools!.tools.single.name, 'shout');
      expect(b.tools!.tools.single.kind, mb.ToolKind.js);
    });

    test('absent requires/tools yield null sections', () {
      final mbd = _makeMbd({
        'manifest': {'id': 'com.example.empty', 'name': 'X', 'version': '1'},
      });
      final b = readBundleAt(mbd)!;
      expect(b.requires, isNull);
      expect(b.tools, isNull);
    });
  });

  group('BundleHostAccessors', () {
    late mb.McpBundle bundle;

    setUp(() {
      final mbd = _makeMbd({
        'manifest': {
          'id': 'com.makemind.examples.demo_showcase',
          'name': 'Demo Showcase',
          'version': '1',
        },
      });
      bundle = readBundleAt(mbd)!;
    });

    test('shortId returns the last dotted segment', () {
      expect(bundle.shortId, 'demo_showcase');
    });

    test('displayLabel falls back to shortId when name is empty', () {
      final mbd = _makeMbd({
        'manifest': {'id': 'com.example.no_name', 'version': '1'},
      });
      final b = readBundleAt(mbd)!;
      expect(b.displayLabel, 'no_name');
    });

    test('displayLabel uses name when present', () {
      expect(bundle.displayLabel, 'Demo Showcase');
    });

    test('resolveAsset joins relative path under directory', () {
      final resolved = bundle.resolveAsset('tools/upper.js');
      expect(
        resolved,
        p.normalize(p.join(bundle.directory!, 'tools/upper.js')),
      );
    });

    test('resolveAsset rejects absolute path', () {
      expect(() => bundle.resolveAsset('/etc/passwd'), throwsStateError);
    });

    test('resolveAsset rejects empty path', () {
      expect(() => bundle.resolveAsset(''), throwsStateError);
    });

    test('resolveAsset rejects path traversal escaping the directory', () {
      expect(() => bundle.resolveAsset('../sneaky.js'), throwsStateError);
      expect(
        () => bundle.resolveAsset('tools/../../escape.js'),
        throwsStateError,
      );
    });

    test('resolveAsset allows traversal that stays inside the directory', () {
      final resolved = bundle.resolveAsset('tools/../tools/upper.js');
      expect(
        resolved,
        p.normalize(p.join(bundle.directory!, 'tools/upper.js')),
      );
    });

    test('resolveJsEntry returns absolute path for kind:js', () {
      const tool = mb.ToolEntry(
        name: 'upper',
        kind: mb.ToolKind.js,
        target: {'entry': 'tools/upper.js', 'fn': 'upper'},
      );
      expect(
        bundle.resolveJsEntry(tool),
        p.normalize(p.join(bundle.directory!, 'tools/upper.js')),
      );
    });

    test('resolveJsEntry returns null for kind:mcp', () {
      const tool = mb.ToolEntry(
        name: 'remote',
        kind: mb.ToolKind.mcp,
        target: {'transport': 'http', 'url': 'http://x'},
      );
      expect(bundle.resolveJsEntry(tool), isNull);
    });

    test('uiEntry pulls kind/path from UiSection.raw', () {
      final mbd = _makeMbd({
        'manifest': {'id': 'com.example.ui', 'name': 'UI', 'version': '1'},
        'ui': {'kind': 'mcp_ui_dsl', 'path': 'ui/app.json'},
      });
      final b = readBundleAt(mbd)!;
      final entry = b.uiEntry!;
      expect(entry.kind, 'mcp_ui_dsl');
      expect(entry.path, 'ui/app.json');
    });

    test('uiEntry returns null when kind is unknown', () {
      final mbd = _makeMbd({
        'manifest': {'id': 'com.example.bad_ui', 'name': 'X', 'version': '1'},
        'ui': {'kind': 'flutter', 'path': 'ui/app.json'},
      });
      final b = readBundleAt(mbd)!;
      expect(b.uiEntry, isNull);
    });

    test('uiEntry returns null when ui section absent', () {
      expect(bundle.uiEntry, isNull);
    });
  });
}
