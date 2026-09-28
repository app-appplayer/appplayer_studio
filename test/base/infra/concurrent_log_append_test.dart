/// Lines appended at the same moment all land whole — the change history
/// (every patch in a burst) and the host chat log (a user turn and its reply
/// back to back). Two unsynchronised appends wrote at the same end offset,
/// so the shorter line overwrote the start of the longer one; the App
/// Builder chat log lost slash-command results that way.
library;

import 'dart:io';

import 'package:appplayer_studio/src/base/chat/chat_persistence.dart';
import 'package:appplayer_studio/src/base/chat/chat_turn.dart';
import 'package:appplayer_studio/src/base/infra/history_log.dart';
import 'package:brain_kernel/brain_kernel.dart'
    show CanonicalChange, CanonicalChangeKind;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('change history keeps every concurrent entry', () async {
    final dir = Directory.systemTemp.createTempSync('history_append_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final log = VibeHistoryLog.open(dir.path);
    await Future.wait([
      for (var i = 0; i < 60; i++)
        log.append(
          CanonicalChange(
            changedPointers: <String>['/ui/pages/p$i${'x' * (i * 5)}'],
            beforeHash: 'b$i',
            afterHash: 'a$i',
            kind: CanonicalChangeKind.patch,
            timestamp: DateTime.now().toUtc(),
          ),
        ),
    ]);
    final lines =
        File(
          '${dir.path}/${VibeHistoryLog.fileName}',
        ).readAsLinesSync().where((l) => l.isNotEmpty).toList();
    expect(lines, hasLength(60));
    expect(await log.readAll(), hasLength(60));
  });

  test('host chat log keeps every concurrent turn', () async {
    final dir = Directory.systemTemp.createTempSync('chat_persist_append_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = '${dir.path}/chats/home.jsonl';
    await Future.wait([
      for (var i = 0; i < 40; i++) ...[
        appendStudioChatTurn(file, ChatTurn(role: 'user', text: 'q$i')),
        appendStudioChatTurn(
          file,
          ChatTurn(role: 'assistant', text: 'answer $i ${'y' * (i * 9)}'),
        ),
      ],
    ]);
    final lines =
        File(file).readAsLinesSync().where((l) => l.isNotEmpty).toList();
    expect(lines, hasLength(80));
    expect(await loadStudioChat(file), hasLength(80));
  });
}
