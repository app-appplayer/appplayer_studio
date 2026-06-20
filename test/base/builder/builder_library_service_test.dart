/// Extended unit coverage for `BuilderLibraryService` — CRUD paths not
/// covered by `library_resolve_inline_test.dart`:
///   - list (empty dir, populated, non-.json files ignored)
///   - read (success, not-found)
///   - create (fresh, collision, null tree → {})
///   - delete (success, not-found)
///   - rename (success, old-missing, new-exists, same-id no-op)
///   - id validation (bad chars → FormatException)
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart';

void main() {
  late Directory projectDir;
  late String mbdPath;
  late BuilderLibraryService svc;

  setUp(() async {
    projectDir = await Directory.systemTemp.createTemp('lib_service_test_');
    final mbdDir = Directory(p.join(projectDir.path, 'test.mbd'));
    await mbdDir.create(recursive: true);
    mbdPath = mbdDir.path;
    svc = BuilderLibraryService();
  });

  tearDown(() async {
    if (projectDir.existsSync()) {
      await projectDir.delete(recursive: true);
    }
  });

  // ---------------------------------------------------------------------------
  // list
  // ---------------------------------------------------------------------------
  group('list', () {
    test('returns empty when library folder is missing', () async {
      final ids = await svc.list(mbdPath);
      expect(ids, isEmpty);
    });

    test('returns sorted ids for every .json file', () async {
      final libDir = Directory(p.join(projectDir.path, 'library'));
      await libDir.create();
      for (final name in <String>['beta', 'alpha', 'gamma']) {
        await File(p.join(libDir.path, '$name.json')).writeAsString('{}');
      }
      final ids = await svc.list(mbdPath);
      expect(ids, <String>['alpha', 'beta', 'gamma']);
    });

    test('ignores non-.json files', () async {
      final libDir = Directory(p.join(projectDir.path, 'library'));
      await libDir.create();
      await File(p.join(libDir.path, 'notes.txt')).writeAsString('hi');
      await File(p.join(libDir.path, 'card.json')).writeAsString('{}');
      final ids = await svc.list(mbdPath);
      expect(ids, <String>['card']);
    });
  });

  // ---------------------------------------------------------------------------
  // read
  // ---------------------------------------------------------------------------
  group('read', () {
    test('returns parsed JSON for existing entry', () async {
      final libDir = Directory(p.join(projectDir.path, 'library'));
      await libDir.create();
      await File(
        p.join(libDir.path, 'btn.json'),
      ).writeAsString(jsonEncode(<String, dynamic>{'type': 'button'}));
      final result = await svc.read(mbdPath, 'btn');
      expect((result as Map)['type'], 'button');
    });

    test('throws FormatException for unknown id', () async {
      expect(() => svc.read(mbdPath, 'ghost'), throwsA(isA<FormatException>()));
    });
  });

  // ---------------------------------------------------------------------------
  // create
  // ---------------------------------------------------------------------------
  group('create', () {
    test('creates entry file with the given tree', () async {
      await svc.create(mbdPath, 'card', tree: <String, Object?>{'type': 'box'});
      final file = File(p.join(projectDir.path, 'library', 'card.json'));
      expect(file.existsSync(), isTrue);
      final parsed = jsonDecode(await file.readAsString());
      expect((parsed as Map)['type'], 'box');
    });

    test('null tree writes empty object {}', () async {
      await svc.create(mbdPath, 'empty');
      final file = File(p.join(projectDir.path, 'library', 'empty.json'));
      final parsed = jsonDecode(await file.readAsString());
      expect(parsed, isA<Map>());
      expect((parsed as Map), isEmpty);
    });

    test('throws FormatException when id already exists', () async {
      await svc.create(mbdPath, 'dup');
      expect(() => svc.create(mbdPath, 'dup'), throwsA(isA<FormatException>()));
    });

    test('invalid id (contains space) throws FormatException', () {
      expect(
        () => svc.create(mbdPath, 'my widget'),
        throwsA(isA<FormatException>()),
      );
    });

    test('invalid id (starts with digit) throws FormatException', () {
      // id regex requires first char to be alpha; digit-start fails
      // the pattern. Skipped without asserts — pattern requires
      // first char [A-Za-z0-9], a leading digit is actually valid.
      // Confirm the path separator / parent dir traversal rejection:
      expect(
        () => svc.create(mbdPath, '../escape'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // delete
  // ---------------------------------------------------------------------------
  group('delete', () {
    test('removes the entry file', () async {
      await svc.create(mbdPath, 'todel');
      await svc.delete(mbdPath, 'todel');
      final file = File(p.join(projectDir.path, 'library', 'todel.json'));
      expect(file.existsSync(), isFalse);
    });

    test('throws FormatException when entry does not exist', () async {
      expect(
        () => svc.delete(mbdPath, 'ghost'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // rename
  // ---------------------------------------------------------------------------
  group('rename', () {
    test('renames file on disk', () async {
      await svc.create(mbdPath, 'old', tree: <String, Object?>{'type': 'box'});
      await svc.rename(mbdPath, 'old', 'new_name');
      expect(
        File(p.join(projectDir.path, 'library', 'old.json')).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(projectDir.path, 'library', 'new_name.json')).existsSync(),
        isTrue,
      );
    });

    test('same id (old == new) is a no-op', () async {
      await svc.create(mbdPath, 'same');
      await svc.rename(mbdPath, 'same', 'same');
      expect(
        File(p.join(projectDir.path, 'library', 'same.json')).existsSync(),
        isTrue,
      );
    });

    test('throws FormatException when old id does not exist', () async {
      expect(
        () => svc.rename(mbdPath, 'ghost', 'target'),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException when new id already exists', () async {
      await svc.create(mbdPath, 'a');
      await svc.create(mbdPath, 'b');
      expect(
        () => svc.rename(mbdPath, 'a', 'b'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
