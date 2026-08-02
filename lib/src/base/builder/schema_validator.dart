/// Schema-driven validation for the atomic write mutators. Looks
/// every authored node / prop up
/// against the catalogue's [WidgetSpec] and returns a diagnostic-shaped
/// rejection when the call would commit something the spec says is
/// invalid.
///
/// Strict mode by default (Q4): unknown props, enum out-of-range,
/// missing required, type mismatch all reject. A future `mode:
/// "lenient"` opt-in could downgrade `extraProperty` to a warning
/// for exploratory authoring.
///
/// Type matching uses a small mapping over the raw yaml `type:
/// "..."` strings:
///   - `string` / `String` → dart String
///   - `number` / `num` / `int` / `double` → dart num
///   - `boolean` / `bool` → dart bool
///   - `Widget` → Map with `type` key
///   - `Array<Widget>` / `List<Widget>` → List of widget Maps
///   - `Action` / `Action<...>` → Map (state / tool / navigation /
///     resource shapes — left to the runtime to enforce deeper)
///   - `Object` / `object` / empty / `unknown` → permissive (no
///     constraint beyond non-null when required)
library;

import 'builder_catalog_service.dart';
import 'widget_spec.dart';

class ValidationResult {
  ValidationResult.ok() : ok = true, rejection = null;
  ValidationResult.reject(Map<String, dynamic> r) : ok = false, rejection = r;

  final bool ok;
  final Map<String, dynamic>? rejection;
}

class SchemaValidator {
  SchemaValidator(this.catalog);

  final BuilderCatalogService catalog;

  /// Validate an entire node before `addNode` commits. Checks:
  /// 1. `type` is a registered widget.
  /// 2. Every required prop is present.
  /// 3. Every provided prop is in the schema (strict).
  /// 4. Every provided prop matches its declared type / enum.
  Future<ValidationResult> validateNode(Object? node) async {
    if (node is! Map) {
      return ValidationResult.reject(<String, dynamic>{
        'code': 'propTypeMismatch',
        'expected': 'object with `type` key',
        'actual': node?.runtimeType.toString(),
        'message': 'A widget node must be a JSON object.',
        'suggestion':
            'Pass {"type": "<widget type>", ...} instead of a '
            'primitive or list.',
      });
    }
    final type = node['type'];
    if (type is! String || type.isEmpty) {
      return ValidationResult.reject(<String, dynamic>{
        'code': 'missingRequired',
        'expected': '`type` (string)',
        'actual': type,
        'message': 'A widget node must declare its `type`.',
        'suggestion':
            'Call studio.builder.ui.catalog.list to discover '
            'available types.',
      });
    }
    final spec = await catalog.schema(type);
    if (spec == null) {
      return ValidationResult.reject(<String, dynamic>{
        'code': 'unknownType',
        'expected': 'a type registered in catalog.list',
        'actual': type,
        'message': 'No widget type named "$type" is registered.',
        'suggestion':
            'Call studio.builder.ui.catalog.list to see available '
            'types.',
      });
    }
    // Tree-shape keys are exempt from the per-prop schema check, which used
    // to mean they were not checked AT ALL — `children: "not-a-list"` and
    // `content: 42` both passed, and the runtime then rendered nothing with
    // no error. Exempt from the SCHEMA, not from being the right shape.
    // `content` and `child` are tree slots on most widgets — but the registry
    // also registers them as spellings of ordinary properties (`content` for
    // `markdown.text`, `child` for `dragTarget.builder`). Where this widget
    // declares such a spelling, the declared type governs and the tree-shape
    // rule does not apply; `markdown {content: "…"}` is a string by contract.
    final declaredSpellings = <String, WidgetPropSpec>{
      for (final p in spec.properties)
        if (!p.isElementPath)
          for (final name in p.spellings) name: p,
    };
    bool governedBySpec(String k) {
      final p = declaredSpellings[k];
      if (p == null) return false;
      final t = p.type.toLowerCase();
      return !t.contains('widget');
    }
    for (final k in const <String>['content', 'child']) {
      if (governedBySpec(k)) continue;
      final v = node[k];
      if (v != null && v is! Map) {
        return ValidationResult.reject(<String, dynamic>{
          'code': 'badTreeShape',
          'path': '/$k',
          'expected': 'a single widget node (object)',
          'actual': v.runtimeType.toString(),
          'message': '`$k` holds one child widget, so it must be an object.',
          'suggestion': 'Wrap it: {"$k": {"type": "...", ...}}.',
        });
      }
    }
    final kids = governedBySpec('children') ? null : node['children'];
    if (kids != null) {
      if (kids is! List) {
        return ValidationResult.reject(<String, dynamic>{
          'code': 'badTreeShape',
          'path': '/children',
          'expected': 'a list of widget nodes',
          'actual': kids.runtimeType.toString(),
          'message': '`children` holds several child widgets, so it must be '
              'a list.',
          'suggestion': 'Wrap it: {"children": [{"type": "...", ...}]}.',
        });
      }
      for (var i = 0; i < kids.length; i++) {
        if (kids[i] is! Map) {
          return ValidationResult.reject(<String, dynamic>{
            'code': 'badTreeShape',
            'path': '/children/$i',
            'expected': 'a widget node (object)',
            'actual': kids[i].runtimeType.toString(),
            'message': 'Every entry in `children` must be a widget node.',
            'suggestion': 'Replace entry $i with {"type": "...", ...}.',
          });
        }
      }
    }

    // 2 + 4: required + per-prop type check on what was provided.
    final providedKeys = <String>{
      ...node.keys.cast<String>().where((k) => k != 'type'),
    };
    final knownKeys = <String>{
      for (final p in spec.properties)
        if (!p.isElementPath) p.key,
    };
    // Tree-shape keys are allowed on every node (they describe the
    // structural slots, not props): content / child / children.
    const treeKeys = <String>{'content', 'child', 'children'};
    // Universal interaction keys — any widget may carry these per
    // mcp_ui_dsl 1.3. Catalog atoms rarely declare them, so the
    // strict per-prop check would falsely reject otherwise valid
    // wiring like `box { click: { type:state, ... } }`.
    const universalActionKeys = <String>{'click', 'onTap'};
    // Spellings §17.3.2 registers count as the property being present, and
    // element-shape declarations (`columns[].key`) are not node keys at all.
    // Without the first, `dragTarget {child: …}` was reported as missing its
    // required `builder` while the value sat there under its other name;
    // without the second, `dataTable` could not be authored at all — the
    // check demanded a key literally named `columns[].key`.
    final aliasOf = <String, String>{
      for (final p in spec.properties)
        if (!p.isElementPath)
          for (final a in p.aliases) a: p.key,
    };
    for (final p in spec.properties) {
      if (p.isElementPath) continue;
      final spelling =
          p.spellings.firstWhere(providedKeys.contains, orElse: () => '');
      final present = spelling.isNotEmpty;
      final value = present ? node[spelling] : null;
      if (p.required && !present) {
        return ValidationResult.reject(<String, dynamic>{
          'code': 'missingRequired',
          'path': '/${p.key}',
          'expected': '${p.key} (${p.type})',
          'message': 'Widget "$type" requires property `${p.key}` (${p.type}).',
          'suggestion': 'Add ${p.key} to the node. ${p.description}',
        });
      }
      if (present) {
        final tv = _checkType(value, p);
        if (tv != null) {
          return ValidationResult.reject(
            tv..putIfAbsent('path', () => '/${p.key}'),
          );
        }
      }
    }
    // 3: extra props rejected (strict). Tree-shape keys and universal
    // interaction keys (click / onTap — accepted on every widget per
    // mcp_ui_dsl 1.3 Actions) are exempt.
    final extras =
        providedKeys
            .difference(knownKeys)
            .difference(aliasOf.keys.toSet())
            .difference(treeKeys)
            .difference(universalActionKeys)
            .toList();
    if (extras.isNotEmpty) {
      final k = extras.first;
      return ValidationResult.reject(<String, dynamic>{
        'code': 'extraProperty',
        'path': '/$k',
        'expected':
            'one of the props declared on $type (${knownKeys.join(', ')})',
        'actual': k,
        'message':
            '"$type" does not declare property `$k`. Strict '
            'validation is on by default.',
        'suggestion':
            'Call studio.builder.ui.catalog.schema({"type": "$type"}) '
            'to see declared props.',
      });
    }
    return ValidationResult.ok();
  }

  /// Validate a single prop change before `setProp` commits. The
  /// caller supplies the node's current `type` (which can be read
  /// via `readNode` first).
  Future<ValidationResult> validateProp({
    required String type,
    required String key,
    required Object? value,
  }) async {
    final spec = await catalog.schema(type);
    if (spec == null) {
      return ValidationResult.reject(<String, dynamic>{
        'code': 'unknownType',
        'expected': 'a type registered in catalog.list',
        'actual': type,
        'message': 'No widget type named "$type" is registered.',
        'suggestion':
            'Verify the node\'s type with studio.builder.ui.readNode.',
      });
    }
    // Tree-shape keys are allowed on every widget (mirror of the
    // `treeKeys` exemption in `validateNode`). They describe
    // structural slots, not catalog-declared props — setProp on a
    // box's `child`, a linear's `children`, or a page's `content`
    // must not trip extraProperty.
    const treeKeys = <String>{'content', 'child', 'children'};
    // Universal action keys — any widget may carry `click` / `onTap`
    // per mcp_ui_dsl. Skip extraProperty when wiring runs through
    // these slots even if the catalog atom doesn't declare them.
    const universalActionKeys = <String>{'click', 'onTap'};
    if (universalActionKeys.contains(key)) {
      // Light shape check — Action object is a Map with String `type`.
      if (value == null) return ValidationResult.ok();
      if (value is! Map || value['type'] is! String) {
        return ValidationResult.reject(<String, dynamic>{
          'code': 'propTypeMismatch',
          'path': '/$key',
          'expected': 'Action object (Map with String `type`)',
          'actual': value.runtimeType.toString(),
          'message':
              'action slot `$key` must be `{type: "<action>", ...}` '
              '(e.g. {"type":"state","action":"set", ...}).',
        });
      }
      return ValidationResult.ok();
    }
    if (treeKeys.contains(key)) {
      // Light shape validation so callers still get a useful
      // diagnostic when they hand the wrong kind of value.
      if (key == 'children') {
        if (value is! List) {
          return ValidationResult.reject(<String, dynamic>{
            'code': 'propTypeMismatch',
            'path': '/$key',
            'expected': 'Array<Widget>',
            'actual': value?.runtimeType.toString(),
            'message':
                'tree-slot `children` must be a list of widget '
                'nodes (`[{type:...}, ...]`).',
          });
        }
      } else {
        // child / content — single widget node OR null (to clear).
        if (value != null && (value is! Map || value['type'] is! String)) {
          return ValidationResult.reject(<String, dynamic>{
            'code': 'propTypeMismatch',
            'path': '/$key',
            'expected': 'Widget object (with `type`) or null',
            'actual': value.runtimeType.toString(),
            'message':
                'tree-slot `$key` must be a `{type, ...}` map (or '
                'null to clear).',
          });
        }
      }
      return ValidationResult.ok();
    }
    WidgetPropSpec? prop;
    for (final p in spec.properties) {
      if (p.key == key) {
        prop = p;
        break;
      }
    }
    if (prop == null) {
      return ValidationResult.reject(<String, dynamic>{
        'code': 'extraProperty',
        'path': '/$key',
        'expected':
            'one of the props declared on $type (${spec.properties.map((p) => p.key).join(', ')})',
        'actual': key,
        'message':
            '"$type" does not declare property `$key`. Strict '
            'validation is on by default.',
        'suggestion':
            'Call studio.builder.ui.catalog.schema({"type": "$type"}) '
            'to see declared props.',
      });
    }
    final tv = _checkType(value, prop);
    if (tv != null) {
      return ValidationResult.reject(tv..putIfAbsent('path', () => '/$key'));
    }
    return ValidationResult.ok();
  }

  /// Returns null on success, or a rejection map (without `path`)
  /// when the value doesn't match the prop's declared type / enum.
  Map<String, dynamic>? _checkType(Object? value, WidgetPropSpec prop) {
    // Enum first — overrides the raw type check.
    if (prop.enumValues.isNotEmpty) {
      if (value is! String || !prop.enumValues.contains(value)) {
        return <String, dynamic>{
          'code': 'enumOutOfRange',
          'expected': prop.enumValues,
          'actual': value,
          'message':
              '`${prop.key}` must be one of '
              '${prop.enumValues.join(', ')}.',
          'suggestion': 'Pick one of the listed values for `${prop.key}`.',
        };
      }
      return null;
    }
    if (value == null) return null; // optional null is fine
    final t = prop.type.trim();
    if (_isStringType(t)) {
      if (value is! String) return _mismatch(prop, 'string', value);
    } else if (_isNumberType(t)) {
      if (value is! num) return _mismatch(prop, 'number', value);
    } else if (_isBoolType(t)) {
      if (value is! bool) return _mismatch(prop, 'boolean', value);
    } else if (_isWidgetType(t)) {
      if (value is! Map || value['type'] is! String) {
        return _mismatch(prop, 'Widget object (with `type`)', value);
      }
    } else if (_isWidgetListType(t)) {
      if (value is! List) {
        return _mismatch(prop, 'Array<Widget>', value);
      }
      for (final e in value) {
        if (e is! Map || e['type'] is! String) {
          return _mismatch(prop, 'Array of Widget objects', e);
        }
      }
    } else if (_isActionType(t)) {
      if (value is! Map) {
        return _mismatch(prop, 'Action object', value);
      }
    }
    // Object / unknown / list / map types are permissive — fine.
    return null;
  }

  Map<String, dynamic> _mismatch(
    WidgetPropSpec prop,
    String expected,
    Object? actual,
  ) => <String, dynamic>{
    'code': 'propTypeMismatch',
    'expected': expected,
    'actual': actual?.runtimeType.toString(),
    'message':
        '`${prop.key}` expects $expected, got '
        '${actual?.runtimeType ?? "null"}.',
    'suggestion':
        'Reread the schema with studio.builder.ui.catalog.schema'
        '({"type": "...", "withExamples": true}) and check the '
        'example DSL for the right shape.',
  };

  bool _isStringType(String t) =>
      t == 'string' || t == 'String' || t == '"string"';
  bool _isNumberType(String t) =>
      t == 'number' || t == 'num' || t == 'int' || t == 'double';
  bool _isBoolType(String t) => t == 'boolean' || t == 'bool' || t == 'Boolean';
  bool _isWidgetType(String t) => t == 'Widget';
  bool _isWidgetListType(String t) =>
      t.startsWith('Array<') || t.startsWith('List<');
  bool _isActionType(String t) => t == 'Action' || t.startsWith('Action<');
}
