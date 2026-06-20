/// Unit tests for [VibeUndoSidecar] and [UndoSnapshot].
///
/// Scenario set:
///   us1  UndoSnapshot.empty — both lists empty, isEmpty true
///   us2  UndoSnapshot with data — isEmpty false
///   us3  read — missing file returns empty snapshot
///   us4  write then read — round-trips undo + redo lists
///   us5  write — no stray .tmp file after write
///   us6  clear — removes the file
///   us7  clear — no-op when file absent
///   us8  read — corrupt file returns empty (no crash)
///   us9  read — non-list JSON returns empty
///   us10 write then clear then read — returns empty after clear
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/apps/app_builder/infra/vibe_undo_sidecar.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('undo_sidecar_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // ── us1 UndoSnapshot.empty ──────────────────────────────────────────
  group('us1 UndoSnapshot.empty', () {
    test('undo and redo lists are empty', () {
      expect(UndoSnapshot.empty.undo, isEmpty);
      expect(UndoSnapshot.empty.redo, isEmpty);
    });

    test('isEmpty returns true', () {
      expect(UndoSnapshot.empty.isEmpty, isTrue);
    });
  });

  // ── us2 UndoSnapshot with data ──────────────────────────────────────
  group('us2 UndoSnapshot with data', () {
    test('isEmpty returns false when undo has entries', () {
      const snap = UndoSnapshot(
        undo: [
          <String, dynamic>{'op': 'add', 'path': '/x'},
        ],
        redo: [],
      );
      expect(snap.isEmpty, isFalse);
    });

    test('isEmpty returns false when redo has entries', () {
      const snap = UndoSnapshot(
        undo: [],
        redo: [
          <String, dynamic>{'op': 'remove', 'path': '/y'},
        ],
      );
      expect(snap.isEmpty, isFalse);
    });
  });

  // ── us3 read missing ────────────────────────────────────────────────
  group('us3 read missing file', () {
    test('returns empty snapshot', () async {
      final sidecar = VibeUndoSidecar.open(tmp.path);
      final snap = await sidecar.read();
      expect(snap.isEmpty, isTrue);
    });
  });

  // ── us4 write → read round-trip ─────────────────────────────────────
  group('us4 write/read round-trip', () {
    test('undo list survives write + read', () async {
      final sidecar = VibeUndoSidecar.open(tmp.path);
      final undoEntry = <String, dynamic>{'layer': 'pages', 'ops': []};
      await sidecar.write(UndoSnapshot(undo: [undoEntry], redo: []));
      final restored = await sidecar.read();
      expect(restored.undo, hasLength(1));
      expect(restored.redo, isEmpty);
    });

    test('redo list survives write + read', () async {
      final sidecar = VibeUndoSidecar.open(tmp.path);
      final redoEntry = <String, dynamic>{'layer': 'pages', 'ops': []};
      await sidecar.write(UndoSnapshot(undo: [], redo: [redoEntry]));
      final restored = await sidecar.read();
      expect(restored.undo, isEmpty);
      expect(restored.redo, hasLength(1));
    });

    test('multiple entries survive write + read', () async {
      final sidecar = VibeUndoSidecar.open(tmp.path);
      final entries = [
        <String, dynamic>{'layer': 'pages', 'idx': 0},
        <String, dynamic>{'layer': 'pages', 'idx': 1},
      ];
      await sidecar.write(UndoSnapshot(undo: entries, redo: []));
      final restored = await sidecar.read();
      expect(restored.undo, hasLength(2));
    });
  });

  // ── us5 write no stray tmp ──────────────────────────────────────────
  group('us5 write atomic', () {
    test('no .tmp file remaining after write', () async {
      final sidecar = VibeUndoSidecar.open(tmp.path);
      await sidecar.write(UndoSnapshot.empty);
      final tmpFile = File(p.join(tmp.path, '${VibeUndoSidecar.fileName}.tmp'));
      expect(await tmpFile.exists(), isFalse);
    });

    test('written file is valid JSON', () async {
      final sidecar = VibeUndoSidecar.open(tmp.path);
      await sidecar.write(
        const UndoSnapshot(
          undo: [
            <String, dynamic>{'a': 1},
          ],
          redo: [],
        ),
      );
      final file = File(p.join(tmp.path, VibeUndoSidecar.fileName));
      expect(await file.exists(), isTrue);
      expect(() => jsonDecode(file.readAsStringSync()), returnsNormally);
    });
  });

  // ── us6 clear removes file ───────────────────────────────────────────
  group('us6 clear', () {
    test('file is gone after clear', () async {
      final sidecar = VibeUndoSidecar.open(tmp.path);
      await sidecar.write(
        const UndoSnapshot(
          undo: [
            <String, dynamic>{'x': 1},
          ],
          redo: [],
        ),
      );
      final file = File(p.join(tmp.path, VibeUndoSidecar.fileName));
      expect(await file.exists(), isTrue);
      await sidecar.clear();
      expect(await file.exists(), isFalse);
    });
  });

  // ── us7 clear no-op when absent ──────────────────────────────────────
  group('us7 clear no-op', () {
    test('no error when file does not exist', () async {
      final sidecar = VibeUndoSidecar.open(tmp.path);
      await expectLater(() => sidecar.clear(), returnsNormally);
    });
  });

  // ── us8 corrupt file ─────────────────────────────────────────────────
  group('us8 corrupt file', () {
    test('read returns empty snapshot without throwing', () async {
      final file = File(p.join(tmp.path, VibeUndoSidecar.fileName));
      await file.writeAsString('{not json!}');
      final sidecar = VibeUndoSidecar.open(tmp.path);
      final snap = await sidecar.read();
      expect(snap.isEmpty, isTrue);
    });
  });

  // ── us9 non-list JSON ────────────────────────────────────────────────
  group('us9 non-object JSON', () {
    test('read returns empty snapshot when root is not a map', () async {
      final file = File(p.join(tmp.path, VibeUndoSidecar.fileName));
      await file.writeAsString('"just a string"');
      final sidecar = VibeUndoSidecar.open(tmp.path);
      final snap = await sidecar.read();
      expect(snap.isEmpty, isTrue);
    });
  });

  // ── us10 write → clear → read ────────────────────────────────────────
  group('us10 write then clear then read', () {
    test('read returns empty after clear', () async {
      final sidecar = VibeUndoSidecar.open(tmp.path);
      await sidecar.write(
        const UndoSnapshot(
          undo: [
            <String, dynamic>{'x': 'y'},
          ],
          redo: [],
        ),
      );
      await sidecar.clear();
      final snap = await sidecar.read();
      expect(snap.isEmpty, isTrue);
    });
  });
}
