/// Unit tests for [VibeChatLog] — the append-only JSONL chat log persisted
/// at `<projectPath>/chat.jsonl`.
///
/// All I/O targets [Directory.systemTemp]; each test gets a fresh temp dir
/// cleaned up in [tearDown]. Tests exercise real disk behaviour.
///
/// Scenario set:
///   cl1   readAll() returns empty list when file does not exist
///   cl2   append() creates the file on first write
///   cl3   append() accumulates turns in order
///   cl4   readAll() parses role / text / at fields correctly
///   cl5   readAll() skips malformed lines without dropping valid ones
///   cl6   readAll() tolerates empty lines (blank lines are ignored)
///   cl7   clear() deletes the file; subsequent readAll() returns empty
///   cl8   clear() is a no-op when file does not exist
///   cl9   removeTurn() removes exactly the matching turn, leaves others
///   cl10  removeTurn() is a no-op when no turn matches
///   cl11  fileName constant is 'chat.jsonl'
///   cl12  open() places the log file inside the given projectPath
///   cl13  append() best-effort — does not throw when parent dir exists
///   cl14  readAll() falls back gracefully when the entire file is corrupt JSON
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart' show ChatTurn;
import 'package:appplayer_studio/src/apps/app_builder/infra/vibe_chat_log.dart';

ChatTurn _turn(String role, String text, {DateTime? at}) =>
    ChatTurn(role: role, text: text, at: at ?? DateTime.utc(2026, 1, 1, 12));

void main() {
  late Directory dir;
  late VibeChatLog log;
  late File chatFile;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('vibe_chat_log_test_');
    log = VibeChatLog.open(dir.path);
    chatFile = File('${dir.path}/${VibeChatLog.fileName}');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  // ── cl1 ────────────────────────────────────────────────────────────────────

  test('cl1: readAll() returns empty list when file does not exist', () async {
    expect(await chatFile.exists(), isFalse);
    final turns = await log.readAll();
    expect(turns, isEmpty);
  });

  // ── cl2 ────────────────────────────────────────────────────────────────────

  test('cl2: append() creates chat.jsonl on first write', () async {
    expect(await chatFile.exists(), isFalse);
    await log.append(_turn('user', 'hello'));
    expect(await chatFile.exists(), isTrue);
  });

  // ── cl3 ────────────────────────────────────────────────────────────────────

  test('cl3: append() accumulates multiple turns in insertion order', () async {
    await log.append(_turn('user', 'first'));
    await log.append(_turn('assistant', 'second'));
    await log.append(_turn('user', 'third'));

    final turns = await log.readAll();
    expect(turns.length, 3);
    expect(turns[0].text, 'first');
    expect(turns[1].text, 'second');
    expect(turns[2].text, 'third');
  });

  // ── cl4 ────────────────────────────────────────────────────────────────────

  test('cl4: readAll() correctly parses role, text, and at fields', () async {
    final ts = DateTime.utc(2026, 6, 5, 9, 0, 0);
    await log.append(_turn('user', 'hi there', at: ts));

    final turns = await log.readAll();
    expect(turns.length, 1);
    expect(turns.first.role, 'user');
    expect(turns.first.text, 'hi there');
    // Timestamps are stored as ISO 8601 UTC strings.
    expect(turns.first.at.toIso8601String(), ts.toIso8601String());
  });

  // ── cl5 ────────────────────────────────────────────────────────────────────

  test(
    'cl5: readAll() skips malformed lines without dropping valid turns',
    () async {
      // Write one valid turn, then inject a corrupt line, then another valid turn.
      await log.append(_turn('user', 'before'));
      await chatFile.writeAsString('NOT VALID JSON\n', mode: FileMode.append);
      await log.append(_turn('assistant', 'after'));

      final turns = await log.readAll();
      expect(turns.length, 2);
      expect(turns.map((t) => t.text).toList(), <String>['before', 'after']);
    },
  );

  // ── cl6 ────────────────────────────────────────────────────────────────────

  test('cl6: readAll() ignores blank / whitespace-only lines', () async {
    await log.append(_turn('user', 'alpha'));
    await chatFile.writeAsString('\n   \n', mode: FileMode.append);
    await log.append(_turn('user', 'beta'));

    final turns = await log.readAll();
    expect(turns.length, 2);
  });

  // ── cl7 ────────────────────────────────────────────────────────────────────

  test(
    'cl7: clear() deletes the file; readAll() returns empty after',
    () async {
      await log.append(_turn('user', 'x'));
      expect(await chatFile.exists(), isTrue);

      await log.clear();
      expect(await chatFile.exists(), isFalse);

      final after = await log.readAll();
      expect(after, isEmpty);
    },
  );

  // ── cl8 ────────────────────────────────────────────────────────────────────

  test('cl8: clear() is a no-op when the file does not exist', () async {
    expect(await chatFile.exists(), isFalse);
    // Must not throw.
    await expectLater(log.clear(), completes);
    expect(await chatFile.exists(), isFalse);
  });

  // ── cl9 ────────────────────────────────────────────────────────────────────

  test(
    'cl9: removeTurn() removes exactly the matching turn, preserves others',
    () async {
      final ts = DateTime.utc(2026, 6, 5, 10);
      final target = _turn('user', 'remove me', at: ts);
      await log.append(_turn('user', 'keep A'));
      await log.append(target);
      await log.append(_turn('assistant', 'keep B'));

      await log.removeTurn(target);

      final remaining = await log.readAll();
      expect(remaining.length, 2);
      expect(remaining.map((t) => t.text).toList(), <String>[
        'keep A',
        'keep B',
      ]);
    },
  );

  // ── cl10 ───────────────────────────────────────────────────────────────────

  test('cl10: removeTurn() is a no-op when no matching turn exists', () async {
    await log.append(_turn('user', 'only turn'));
    final phantom = _turn('user', 'not present', at: DateTime.utc(2000));

    await log.removeTurn(phantom);

    final turns = await log.readAll();
    expect(turns.length, 1);
    expect(turns.first.text, 'only turn');
  });

  // ── cl11 ───────────────────────────────────────────────────────────────────

  test('cl11: VibeChatLog.fileName is "chat.jsonl"', () {
    expect(VibeChatLog.fileName, 'chat.jsonl');
  });

  // ── cl12 ───────────────────────────────────────────────────────────────────

  test('cl12: open() places the log inside the given projectPath', () async {
    await log.append(_turn('user', 'placed'));
    expect(
      await chatFile.exists(),
      isTrue,
      reason: 'file must be at <projectPath>/chat.jsonl',
    );
  });

  // ── cl13 ───────────────────────────────────────────────────────────────────

  test(
    'cl13: append() succeeds even when projectPath dir is newly created',
    () async {
      final nested = Directory('${dir.path}/new_project');
      // Do NOT pre-create nested — append must create it.
      final nestedLog = VibeChatLog.open(nested.path);
      await nestedLog.append(_turn('user', 'deep'));
      final turns = await nestedLog.readAll();
      expect(turns.length, 1);
      expect(turns.first.text, 'deep');
    },
  );

  // ── cl14 ───────────────────────────────────────────────────────────────────

  test(
    'cl14: readAll() returns empty list when entire file is corrupt',
    () async {
      await chatFile.writeAsString('{ this is not json at all }\nXXXXX\n');
      final turns = await log.readAll();
      // Neither line is a valid Map<String, dynamic>; result must be empty,
      // not a throw.
      expect(turns, isEmpty);
    },
  );
}
