/// Atomic JSON-array file backing one storage collection.
///
/// Each persistent storage flushes the full collection as a single JSON
/// array of entity maps. Writes go through a temp file + rename so a crash
/// mid-write never leaves a half-written (corrupt) collection on disk.
library;

import 'dart:convert';
import 'dart:io';

/// A single `<rootDir>/<name>.json` collection file.
class CollectionFile {
  CollectionFile(this.rootDir, this.name);

  /// Directory holding all collection files (e.g. `<projectRoot>/.factgraph`).
  final String rootDir;

  /// Collection base name without extension (e.g. `facts`).
  final String name;

  File get _file => File('$rootDir/$name.json');
  File get _tmp => File('$rootDir/$name.json.tmp');

  /// Read the collection. Returns an empty list when the file is absent or
  /// empty — a fresh project simply has no collections yet.
  Future<List<Map<String, dynamic>>> read() async {
    final f = _file;
    if (!await f.exists()) return const [];
    final raw = await f.readAsString();
    if (raw.trim().isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  /// Atomically replace the collection with [items].
  Future<void> write(List<Map<String, dynamic>> items) async {
    await Directory(rootDir).create(recursive: true);
    await _tmp.writeAsString(jsonEncode(items), flush: true);
    await _tmp.rename(_file.path);
  }
}
