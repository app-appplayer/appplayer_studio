/// Unit coverage for `createProjectFolder` — the disk-side scaffolding
/// helper. Tests the success path, all guard-condition branches, custom
/// extension/bundleSubdir options, and initialFiles seeding.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart';

void main() {
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('proj_layout_test_');
  });

  tearDown(() async {
    if (tmpDir.existsSync()) {
      await tmpDir.delete(recursive: true);
    }
  });

  // ---------------------------------------------------------------------------
  // Success path
  // ---------------------------------------------------------------------------
  group('success path', () {
    test('creates expected layout and returns ok:true + paths', () async {
      final result = await createProjectFolder(
        name: 'my_app',
        parent: tmpDir.path,
      );
      expect(result['ok'], isTrue);
      expect(result.containsKey('projectPath'), isTrue);
      expect(result.containsKey('bundlePath'), isTrue);
      expect(result.containsKey('metaFile'), isTrue);

      final projectPath = result['projectPath'] as String;
      expect(Directory(projectPath).existsSync(), isTrue);
      // Default bundle subdir is <name>.mbd
      expect(Directory(p.join(projectPath, 'my_app.mbd')).existsSync(), isTrue);
      expect(Directory(p.join(projectPath, 'drafts')).existsSync(), isTrue);
      expect(Directory(p.join(projectPath, 'build')).existsSync(), isTrue);
      expect(File(p.join(projectPath, 'project.sbproj')).existsSync(), isTrue);
    });

    test(
      'metadata file contains schemaVersion, name, createdAt, bundle',
      () async {
        final result = await createProjectFolder(
          name: 'meta_check',
          parent: tmpDir.path,
        );
        final metaFile = File(result['metaFile'] as String);
        final meta =
            jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
        expect(meta['schemaVersion'], '0.1');
        expect(meta['name'], 'meta_check');
        expect(meta['bundle'], 'meta_check.mbd');
        expect(meta['activeChannel'], 'main');
        expect(meta.containsKey('createdAt'), isTrue);
      },
    );

    test('custom ext changes metadata filename', () async {
      final result = await createProjectFolder(
        name: 'custom_ext',
        parent: tmpDir.path,
        ext: '.vsproj',
      );
      final metaFile = result['metaFile'] as String;
      expect(p.basename(metaFile), 'project.vsproj');
      expect(File(metaFile).existsSync(), isTrue);
    });

    test('custom bundleSubdir is used', () async {
      final result = await createProjectFolder(
        name: 'custom_bundle',
        parent: tmpDir.path,
        bundleSubdir: 'override.mbd',
      );
      final projectPath = result['projectPath'] as String;
      expect(
        Directory(p.join(projectPath, 'override.mbd')).existsSync(),
        isTrue,
      );
      expect(result['bundlePath'], endsWith('override.mbd'));
    });
  });

  // ---------------------------------------------------------------------------
  // Guard conditions
  // ---------------------------------------------------------------------------
  group('guard conditions', () {
    test('empty name returns ok:false', () async {
      final r = await createProjectFolder(name: '', parent: tmpDir.path);
      expect(r['ok'], isFalse);
      expect((r['error'] as String), contains('name'));
    });

    test('empty parent returns ok:false', () async {
      final r = await createProjectFolder(name: 'x', parent: '');
      expect(r['ok'], isFalse);
      expect((r['error'] as String), contains('parent'));
    });

    test('name with / returns ok:false', () async {
      final r = await createProjectFolder(
        name: 'bad/name',
        parent: tmpDir.path,
      );
      expect(r['ok'], isFalse);
      expect((r['error'] as String), contains('path separator'));
    });

    test('name with .. returns ok:false', () async {
      final r = await createProjectFolder(
        name: 'bad..name',
        parent: tmpDir.path,
      );
      expect(r['ok'], isFalse);
      expect((r['error'] as String), contains('..'));
    });

    test('name with backslash returns ok:false', () async {
      final r = await createProjectFolder(
        name: r'bad\name',
        parent: tmpDir.path,
      );
      expect(r['ok'], isFalse);
    });

    test('existing project path returns ok:false', () async {
      // Create the directory first so it already exists.
      final existing = Directory(p.join(tmpDir.path, 'exists'));
      await existing.create();
      final r = await createProjectFolder(name: 'exists', parent: tmpDir.path);
      expect(r['ok'], isFalse);
      expect((r['error'] as String), contains('already exists'));
    });
  });

  // ---------------------------------------------------------------------------
  // initialFiles seeding
  // ---------------------------------------------------------------------------
  group('initialFiles', () {
    test('string content written verbatim', () async {
      final result = await createProjectFolder(
        name: 'seeded',
        parent: tmpDir.path,
        initialFiles: <Map<String, dynamic>>[
          <String, dynamic>{'path': 'README.txt', 'content': 'Hello world'},
        ],
      );
      final projectPath = result['projectPath'] as String;
      final content =
          await File(p.join(projectPath, 'README.txt')).readAsString();
      expect(content, 'Hello world');
    });

    test('map content encoded as pretty JSON', () async {
      final result = await createProjectFolder(
        name: 'json_seed',
        parent: tmpDir.path,
        initialFiles: <Map<String, dynamic>>[
          <String, dynamic>{
            'path': 'ui/app.json',
            'content': <String, dynamic>{'type': 'application'},
          },
        ],
      );
      final projectPath = result['projectPath'] as String;
      final raw =
          await File(p.join(projectPath, 'ui', 'app.json')).readAsString();
      final parsed = jsonDecode(raw) as Map;
      expect(parsed['type'], 'application');
    });

    test('null content writes empty string', () async {
      final result = await createProjectFolder(
        name: 'null_content',
        parent: tmpDir.path,
        initialFiles: <Map<String, dynamic>>[
          <String, dynamic>{'path': 'empty.txt', 'content': null},
        ],
      );
      final projectPath = result['projectPath'] as String;
      final content =
          await File(p.join(projectPath, 'empty.txt')).readAsString();
      expect(content, '');
    });

    test('entry with .. in path is silently skipped', () async {
      final result = await createProjectFolder(
        name: 'escape_attempt',
        parent: tmpDir.path,
        initialFiles: <Map<String, dynamic>>[
          <String, dynamic>{'path': '../evil.txt', 'content': 'escape'},
          <String, dynamic>{'path': 'safe.txt', 'content': 'ok'},
        ],
      );
      final projectPath = result['projectPath'] as String;
      // The evil entry is skipped — file must NOT appear at project root's
      // parent. The safe entry IS written.
      expect(
        File(p.join(p.dirname(projectPath), 'evil.txt')).existsSync(),
        isFalse,
      );
      expect(File(p.join(projectPath, 'safe.txt')).existsSync(), isTrue);
    });
  });
}
