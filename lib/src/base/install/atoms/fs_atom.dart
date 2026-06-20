/// Filesystem atom — `host.fs.*`. Scoped to the bundle's install root
/// (mb.McpBundle.directory) so a misbehaving bundle can't reach the
/// host's filesystem outside its own .mbd. Read / list only in the
/// 5.3 first cut; write / watch land in 5.4 once a real tool needs
/// them.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'atom_category.dart';

class FsAtom extends AtomCategory {
  FsAtom({required this.bundleRoot});

  /// Absolute path to the bundle root all relative paths resolve
  /// against. Typically `bundle.directory` from
  /// [readBundleAt] / [BundleHostAccessors].
  final String bundleRoot;

  @override
  String get key => 'fs';

  @override
  List<AtomVerb> get verbs => const [
    AtomVerb('read', description: 'Read a UTF-8 text file at the path.'),
    AtomVerb(
      'list',
      description: 'List immediate entries (file/dir names) under the path.',
    ),
    AtomVerb('exists', description: 'Check whether a path exists.'),
  ];

  @override
  Future<Object?> dispatch(String verb, List<Object?> args) async {
    switch (verb) {
      case 'read':
        final path = _stringArg(args, 0, 'path');
        return _read(path);
      case 'list':
        final path =
            args.isEmpty ? '.' : _stringArg(args, 0, 'path', defaultValue: '.');
        return _list(path);
      case 'exists':
        final path = _stringArg(args, 0, 'path');
        return _exists(path);
      default:
        throw ArgumentError('unknown verb: fs.$verb');
    }
  }

  /// Resolve [relativePath] against [bundleRoot] with the same path-
  /// safety guarantees as `BundleHostAccessors.resolveAsset`.
  String _resolve(String relativePath) {
    if (relativePath.isEmpty) {
      throw ArgumentError('path is empty');
    }
    if (p.isAbsolute(relativePath)) {
      throw ArgumentError(
        'path must be inside the bundle, got absolute "$relativePath"',
      );
    }
    final joined = p.normalize(p.join(bundleRoot, relativePath));
    final rootWithSep =
        bundleRoot.endsWith(p.separator)
            ? bundleRoot
            : '$bundleRoot${p.separator}';
    if (joined != bundleRoot && !joined.startsWith(rootWithSep)) {
      throw ArgumentError(
        'path "$relativePath" escapes bundle root "$bundleRoot"',
      );
    }
    return joined;
  }

  Future<String> _read(String relativePath) async {
    final f = File(_resolve(relativePath));
    if (!await f.exists()) {
      throw StateError('file not found: $relativePath');
    }
    return f.readAsString();
  }

  Future<List<String>> _list(String relativePath) async {
    final d = Directory(_resolve(relativePath));
    if (!await d.exists()) {
      throw StateError('directory not found: $relativePath');
    }
    final entries = <String>[];
    await for (final e in d.list(followLinks: false)) {
      entries.add(p.basename(e.path));
    }
    entries.sort();
    return entries;
  }

  Future<bool> _exists(String relativePath) async {
    final abs = _resolve(relativePath);
    return (await File(abs).exists()) || (await Directory(abs).exists());
  }

  String _stringArg(
    List<Object?> args,
    int idx,
    String name, {
    String? defaultValue,
  }) {
    if (idx >= args.length || args[idx] == null) {
      if (defaultValue != null) return defaultValue;
      throw ArgumentError('missing required arg "$name"');
    }
    final v = args[idx];
    if (v is! String) {
      throw ArgumentError('arg "$name" must be String, got ${v.runtimeType}');
    }
    return v;
  }
}
