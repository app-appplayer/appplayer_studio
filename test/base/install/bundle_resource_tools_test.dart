/// Unit coverage for `registerBundleResourceTools` — the four
/// `studio.bundle.*` host-level bundle-file readers registered on a
/// bare `InProcessKernelServerHost`:
///
///   - `list_assets` / `read_asset` — confined to the 12 reserved
///     `BundleFolder` slots via `mcp_bundle.BundleResources`.
///   - `list_files` / `read_file` — unconfined bundle-root readers
///     (any file under the `.mbd/` root), with their own `..` /
///     absolute-path guards since they bypass `BundleResources`.
///
/// Locks:
///   - both tool families register under `studio.bundle.*`.
///   - `list_assets` / `read_asset` respect the folder whitelist
///     (`_bundleFolderByName`) and reject unknown folder names.
///   - `list_assets`'s `subpath` prefix filter (exact match OR
///     `<prefix>/` boundary — not a bare substring match).
///   - `read_asset` surfaces missing-file failures as `{ok:false}`
///     (not a thrown exception) via the generic catch.
///   - `list_files` / `read_file` see files OUTSIDE the seven reserved
///     folders (e.g. `scenarios/*.json`) that `list_assets` /
///     `read_asset` cannot reach, and reject `..` / absolute paths.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart';

Future<Map<String, dynamic>> _call(
  mk.KernelServerHost host,
  String name,
  Map<String, dynamic> args,
) async {
  final result = await host.callTool(name, args);
  final text = (result.content.first as mk.KernelTextContent).text;
  return jsonDecode(text) as Map<String, dynamic>;
}

void main() {
  late Directory tmpDir;
  late mk.InProcessKernelServerHost host;
  late String mbdPath;

  setUp(() async {
    tmpDir = Directory.systemTemp.createTempSync('bundle_resource_test_');
    final mbdDir = Directory(p.join(tmpDir.path, 'sample.mbd'));
    await mbdDir.create(recursive: true);
    mbdPath = mbdDir.path;
    host =
        mk.InProcessKernelServerHost(name: 'resource-test', version: '0.0.0');
    registerBundleResourceTools(host);
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  Future<void> writeAsset(String folder, String relPath, String content) async {
    final file = File(p.join(mbdPath, folder, relPath));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  test('registers all 4 studio.bundle.* tools', () {
    final names = host.toolDefinitions.map((d) => d.name).toSet();
    expect(
      names,
      containsAll(<String>[
        'studio.bundle.list_assets',
        'studio.bundle.read_asset',
        'studio.bundle.list_files',
        'studio.bundle.read_file',
      ]),
    );
  });

  group('list_assets', () {
    test('missing mbdPath rejects', () async {
      final out = await _call(host, 'studio.bundle.list_assets', {});
      expect(out['ok'], isFalse);
    });

    test('unknown folder name rejects', () async {
      final out = await _call(host, 'studio.bundle.list_assets', {
        'mbdPath': mbdPath,
        'folder': 'bogus',
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('unknown folder'));
    });

    test('defaults to the assets folder', () async {
      await writeAsset('assets', 'icon.png', 'fake-bytes');
      final out = await _call(host, 'studio.bundle.list_assets', {
        'mbdPath': mbdPath,
      });
      expect(out['ok'], isTrue);
      expect(out['folder'], 'assets');
      expect(out['paths'], <String>['icon.png']);
    });

    test('lists an explicit reserved folder', () async {
      await writeAsset('knowledge', 'doc1.md', '# doc1');
      await writeAsset('knowledge', 'sub/doc2.md', '# doc2');
      final out = await _call(host, 'studio.bundle.list_assets', {
        'mbdPath': mbdPath,
        'folder': 'knowledge',
      });
      expect(out['ok'], isTrue);
      expect(out['paths'], containsAll(<String>['doc1.md', 'sub/doc2.md']));
    });

    test('missing folder on disk returns an empty list, not an error',
        () async {
      final out = await _call(host, 'studio.bundle.list_assets', {
        'mbdPath': mbdPath,
        'folder': 'agents',
      });
      expect(out['ok'], isTrue);
      expect(out['paths'], isEmpty);
    });

    test('subpath filters to prefix-matching entries (boundary, not '
        'substring)', () async {
      await writeAsset('assets', 'icons/a.png', 'x');
      await writeAsset('assets', 'icons/b.png', 'x');
      await writeAsset('assets', 'iconography.txt', 'x');
      await writeAsset('assets', 'other.png', 'x');
      final out = await _call(host, 'studio.bundle.list_assets', {
        'mbdPath': mbdPath,
        'subpath': 'icons',
      });
      expect(out['ok'], isTrue);
      final paths = (out['paths'] as List).cast<String>();
      expect(paths, containsAll(<String>['icons/a.png', 'icons/b.png']));
      // 'iconography.txt' shares the 'icons' prefix as raw characters
      // but not the `icons/` path-segment boundary — excluded.
      expect(paths, isNot(contains('iconography.txt')));
      expect(paths, isNot(contains('other.png')));
    });

    test('subpath exact file match is included via the `path == sub` '
        'branch', () async {
      await writeAsset('assets', 'exact.png', 'x');
      final out = await _call(host, 'studio.bundle.list_assets', {
        'mbdPath': mbdPath,
        'subpath': 'exact.png',
      });
      expect(out['ok'], isTrue);
      expect(out['paths'], <String>['exact.png']);
    });
  });

  group('read_asset', () {
    test('missing mbdPath rejects', () async {
      final out = await _call(host, 'studio.bundle.read_asset', {
        'path': 'x',
      });
      expect(out['ok'], isFalse);
    });

    test('missing path rejects', () async {
      final out = await _call(host, 'studio.bundle.read_asset', {
        'mbdPath': mbdPath,
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('path required'));
    });

    test('unknown folder rejects', () async {
      final out = await _call(host, 'studio.bundle.read_asset', {
        'mbdPath': mbdPath,
        'folder': 'bogus',
        'path': 'x',
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('unknown folder'));
    });

    test('missing file surfaces {ok:false} via the generic catch, not a '
        'thrown exception', () async {
      final out = await _call(host, 'studio.bundle.read_asset', {
        'mbdPath': mbdPath,
        'path': 'ghost.md',
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('read failed'));
    });

    test('reads UTF-8 text content from the default (assets) folder',
        () async {
      await writeAsset('assets', 'notes.txt', 'hello world');
      final out = await _call(host, 'studio.bundle.read_asset', {
        'mbdPath': mbdPath,
        'path': 'notes.txt',
      });
      expect(out['ok'], isTrue);
      expect(out['folder'], 'assets');
      expect(out['content'], 'hello world');
    });

    test('reads from an explicit reserved folder', () async {
      await writeAsset('skills', 'summarize.json', '{"id":"summarize"}');
      final out = await _call(host, 'studio.bundle.read_asset', {
        'mbdPath': mbdPath,
        'folder': 'skills',
        'path': 'summarize.json',
      });
      expect(out['ok'], isTrue);
      expect(out['content'], '{"id":"summarize"}');
    });
  });

  group('list_files (unconfined bundle-root listing)', () {
    test('missing mbdPath rejects', () async {
      final out = await _call(host, 'studio.bundle.list_files', {});
      expect(out['ok'], isFalse);
    });

    test('bundle not found rejects', () async {
      final out = await _call(host, 'studio.bundle.list_files', {
        'mbdPath': p.join(tmpDir.path, 'ghost.mbd'),
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('bundle not found'));
    });

    test('absolute subpath rejects', () async {
      final out = await _call(host, 'studio.bundle.list_files', {
        'mbdPath': mbdPath,
        'subpath': '/etc',
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('no `..`'));
    });

    test('subpath containing .. rejects', () async {
      final out = await _call(host, 'studio.bundle.list_files', {
        'mbdPath': mbdPath,
        'subpath': '../escape',
      });
      expect(out['ok'], isFalse);
    });

    test('sees files outside the 7 reserved BundleFolder slots '
        '(e.g. scenarios/)', () async {
      final scenarios = Directory(p.join(mbdPath, 'scenarios'));
      await scenarios.create(recursive: true);
      await File(p.join(scenarios.path, 'intro.json')).writeAsString('{}');
      await File(p.join(mbdPath, 'manifest.json')).writeAsString('{}');
      final out = await _call(host, 'studio.bundle.list_files', {
        'mbdPath': mbdPath,
      });
      expect(out['ok'], isTrue);
      final paths = (out['paths'] as List).cast<String>();
      expect(paths, containsAll(<String>['scenarios/intro.json', 'manifest.json']));
    });

    test('subpath narrows the listing and is echoed back', () async {
      await writeAsset('assets', 'a.png', 'x');
      final scenarios = Directory(p.join(mbdPath, 'scenarios'));
      await scenarios.create(recursive: true);
      await File(p.join(scenarios.path, 'intro.json')).writeAsString('{}');
      final out = await _call(host, 'studio.bundle.list_files', {
        'mbdPath': mbdPath,
        'subpath': 'scenarios',
      });
      expect(out['ok'], isTrue);
      expect(out['subpath'], 'scenarios');
      expect(out['paths'], <String>['scenarios/intro.json']);
    });

    test('empty bundle root returns an empty list', () async {
      final out = await _call(host, 'studio.bundle.list_files', {
        'mbdPath': mbdPath,
      });
      expect(out['ok'], isTrue);
      expect(out['paths'], isEmpty);
    });
  });

  group('read_file (unconfined bundle-root reader)', () {
    test('missing mbdPath / relPath each reject', () async {
      var out = await _call(host, 'studio.bundle.read_file', {});
      expect(out['ok'], isFalse);
      out = await _call(host, 'studio.bundle.read_file', {
        'mbdPath': mbdPath,
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('relPath required'));
    });

    test('absolute / traversal relPath rejects', () async {
      var out = await _call(host, 'studio.bundle.read_file', {
        'mbdPath': mbdPath,
        'relPath': '/etc/passwd',
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('no `..`'));

      out = await _call(host, 'studio.bundle.read_file', {
        'mbdPath': mbdPath,
        'relPath': '../../etc/passwd',
      });
      expect(out['ok'], isFalse);
    });

    test('missing file rejects with a not-found message', () async {
      final out = await _call(host, 'studio.bundle.read_file', {
        'mbdPath': mbdPath,
        'relPath': 'ghost.json',
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('file not found'));
    });

    test('reads a file outside the reserved folders (e.g. '
        'scenarios/intro.json)', () async {
      final scenarios = Directory(p.join(mbdPath, 'scenarios'));
      await scenarios.create(recursive: true);
      await File(p.join(scenarios.path, 'intro.json'))
          .writeAsString('{"id":"intro"}');
      final out = await _call(host, 'studio.bundle.read_file', {
        'mbdPath': mbdPath,
        'relPath': 'scenarios/intro.json',
      });
      expect(out['ok'], isTrue);
      expect(out['path'], 'scenarios/intro.json');
      expect(out['content'], '{"id":"intro"}');
    });
  });
}
