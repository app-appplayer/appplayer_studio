/// Turns appended at the same moment all land intact. A slash command
/// appends the user turn and its result turn without waiting on each other;
/// two unsynchronised appends wrote at the same end offset, so the shorter
/// line overwrote the start of the longer one and the log kept a fragment
/// (`","at":"…"}`) instead of the result.
library;

import 'dart:io';

import 'package:appplayer_studio/src/apps/app_builder/core/types.dart';
import 'package:appplayer_studio/src/apps/app_builder/infra/vibe_chat_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('concurrent appends keep every turn whole', () async {
    final dir = Directory.systemTemp.createTempSync('chat_log_append_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final log = VibeChatLog.open(dir.path);
    final writes = <Future<void>>[];
    for (var i = 0; i < 40; i++) {
      writes
        ..add(log.append(ChatTurn(role: 'user', text: '/cmd$i')))
        ..add(
          log.append(
            ChatTurn(role: 'system', text: '✓ result $i · ${'x' * (i * 7)}'),
          ),
        );
    }
    await Future.wait(writes);
    final lines =
        File(
          '${dir.path}/${VibeChatLog.fileName}',
        ).readAsLinesSync().where((l) => l.isNotEmpty).toList();
    expect(lines, hasLength(80));
    expect((await log.readAll()).length, 80);
  });
}
