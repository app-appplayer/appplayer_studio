/// Backs the seven `studio.builder.lib.*` tools (P5 + placeInline).
/// The "library" is a Studio Builder *project-level* working set of
/// widget instances — atom / composite / scaffold / page kinds are
/// *not* distinguished at this layer (sub-kind only matters in the
/// builder UI's catalog grouping). Storage: one JSON file per
/// instance at `<projectPath>/library/<id>.json`, where
/// `projectPath` is the parent folder of the `.mbd` being edited
/// (the `.sbproj` project root). The library sits **outside** the
/// `.mbd` on purpose — it is an authoring asset, not a distribution
/// artifact, so `.mcpb` export skips it.
///
/// Why a separate folder instead of inlining: lets the builder
/// surface "edit + verify in isolation" UX without re-mounting
/// the whole app tree on every prop tweak. The instance is loaded
/// alone, validated alone, screenshotted alone — then dropped into
/// the app tree via the write mutators when the author is happy.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class BuilderLibraryService {
  /// Folder name (sits at the project root, parent of the .mbd).
  static const folderName = 'library';

  /// Resolve the library root for the project that owns [mbdPath].
  /// Project = parent folder of the .mbd (where `project.sbproj`
  /// lives). Library is authoring-only — never ships with the
  /// exported bundle.
  String _projectRoot(String mbdPath) => p.dirname(mbdPath);

  Directory _libDir(String mbdPath) =>
      Directory(p.join(_projectRoot(mbdPath), folderName));

  File _entryFile(String mbdPath, String id) =>
      File(p.join(_projectRoot(mbdPath), folderName, '$id.json'));

  /// Validate id — alphanumeric + dash/underscore so it round-trips
  /// through the filesystem on every supported platform.
  static final _idPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_\-.]{0,127}$');

  void _checkId(String id) {
    if (!_idPattern.hasMatch(id)) {
      throw FormatException('library id must match $_idPattern: $id');
    }
  }

  /// List every instance id in the library. Returns empty when the
  /// library folder is missing (= no instances saved yet).
  Future<List<String>> list(String mbdPath) async {
    final dir = _libDir(mbdPath);
    if (!dir.existsSync()) return const <String>[];
    final ids = <String>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.endsWith('.json')) continue;
      ids.add(name.substring(0, name.length - '.json'.length));
    }
    ids.sort();
    return ids;
  }

  /// Read one instance's stored tree. Throws [FormatException] when
  /// the id has no matching file (caller maps to `pathNotFound`).
  Future<Object?> read(String mbdPath, String id) async {
    _checkId(id);
    final file = _entryFile(mbdPath, id);
    if (!file.existsSync()) {
      throw FormatException('library entry not found: $id');
    }
    return jsonDecode(await file.readAsString());
  }

  /// Create a new instance. Optional [tree] seeds the body; pass
  /// null for an empty `{}` stub the author can flesh out later.
  /// Throws when the id already exists — the caller should call
  /// `delete` + `create` (or use a `rename` flow) for explicit
  /// replacement so accidental overwrites surface.
  Future<void> create(String mbdPath, String id, {Object? tree}) async {
    _checkId(id);
    final dir = _libDir(mbdPath);
    if (!dir.existsSync()) await dir.create(recursive: true);
    final file = _entryFile(mbdPath, id);
    if (file.existsSync()) {
      throw FormatException(
        'library entry already exists: $id (use delete + create or '
        'rename for explicit replacement)',
      );
    }
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(tree ?? <String, Object?>{}));
  }

  /// Delete one instance. Throws when the id has no matching file.
  Future<void> delete(String mbdPath, String id) async {
    _checkId(id);
    final file = _entryFile(mbdPath, id);
    if (!file.existsSync()) {
      throw FormatException('library entry not found: $id');
    }
    await file.delete();
  }

  /// Rename an instance. Throws when `oldId` missing or `newId`
  /// already exists. Does not rewrite tree-internal references —
  /// follow-up work will surface those via `findReferences` once
  /// the write mutators learn the `use` widget shape.
  Future<void> rename(String mbdPath, String oldId, String newId) async {
    _checkId(oldId);
    _checkId(newId);
    if (oldId == newId) return;
    final oldFile = _entryFile(mbdPath, oldId);
    final newFile = _entryFile(mbdPath, newId);
    if (!oldFile.existsSync()) {
      throw FormatException('library entry not found: $oldId');
    }
    if (newFile.existsSync()) {
      throw FormatException('library entry already exists: $newId');
    }
    await oldFile.rename(newFile.path);
  }

  /// Resolve a library instance into a ready-to-insert subtree.
  ///
  /// Reads the stored entry, then walks the JSON value substituting
  /// `{{paramName}}` placeholders with values from [params]:
  ///
  /// - A string whose entire content is `{{name}}` is replaced by
  ///   the raw param value, so numeric / map / list params keep
  ///   their type (e.g. `{{width}}` -> `168` as a number).
  /// - A string with embedded `{{name}}` occurrences is rewritten
  ///   using `param.toString()` for each match; this is how labels
  ///   and class-like attributes compose multiple values.
  /// - Unresolved placeholders collapse to an empty string and
  ///   are reported in the returned `warnings` list so the caller
  ///   can surface them without aborting the placement.
  ///
  /// Caller is expected to feed the resulting tree to an `addNode`
  /// / `applyPatch` op so the inline form lands in `ui/app.json`.
  Future<({Object? tree, List<String> warnings})> resolveInline(
    String mbdPath,
    String id,
    Map<String, Object?> params,
  ) async {
    _checkId(id);
    final raw = await read(mbdPath, id);
    final warnings = <String>[];
    final tree = _substitute(raw, params, warnings);
    return (tree: tree, warnings: warnings);
  }

  Object? _substitute(
    Object? node,
    Map<String, Object?> params,
    List<String> warnings,
  ) {
    if (node is String) {
      return _substituteString(node, params, warnings);
    }
    if (node is List) {
      return <Object?>[for (final e in node) _substitute(e, params, warnings)];
    }
    if (node is Map) {
      return <String, Object?>{
        for (final e in node.entries)
          e.key.toString(): _substitute(e.value, params, warnings),
      };
    }
    return node;
  }

  static final _whole = RegExp(r'^\{\{(\w+)\}\}$');
  static final _embedded = RegExp(r'\{\{(\w+)\}\}');

  Object? _substituteString(
    String s,
    Map<String, Object?> params,
    List<String> warnings,
  ) {
    final whole = _whole.firstMatch(s);
    if (whole != null) {
      final key = whole.group(1)!;
      if (params.containsKey(key)) return params[key];
      warnings.add('unresolved param: $key');
      return '';
    }
    return s.replaceAllMapped(_embedded, (m) {
      final key = m.group(1)!;
      if (params.containsKey(key)) return params[key]?.toString() ?? '';
      warnings.add('unresolved param: $key');
      return '';
    });
  }
}
