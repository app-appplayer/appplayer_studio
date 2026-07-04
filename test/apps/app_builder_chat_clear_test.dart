/// Verifies the App Builder chat "clear conversation" persistence fix.
///
/// Bug (user-reported): clearing the chat removed turns from the panel
/// but NOT the on-disk `chat.jsonl`, so a restart reloaded the cleared
/// turns. Root cause: the App Builder wired `onTurnPersisted` (append)
/// but left `onClearLog` null, so `VibeChatController.clear()` only
/// emptied the in-memory feed.
///
/// Fix (shell_layout.dart): wire `widget.chat.onClearLog =
/// () => proj.chatLog.clear()` everywhere `onTurnPersisted` is set.
/// This test exercises that exact mechanism end-to-end against a real
/// `VibeChatLog` on disk, plus a negative control proving the pre-fix
/// wiring leaks.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart' show VibeChatController, ChatTurn;
import 'package:appplayer_studio/src/apps/app_builder/infra/vibe_chat_log.dart';

void main() {
  late Directory dir;
  late VibeChatLog log;
  late File chatFile;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ab_chat_clear');
    log = VibeChatLog.open(dir.path);
    chatFile = File('${dir.path}/${VibeChatLog.fileName}');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  ChatTurn _t(String text) => ChatTurn(role: 'user', text: text);

  test('FIX: clear() with onClearLog wired deletes chat.jsonl', () async {
    await log.append(_t('hello'));
    expect(await chatFile.exists(), isTrue, reason: 'append creates the log');

    // Exactly the shell_layout wiring: onClearLog = () => chatLog.clear().
    final ctrl = VibeChatController(
      send: (_) async => ChatTurn(role: 'assistant', text: 'ok'),
      onClearLog: () => log.clear(),
    );
    await ctrl.clear();

    expect(
      await chatFile.exists(),
      isFalse,
      reason: 'clear() must wipe the on-disk log so a restart stays clear',
    );
  });

  test(
    'FIX D7a: clear() also resets the coordinator LLM history via onClearLog',
    () async {
      await log.append(_t('hello'));

      // Model the shell_layout D7a wiring: onClearLog wipes the disk log AND
      // resets the LLM's in-memory history, so a Clear is a genuine fresh
      // start. Pre-D7a it only cleared the disk log, so the coordinator kept
      // reusing prior thread precedent after a Clear (the "Clear" was a lie).
      final llmHistory = <String>['prior-1', 'prior-2'];
      var historyReset = false;
      final ctrl = VibeChatController(
        send: (_) async => ChatTurn(role: 'assistant', text: 'ok'),
        onClearLog: () async {
          await log.clear();
          llmHistory.clear(); // stands in for llm.resetHistory()
          historyReset = true;
        },
      );
      await ctrl.clear();

      expect(await chatFile.exists(), isFalse);
      expect(historyReset, isTrue);
      expect(
        llmHistory,
        isEmpty,
        reason: 'Clear must reset the LLM history, not just the disk log — '
            'else the coordinator reuses prior precedent after Clear (D7a)',
      );
    },
  );

  test(
    'BUG control: clear() WITHOUT onClearLog leaves chat.jsonl on disk',
    () async {
      await log.append(_t('hello'));
      expect(await chatFile.exists(), isTrue);

      // Pre-fix state — no onClearLog hook (the App Builder's old wiring).
      final ctrl = VibeChatController(
        send: (_) async => ChatTurn(role: 'assistant', text: 'ok'),
      );
      await ctrl.clear();

      expect(
        await chatFile.exists(),
        isTrue,
        reason: 'reproduces the reported bug: cleared turns reload on restart',
      );
    },
  );
}
