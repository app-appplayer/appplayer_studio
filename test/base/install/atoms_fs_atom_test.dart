/// Unit tests for `FsAtom` — the bundle-scoped filesystem atom.
/// Also covers `AtomVerb` / `AtomCategory` interface basics.
///
///   fa1  AtomVerb carries name + optional description
///   fa2  FsAtom.key is 'fs'
///   fa3  FsAtom.verbs declares read / list / exists
///   fa4  dispatch 'read' returns file content
///   fa5  dispatch 'read' throws StateError for missing file
///   fa6  dispatch 'list' returns sorted entry names
///   fa7  dispatch 'list' with no args defaults to '.'
///   fa8  dispatch 'exists' true for present file, false for absent
///   fa9  path traversal outside bundle root throws ArgumentError
///   fa10 absolute path arg throws ArgumentError
///   fa11 unknown verb throws ArgumentError
///   fa12 missing required arg throws ArgumentError
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/base/install/atoms/atom_category.dart';
import 'package:appplayer_studio/src/base/install/atoms/fs_atom.dart';

void main() {
  late Directory tmpDir;
  late FsAtom atom;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('fs_atom_test_');
    // Create a small test tree inside the bundle root.
    await File(p.join(tmpDir.path, 'hello.txt')).writeAsString('Hello world');
    await Directory(p.join(tmpDir.path, 'subdir')).create();
    await File(
      p.join(tmpDir.path, 'subdir', 'nested.txt'),
    ).writeAsString('Nested');
    atom = FsAtom(bundleRoot: tmpDir.path);
  });

  tearDown(() async {
    if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
  });

  // ---------------------------------------------------------------------------
  // fa1 — AtomVerb
  // ---------------------------------------------------------------------------
  group('fa1 AtomVerb', () {
    test('fa1 name is accessible', () {
      const v = AtomVerb('read', description: 'Read a file');
      expect(v.name, 'read');
      expect(v.description, 'Read a file');
    });

    test('fa1 description is optional (null)', () {
      const v = AtomVerb('list');
      expect(v.name, 'list');
      expect(v.description, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // fa2–fa3 — FsAtom metadata
  // ---------------------------------------------------------------------------
  group('fa2–fa3 FsAtom metadata', () {
    test('fa2 key is "fs"', () {
      expect(atom.key, 'fs');
    });

    test('fa3 verbs includes read, list, exists', () {
      final names = atom.verbs.map((v) => v.name).toSet();
      expect(names, containsAll(<String>['read', 'list', 'exists']));
    });
  });

  // ---------------------------------------------------------------------------
  // fa4 — read
  // ---------------------------------------------------------------------------
  group('fa4 dispatch read', () {
    test('fa4 returns file content as String', () async {
      final result = await atom.dispatch('read', ['hello.txt']);
      expect(result, 'Hello world');
    });

    test('fa4 reads nested file via relative path', () async {
      final result = await atom.dispatch('read', ['subdir/nested.txt']);
      expect(result, 'Nested');
    });

    // fa5
    test('fa5 throws StateError for missing file', () async {
      expect(
        () => atom.dispatch('read', ['no_such_file.txt']),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // fa6–fa7 — list
  // ---------------------------------------------------------------------------
  group('fa6 dispatch list', () {
    test('fa6 returns sorted entry names', () async {
      final result = await atom.dispatch('list', ['.']) as List<String>;
      expect(result, containsAll(<String>['hello.txt', 'subdir']));
      // Result must be sorted.
      final sorted = [...result]..sort();
      expect(result, sorted);
    });

    test('fa6 lists a subdirectory', () async {
      final result = await atom.dispatch('list', ['subdir']) as List<String>;
      expect(result, contains('nested.txt'));
    });

    // fa7
    test('fa7 no args defaults to root', () async {
      final result = await atom.dispatch('list', const []) as List<String>;
      expect(result, isNotEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // fa8 — exists
  // ---------------------------------------------------------------------------
  group('fa8 dispatch exists', () {
    test('fa8 returns true for a present file', () async {
      expect(await atom.dispatch('exists', ['hello.txt']), isTrue);
    });

    test('fa8 returns true for a present directory', () async {
      expect(await atom.dispatch('exists', ['subdir']), isTrue);
    });

    test('fa8 returns false for absent path', () async {
      expect(await atom.dispatch('exists', ['ghost.txt']), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // fa9 — path traversal
  // ---------------------------------------------------------------------------
  group('fa9 path traversal rejected', () {
    test('fa9 .. that escapes bundle root throws ArgumentError', () {
      expect(
        () => atom.dispatch('read', ['../escape.txt']),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('fa9 nested traversal that escapes throws ArgumentError', () {
      expect(
        () => atom.dispatch('read', ['subdir/../../escape.txt']),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('fa9 traversal that stays inside is allowed', () async {
      // subdir/../hello.txt resolves to hello.txt inside root — allowed.
      final result = await atom.dispatch('read', ['subdir/../hello.txt']);
      expect(result, 'Hello world');
    });
  });

  // ---------------------------------------------------------------------------
  // fa10 — absolute path
  // ---------------------------------------------------------------------------
  group('fa10 absolute path rejected', () {
    test('fa10 absolute path throws ArgumentError', () {
      expect(
        () => atom.dispatch('read', ['/etc/passwd']),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // fa11 — unknown verb
  // ---------------------------------------------------------------------------
  group('fa11 unknown verb', () {
    test('fa11 throws ArgumentError', () {
      expect(
        () => atom.dispatch('write', ['x.txt', 'content']),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // fa12 — missing required arg
  // ---------------------------------------------------------------------------
  group('fa12 missing required arg', () {
    test('fa12 read with no args throws ArgumentError', () {
      expect(
        () => atom.dispatch('read', const []),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('fa12 exists with no args throws ArgumentError', () {
      expect(
        () => atom.dispatch('exists', const []),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
