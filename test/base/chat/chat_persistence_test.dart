/// Comprehensive tests for `chat_persistence.dart`:
/// - `studioChatFile`: path derivation + key sanitisation
/// - `appendStudioChatTurn`: lazy dir creation + jsonl append
/// - `loadStudioChat`: missing, valid, mixed, malformed
/// - `clearStudioChatLog`: present, absent
///
/// Companion to `test/base/chat_persistence_corruption_test.dart` which
/// was the first guard; this file adds the missing surface (path / append /
/// clear).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/base/chat/chat_persistence.dart';
import 'package:appplayer_studio/src/base/chat/chat_turn.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('chat_persist_full_');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // ---- studioChatFile ---------------------------------------------------

  group('studioChatFile — path derivation', () {
    test('simple key maps to <configRoot>/chats/<key>.jsonl', () {
      final path = studioChatFile(configRoot: '/cfg', key: 'home');
      expect(path, p.join('/cfg', 'chats', 'home.jsonl'));
    });

    test('key with slashes is sanitised (slashes → underscore)', () {
      final path = studioChatFile(configRoot: '/cfg', key: '/path/to/package');
      expect(path, endsWith('.jsonl'));
      // No directory separator in the filename segment
      final filename = p.basename(path);
      expect(filename.contains('/'), isFalse);
    });

    test('composite key (::) is sanitised', () {
      final path = studioChatFile(
        configRoot: '/cfg',
        key: '/pkg/path::/proj/path',
      );
      final filename = p.basename(path);
      // Colons become underscores
      expect(filename.contains(':'), isFalse);
      expect(filename, endsWith('.jsonl'));
    });

    test('key with spaces is sanitised to underscores', () {
      final path = studioChatFile(configRoot: '/cfg', key: 'my project name');
      final filename = p.basename(path);
      expect(filename.contains(' '), isFalse);
    });

    test('allowed chars (alnum, dot, underscore, hyphen) are preserved', () {
      const key = 'hello_world-2024.test';
      final path = studioChatFile(configRoot: '/cfg', key: key);
      expect(p.basename(path), '$key.jsonl');
    });

    test('different configRoots produce different paths', () {
      final a = studioChatFile(configRoot: '/cfgA', key: 'home');
      final b = studioChatFile(configRoot: '/cfgB', key: 'home');
      expect(a, isNot(equals(b)));
    });
  });

  // ---- appendStudioChatTurn ---------------------------------------------

  group('appendStudioChatTurn', () {
    test('creates parent dirs lazily + writes a valid json line', () async {
      final filePath = p.join(tmp.path, 'nested', 'deep', 'chat.jsonl');
      final turn = ChatTurn(
        role: 'user',
        text: 'hello',
        at: DateTime.utc(2026, 1, 1),
      );
      await appendStudioChatTurn(filePath, turn);

      final f = File(filePath);
      expect(await f.exists(), isTrue);
      final content = await f.readAsString();
      final parsed = jsonDecode(content.trim()) as Map<String, dynamic>;
      expect(parsed['role'], 'user');
      expect(parsed['text'], 'hello');
    });

    test('appends multiple turns without overwriting', () async {
      final filePath = p.join(tmp.path, 'chat.jsonl');
      final t1 = ChatTurn(
        role: 'user',
        text: 'msg1',
        at: DateTime.utc(2026, 1, 1),
      );
      final t2 = ChatTurn(
        role: 'assistant',
        text: 'reply1',
        at: DateTime.utc(2026, 1, 1, 0, 0, 1),
      );
      await appendStudioChatTurn(filePath, t1);
      await appendStudioChatTurn(filePath, t2);

      final lines = await File(filePath).readAsLines().then(
        (ls) => ls.where((l) => l.trim().isNotEmpty).toList(),
      );
      expect(lines.length, 2);
      expect((jsonDecode(lines[0]) as Map)['text'], 'msg1');
      expect((jsonDecode(lines[1]) as Map)['text'], 'reply1');
    });

    test('fileCount field is omitted when null', () async {
      final filePath = p.join(tmp.path, 'chat.jsonl');
      final turn = ChatTurn(
        role: 'assistant',
        text: 'no fileCount',
        at: DateTime.utc(2026, 1, 1),
      );
      await appendStudioChatTurn(filePath, turn);
      final raw =
          jsonDecode((await File(filePath).readAsString()).trim())
              as Map<String, dynamic>;
      expect(raw.containsKey('fileCount'), isFalse);
    });

    test('fileCount field is included when non-null', () async {
      final filePath = p.join(tmp.path, 'chat.jsonl');
      final turn = ChatTurn(
        role: 'assistant.patch',
        text: 'patched 3 files',
        fileCount: 3,
        at: DateTime.utc(2026, 1, 1),
      );
      await appendStudioChatTurn(filePath, turn);
      final raw =
          jsonDecode((await File(filePath).readAsString()).trim())
              as Map<String, dynamic>;
      expect(raw['fileCount'], 3);
    });

    test('at field is serialised as ISO-8601 UTC string', () async {
      final filePath = p.join(tmp.path, 'chat.jsonl');
      final when = DateTime.utc(2026, 6, 1, 12, 0, 0);
      await appendStudioChatTurn(
        filePath,
        ChatTurn(role: 'user', text: 'ts check', at: when),
      );
      final raw =
          jsonDecode((await File(filePath).readAsString()).trim())
              as Map<String, dynamic>;
      expect(raw['at'], when.toIso8601String());
    });

    test(
      'is best-effort: does not throw when dir is unwritable path',
      () async {
        // Use an impossible nested path under a file (not a dir).
        final blocker = File(p.join(tmp.path, 'blocking_file'));
        await blocker.writeAsString('x');
        // A path that treats a FILE as a directory — should silently swallow.
        final filePath = p.join(tmp.path, 'blocking_file', 'chat.jsonl');
        await expectLater(
          appendStudioChatTurn(
            filePath,
            ChatTurn(role: 'user', text: 'fail silently'),
          ),
          completes,
        );
      },
    );
  });

  // ---- loadStudioChat ---------------------------------------------------

  group('loadStudioChat', () {
    test('missing file returns empty list (not an error)', () async {
      final turns = await loadStudioChat(p.join(tmp.path, 'absent.jsonl'));
      expect(turns, isEmpty);
    });

    test('empty file returns empty list', () async {
      final f = File(p.join(tmp.path, 'empty.jsonl'));
      await f.writeAsString('');
      expect(await loadStudioChat(f.path), isEmpty);
    });

    test('blank lines are skipped without error', () async {
      final f = File(p.join(tmp.path, 'blanks.jsonl'));
      await f.writeAsString(
        '\n  \n{"role":"user","text":"hi","at":"2026-01-01T00:00:00.000Z"}\n\n',
      );
      final turns = await loadStudioChat(f.path);
      expect(turns.length, 1);
      expect(turns.first.text, 'hi');
    });

    test('parses role, text, at, fileCount fields', () async {
      final f = File(p.join(tmp.path, 'full.jsonl'));
      await f.writeAsString(
        '{"role":"assistant.patch","text":"patched","fileCount":5,'
        '"at":"2026-02-01T08:30:00.000Z"}\n',
      );
      final turns = await loadStudioChat(f.path);
      expect(turns.length, 1);
      expect(turns.first.role, 'assistant.patch');
      expect(turns.first.fileCount, 5);
      expect(turns.first.at.year, 2026);
      expect(turns.first.at.month, 2);
    });

    test('missing role field defaults to "system"', () async {
      final f = File(p.join(tmp.path, 'norole.jsonl'));
      await f.writeAsString('{"text":"hi","at":"2026-01-01T00:00:00.000Z"}\n');
      final turns = await loadStudioChat(f.path);
      expect(turns.first.role, 'system');
    });

    test('missing text field defaults to empty string', () async {
      final f = File(p.join(tmp.path, 'notext.jsonl'));
      await f.writeAsString(
        '{"role":"user","at":"2026-01-01T00:00:00.000Z"}\n',
      );
      final turns = await loadStudioChat(f.path);
      expect(turns.first.text, '');
    });

    test(
      'malformed at field falls back to a DateTime without throwing',
      () async {
        final f = File(p.join(tmp.path, 'bdat.jsonl'));
        await f.writeAsString(
          '{"role":"user","text":"test","at":"not-a-date"}\n',
        );
        final turns = await loadStudioChat(f.path);
        expect(turns.length, 1); // turn is kept, bad date falls back to now
      },
    );

    test('round-trip: append then load produces identical values', () async {
      final filePath = p.join(tmp.path, 'roundtrip.jsonl');
      final t1 = ChatTurn(
        role: 'user',
        text: 'round-trip user',
        at: DateTime.utc(2026, 3, 15, 10, 0, 0),
      );
      final t2 = ChatTurn(
        role: 'assistant',
        text: 'round-trip assistant',
        fileCount: 2,
        at: DateTime.utc(2026, 3, 15, 10, 0, 5),
      );
      await appendStudioChatTurn(filePath, t1);
      await appendStudioChatTurn(filePath, t2);

      final loaded = await loadStudioChat(filePath);
      expect(loaded.length, 2);
      expect(loaded[0].role, t1.role);
      expect(loaded[0].text, t1.text);
      expect(loaded[0].at.toIso8601String(), t1.at.toIso8601String());
      expect(loaded[1].fileCount, 2);
    });
  });

  // ---- clearStudioChatLog -----------------------------------------------

  group('clearStudioChatLog', () {
    test('deletes existing file', () async {
      final f = File(p.join(tmp.path, 'chat.jsonl'));
      await f.writeAsString('{"role":"user","text":"x"}\n');
      expect(await f.exists(), isTrue);
      await clearStudioChatLog(f.path);
      expect(await f.exists(), isFalse);
    });

    test('missing file is silently ignored (best-effort)', () async {
      final path = p.join(tmp.path, 'nonexistent.jsonl');
      await expectLater(clearStudioChatLog(path), completes);
    });

    test('after clear, load returns empty list', () async {
      final filePath = p.join(tmp.path, 'cleared.jsonl');
      final turn = ChatTurn(
        role: 'user',
        text: 'to be cleared',
        at: DateTime.utc(2026, 1, 1),
      );
      await appendStudioChatTurn(filePath, turn);
      await clearStudioChatLog(filePath);
      final turns = await loadStudioChat(filePath);
      expect(turns, isEmpty);
    });
  });
}
