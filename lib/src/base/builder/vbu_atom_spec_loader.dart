/// Reads `tools/builder/vibe_studio_ui/dart/lib/src/atoms/<name>.yaml`
/// (the vbu atom self-descriptions that sit next to each atom's dart
/// body) and turns each into a [WidgetSpec] with `source = custom`.
///
/// The yaml sits in `vibe_studio_ui` so an atom ships its widget
/// shape, props and examples right next to its inert body — every
/// downstream catalogue (here) reads the same source of truth.
///
/// Path discovery walks up from `Directory.current` (and the resolved
/// executable) looking for the workspace marker, then joins
/// `tools/builder/vibe_studio_ui/dart/lib/src/atoms`. Dev mode is
/// covered; release-mode packaging will need an assets-bundle path
/// (tracked as a follow-up to P1).
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'widget_spec.dart';

class VbuAtomSpecLoader {
  VbuAtomSpecLoader({String? workspaceRoot}) : _workspaceRoot = workspaceRoot;

  static const _atomsRelPath =
      'tools/builder/vibe_studio_ui/dart/lib/src/atoms';

  String? _workspaceRoot;
  List<WidgetSpec>? _cache;

  /// Returns every custom (vbu atom) widget spec. Empty when the
  /// workspace root or the atoms directory cannot be located —
  /// caller treats that as "no custom widgets".
  Future<List<WidgetSpec>> load() async {
    if (_cache != null) return _cache!;
    final root = _workspaceRoot ?? _findWorkspaceRoot();
    if (root == null) {
      _workspaceRoot = null;
      _cache = const <WidgetSpec>[];
      return _cache!;
    }
    _workspaceRoot = root;
    final atomsDir = Directory(p.join(root, _atomsRelPath));
    if (!atomsDir.existsSync()) {
      _cache = const <WidgetSpec>[];
      return _cache!;
    }
    final out = <WidgetSpec>[];
    await for (final entity in atomsDir.list(recursive: false)) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.yaml')) continue;
      try {
        final raw = await entity.readAsString();
        final parsed = loadYaml(raw);
        final spec = _parseCustomYaml(parsed);
        if (spec != null) out.add(spec);
      } catch (_) {
        // Skip malformed entries silently.
      }
    }
    _cache = List<WidgetSpec>.unmodifiable(out);
    return _cache!;
  }

  Future<WidgetSpec?> get(String type) async {
    final all = await load();
    for (final s in all) {
      if (s.type == type) return s;
    }
    return null;
  }

  String? get workspaceRoot => _workspaceRoot;

  // ── path discovery ─────────────────────────────────────────────

  static String? _findWorkspaceRoot() {
    final candidates = <String>[
      Directory.current.path,
      ..._walkUp(Directory.current.path),
      ..._walkUp(p.dirname(Platform.resolvedExecutable)),
    ];
    for (final c in candidates) {
      if (Directory(p.join(c, _atomsRelPath)).existsSync()) return c;
    }
    return null;
  }

  static Iterable<String> _walkUp(String start) sync* {
    var dir = start;
    for (var i = 0; i < 12; i++) {
      final parent = p.dirname(dir);
      if (parent == dir) break;
      yield parent;
      dir = parent;
    }
  }

  // ── yaml → WidgetSpec ──────────────────────────────────────────

  static WidgetSpec? _parseCustomYaml(dynamic yaml) {
    if (yaml is! Map) return null;
    final type = yaml['type'];
    if (type is! String) return null;
    final category = (yaml['category'] as String?) ?? 'uncategorized';
    final description = (yaml['description'] as String?) ?? '';
    final profile = yaml['profile'] as String?;
    final since = yaml['since'] as String?;

    final props = <WidgetPropSpec>[];
    final rawProps = yaml['properties'];
    if (rawProps is Map) {
      rawProps.forEach((k, v) {
        if (k is! String || v is! Map) return;
        final propType = _typeString(v['type']);
        final propDesc = (v['description'] as String?) ?? '';
        final isRequired =
            propDesc.startsWith('required |') ||
            propDesc.startsWith('required|') ||
            v['required'] == true;
        final rawEnum = v['enum'];
        final enumValues =
            rawEnum is List
                ? List<String>.unmodifiable(
                  rawEnum.whereType<String>().toList(),
                )
                : const <String>[];
        props.add(
          WidgetPropSpec(
            key: k,
            type: propType,
            description: propDesc,
            defaultValue: v['default'],
            required: isRequired,
            enumValues: enumValues,
          ),
        );
      });
    }

    final examples = <WidgetExampleSpec>[];
    final rawEx = yaml['examples'];
    if (rawEx is List) {
      for (final e in rawEx) {
        if (e is! Map) continue;
        final name = (e['name'] as String?) ?? 'example';
        final dsl = (e['dsl'] as String?) ?? '';
        if (dsl.isEmpty) continue;
        examples.add(WidgetExampleSpec(name: name, dsl: dsl));
      }
    }

    return WidgetSpec(
      type: type,
      category: category,
      source: WidgetSource.custom,
      description: description,
      profile: profile,
      since: since,
      properties: props,
      examples: examples,
    );
  }

  /// Mirror of DslSpecLoader's helper — list-valued `type` fields
  /// flatten to `"a | b"` so union-typed props still surface in
  /// the catalogue without crashing the loader.
  static String _typeString(Object? raw) {
    if (raw is String) return raw.trim();
    if (raw is List) {
      final strs = raw.whereType<String>().map((s) => s.trim()).toList();
      if (strs.isNotEmpty) return strs.join(' | ');
    }
    return 'unknown';
  }
}
