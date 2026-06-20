/// Chat-log persistence helpers — every studio host stores per-tab
/// chat history as `<configRoot>/chats/<safeKey>.jsonl`. Lifted out of
/// the host so all studio binaries share the same on-disk layout and
/// load/append/clear semantics.
///
/// Pure top-level helpers — no widget / instance dependency. The host
/// owns the key naming policy (home / package / package::project); base
/// only does the path arithmetic + serialization.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'chat_turn.dart';

/// Resolve the on-disk jsonl path for chat history key [key].
///
/// `<configRoot>/chats/<safeKey>.jsonl` — non-alnum / dot / underscore
/// / hyphen chars in [key] are replaced with `_` so package paths and
/// `package::project` composite keys map cleanly onto a filename.
///
/// Callers may pass a non-existent [configRoot] — file IO is lazy and
/// best-effort; the caller decides whether to materialise the directory.
String studioChatFile({required String configRoot, required String key}) {
  final safe = key.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
  return p.join(configRoot, 'chats', '$safe.jsonl');
}

/// Read every persisted [ChatTurn] from [filePath]. Returns an empty
/// list when the file is missing or malformed — chat history is
/// best-effort and never blocks rehydrate.
Future<List<ChatTurn>> loadStudioChat(String filePath) async {
  final f = File(filePath);
  if (!await f.exists()) return const <ChatTurn>[];
  try {
    final lines = await f.readAsLines();
    final out = <ChatTurn>[];
    var skipped = 0;
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final m = jsonDecode(line) as Map<String, dynamic>;
        out.add(
          ChatTurn(
            role: (m['role'] as String?) ?? 'system',
            text: (m['text'] as String?) ?? '',
            fileCount: m['fileCount'] as int?,
            at:
                DateTime.tryParse((m['at'] as String?) ?? '') ??
                DateTime.now().toUtc(),
          ),
        );
      } catch (_) {
        skipped++;
      }
    }
    if (skipped > 0) {
      // A skipped line = a chat turn that silently disappears from the
      // panel. Surface it (chat history is the user's data).
      stderr.writeln(
        'chat_persistence: ${p.basename(filePath)} — skipped '
        '$skipped malformed line(s); those turns are not shown',
      );
    }
    return out;
  } catch (e) {
    // File exists (missing was returned above) but is unreadable /
    // malformed → empty rather than crashing rehydrate. Surface it — a
    // corrupt chat log silently showing empty is the chat.jsonl data-loss
    // class. The on-disk file is preserved (read-only failure; appends
    // never overwrite it).
    stderr.writeln('chat_persistence: failed to read $filePath: $e');
    return const <ChatTurn>[];
  }
}

/// Append a single [turn] to the jsonl log at [filePath]. Creates the
/// parent directory lazily — best-effort, never throws.
Future<void> appendStudioChatTurn(String filePath, ChatTurn turn) async {
  try {
    final f = File(filePath);
    await f.parent.create(recursive: true);
    final json = jsonEncode(<String, dynamic>{
      'role': turn.role,
      'text': turn.text,
      if (turn.fileCount != null) 'fileCount': turn.fileCount,
      'at': turn.at.toIso8601String(),
    });
    await f.writeAsString('$json\n', mode: FileMode.append);
  } catch (_) {
    /* best-effort */
  }
}

/// Delete the jsonl log at [filePath]. Used by the chat panel's
/// "clear history" affordance. Best-effort — missing file is OK.
Future<void> clearStudioChatLog(String filePath) async {
  try {
    final f = File(filePath);
    if (await f.exists()) await f.delete();
  } catch (_) {
    /* best-effort */
  }
}
