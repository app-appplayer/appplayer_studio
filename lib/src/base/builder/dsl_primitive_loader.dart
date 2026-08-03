/// Reads `specs/mcp_ui_dsl/spec/<version>/configs/_primitive/<Name>.yaml`
/// and turns each `definition` (a JSON Schema fragment) into a value check
/// the authoring surface can run.
///
/// Why this exists: the checker knew widget properties but not what a
/// PRIMITIVE accepts, so `Color` — declared on dozens of slots — was never
/// checked. `box {color: "notacolor"}` passed authoring and rendered nothing:
/// the checker told the author the document was fine and the screen disagreed.
/// The spec already carries the contract (three spellings for `Color`, the
/// alignment names, the `IconRef` forms); reading it beats a hand-list that
/// goes stale the next time the spec moves.
///
/// Only the branch KINDS the primitives actually use are modelled — pattern,
/// enum, `$ref: Binding`, and the loose object/number/string forms. An
/// unmodelled branch makes the primitive permissive rather than wrong: a
/// checker that rejects what it merely does not understand is worse than one
/// that lets it through.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'dsl_spec_loader.dart' show kDslSpecVersion;

/// One `_primitive/<Name>.yaml`, reduced to what a value must satisfy.
class DslPrimitive {
  DslPrimitive({
    required this.name,
    required this.patterns,
    required this.enumValues,
    required this.acceptsBinding,
    required this.acceptsObject,
    required this.acceptsNumber,
    required this.acceptsBareString,
  });

  final String name;
  final List<RegExp> patterns;
  final List<String> enumValues;

  /// A `$ref` to `Binding` — `{{…}}` is accepted in that position.
  final bool acceptsBinding;
  final bool acceptsObject;
  final bool acceptsNumber;

  /// A `type: string` branch with no pattern (e.g. `IconRef`'s bare name
  /// form) — any string satisfies it, so the primitive cannot reject strings.
  final bool acceptsBareString;

  /// Whether [value] satisfies this primitive. Null means "no opinion":
  /// the primitive declares nothing this checker models.
  bool? accepts(Object? value) {
    if (patterns.isEmpty &&
        enumValues.isEmpty &&
        !acceptsObject &&
        !acceptsNumber &&
        !acceptsBareString) {
      return null;
    }
    if (value is Map) return acceptsObject ? true : null;
    if (value is num) return acceptsNumber ? true : null;
    if (value is! String) return null;
    if (acceptsBinding && _binding.hasMatch(value)) return true;
    if (acceptsBareString) return true;
    if (enumValues.contains(value)) return true;
    for (final re in patterns) {
      if (re.hasMatch(value)) return true;
    }
    return false;
  }

  /// Human-readable summary for a rejection message.
  String get expectation {
    final parts = <String>[
      if (enumValues.isNotEmpty)
        'one of ${enumValues.take(6).join(', ')}'
            '${enumValues.length > 6 ? ', …' : ''}',
      for (final re in patterns) 'matching ${re.pattern}',
      if (acceptsObject) 'an object form',
      if (acceptsBinding) 'a `{{binding}}`',
    ];
    return '$name — ${parts.join(' · ')}';
  }

  static final RegExp _binding = RegExp(r'^\{\{.*\}\}$');
}

class DslPrimitiveLoader {
  DslPrimitiveLoader({this.version = kDslSpecVersion, String? specsRoot})
    : _specsRoot = specsRoot;

  final String version;
  final String? _specsRoot;
  Map<String, DslPrimitive>? _cache;

  /// `<Name>` → primitive. Empty when the specs tree is absent (a standalone
  /// clone of the studio has no `specs/` beside it).
  Future<Map<String, DslPrimitive>> load() async {
    if (_cache != null) return _cache!;
    final root = _specsRoot ?? _findSpecsRoot();
    if (root == null) return _cache = const <String, DslPrimitive>{};
    final dir = Directory(
      p.join(root, 'mcp_ui_dsl', 'spec', version, 'configs', '_primitive'),
    );
    if (!dir.existsSync()) return _cache = const <String, DslPrimitive>{};
    final out = <String, DslPrimitive>{};
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.yaml')) continue;
      try {
        final doc = loadYaml(f.readAsStringSync());
        if (doc is! YamlMap) continue;
        final name = doc['name'];
        if (name is! String) continue;
        final prim = _parse(name, doc['definition']);
        if (prim != null) out[name] = prim;
      } catch (_) {
        // A primitive that will not parse is left out — the property it
        // types stays permissive, which is the pre-existing behaviour.
      }
    }
    return _cache = Map<String, DslPrimitive>.unmodifiable(out);
  }

  static DslPrimitive? _parse(String name, Object? definition) {
    Object? defn = definition;
    if (defn is YamlMap) defn = json.decode(json.encode(defn));
    if (defn is String) {
      try {
        defn = json.decode(defn);
      } catch (_) {
        return null;
      }
    }
    if (defn is! Map) return null;
    final branches = <Map<String, dynamic>>[];
    void collect(Object? node) {
      if (node is! Map) return;
      final one = node['oneOf'] ?? node['anyOf'];
      if (one is List) {
        for (final b in one) {
          collect(b);
        }
        return;
      }
      branches.add(node.cast<String, dynamic>());
    }

    collect(defn);
    final patterns = <RegExp>[];
    final enums = <String>[];
    var binding = false, object = false, number = false, bareString = false;
    for (final b in branches) {
      final ref = b[r'$ref'];
      if (ref is String && ref.endsWith('Binding')) {
        binding = true;
        continue;
      }
      final pattern = b['pattern'];
      if (pattern is String) {
        try {
          patterns.add(RegExp(pattern));
        } catch (_) {
          // An invalid pattern must not silently accept everything — that is
          // exactly how the `(?i:)` form let any string through upstream.
          // Dropping it leaves the other branches to decide.
        }
        continue;
      }
      final e = b['enum'];
      if (e is List) {
        enums.addAll(e.whereType<String>());
        continue;
      }
      final t = b['type'];
      if (t == 'object' || b['properties'] != null) {
        object = true;
      } else if (t == 'number' || t == 'integer') {
        number = true;
      } else if (t == 'string') {
        bareString = true;
      }
    }
    return DslPrimitive(
      name: name,
      patterns: patterns,
      enumValues: enums,
      acceptsBinding: binding,
      acceptsObject: object,
      acceptsNumber: number,
      acceptsBareString: bareString,
    );
  }

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
}
