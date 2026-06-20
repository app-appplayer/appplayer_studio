/// Reads `specs/mcp_ui_dsl/spec/<version>/widgets/<category>/<name>.yaml`
/// off the filesystem and turns each yaml into a [WidgetSpec] with
/// `source = standard`. Cached after the first scan so the builder
/// catalogue stays cheap to query.
///
/// The specs root is discovered by walking up from `Directory.current`
/// (and the resolved executable) looking for a `specs/` folder —
/// mirrors `_findSeedRoot` in `vibe_studio_host_app.dart`.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'widget_spec.dart';

class DslSpecLoader {
  DslSpecLoader({this.version = '1.3', String? specsRoot})
    : _specsRoot = specsRoot;

  /// Spec version under `specs/mcp_ui_dsl/spec/<version>/`. Defaults
  /// to `1.3` (the current canonical).
  final String version;

  String? _specsRoot;
  List<WidgetSpec>? _cache;
  final List<Map<String, String>> _skipped = <Map<String, String>>[];

  /// Returns every standard widget spec found under
  /// `specs/mcp_ui_dsl/spec/<version>/widgets/**.yaml`. Empty list
  /// when the specs root is missing — caller treats that as "no
  /// standard widgets available" rather than crashing.
  Future<List<WidgetSpec>> load() async {
    if (_cache != null) return _cache!;
    final root = _specsRoot ?? _findSpecsRoot();
    if (root == null) {
      _specsRoot = null;
      _cache = const <WidgetSpec>[];
      return _cache!;
    }
    _specsRoot = root;
    final widgetsDir = Directory(
      p.join(root, 'mcp_ui_dsl', 'spec', version, 'widgets'),
    );
    if (!widgetsDir.existsSync()) {
      _cache = const <WidgetSpec>[];
      return _cache!;
    }
    final out = <WidgetSpec>[];
    _skipped.clear();
    await for (final entity in widgetsDir.list(recursive: true)) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.yaml')) continue;
      final rel = entity.path.substring(root.length + 1);
      try {
        final raw = await entity.readAsString();
        final parsed = loadYaml(raw);
        final spec = _parseStandardYaml(parsed);
        if (spec == null) {
          final reason =
              parsed is! Map
                  ? 'root-not-map (got ${parsed.runtimeType})'
                  : (parsed['type'] is! String
                      ? 'type-field-missing-or-non-string'
                      : 'unknown');
          _skipped.add(<String, String>{'path': rel, 'reason': reason});
          continue;
        }
        out.add(spec);
      } catch (e) {
        _skipped.add(<String, String>{
          'path': rel,
          'reason':
              'parse-error: ${e.toString().substring(0, e.toString().length.clamp(0, 120))}',
        });
      }
    }
    _cache = List<WidgetSpec>.unmodifiable(out);
    return _cache!;
  }

  /// Paths (relative to specs root) that the loader skipped, with
  /// the reason for each. Populated by [load]; consult via the
  /// catalog diag tool to surface yaml that needs a linter pass.
  List<Map<String, String>> get skipped =>
      List<Map<String, String>>.unmodifiable(_skipped);

  /// Lookup by exact type. Loads on demand. Returns null when no
  /// matching standard widget exists.
  Future<WidgetSpec?> get(String type) async {
    final all = await load();
    for (final s in all) {
      if (s.type == type) return s;
    }
    return null;
  }

  /// Resolved specs root once [load] has executed (or null when not
  /// found). Exposed so the host can surface a diagnostic.
  String? get specsRoot => _specsRoot;

  // ── path discovery ─────────────────────────────────────────────

  static String? _findSpecsRoot() {
    final candidates = <String>[
      p.join(Directory.current.path, 'specs'),
      ..._walkUp(Directory.current.path, 'specs'),
      ..._walkUp(p.dirname(Platform.resolvedExecutable), 'specs'),
    ];
    for (final c in candidates) {
      if (Directory(c).existsSync()) return c;
    }
    return null;
  }

  static Iterable<String> _walkUp(String start, String target) sync* {
    var dir = start;
    for (var i = 0; i < 12; i++) {
      final parent = p.dirname(dir);
      if (parent == dir) break;
      yield p.join(parent, target);
      dir = parent;
    }
  }

  // ── yaml → WidgetSpec ──────────────────────────────────────────

  static WidgetSpec? _parseStandardYaml(dynamic yaml) {
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
      source: WidgetSource.standard,
      description: description,
      profile: profile,
      since: since,
      properties: props,
      examples: examples,
    );
  }

  /// Convert a yaml `type:` value to a single descriptive string.
  /// Some 1.3 widget specs use a list form (`type: ["number",
  /// "string"]`) for union types — flatten to `"number | string"`
  /// so the validator can still surface it; deeper union-aware
  /// type matching lands as a follow-up.
  static String _typeString(Object? raw) {
    if (raw is String) return raw.trim();
    if (raw is List) {
      final strs = raw.whereType<String>().map((s) => s.trim()).toList();
      if (strs.isNotEmpty) return strs.join(' | ');
    }
    return 'unknown';
  }
}
