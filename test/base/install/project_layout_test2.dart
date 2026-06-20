/// Unit tests for `createProjectFolder` — the disk-side scaffolding helper.
///
/// Tests use temp directories and are boot-independent.
/// The existing `project_layout_test.dart` already exists; these are
/// additional scenarios not yet covered there.
///
/// Scenarios:
///   pl1  empty name → {ok: false, error: 'name required'}
///   pl2  empty parent → {ok: false, error: 'parent required'}
///   pl3  name with slash → path traversal rejected
///   pl4  name with '..' → rejected
///   pl5  existing folder → rejected (no overwrite)
///   pl6  happy path — creates project / bundle / drafts / build dirs
///   pl7  happy path — creates .sbproj metadata file with expected keys
///   pl8  custom bundleSubdir overrides default '<name>.mbd'
///   pl9  initialFiles with string content are written verbatim
///   pl10 initialFiles with '..' path skipped (security)
///   pl11 initialFiles with non-string content written as pretty JSON
///   pl12 returned map contains ok=true and projectPath / bundlePath / metaFile
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/base/install/project_layout.dart';

Future<Directory> _tmpDir() => Directory.systemTemp.createTemp('pl2_test_');

void main() {
  group('createProjectFolder', () {
    late Directory root;

    setUp(() async => root = await _tmpDir());
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    // pl1
    test('pl1 empty name returns error', () async {
      final r = await createProjectFolder(name: '', parent: root.path);
      expect(r['ok'], isFalse);
      expect((r['error'] as String).toLowerCase(), contains('name'));
    });

    // pl2
    test('pl2 empty parent returns error', () async {
      final r = await createProjectFolder(name: 'proj', parent: '');
      expect(r['ok'], isFalse);
      expect((r['error'] as String).toLowerCase(), contains('parent'));
    });

    // pl3
    test('pl3 name with slash rejected', () async {
      final r = await createProjectFolder(name: 'a/b', parent: root.path);
      expect(r['ok'], isFalse);
    });

    // pl4
    test('pl4 name with .. rejected', () async {
      final r = await createProjectFolder(name: '..', parent: root.path);
      expect(r['ok'], isFalse);
    });

    // pl5
    test('pl5 existing folder returns error', () async {
      final existing = Directory(p.join(root.path, 'existing'));
      await existing.create();
      final r = await createProjectFolder(name: 'existing', parent: root.path);
      expect(r['ok'], isFalse);
      expect((r['error'] as String), contains('already exists'));
    });

    // pl6
    test('pl6 happy path creates required directories', () async {
      final r = await createProjectFolder(name: 'proj1', parent: root.path);
      expect(r['ok'], isTrue);
      final projPath = r['projectPath'] as String;
      expect(Directory(projPath).existsSync(), isTrue);
      expect(Directory(p.join(projPath, 'proj1.mbd')).existsSync(), isTrue);
      expect(Directory(p.join(projPath, 'drafts')).existsSync(), isTrue);
      expect(Directory(p.join(projPath, 'build')).existsSync(), isTrue);
    });

    // pl7
    test('pl7 metadata file contains expected keys', () async {
      final r = await createProjectFolder(name: 'myproj', parent: root.path);
      expect(r['ok'], isTrue);
      final metaPath = r['metaFile'] as String;
      final raw = File(metaPath).readAsStringSync();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      expect(json['schemaVersion'], '0.1');
      expect(json['name'], 'myproj');
      expect(json['bundle'], 'myproj.mbd');
      expect(json.containsKey('createdAt'), isTrue);
      expect(json.containsKey('activeChannel'), isTrue);
    });

    // pl8
    test('pl8 custom bundleSubdir overrides default', () async {
      final r = await createProjectFolder(
        name: 'custom',
        parent: root.path,
        bundleSubdir: 'custom_bundle.mbd',
      );
      expect(r['ok'], isTrue);
      final bundlePath = r['bundlePath'] as String;
      expect(p.basename(bundlePath), 'custom_bundle.mbd');
      expect(Directory(bundlePath).existsSync(), isTrue);
    });

    // pl9
    test('pl9 initialFiles string content written verbatim', () async {
      final r = await createProjectFolder(
        name: 'withfiles',
        parent: root.path,
        initialFiles: [
          {'path': 'README.md', 'content': '# Hello'},
        ],
      );
      expect(r['ok'], isTrue);
      final projPath = r['projectPath'] as String;
      final readme = File(p.join(projPath, 'README.md'));
      expect(readme.existsSync(), isTrue);
      expect(readme.readAsStringSync(), '# Hello');
    });

    // pl10
    test('pl10 initialFiles with .. path skipped', () async {
      final r = await createProjectFolder(
        name: 'safeguard',
        parent: root.path,
        initialFiles: [
          {'path': '../evil.txt', 'content': 'EVIL'},
        ],
      );
      expect(r['ok'], isTrue);
      // evil.txt must not exist next to root
      final evil = File(p.join(root.path, 'evil.txt'));
      expect(evil.existsSync(), isFalse);
    });

    // pl11
    test('pl11 non-string content written as pretty JSON', () async {
      final r = await createProjectFolder(
        name: 'jsonfile',
        parent: root.path,
        initialFiles: [
          {
            'path': 'config.json',
            'content': {'key': 'value', 'num': 42},
          },
        ],
      );
      expect(r['ok'], isTrue);
      final projPath = r['projectPath'] as String;
      final cfg = File(p.join(projPath, 'config.json'));
      expect(cfg.existsSync(), isTrue);
      final decoded = jsonDecode(cfg.readAsStringSync());
      expect(decoded['key'], 'value');
      expect(decoded['num'], 42);
    });

    // pl12
    test('pl12 returned map contains ok=true and paths', () async {
      final r = await createProjectFolder(name: 'ret', parent: root.path);
      expect(r['ok'], isTrue);
      expect(r['projectPath'], isA<String>());
      expect(r['bundlePath'], isA<String>());
      expect(r['metaFile'], isA<String>());
    });
  });
}
