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
import 'dsl_primitive_loader.dart';
import 'widget_spec.dart';

class ValidationResult {
  ValidationResult.ok() : ok = true, rejection = null;
  ValidationResult.reject(Map<String, dynamic> r) : ok = false, rejection = r;

  final bool ok;
  final Map<String, dynamic>? rejection;
}

class SchemaValidator {
  SchemaValidator(this.catalog, {DslPrimitiveLoader? primitives})
    : _primitives = primitives ?? DslPrimitiveLoader();

  final BuilderCatalogService catalog;

  /// Spec primitives (`Color`, `Alignment`, `IconRef`, …). The checker used
  /// to treat every named type as permissive, so a slot typed `Color`
  /// accepted any string and the author learned nothing until the screen
  /// came up empty.
  final DslPrimitiveLoader _primitives;
  Map<String, DslPrimitive> _prims = const <String, DslPrimitive>{};

  /// Validate an entire node before `addNode` commits. Checks:
  /// 1. `type` is a registered widget.
  /// 2. Every required prop is present.
  /// 3. Every provided prop is in the schema (strict).
  /// 4. Every provided prop matches its declared type / enum.
  Future<ValidationResult> validateNode(Object? node) async {
    _prims = await _primitives.load();
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
    // 2b: element-shape declarations (`columns[].key`, `options.legend.
    // position`). The registry declares 21 of them and the checker skipped
    // every one, so `dataTable` rows missing their key and
    // `chart {options: {legend: {position: "nowhere"}}}` both passed while
    // the runtime read nothing. Walk into the value and apply the sub-spec.
    for (final sub in spec.properties.where((p) => p.isElementPath)) {
      final rejection = _checkNested(node, sub, type);
      if (rejection != null) return ValidationResult.reject(rejection);
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

  /// Apply an element-path declaration (`columns[].key`, `a.b.c`) to [node].
  ///
  /// Absent containers are not an error here — the top-level check already
  /// decided whether the container itself was required. What this catches is
  /// a container that IS present and whose contents disagree with the
  /// registry.
  Map<String, dynamic>? _checkNested(
    Map<dynamic, dynamic> node,
    WidgetPropSpec sub,
    String type,
  ) {
    final segments = sub.key.split('.');
    var current = <Object?>[node];
    for (var i = 0; i < segments.length; i++) {
      final raw = segments[i];
      final isList = raw.endsWith('[]');
      final name = isList ? raw.substring(0, raw.length - 2) : raw;
      final next = <Object?>[];
      for (final holder in current) {
        if (holder is! Map) continue;
        final value = holder[name];
        final last = i == segments.length - 1;
        if (value == null) {
          if (sub.required && holder.containsKey(name) == false && !last) {
            continue; // container absent — nothing to say
          }
          if (sub.required && last) {
            return <String, dynamic>{
              'code': 'missingRequired',
              'path': '/${sub.key}',
              'expected': '${sub.key} (${sub.type})',
              'message':
                  'Widget "$type" requires `${sub.key}`. ${sub.description}',
              'suggestion': 'Add $name to each entry of the container.',
            };
          }
          continue;
        }
        if (isList) {
          if (value is! List) {
            return <String, dynamic>{
              'code': 'propTypeMismatch',
              'path': '/$name',
              'expected': 'a list',
              'actual': value.runtimeType.toString(),
              'message': '`$name` must be a list — `${sub.key}` describes its '
                  'entries.',
              'suggestion': 'Wrap the entries: {"$name": [ … ]}.',
            };
          }
          next.addAll(value);
        } else {
          next.add(value);
        }
      }
      current = next;
      if (current.isEmpty) return null;
    }
    // `current` now holds the leaf values the declaration governs.
    for (final leaf in current) {
      final rejection = _checkType(leaf, sub);
      if (rejection != null) {
        return rejection..putIfAbsent('path', () => '/${sub.key}');
      }
    }
    return null;
  }

  /// Returns null on success, or a rejection map (without `path`)
  /// when the value doesn't match the prop's declared type / enum.
  Map<String, dynamic>? _checkType(Object? value, WidgetPropSpec prop) {
    // Enum first — overrides the raw type check. Gated on the ACCEPTED set so
    // a property that carries only legacy spellings is still range-checked.
    if (prop.allowedValues.isNotEmpty) {
      // A binding stands in for any literal: the value is not known until the
      // runtime resolves it, so there is nothing to range-check here. Rejecting
      // it made every `variant: "{{state.x}}"` unauthorable even though it
      // renders (spec 1.4 widened enum slots to literal OR binding).
      if (isBindingExpression(value)) return null;
      // `allowedValues`, not `enumValues`: a spelling the spec keeps accepting
      // renders fine, and this check runs when a document LOADS — rejecting it
      // would stop an already-published bundle from opening. The message still
      // names only the documented values, so an author is never taught one.
      if (value is! String || !prop.allowedValues.contains(value)) {
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
    } else if (_isListType(t)) {
      // Every `array<X>` / `Array<X>` / `List<X>` slot must hold a list. The
      // element check is stricter only for widgets; an item shape (`Option`,
      // `Column`, …) is checked by the nested-declaration pass, and a scalar
      // element list is left alone. Before this, `array<Option>` had no shape
      // check at all — `options: "notalist"` authored clean, because only
      // `Array<Widget>` was recognised as a list.
      if (value is! List) {
        return _mismatch(prop, t, value);
      }
      if (_listElementIsWidget(t)) {
        for (final e in value) {
          if (e is! Map || e['type'] is! String) {
            return _mismatch(prop, 'Array of Widget objects', e);
          }
        }
      } else {
        final item = _primitiveFor(_listElementType(t));
        if (item != null) {
          for (final e in value) {
            final missing = item.missingRequiredKeys(e);
            if (missing.isNotEmpty) {
              return _missingItemKey(prop, item.name, missing.first, e);
            }
          }
        }
      }
    } else if (_isActionType(t)) {
      if (value is! Map) {
        return _mismatch(prop, 'Action object', value);
      }
    } else {
      // A named spec primitive (`Color`, `Alignment`, `IconRef`, …). The
      // contract lives in `configs/_primitive/<Name>.yaml`; read it rather
      // than keep a copy here that goes stale the next time the spec moves.
      final prim = _primitiveFor(t);
      final missing = prim?.missingRequiredKeys(value) ?? const <String>[];
      if (missing.isNotEmpty) {
        return _missingItemKey(prop, prim!.name, missing.first, value);
      }
      final verdict = prim?.accepts(value);
      if (verdict == false && !_unionAlsoAccepts(t, value)) {
        return <String, dynamic>{
          'code': 'primitiveOutOfRange',
          'expected': prim!.expectation,
          'actual': value,
          'message': '`${prop.key}` is a ${prim.name}: "$value" is not one of '
              'the forms it accepts.',
          'suggestion': 'See `configs/_primitive/${prim.name}.yaml` for the '
              'accepted spellings.',
        };
      }
    }
    // Object / unknown / list / map types are permissive — fine.
    return null;
  }

  /// The element type a list slot names — `array<Option>` → `Option`.
  String _listElementType(String t) {
    final open = t.indexOf('<');
    if (open < 0) return '';
    return t.substring(open + 1, t.length - 1).trim();
  }

  Map<String, dynamic> _missingItemKey(
    WidgetPropSpec prop,
    String shape,
    String key,
    Object? item,
  ) => <String, dynamic>{
    'code': 'missingRequired',
    'expected': '$shape with `$key`',
    'actual': item,
    'message': '`${prop.key}` holds a $shape that is missing required '
        'property `$key`.',
    'suggestion': 'Every $shape must declare `$key`; a misspelled key is kept '
        'as an extra rather than read, so the entry ends up without one.',
  };

  /// Whether a union type has a SCALAR branch that takes [value] on its own.
  ///
  /// `box.padding` is declared `["string", "EdgeInsets"]` because the spec
  /// accepts an M3 spacing token there (`md`, or any custom slot in
  /// `theme.spacing`) as well as the inset object. Checking only the named
  /// primitive rejected `padding: "md"` — a spelling the spec documents — so
  /// the scalar branch has to be honoured before the primitive verdict stands.
  ///
  /// Deliberately narrow: only the branch kinds a scalar can satisfy. A union
  /// of two named primitives still has to satisfy one of them.
  bool _unionAlsoAccepts(String declared, Object? value) {
    final parts = declared.split('|').map((p) => p.trim().replaceAll('"', ''));
    for (final t in parts) {
      if (_isStringType(t) && value is String) return true;
      if (_isNumberType(t) && value is num) return true;
      if (_isBoolType(t) && value is bool) return true;
      if (t == 'any') return true;
    }
    return false;
  }

  /// The primitive a declared type names, if any. A union (`Color | binding`)
  /// resolves to its first named primitive — the binding half is already
  /// covered by every primitive that refs `Binding`.
  DslPrimitive? _primitiveFor(String declared) {
    for (final part in declared.split('|')) {
      final t = part.trim().replaceAll('"', '');
      final prim = _prims[t];
      if (prim != null) return prim;
    }
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
  bool _isListType(String t) =>
      t.startsWith('Array<') || t.startsWith('List<') || t.startsWith('array<');

  /// Whether a list slot's ELEMENTS are widgets — `array<Widget>` and the
  /// bare `Array<…>` shorthand the 1.3 specs used for children.
  bool _listElementIsWidget(String t) {
    final open = t.indexOf('<');
    final inner = t.substring(open + 1, t.length - 1).trim();
    return inner.isEmpty || inner == 'Widget';
  }
  bool _isActionType(String t) => t == 'Action' || t.startsWith('Action<');
}
