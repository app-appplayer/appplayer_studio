/// Unit tests for [FileToolsDispatcher] — the sandbox-bounded file-op
/// dispatcher the LLM uses during code generation.
///
/// All file I/O is rooted under [Directory.systemTemp] and cleaned up in
/// [tearDown]. Tests exercise real disk behaviour — no mocks.
///
/// Scenario set:
///   ft1  writeFile happy path — writes content, file readable back
///   ft2  writeFile auto-creates parent directories
///   ft3  writeFile rejects absolute path (escapes sandbox)
///   ft4  writeFile rejects path traversal with `..`
///   ft5  writeFile fires onAfterMutate with the resolved absolute path
///   ft6  readFile returns file content in entries[0]
///   ft7  readFile fails when file is missing
///   ft8  readFile rejects absolute path
///   ft9  editFile replaces exactly one occurrence
///   ft10 editFile fails when oldString is absent
///   ft11 editFile fails when oldString appears multiple times
///   ft12 editFile fails on missing file
///   ft13 editFile fires onAfterMutate on success
///   ft14 makeDir creates a nested directory and fires onAfterMutate
///   ft15 makeDir rejects absolute path
///   ft16 deleteFile removes a file and fires onAfterMutate
///   ft17 deleteFile removes a directory recursively
///   ft18 deleteFile returns failure when target is absent
///   ft19 deleteFile rejects absolute path
///   ft20 listDir returns sorted relative entries, directories end with /
///   ft21 listDir fails when directory is missing
///   ft22 listDir rejects absolute path
///   ft23 dispatch routes all six named tools and returns null for unknown
///   ft24 FileToolResult.toJson includes correct keys
///   ft25 encodeFileToolResult round-trips through jsonDecode
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/apps/app_builder/feat/file_tools.dart';

void main() {
  late Directory sandbox;
  late FileToolsDispatcher dispatcher;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('file_tools_test_');
    dispatcher = FileToolsDispatcher(projectRoot: sandbox.path);
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  // ── ft1: writeFile happy path ─────────────────────────────────────────────

  test('ft1: writeFile writes content and succeeds', () async {
    final r = await dispatcher.writeFile(path: 'hello.txt', content: 'world');
    expect(r.success, isTrue);
    expect(r.path, 'hello.txt');
    final content =
        await File(p.join(sandbox.path, 'hello.txt')).readAsString();
    expect(content, 'world');
  });

  // ── ft2: writeFile creates parent directories ─────────────────────────────

  test('ft2: writeFile auto-creates intermediate directories', () async {
    final r = await dispatcher.writeFile(
      path: 'a/b/c/deep.txt',
      content: 'deep',
    );
    expect(r.success, isTrue);
    expect(await File(p.join(sandbox.path, 'a/b/c/deep.txt')).exists(), isTrue);
  });

  // ── ft3: writeFile rejects absolute path ─────────────────────────────────

  test('ft3: writeFile rejects an absolute path', () async {
    final r = await dispatcher.writeFile(path: '/etc/evil.txt', content: 'x');
    expect(r.success, isFalse);
    expect(r.message, contains('escapes'));
  });

  // ── ft4: writeFile rejects path traversal ────────────────────────────────

  test('ft4: writeFile rejects .. path traversal', () async {
    final r = await dispatcher.writeFile(path: '../outside.txt', content: 'x');
    expect(r.success, isFalse);
    expect(r.message, contains('escapes'));
  });

  // ── ft5: writeFile fires onAfterMutate ───────────────────────────────────

  test(
    'ft5: writeFile calls onAfterMutate with the resolved absolute path',
    () async {
      String? captured;
      final d = FileToolsDispatcher(
        projectRoot: sandbox.path,
        onAfterMutate: (abs) async => captured = abs,
      );
      await d.writeFile(path: 'file.txt', content: 'ok');
      expect(captured, p.join(sandbox.path, 'file.txt'));
    },
  );

  // ── ft6: readFile returns content in entries[0] ──────────────────────────

  test('ft6: readFile returns file content in entries[0]', () async {
    await File(p.join(sandbox.path, 'r.txt')).writeAsString('data');
    final r = await dispatcher.readFile(path: 'r.txt');
    expect(r.success, isTrue);
    expect(r.entries, isNotNull);
    expect(r.entries!.first, 'data');
    expect(r.message, contains('bytes'));
  });

  // ── ft7: readFile fails when file is missing ─────────────────────────────

  test('ft7: readFile returns failure for missing file', () async {
    final r = await dispatcher.readFile(path: 'ghost.txt');
    expect(r.success, isFalse);
    expect(r.message, contains('not found'));
  });

  // ── ft8: readFile rejects absolute path ──────────────────────────────────

  test('ft8: readFile rejects an absolute path', () async {
    final r = await dispatcher.readFile(path: '/etc/hosts');
    expect(r.success, isFalse);
    expect(r.message, contains('escapes'));
  });

  // ── ft9: editFile replaces exactly one occurrence ─────────────────────────

  test('ft9: editFile replaces the unique oldString', () async {
    await File(p.join(sandbox.path, 'code.txt')).writeAsString('aaa bbb ccc');
    final r = await dispatcher.editFile(
      path: 'code.txt',
      oldString: 'bbb',
      newString: 'ZZZ',
    );
    expect(r.success, isTrue);
    final updated = await File(p.join(sandbox.path, 'code.txt')).readAsString();
    expect(updated, 'aaa ZZZ ccc');
  });

  // ── ft10: editFile fails when oldString absent ────────────────────────────

  test('ft10: editFile fails when oldString is absent', () async {
    await File(p.join(sandbox.path, 'code.txt')).writeAsString('hello world');
    final r = await dispatcher.editFile(
      path: 'code.txt',
      oldString: 'MISSING',
      newString: 'x',
    );
    expect(r.success, isFalse);
    expect(r.message, contains('not found'));
  });

  // ── ft11: editFile fails on ambiguous match ───────────────────────────────

  test('ft11: editFile fails when oldString matches multiple times', () async {
    await File(p.join(sandbox.path, 'dup.txt')).writeAsString('foo foo foo');
    final r = await dispatcher.editFile(
      path: 'dup.txt',
      oldString: 'foo',
      newString: 'bar',
    );
    expect(r.success, isFalse);
    expect(r.message, contains('multiple'));
  });

  // ── ft12: editFile fails on missing file ──────────────────────────────────

  test('ft12: editFile returns failure for missing file', () async {
    final r = await dispatcher.editFile(
      path: 'absent.txt',
      oldString: 'x',
      newString: 'y',
    );
    expect(r.success, isFalse);
    expect(r.message, contains('not found'));
  });

  // ── ft13: editFile fires onAfterMutate ───────────────────────────────────

  test('ft13: editFile calls onAfterMutate on success', () async {
    String? captured;
    final d = FileToolsDispatcher(
      projectRoot: sandbox.path,
      onAfterMutate: (abs) async => captured = abs,
    );
    await File(p.join(sandbox.path, 'e.txt')).writeAsString('old text here');
    await d.editFile(path: 'e.txt', oldString: 'old text', newString: 'NEW');
    expect(captured, p.join(sandbox.path, 'e.txt'));
  });

  // ── ft14: makeDir creates nested directory ────────────────────────────────

  test(
    'ft14: makeDir creates a nested directory and fires onAfterMutate',
    () async {
      String? captured;
      final d = FileToolsDispatcher(
        projectRoot: sandbox.path,
        onAfterMutate: (abs) async => captured = abs,
      );
      final r = await d.makeDir(path: 'src/lib/utils');
      expect(r.success, isTrue);
      expect(
        await Directory(p.join(sandbox.path, 'src/lib/utils')).exists(),
        isTrue,
      );
      expect(captured, p.join(sandbox.path, 'src/lib/utils'));
    },
  );

  // ── ft15: makeDir rejects absolute path ──────────────────────────────────

  test('ft15: makeDir rejects an absolute path', () async {
    final r = await dispatcher.makeDir(path: '/tmp/escape');
    expect(r.success, isFalse);
    expect(r.message, contains('escapes'));
  });

  // ── ft16: deleteFile removes a file ──────────────────────────────────────

  test('ft16: deleteFile removes a file and fires onAfterMutate', () async {
    final file = File(p.join(sandbox.path, 'del.txt'));
    await file.writeAsString('x');
    String? captured;
    final d = FileToolsDispatcher(
      projectRoot: sandbox.path,
      onAfterMutate: (abs) async => captured = abs,
    );
    final r = await d.deleteFile(path: 'del.txt');
    expect(r.success, isTrue);
    expect(r.message, contains('deleted'));
    expect(await file.exists(), isFalse);
    expect(captured, file.path);
  });

  // ── ft17: deleteFile removes a directory recursively ─────────────────────

  test('ft17: deleteFile removes a directory recursively', () async {
    final dir = Directory(p.join(sandbox.path, 'mydir'));
    await dir.create();
    await File(p.join(dir.path, 'inner.txt')).writeAsString('x');
    final r = await dispatcher.deleteFile(path: 'mydir');
    expect(r.success, isTrue);
    expect(await dir.exists(), isFalse);
  });

  // ── ft18: deleteFile returns failure for absent target ────────────────────

  test('ft18: deleteFile returns failure when target does not exist', () async {
    final r = await dispatcher.deleteFile(path: 'ghost_dir');
    expect(r.success, isFalse);
    expect(r.message, contains('not found'));
  });

  // ── ft19: deleteFile rejects absolute path ────────────────────────────────

  test('ft19: deleteFile rejects an absolute path', () async {
    final r = await dispatcher.deleteFile(path: '/tmp/nope');
    expect(r.success, isFalse);
    expect(r.message, contains('escapes'));
  });

  // ── ft20: listDir returns sorted relative entries ─────────────────────────

  test(
    'ft20: listDir returns sorted entries, directory entries end with /',
    () async {
      await File(p.join(sandbox.path, 'b.txt')).writeAsString('b');
      await File(p.join(sandbox.path, 'a.txt')).writeAsString('a');
      await Directory(p.join(sandbox.path, 'subdir')).create();
      final r = await dispatcher.listDir(path: '.');
      expect(r.success, isTrue);
      expect(r.entries, isNotNull);
      // Relative paths: 'a.txt', 'b.txt', 'subdir/'
      expect(r.entries, contains('a.txt'));
      expect(r.entries, contains('b.txt'));
      expect(r.entries, contains('subdir/'));
      // Verify sorted order (a.txt before b.txt).
      final aIdx = r.entries!.indexOf('a.txt');
      final bIdx = r.entries!.indexOf('b.txt');
      expect(aIdx, lessThan(bIdx));
    },
  );

  // ── ft21: listDir fails when directory is missing ─────────────────────────

  test('ft21: listDir returns failure for missing directory', () async {
    final r = await dispatcher.listDir(path: 'no_such_dir');
    expect(r.success, isFalse);
    expect(r.message, contains('not found'));
  });

  // ── ft22: listDir rejects absolute path ──────────────────────────────────

  test('ft22: listDir rejects an absolute path', () async {
    final r = await dispatcher.listDir(path: '/tmp');
    expect(r.success, isFalse);
    expect(r.message, contains('escapes'));
  });

  // ── ft23: dispatch routing ────────────────────────────────────────────────

  test('ft23: dispatch routes all six tools correctly', () async {
    // write_file
    final w = await dispatcher.dispatch('write_file', <String, dynamic>{
      'path': 'dispatch.txt',
      'content': 'ok',
    });
    expect(w, isNotNull);
    expect(w!.success, isTrue);

    // read_file
    final rd = await dispatcher.dispatch('read_file', <String, dynamic>{
      'path': 'dispatch.txt',
    });
    expect(rd!.success, isTrue);
    expect(rd.entries!.first, 'ok');

    // edit_file
    final ed = await dispatcher.dispatch('edit_file', <String, dynamic>{
      'path': 'dispatch.txt',
      'oldString': 'ok',
      'newString': 'updated',
    });
    expect(ed!.success, isTrue);

    // make_dir
    final md = await dispatcher.dispatch('make_dir', <String, dynamic>{
      'path': 'newdir',
    });
    expect(md!.success, isTrue);

    // list_dir
    final ls = await dispatcher.dispatch('list_dir', <String, dynamic>{
      'path': '.',
    });
    expect(ls!.success, isTrue);
    expect(ls.entries, contains('dispatch.txt'));

    // delete_file
    final del = await dispatcher.dispatch('delete_file', <String, dynamic>{
      'path': 'dispatch.txt',
    });
    expect(del!.success, isTrue);

    // unknown — must return null
    final unknown = await dispatcher.dispatch('unknown_tool', const {});
    expect(unknown, isNull);
  });

  // ── ft24: FileToolResult.toJson ───────────────────────────────────────────

  test('ft24: FileToolResult.toJson includes expected keys', () async {
    final success = FileToolResult.success(
      message: 'wrote 5 bytes',
      path: 'foo.txt',
      entries: <String>['content'],
    );
    final j = success.toJson();
    expect(j['ok'], isTrue);
    expect(j['message'], 'wrote 5 bytes');
    expect(j['path'], 'foo.txt');
    expect(j['entries'], <String>['content']);

    final failure = FileToolResult.failure('oops', path: 'bar.txt');
    final jf = failure.toJson();
    expect(jf['ok'], isFalse);
    expect(
      jf.containsKey('entries'),
      isFalse,
      reason: 'null entries must be omitted from JSON',
    );
  });

  // ── ft25: encodeFileToolResult round-trip ─────────────────────────────────

  test('ft25: encodeFileToolResult produces valid JSON', () async {
    final r = FileToolResult.success(
      message: 'read 10 bytes',
      path: 'x.txt',
      entries: <String>['hello'],
    );
    final encoded = encodeFileToolResult(r);
    final decoded = jsonDecode(encoded) as Map<String, dynamic>;
    expect(decoded['ok'], isTrue);
    expect(decoded['message'], 'read 10 bytes');
    expect(decoded['entries'], <String>['hello']);
  });

  // ── claimedTools constant ─────────────────────────────────────────────────

  test('claimedTools contains the six expected tool names', () {
    expect(
      FileToolsDispatcher.claimedTools,
      containsAll(<String>[
        'write_file',
        'edit_file',
        'make_dir',
        'delete_file',
        'read_file',
        'list_dir',
      ]),
    );
    expect(FileToolsDispatcher.claimedTools.length, 6);
  });

  // ── toolDefinitions schema shape ─────────────────────────────────────────

  test(
    'toolDefinitions has six entries each with name + description + parameters',
    () {
      final defs = FileToolsDispatcher.toolDefinitions;
      expect(defs.length, 6);
      for (final d in defs) {
        expect(d.containsKey('name'), isTrue);
        expect(d.containsKey('description'), isTrue);
        expect(d.containsKey('parameters'), isTrue);
        final params = d['parameters'] as Map<String, dynamic>;
        expect(params['type'], 'object');
        expect(params.containsKey('required'), isTrue);
      }
    },
  );
}
