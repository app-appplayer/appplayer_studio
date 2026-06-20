import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/types.dart';

/// Append-only line-delimited JSON log of LLM dialogue turns. Lives at
/// `<projectPath>/chat.jsonl`. One line = one turn.
///
/// Survives across sessions so the user can resume a conversation
/// where they left off. Importing a different bundle does not clear
/// the chat — it stays a property of the project, not the bundle.
class VibeChatLog {
  VibeChatLog._(this._path);

  final String _path;

  static const String fileName = 'chat.jsonl';

  /// Open (or create) the chat log inside [projectPath].
  static VibeChatLog open(String projectPath) =>
      VibeChatLog._(p.join(projectPath, fileName));

  /// Read all turns. Returns empty when the file is missing or
  /// malformed (we don't fail the project open over a corrupt log).
  Future<List<ChatTurn>> readAll() async {
    final file = File(_path);
    if (!await file.exists()) return <ChatTurn>[];
    try {
      final lines = await file.readAsLines();
      final out = <ChatTurn>[];
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final raw = jsonDecode(line);
          if (raw is Map<String, dynamic>) {
            out.add(_turnFromJson(raw));
          }
        } catch (_) {
          /* skip malformed line */
        }
      }
      return out;
    } catch (_) {
      return <ChatTurn>[];
    }
  }

  /// Append one turn to the log. Best-effort — failures are swallowed
  /// so a write hiccup never breaks the chat experience.
  Future<void> append(ChatTurn turn) async {
    try {
      final file = File(_path);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${jsonEncode(_turnToJson(turn))}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      /* ignore */
    }
  }

  /// Drop the entire log (used by `revert`-style flows that want a
  /// clean conversation, or by tests). Best-effort.
  Future<void> clear() async {
    try {
      final file = File(_path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      /* ignore */
    }
  }

  /// Remove every turn whose role + text + timestamp match [target].
  /// Append-only file → rewrite without the offending lines. Best
  /// effort; partial writes leave the file in its original state.
  Future<void> removeTurn(ChatTurn target) async {
    try {
      final all = await readAll();
      final keep =
          all
              .where(
                (t) =>
                    !(t.role == target.role &&
                        t.text == target.text &&
                        t.at.toIso8601String() == target.at.toIso8601String()),
              )
              .toList();
      if (keep.length == all.length) return;
      final file = File(_path);
      final tmp = File('$_path.tmp');
      final buf = StringBuffer();
      for (final t in keep) {
        buf
          ..write(jsonEncode(_turnToJson(t)))
          ..write('\n');
      }
      await tmp.writeAsString(buf.toString(), flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      /* ignore */
    }
  }

  static Map<String, dynamic> _turnToJson(ChatTurn turn) => <String, dynamic>{
    'role': turn.role,
    'text': turn.text,
    'at': turn.at.toIso8601String(),
    if (turn.layer is LayerId) 'layer': (turn.layer as LayerId).name,
    if (turn.fileCount != null) 'fileCount': turn.fileCount,
  };

  static ChatTurn _turnFromJson(Map<String, dynamic> json) {
    DateTime parseAt(dynamic v) {
      if (v is String) {
        try {
          return DateTime.parse(v).toUtc();
        } catch (_) {
          /* fall through */
        }
      }
      return DateTime.now().toUtc();
    }

    return ChatTurn(
      role: (json['role'] as String?) ?? 'assistant',
      text: (json['text'] as String?) ?? '',
      fileCount: json['fileCount'] as int?,
      at: parseAt(json['at']),
    );
  }
}
