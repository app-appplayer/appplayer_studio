import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Sidecar that mirrors the canonical's undo / redo stacks to
/// `<projectPath>/undo.json`. Lets the user keep undoing across an app
/// restart.
///
/// Best-effort — disk failures don't break the in-memory editing
/// experience. Stored shape:
/// ```
/// { "schemaVersion": 1, "undo": [<patch>...], "redo": [<patch>...] }
/// ```
/// Where each `<patch>` is `{ layer, ops, originator }` matching
/// `WorkspaceCanonical.undoStackJson` element format.
class VibeUndoSidecar {
  VibeUndoSidecar._(this._path);

  final String _path;

  static const String fileName = 'undo.json';

  /// Open (or create) the undo sidecar inside [projectPath].
  static VibeUndoSidecar open(String projectPath) =>
      VibeUndoSidecar._(p.join(projectPath, fileName));

  /// Read previously-persisted stacks. Returns empty lists when the
  /// file is missing or malformed (corrupt undo state should never
  /// block project open).
  Future<UndoSnapshot> read() async {
    final file = File(_path);
    if (!await file.exists()) return UndoSnapshot.empty;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, dynamic>) return UndoSnapshot.empty;
      List<Map<String, dynamic>> grab(String key) {
        final v = raw[key];
        if (v is! List) return const <Map<String, dynamic>>[];
        return <Map<String, dynamic>>[
          for (final entry in v)
            if (entry is Map<String, dynamic>) entry,
        ];
      }

      return UndoSnapshot(undo: grab('undo'), redo: grab('redo'));
    } catch (_) {
      return UndoSnapshot.empty;
    }
  }

  /// Persist [snapshot] atomically. Failures are swallowed.
  Future<void> write(UndoSnapshot snapshot) async {
    try {
      final file = File(_path);
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
          'schemaVersion': 1,
          'undo': snapshot.undo,
          'redo': snapshot.redo,
        }),
      );
      await tmp.rename(file.path);
    } catch (_) {
      /* ignore */
    }
  }

  /// Delete the file. Used when both stacks become empty so the
  /// project doesn't accumulate stale undo blobs.
  Future<void> clear() async {
    try {
      final file = File(_path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      /* ignore */
    }
  }
}

/// Read / write payload for [VibeUndoSidecar].
class UndoSnapshot {
  const UndoSnapshot({required this.undo, required this.redo});

  final List<Map<String, dynamic>> undo;
  final List<Map<String, dynamic>> redo;

  bool get isEmpty => undo.isEmpty && redo.isEmpty;

  static const UndoSnapshot empty = UndoSnapshot(
    undo: <Map<String, dynamic>>[],
    redo: <Map<String, dynamic>>[],
  );
}
