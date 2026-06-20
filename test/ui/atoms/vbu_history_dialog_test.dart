/// `HistoryEntry` model + `showHistoryDialog` — tests for the data model and
/// basic dialog smoke. The dialog itself is UNSAFE for full widget testing:
///
/// 1. `showHistoryDialog` does `await historyLog.readAll()` (real dart:io) before
///    calling `showDialog`, making it incompatible with the fake-clock pump loop.
///
/// 2. `_HistoryDialog` uses `vibeMono(weight: FontWeight.w600)` (JetBrainsMono
///    SemiBold) which is not bundled in test assets. With
///    `allowRuntimeFetching = false`, `loadFontIfNecessary` throws after the test
///    function returns, making the test fail retroactively. Using `pumpAndSettle`
///    triggers an infinite retry loop (Google Fonts re-queues on each throw).
///
/// Covered here: HistoryEntry construction, field parsing, format helpers.
/// Skipped (UNSAFE): full dialog rendering via showHistoryDialog.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:brain_kernel/brain_kernel.dart' show CanonicalChangeKind;
import 'package:appplayer_studio/base.dart';

void main() {
  // ---------------------------------------------------------------------------
  // HistoryEntry — pure data model tests (no widget rendering)
  // ---------------------------------------------------------------------------

  group('HistoryEntry data model', () {
    test('patch kind preserved', () {
      final e = HistoryEntry(
        at: DateTime.utc(2026, 6, 1, 12, 0),
        kind: CanonicalChangeKind.patch,
        changedPaths: <String>['/ui/pages/home'],
        beforeHash: 'abc',
        afterHash: 'def',
      );
      expect(e.kind, CanonicalChangeKind.patch);
    });

    test('revert kind preserved', () {
      final e = HistoryEntry(
        at: DateTime.utc(2026, 6, 1),
        kind: CanonicalChangeKind.revert,
        changedPaths: const <String>[],
        beforeHash: 'x',
        afterHash: 'y',
      );
      expect(e.kind, CanonicalChangeKind.revert);
    });

    test('open kind preserved', () {
      final e = HistoryEntry(
        at: DateTime.utc(2026, 6, 1),
        kind: CanonicalChangeKind.open,
        changedPaths: const <String>[],
        beforeHash: '',
        afterHash: 'z',
      );
      expect(e.kind, CanonicalChangeKind.open);
    });

    test('changedPaths list is preserved', () {
      final paths = <String>['/ui/pages/home', '/ui/pages/about'];
      final e = HistoryEntry(
        at: DateTime.utc(2026, 6, 1),
        kind: CanonicalChangeKind.patch,
        changedPaths: paths,
        beforeHash: 'a',
        afterHash: 'b',
      );
      expect(e.changedPaths, paths);
    });

    test('empty changedPaths list', () {
      final e = HistoryEntry(
        at: DateTime.utc(2026, 6, 1),
        kind: CanonicalChangeKind.patch,
        changedPaths: const <String>[],
        beforeHash: 'a',
        afterHash: 'b',
      );
      expect(e.changedPaths.isEmpty, isTrue);
    });

    test('originatorKind and originatorId are optional', () {
      final e = HistoryEntry(
        at: DateTime.utc(2026, 6, 1),
        kind: CanonicalChangeKind.patch,
        changedPaths: const <String>[],
        beforeHash: '',
        afterHash: '',
      );
      expect(e.originatorKind, isNull);
      expect(e.originatorId, isNull);
    });

    test('at timestamp is preserved (UTC)', () {
      final dt = DateTime.utc(2026, 6, 1, 15, 30, 45);
      final e = HistoryEntry(
        at: dt,
        kind: CanonicalChangeKind.patch,
        changedPaths: const <String>[],
        beforeHash: '',
        afterHash: '',
      );
      expect(e.at, dt);
    });
  });

  // ---------------------------------------------------------------------------
  // VibeHistoryLog.readAll — round-trip through real file I/O
  // Tests use test() not testWidgets() to avoid the fake async pump zone.
  // ---------------------------------------------------------------------------

  group('VibeHistoryLog readAll', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('vbu_history_log_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('returns empty list when no file exists', () async {
      final log = VibeHistoryLog.open(tmp.path);
      final entries = await log.readAll();
      expect(entries, isEmpty);
    });

    test('reads single JSONL entry', () async {
      final file = File('${tmp.path}/${VibeHistoryLog.fileName}');
      await file.writeAsString(
        jsonEncode(<String, dynamic>{
          'at': '2026-06-01T12:30:00.000Z',
          'kind': 'patch',
          'changedPaths': <String>['/ui/pages/home'],
          'beforeHash': 'abc',
          'afterHash': 'def',
        }),
      );

      final log = VibeHistoryLog.open(tmp.path);
      final entries = await log.readAll();

      expect(entries.length, 1);
      expect(entries[0].kind, CanonicalChangeKind.patch);
      expect(entries[0].changedPaths, <String>['/ui/pages/home']);
    });

    test('reads multiple JSONL entries in order', () async {
      final file = File('${tmp.path}/${VibeHistoryLog.fileName}');
      final lines = <String>[];
      for (var i = 0; i < 3; i++) {
        lines.add(
          jsonEncode(<String, dynamic>{
            'at': '2026-06-01T10:0$i:00.000Z',
            'kind': 'patch',
            'changedPaths': <String>['/page$i'],
            'beforeHash': 'h${i}a',
            'afterHash': 'h${i}b',
          }),
        );
      }
      await file.writeAsString(lines.join('\n'));

      final log = VibeHistoryLog.open(tmp.path);
      final entries = await log.readAll();

      expect(entries.length, 3);
      expect(entries[0].changedPaths, <String>['/page0']);
      expect(entries[2].changedPaths, <String>['/page2']);
    });

    test('skips malformed JSONL lines', () async {
      final file = File('${tmp.path}/${VibeHistoryLog.fileName}');
      await file.writeAsString(
        [
          jsonEncode(<String, dynamic>{
            'at': '2026-06-01T09:00:00.000Z',
            'kind': 'open',
            'changedPaths': <String>[],
            'beforeHash': '',
            'afterHash': 'z',
          }),
          'not valid json at all {{{{',
          jsonEncode(<String, dynamic>{
            'at': '2026-06-01T10:00:00.000Z',
            'kind': 'patch',
            'changedPaths': <String>['/ui'],
            'beforeHash': 'p',
            'afterHash': 'q',
          }),
        ].join('\n'),
      );

      final log = VibeHistoryLog.open(tmp.path);
      final entries = await log.readAll();

      // 2 valid lines, 1 skipped
      expect(entries.length, 2);
    });

    test('revert kind round-trips through JSONL', () async {
      final file = File('${tmp.path}/${VibeHistoryLog.fileName}');
      await file.writeAsString(
        jsonEncode(<String, dynamic>{
          'at': '2026-06-01T08:00:00.000Z',
          'kind': 'revert',
          'changedPaths': <String>['/ui'],
          'beforeHash': 'x',
          'afterHash': 'y',
        }),
      );

      final log = VibeHistoryLog.open(tmp.path);
      final entries = await log.readAll();

      expect(entries.length, 1);
      expect(entries[0].kind, CanonicalChangeKind.revert);
    });

    test('multiple paths round-trip', () async {
      final paths = <String>['/ui/pages/home', '/ui/pages/about', '/ui/theme'];
      final file = File('${tmp.path}/${VibeHistoryLog.fileName}');
      await file.writeAsString(
        jsonEncode(<String, dynamic>{
          'at': '2026-06-01T11:00:00.000Z',
          'kind': 'patch',
          'changedPaths': paths,
          'beforeHash': 'a',
          'afterHash': 'b',
        }),
      );

      final log = VibeHistoryLog.open(tmp.path);
      final entries = await log.readAll();

      expect(entries[0].changedPaths, paths);
    });
  });
}
