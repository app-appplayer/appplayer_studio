/// Backs the four read-side `studio.builder.ui.*` tools:
/// `readNode` / `readTree` / `findNodes` / `diff`. Every path is a
/// JSON Pointer ([ptrGet]) so callers share the same mental model
/// as `applyPatch` (RFC 6902) and the upcoming write mutators.
///
/// File source: `<mbdPath>/ui/app.json`. Read on demand — no
/// in-memory caching at this layer; future work may add it once the
/// write mutators land and the file → tree round-trip stabilises.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'json_pointer.dart';

class BuilderUiReadService {
  /// Load and decode `<mbdPath>/ui/app.json`. Throws
  /// [FormatException] when the file is missing or malformed —
  /// callers should translate to §4 diagnostic shape.
  Future<Object?> loadUi(String mbdPath) async {
    final file = File(p.join(mbdPath, 'ui', 'app.json'));
    if (!file.existsSync()) {
      throw FormatException('ui/app.json not found at $mbdPath');
    }
    return jsonDecode(await file.readAsString());
  }

  /// Return type + props + child-path summary for the node at
  /// [path]. Non-Map nodes (lists / primitives) are returned as
  /// `{path, value}`.
  Future<Map<String, dynamic>> readNode(String mbdPath, String path) async {
    final root = await loadUi(mbdPath);
    final node = ptrGet(root, path);
    if (node is! Map) {
      return <String, dynamic>{
        'path': path.isEmpty ? '/' : path,
        'value': node,
      };
    }
    final type = node['type'];
    final props = <String, dynamic>{};
    final children = <String>[];
    for (final e in node.entries) {
      final k = e.key.toString();
      final v = e.value;
      if (k == 'type') continue;
      if (k == 'content' || k == 'child') {
        children.add('${path.isEmpty ? '' : path}/$k');
      } else if (k == 'children' && v is List) {
        for (var i = 0; i < v.length; i++) {
          children.add('${path.isEmpty ? '' : path}/children/$i');
        }
      } else {
        props[k] = v;
      }
    }
    return <String, dynamic>{
      'path': path.isEmpty ? '/' : path,
      'type': type,
      'props': props,
      'children': children,
    };
  }

  /// Return the subtree rooted at [path] up to [depth] levels deep.
  /// Default depth `null` = full tree.
  Future<Map<String, dynamic>> readTree(
    String mbdPath, {
    String path = '',
    int? depth,
  }) async {
    final root = await loadUi(mbdPath);
    final node = path.isEmpty ? root : ptrGet(root, path);
    return <String, dynamic>{
      'path': path.isEmpty ? '/' : path,
      'tree': _sliceTree(node, depth ?? _unbounded),
    };
  }

  static const _unbounded = 1 << 30;

  Object? _sliceTree(Object? node, int depth) {
    if (depth <= 0) {
      if (node is Map || node is List) return '<truncated>';
      return node;
    }
    if (node is Map) {
      final out = <String, dynamic>{};
      for (final e in node.entries) {
        out[e.key.toString()] = _sliceTree(e.value, depth - 1);
      }
      return out;
    }
    if (node is List) {
      return <Object?>[for (final v in node) _sliceTree(v, depth - 1)];
    }
    return node;
  }

  /// Walk the tree and return JSON-Pointer paths of every node that
  /// matches the filters. Both filters optional — omit both for a
  /// full path index (useful for `findNodes({}).length`).
  ///
  /// - [typeOf] — exact match on `node['type']`.
  /// - [propEq] — every key/value pair must match `node[key]`.
  Future<List<String>> findNodes(
    String mbdPath, {
    String? typeOf,
    Map<String, Object?>? propEq,
  }) async {
    final root = await loadUi(mbdPath);
    final hits = <String>[];
    _walk(root, '', (path, node) {
      if (node is! Map) return;
      if (typeOf != null && node['type'] != typeOf) return;
      if (propEq != null) {
        for (final e in propEq.entries) {
          if (node[e.key] != e.value) return;
        }
      }
      hits.add(path.isEmpty ? '/' : path);
    });
    return hits;
  }

  void _walk(
    Object? node,
    String path,
    void Function(String path, Object? node) cb,
  ) {
    cb(path, node);
    if (node is Map) {
      for (final e in node.entries) {
        _walk(e.value, '$path/${e.key}', cb);
      }
    } else if (node is List) {
      for (var i = 0; i < node.length; i++) {
        _walk(node[i], '$path/$i', cb);
      }
    }
  }

  /// JSON tree diff. Returns a list of RFC-6902-shaped ops
  /// (`add`/`remove`/`replace`) capturing every leaf-level change.
  /// Callers pass already-decoded `from` and `to` trees (e.g. two
  /// `readTree` snapshots).
  Future<List<Map<String, dynamic>>> diff(Object? from, Object? to) async {
    final ops = <Map<String, dynamic>>[];
    _diffRecursive(from, to, '', ops);
    return ops;
  }

  static final _missing = Object();

  void _diffRecursive(
    Object? a,
    Object? b,
    String path,
    List<Map<String, dynamic>> ops,
  ) {
    if (_jsonEq(a, b)) return;
    if (a is Map && b is Map) {
      final keys = <String>{
        ...a.keys.map((k) => k.toString()),
        ...b.keys.map((k) => k.toString()),
      };
      for (final k in keys) {
        _diffRecursive(a[k], b[k], '$path/$k', ops);
      }
      return;
    }
    if (a is List && b is List) {
      final len = a.length > b.length ? a.length : b.length;
      for (var i = 0; i < len; i++) {
        final av = i < a.length ? a[i] : _missing;
        final bv = i < b.length ? b[i] : _missing;
        _diffRecursive(av, bv, '$path/$i', ops);
      }
      return;
    }
    final aMissing = identical(a, _missing) || a == null;
    final bMissing = identical(b, _missing) || b == null;
    final pathOut = path.isEmpty ? '/' : path;
    if (aMissing && !bMissing) {
      ops.add(<String, dynamic>{'op': 'add', 'path': pathOut, 'value': b});
    } else if (bMissing && !aMissing) {
      ops.add(<String, dynamic>{'op': 'remove', 'path': pathOut});
    } else {
      ops.add(<String, dynamic>{'op': 'replace', 'path': pathOut, 'value': b});
    }
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
}
