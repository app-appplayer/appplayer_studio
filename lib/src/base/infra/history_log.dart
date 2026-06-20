import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart'
    show CanonicalChange, CanonicalChangeKind, PatchOriginator;

/// Append-only audit log of canonical mutations. Lives at
/// `<projectPath>/history.jsonl`. One line = one [CanonicalChange]. Patch
/// kinds carry the originator + paths; lifecycle transitions (open /
/// saveAs / revert) are recorded with no originator.
///
/// Audit-only for now — the foundation for undo / redo and a future
/// "recent changes" UI. Not consulted by the runtime.
class VibeHistoryLog {
  VibeHistoryLog._(this._path);

  final String _path;

  static const String fileName = 'history.jsonl';

  /// Open (or create) the history log inside [projectPath].
  static VibeHistoryLog open(String projectPath) =>
      VibeHistoryLog._(p.join(projectPath, fileName));

  /// Read every entry. Malformed lines are skipped — a corrupt audit
  /// log should never block project open.
  Future<List<HistoryEntry>> readAll() async {
    final file = File(_path);
    if (!await file.exists()) return <HistoryEntry>[];
    try {
      final lines = await file.readAsLines();
      final out = <HistoryEntry>[];
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final raw = jsonDecode(line);
          if (raw is Map<String, dynamic>) {
            out.add(HistoryEntry.fromJson(raw));
          }
        } catch (_) {
          /* skip malformed line */
        }
      }
      return out;
    } catch (_) {
      return <HistoryEntry>[];
    }
  }

  /// Append one change. Best-effort — write failures are swallowed.
  /// We never let an audit-log hiccup interrupt the editing experience.
  Future<void> append(CanonicalChange change) async {
    try {
      final file = File(_path);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${jsonEncode(_changeToJson(change))}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      /* ignore */
    }
  }

  /// Drop the entire log. Used by tests + any future "fresh start" UI.
  Future<void> clear() async {
    try {
      final file = File(_path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      /* ignore */
    }
  }

  static Map<String, dynamic> _changeToJson(CanonicalChange c) {
    // Kernel's [CanonicalChange.originator] is `Object?`. App_builder
    // populates it with sealed [PatchOriginator] subtypes; each carries
    // its own `toJson()`. Foreign originators (other shapes) fall back
    // to toString().
    final origin = c.originator;
    final originJson =
        origin == null
            ? null
            : origin is PatchOriginator
            ? origin.toJson()
            : <String, dynamic>{'kind': origin.toString()};
    return <String, dynamic>{
      'at': DateTime.now().toUtc().toIso8601String(),
      'kind': c.kind.name,
      'changedPaths': c.changedPointers,
      'beforeHash': c.beforeHash,
      'afterHash': c.afterHash,
      if (originJson != null) 'originator': originJson,
    };
  }
}

/// One row from history.jsonl. Mirrors [CanonicalChange] but keeps the
/// recorded timestamp so audit consumers can sort.
class HistoryEntry {
  HistoryEntry({
    required this.at,
    required this.kind,
    required this.changedPaths,
    required this.beforeHash,
    required this.afterHash,
    this.originatorKind,
    this.originatorId,
  });

  final DateTime at;
  final CanonicalChangeKind kind;
  final List<String> changedPaths;
  final String beforeHash;
  final String afterHash;
  final String? originatorKind;
  final String? originatorId;

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
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

    CanonicalChangeKind parseKind(String? name) {
      for (final k in CanonicalChangeKind.values) {
        if (k.name == name) return k;
      }
      return CanonicalChangeKind.patch;
    }

    final originator = json['originator'];
    String? extractedId;
    if (originator is Map) {
      // Sealed [PatchOriginator] subtypes each surface their primary
      // identifier under a different key. Pick the first that exists so
      // the audit row carries a meaningful "who/what" tag without the
      // consumer having to switch on `kind`.
      for (final key in const <String>[
        'turnId', // LlmOriginator
        'clientId', // McpClientOriginator
        'sourcePath', // ImportOriginator
        'subcommand', // CliOriginator
        'note', // UserOriginator
        'id', // legacy flat shape
      ]) {
        final v = originator[key];
        if (v is String && v.isNotEmpty) {
          extractedId = v;
          break;
        }
      }
    }
    return HistoryEntry(
      at: parseAt(json['at']),
      kind: parseKind(json['kind'] as String?),
      changedPaths: <String>[
        for (final v in (json['changedPaths'] as List? ?? const <dynamic>[]))
          if (v is String) v,
      ],
      beforeHash: (json['beforeHash'] as String?) ?? '',
      afterHash: (json['afterHash'] as String?) ?? '',
      originatorKind: originator is Map ? originator['kind'] as String? : null,
      originatorId: extractedId,
    );
  }
}
