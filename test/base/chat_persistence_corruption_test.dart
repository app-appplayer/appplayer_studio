/// Data-loss / parse-masking guard for chat history (cherry #1 MED4).
///
/// `loadStudioChat` must distinguish *missing* (normal → empty) from
/// *malformed* (recover what's valid, but never silently drop the whole
/// log). The on-disk file is read-only here — appends never overwrite it —
/// so the guard is about not hiding corruption behind a blank panel.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/chat/chat_persistence.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('chat_persist_test_');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  String path(String name) => '${tmp.path}/$name';

  test('missing file → empty (normal new-chat path, no error)', () async {
    final turns = await loadStudioChat(path('absent.jsonl'));
    expect(turns, isEmpty);
  });

  test('valid jsonl → all turns parsed in order', () async {
    final f = File(path('chat.jsonl'));
    await f.writeAsString(
      '{"role":"user","text":"hi","at":"2026-06-05T00:00:00Z"}\n'
      '{"role":"assistant","text":"hello","at":"2026-06-05T00:00:01Z"}\n',
    );
    final turns = await loadStudioChat(f.path);
    expect(turns.length, 2);
    expect(turns[0].role, 'user');
    expect(turns[0].text, 'hi');
    expect(turns[1].text, 'hello');
  });

  test(
    'one malformed line is skipped, valid turns survive (not all-or-nothing)',
    () async {
      final f = File(path('chat.jsonl'));
      await f.writeAsString(
        '{"role":"user","text":"keep me","at":"2026-06-05T00:00:00Z"}\n'
        'THIS LINE IS NOT JSON\n'
        '{"role":"assistant","text":"keep me too","at":"2026-06-05T00:00:01Z"}\n',
      );
      final turns = await loadStudioChat(f.path);
      // The two valid turns survive; the corrupt line is dropped (surfaced
      // via stderr), not the whole file.
      expect(turns.length, 2);
      expect(turns.map((t) => t.text), <String>['keep me', 'keep me too']);
    },
  );

  test('empty file → empty list (not an error)', () async {
    final f = File(path('chat.jsonl'));
    await f.writeAsString('');
    final turns = await loadStudioChat(f.path);
    expect(turns, isEmpty);
  });
}
