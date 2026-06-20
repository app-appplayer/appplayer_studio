/// Public JSON Pointer helpers (RFC 6901). Lifted from the
/// file-private `_ptr*` helpers in `builder_mutator_tools.dart` so the
/// new atomic ui mutators (P2~P4 of studio-builder-rebuild) can share
/// the same traversal semantics. Mutator tools will adopt these in a
/// follow-up refactor; for now the two copies stay in sync by virtue
/// of being literal duplicates.
///
/// All functions throw [FormatException] on malformed input — the
/// caller should translate into the §4 diagnostic shape so external
/// LLMs see `{code, path, expected, actual, message, suggestion}`
/// instead of a raw stack trace.
library;

/// Parse a JSON Pointer string into its segments.
///
/// - `""` → `[]` (root)
/// - `"/a/b"` → `["a", "b"]`
/// - `~1` decoded back to `/`, `~0` decoded back to `~`.
List<String> ptrSegments(String pointer) {
  if (pointer == '') return const <String>[];
  if (!pointer.startsWith('/')) {
    throw FormatException('JSON Pointer must start with /: $pointer');
  }
  return pointer
      .substring(1)
      .split('/')
      .map((s) => s.replaceAll('~1', '/').replaceAll('~0', '~'))
      .toList();
}

/// Walk [root] along [pointer]. Returns the addressed value (any JSON
/// type, including null). Throws when a segment cannot be resolved.
Object? ptrGet(Object? root, String pointer) {
  Object? cur = root;
  for (final seg in ptrSegments(pointer)) {
    if (cur is Map) {
      cur = cur[seg];
    } else if (cur is List) {
      final idx = int.tryParse(seg);
      if (idx == null || idx < 0 || idx >= cur.length) {
        throw FormatException('JSON Pointer list index OOB: $pointer');
      }
      cur = cur[idx];
    } else {
      throw FormatException('JSON Pointer traversal failed at $seg: $pointer');
    }
  }
  return cur;
}

/// Set [value] at [pointer] in [root].
///
/// - `insert: true` on a list pointer inserts at the index (RFC 6902
///   `add` semantics).
/// - `insert: false` replaces (RFC 6902 `replace` semantics).
/// - List `-` segment appends.
void ptrSet(
  Object? root,
  String pointer,
  Object? value, {
  required bool insert,
}) {
  final segs = ptrSegments(pointer);
  if (segs.isEmpty) {
    throw FormatException('JSON Pointer empty (cannot set root)');
  }
  Object? parent = root;
  for (var i = 0; i < segs.length - 1; i++) {
    final seg = segs[i];
    if (parent is Map) {
      parent = parent[seg];
    } else if (parent is List) {
      final idx = int.tryParse(seg);
      if (idx == null || idx < 0 || idx >= parent.length) {
        throw FormatException('JSON Pointer list index OOB: $pointer');
      }
      parent = parent[idx];
    } else {
      throw FormatException('JSON Pointer traversal failed at $seg: $pointer');
    }
  }
  final last = segs.last;
  if (parent is Map) {
    parent[last] = value;
  } else if (parent is List) {
    if (last == '-') {
      parent.add(value);
    } else {
      final idx = int.tryParse(last);
      if (idx == null) {
        throw FormatException('JSON Pointer list index invalid: $last');
      }
      if (insert) {
        if (idx < 0 || idx > parent.length) {
          throw FormatException('JSON Pointer add index OOB: $idx');
        }
        parent.insert(idx, value);
      } else {
        if (idx < 0 || idx >= parent.length) {
          throw FormatException('JSON Pointer replace index OOB: $idx');
        }
        parent[idx] = value;
      }
    }
  } else {
    throw FormatException(
      'JSON Pointer cannot set on non-collection: $pointer',
    );
  }
}

/// Remove the value addressed by [pointer] from [root].
void ptrRemove(Object? root, String pointer) {
  final segs = ptrSegments(pointer);
  if (segs.isEmpty) {
    throw FormatException('JSON Pointer empty (cannot remove root)');
  }
  Object? parent = root;
  for (var i = 0; i < segs.length - 1; i++) {
    final seg = segs[i];
    if (parent is Map) {
      parent = parent[seg];
    } else if (parent is List) {
      final idx = int.tryParse(seg);
      if (idx == null || idx < 0 || idx >= parent.length) {
        throw FormatException('JSON Pointer list index OOB: $pointer');
      }
      parent = parent[idx];
    } else {
      throw FormatException('JSON Pointer traversal failed at $seg: $pointer');
    }
  }
  final last = segs.last;
  if (parent is Map) {
    parent.remove(last);
  } else if (parent is List) {
    final idx = int.tryParse(last);
    if (idx == null || idx < 0 || idx >= parent.length) {
      throw FormatException('JSON Pointer list index OOB: $pointer');
    }
    parent.removeAt(idx);
  } else {
    throw FormatException(
      'JSON Pointer cannot remove on non-collection: $pointer',
    );
  }
}
