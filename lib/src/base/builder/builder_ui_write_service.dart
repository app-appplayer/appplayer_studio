/// Backs the five atomic write tools (P3 of studio-builder-rebuild):
/// `addNode` / `setProp` / `removeNode` / `moveNode` /
/// `reorderChildren`. Each method:
///
/// 1. Reads `<mbdPath>/ui/app.json` into a mutable tree.
/// 2. Resolves the target JSON Pointer ([ptrGet] / [ptrSet] / etc).
/// 3. Mutates the tree in place.
/// 4. (When `dryRun == false`) writes the tree back atomically — a
///    temp file + rename — so an interrupted write cannot leave
///    the bundle with half-written ui/app.json.
///
/// Schema validation lands in P3.2 (this file's mutator returns
/// `ok:true` for any well-formed JSON Pointer that resolves; the
/// catalog-driven validation step layers on top via a small
/// `SchemaValidator` helper).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'json_pointer.dart';

class BuilderUiWriteService {
  /// Load `<mbdPath>/ui/app.json` as a mutable tree. Returns the
  /// decoded root (a Map for a valid page, possibly other shapes
  /// in malformed cases — caller handles defensively).
  Future<Object?> _loadMutable(String mbdPath) async {
    final file = File(p.join(mbdPath, 'ui', 'app.json'));
    if (!file.existsSync()) {
      throw FormatException('ui/app.json not found at $mbdPath');
    }
    return jsonDecode(await file.readAsString());
  }

  /// Atomic write — encode + write to `<file>.tmp` + rename. Keeps
  /// the on-disk ui/app.json intact when the process is killed
  /// mid-write.
  Future<void> _commit(String mbdPath, Object? root) async {
    final file = File(p.join(mbdPath, 'ui', 'app.json'));
    final tmp = File(p.join(mbdPath, 'ui', 'app.json.tmp'));
    const encoder = JsonEncoder.withIndent('  ');
    await tmp.writeAsString(encoder.convert(root));
    await tmp.rename(file.path);
  }

  /// Add [node] under [path]. When the parent at [path] is a list,
  /// [position] inserts there (default = end). When the parent is a
  /// map, [path] is interpreted as the new key's full pointer and
  /// the parent's existing value at that key is *replaced* (add on
  /// a map slot is treated like RFC-6902 `add` semantics).
  /// Discriminators that look widget-shaped (Map with String `type`)
  /// but the spec treats them as Action / value-object payloads, not
  /// renderable widgets. Used in `applyPatch` to bypass widget
  /// validation for these values. Keep in sync with docs/04_Actions.md.
  static const _kKnownActionTypes = <String>{
    'state',
    'tool',
    'navigate',
    'notification',
    'event',
    'batch',
    'pickFile',
    'spawnDialog',
    'closeDialog',
    'service.invoke',
    'lifecycle',
  };

  Future<Map<String, dynamic>> addNode({
    required String mbdPath,
    required String path,
    int? position,
    required Object node,
    bool dryRun = false,
  }) async {
    final root = await _loadMutable(mbdPath);
    final parent = path.isEmpty ? root : ptrGet(root, path);
    if (parent is List) {
      final idx = position ?? parent.length;
      if (idx < 0 || idx > parent.length) {
        throw FormatException(
          'addNode position OOB: $idx (list length ${parent.length})',
        );
      }
      parent.insert(idx, node);
    } else {
      // Map-slot semantics. `path` names the slot itself (e.g.
      // `/content/children/0/child`); the slot may already hold a
      // value (replace) or be missing entirely (create). ptrSet
      // navigates to the grandparent (which MUST be a Map for the
      // slot name to resolve) and assigns the last segment. Throws
      // on a malformed pointer or non-collection grandparent — the
      // tool handler maps that to a §4 pathNotFound diagnostic.
      ptrSet(root, path, node, insert: true);
    }
    if (!dryRun) await _commit(mbdPath, root);
    return <String, dynamic>{'ok': true, 'dryRun': dryRun};
  }

  /// Replace one property of the node at [path]. Internally
  /// constructs the prop pointer (`<path>/<key>`) and uses
  /// `ptrSet(insert: false)` (RFC-6902 replace).
  Future<Map<String, dynamic>> setProp({
    required String mbdPath,
    required String path,
    required String key,
    required Object? value,
    bool dryRun = false,
  }) async {
    final root = await _loadMutable(mbdPath);
    final node = path.isEmpty ? root : ptrGet(root, path);
    if (node is! Map) {
      throw FormatException('setProp target must be a Map node: $path');
    }
    node[key] = value;
    if (!dryRun) await _commit(mbdPath, root);
    return <String, dynamic>{'ok': true, 'dryRun': dryRun};
  }

  /// Register [entry] under `ApplicationDefinition.templates[<name>]`.
  ///
  /// Ensures the `templates` map exists at root (creates `{}` when
  /// missing), then:
  ///
  /// - **not present** → add. Returns `registered: true, replaced: false`.
  /// - **present + structurally identical** (same encoded JSON) → no-op
  ///   (idempotent). Returns `registered: false, replaced: false`.
  /// - **present + different** + `force == false` → throws
  ///   `FormatException('template already exists: …')`. Caller maps
  ///   to `alreadyExists` rejection.
  /// - **present + different** + `force == true` → replace. Returns
  ///   `registered: true, replaced: true`.
  ///
  /// Paired with `placeAsTemplate` (the tool handler in
  /// `builder_library_tools.dart`) — register once, then `addNode`
  /// a `{type:"use", template, params}` site so the library entry
  /// is reused by reference (any subsequent register with the same
  /// id no-ops; a deliberate edit needs `force: true`).
  Future<Map<String, dynamic>> addTemplate({
    required String mbdPath,
    required String name,
    required Object entry,
    bool force = false,
    bool dryRun = false,
  }) async {
    final root = await _loadMutable(mbdPath);
    if (root is! Map) {
      throw FormatException('addTemplate requires a Map root in ui/app.json');
    }
    final templates =
        (root['templates'] is Map)
            ? (root['templates'] as Map).cast<String, Object?>()
            : <String, Object?>{};
    final existing = templates[name];
    var replaced = false;
    var registered = true;
    if (existing != null) {
      final sameJson = jsonEncode(existing) == jsonEncode(entry);
      if (sameJson) {
        // Idempotent — nothing to write.
        registered = false;
      } else if (!force) {
        throw FormatException(
          'template already exists: $name (pass force:true to replace)',
        );
      } else {
        replaced = true;
      }
    }
    if (registered || replaced) {
      templates[name] = entry;
      root['templates'] = templates;
      if (!dryRun) await _commit(mbdPath, root);
    }
    return <String, dynamic>{
      'ok': true,
      'dryRun': dryRun,
      'name': name,
      'registered': registered || replaced,
      'replaced': replaced,
    };
  }

  /// Remove the node at [path]. List elements collapse (RFC-6902
  /// remove); map keys disappear.
  Future<Map<String, dynamic>> removeNode({
    required String mbdPath,
    required String path,
    bool dryRun = false,
  }) async {
    final root = await _loadMutable(mbdPath);
    if (path.isEmpty) {
      throw FormatException('removeNode cannot target root');
    }
    ptrRemove(root, path);
    if (!dryRun) await _commit(mbdPath, root);
    return <String, dynamic>{'ok': true, 'dryRun': dryRun};
  }

  /// Move the node at [fromPath] to [toPath]. If [toPath]'s parent
  /// is a list, [position] picks the insert index (default = end).
  Future<Map<String, dynamic>> moveNode({
    required String mbdPath,
    required String fromPath,
    required String toPath,
    int? position,
    bool dryRun = false,
  }) async {
    final root = await _loadMutable(mbdPath);
    final v = ptrGet(root, fromPath);
    ptrRemove(root, fromPath);
    // After remove, if toPath shares a list parent and the from
    // segment's index was earlier, the destination index would
    // shift; RFC-6902 leaves that ambiguous — we honor the post-
    // remove tree as-is, matching the json-patch convention.
    final destParent =
        (() {
          try {
            final segs = ptrSegments(toPath);
            if (segs.isEmpty) return null;
            final parentPath = '/${segs.sublist(0, segs.length - 1).join('/')}';
            return ptrGet(root, parentPath == '/' ? '' : parentPath);
          } on FormatException {
            return null;
          }
        })();
    if (destParent is List && position != null) {
      destParent.insert(position, v);
    } else {
      ptrSet(root, toPath, v, insert: true);
    }
    if (!dryRun) await _commit(mbdPath, root);
    return <String, dynamic>{'ok': true, 'dryRun': dryRun};
  }

  /// Apply a RFC-6902 patch (a list of `{op, path, value?, from?}`
  /// entries) atomically. Either every op succeeds and the result
  /// commits, or any failure rejects the whole batch with the
  /// offending `opIndex` plus a §4 diagnostic.
  ///
  /// Supported ops: `add` / `remove` / `replace` / `move` / `copy`
  /// / `test`. When [validateNode] is non-null, every `add` / `replace`
  /// op whose `value` is a widget node (Map with `type` key) is
  /// run through it before the in-memory mutation, so type / required
  /// / enum / extra-property mistakes are caught up front.
  Future<Map<String, dynamic>> applyPatch({
    required String mbdPath,
    required List<Object?> ops,
    bool dryRun = false,
    Future<Map<String, dynamic>?> Function(Object node)? validateNode,
  }) async {
    final root = await _loadMutable(mbdPath);
    for (var i = 0; i < ops.length; i++) {
      final raw = ops[i];
      if (raw is! Map) {
        throw FormatException('op[$i] not an object');
      }
      final op = raw.cast<String, Object?>();
      // Validate widget values before applying. Action discriminators
      // (state / tool / navigate / …) share the `type` shape with
      // widgets but are NOT widget nodes — skip widget validation
      // for them, otherwise wiring like `{type:"state",action:"set"}`
      // would trip `unknownType` (#B-1).
      if (validateNode != null) {
        final type = op['op'];
        final value = op['value'];
        if ((type == 'add' || type == 'replace') &&
            value is Map &&
            value['type'] is String &&
            !_kKnownActionTypes.contains(value['type'] as String)) {
          final reject = await validateNode(value);
          if (reject != null) {
            return <String, dynamic>{'ok': false, 'opIndex': i, ...reject};
          }
        }
      }
      _applyOp(root, op);
    }
    if (!dryRun) await _commit(mbdPath, root);
    return <String, dynamic>{
      'ok': true,
      'dryRun': dryRun,
      'opCount': ops.length,
    };
  }

  void _applyOp(Object? root, Map<String, Object?> op) {
    final type = op['op'];
    if (type is! String) {
      throw FormatException('op missing `op` field');
    }
    final path = op['path'];
    if (path is! String) {
      throw FormatException('op missing `path` field');
    }
    switch (type) {
      case 'add':
        ptrSet(root, path, op['value'], insert: true);
        break;
      case 'remove':
        ptrRemove(root, path);
        break;
      case 'replace':
        ptrSet(root, path, op['value'], insert: false);
        break;
      case 'move':
        final from = op['from'];
        if (from is! String) {
          throw FormatException('move op requires `from` (string)');
        }
        final v = ptrGet(root, from);
        ptrRemove(root, from);
        ptrSet(root, path, v, insert: true);
        break;
      case 'copy':
        final from = op['from'];
        if (from is! String) {
          throw FormatException('copy op requires `from` (string)');
        }
        final v = ptrGet(root, from);
        ptrSet(root, path, _deepCopy(v), insert: true);
        break;
      case 'test':
        final actual = ptrGet(root, path);
        if (!_jsonEq(actual, op['value'])) {
          throw FormatException(
            'test op failed at $path: expected ${op['value']}, got $actual',
          );
        }
        break;
      default:
        throw FormatException('unknown op: $type');
    }
  }

  Object? _deepCopy(Object? v) {
    if (v is Map) {
      return <String, Object?>{
        for (final e in v.entries) e.key.toString(): _deepCopy(e.value),
      };
    }
    if (v is List) {
      return <Object?>[for (final e in v) _deepCopy(e)];
    }
    return v;
  }

  bool _jsonEq(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return a == b;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final e in a.entries) {
        if (!b.containsKey(e.key)) return false;
        if (!_jsonEq(e.value, b[e.key])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_jsonEq(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  /// Reorder a list at [path] using [order] — an index permutation
  /// whose length must equal the current list length. Element `i`
  /// of the new list is the old element at `order[i]`.
  Future<Map<String, dynamic>> reorderChildren({
    required String mbdPath,
    required String path,
    required List<int> order,
    bool dryRun = false,
  }) async {
    final root = await _loadMutable(mbdPath);
    final list = path.isEmpty ? root : ptrGet(root, path);
    if (list is! List) {
      throw FormatException('reorderChildren target must be a list: $path');
    }
    if (order.length != list.length) {
      throw FormatException(
        'reorderChildren order length ${order.length} != list length '
        '${list.length}',
      );
    }
    final seen = <int>{};
    for (final i in order) {
      if (i < 0 || i >= list.length || !seen.add(i)) {
        throw FormatException(
          'reorderChildren order must be a permutation of [0..n)',
        );
      }
    }
    final copy = List<Object?>.from(list);
    list.clear();
    for (final i in order) {
      list.add(copy[i]);
    }
    if (!dryRun) await _commit(mbdPath, root);
    return <String, dynamic>{'ok': true, 'dryRun': dryRun};
  }
}
