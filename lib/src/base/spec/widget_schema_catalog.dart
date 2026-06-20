import 'dart:convert';

// Reach into core's internal `src/` to grab the generated widgets schema
// constant. Core does not publicly export the constant yet, but Dart
// imports do not enforce the `src/` privacy convention. The constant is
// the single source of truth for the DSL widget registry — using it
// here ensures the Properties form and the runtime stay aligned.
// ignore: implementation_imports
import 'package:flutter_mcp_ui_core/src/schema/widgets_schema.g.dart'
    show mcpUiDslWidgetsSchemaJson;

/// Runtime-friendly view of one property in a widget's JSON Schema entry.
class WidgetPropertyDescriptor {
  WidgetPropertyDescriptor({
    required this.name,
    this.jsonType,
    this.enumValues,
    this.description,
    this.isWidgetEdge = false,
    this.required = false,
    this.defaultValue,
  });

  /// Property key as it appears under `properties:` in the schema.
  final String name;

  /// `string` / `integer` / `number` / `boolean` / `object` / `array` /
  /// null when the schema uses `anyOf` / `$ref` only.
  final String? jsonType;

  /// Concrete list of accepted string values when the schema declares
  /// `enum`.
  final List<String>? enumValues;

  /// Markdown-flavoured description from the schema. Surface as a
  /// tooltip / helper text so the user has spec-level guidance inline.
  final String? description;

  /// True when the property is a child widget slot (single `$ref` to
  /// `Widget`, or an array of such refs). The Properties form skips
  /// these — child editing happens in the widget tree.
  final bool isWidgetEdge;

  /// True when the property is in the schema's `required` list.
  final bool required;

  /// `default:` value declared in the schema, when present. Currently
  /// only surfaced as a hint string.
  final String? defaultValue;
}

/// Singleton facade over the generated MCP UI DSL widgets schema. Lazily
/// parses the JSON once, then answers per-type lookups in O(props).
class WidgetSchemaCatalog {
  WidgetSchemaCatalog._() {
    final raw = jsonDecode(mcpUiDslWidgetsSchemaJson);
    _defs =
        (raw is Map && raw[r'$defs'] is Map)
            ? Map<String, dynamic>.from(raw[r'$defs'] as Map)
            : <String, dynamic>{};
  }

  static final WidgetSchemaCatalog instance = WidgetSchemaCatalog._();

  late final Map<String, dynamic> _defs;
  final Map<String, List<WidgetPropertyDescriptor>> _cache =
      <String, List<WidgetPropertyDescriptor>>{};

  /// Ordered property descriptors for the given widget [type]. Order
  /// follows declaration order in the schema. Returns an empty list
  /// when the type is unknown.
  List<WidgetPropertyDescriptor> propertiesFor(String type) {
    final cached = _cache[type];
    if (cached != null) return cached;
    final def = _findDef(type);
    if (def == null) return _cache[type] = const <WidgetPropertyDescriptor>[];
    final props = def['properties'];
    if (props is! Map) return _cache[type] = const <WidgetPropertyDescriptor>[];
    final required = <String>{
      for (final r
          in (def['required'] as List?)?.whereType<String>() ??
              const <String>[])
        r,
    };
    final out = <WidgetPropertyDescriptor>[];
    for (final entry in props.entries) {
      final name = entry.key as String;
      if (name == 'type') continue;
      final spec = entry.value;
      if (spec is! Map) continue;
      out.add(
        _toDescriptor(
          name,
          Map<String, dynamic>.from(spec),
          required.contains(name),
        ),
      );
    }
    return _cache[type] = List.unmodifiable(out);
  }

  /// Whether the catalog recognises this widget type.
  bool knows(String type) => _findDef(type) != null;

  /// Canonical widget type names declared in the schema (`$defs` keys).
  /// Aliases declared via a type's enum entry are not listed here — they
  /// resolve through [knows] / [propertiesFor] / [rawDef] but the
  /// canonical key is the registry surface.
  List<String> get types =>
      List<String>.unmodifiable(_defs.keys.where((k) => k != 'Widget'));

  /// Raw JSON-Schema fragment for [type] (the `$defs/<type>` body).
  /// Returns null when the type is unknown. Use this when an LLM needs
  /// the full schema verbatim — `propertiesFor` is the lossy view used
  /// by the Properties form.
  Map<String, dynamic>? rawDef(String type) => _findDef(type);

  /// Raw schema document (`mcpUiDslWidgetsSchemaJson` parsed). Useful
  /// for one-shot exposure to MCP clients via `vibe://widgets`.
  String get rawSchemaJson => mcpUiDslWidgetsSchemaJson;

  /// Spec-level description for the widget type itself (the body text
  /// at the top of the `$defs/<type>` entry). Useful as a hint near the
  /// type heading.
  String? descriptionOf(String type) {
    final def = _findDef(type);
    if (def == null) return null;
    final desc = def['description'];
    return desc is String ? desc : null;
  }

  Map<String, dynamic>? _findDef(String type) {
    // Most widget keys match their type field directly. Try that first.
    final direct = _defs[type];
    if (direct is Map) return Map<String, dynamic>.from(direct);
    // Fallback — some defs map multiple `type` aliases (e.g. alertDialog
    // accepts both 'alertDialog' and 'alert'). Walk all defs and check
    // whether the candidate's `type` enum includes the requested name.
    for (final entry in _defs.entries) {
      final v = entry.value;
      if (v is! Map) continue;
      final propsRaw = v['properties'];
      if (propsRaw is! Map) continue;
      final typeProp = propsRaw['type'];
      if (typeProp is! Map) continue;
      final en = typeProp['enum'];
      if (en is List && en.contains(type)) {
        return Map<String, dynamic>.from(v);
      }
    }
    return null;
  }

  WidgetPropertyDescriptor _toDescriptor(
    String name,
    Map<String, dynamic> spec,
    bool required,
  ) {
    // `$ref` directly to Widget = single child slot.
    final ref = spec[r'$ref'];
    if (ref == r'#/$defs/Widget') {
      return WidgetPropertyDescriptor(
        name: name,
        isWidgetEdge: true,
        required: required,
        description: spec['description'] as String?,
      );
    }
    // `array of $ref Widget` = list of children slot.
    if (spec['type'] == 'array') {
      final items = spec['items'];
      if (items is Map && items[r'$ref'] == r'#/$defs/Widget') {
        return WidgetPropertyDescriptor(
          name: name,
          isWidgetEdge: true,
          required: required,
          description: spec['description'] as String?,
        );
      }
    }
    // Most numeric / string properties allow a binding-string alongside
    // the typed value via `anyOf: [<typed>, {type:'string', pattern:'^\\{\\{...\\}\\}$'}]`.
    // Surface the typed branch so the editor uses the right control;
    // bindings still work because we always commit raw strings/numbers.
    final unwrapped = _unwrapAnyOf(spec);
    return WidgetPropertyDescriptor(
      name: name,
      jsonType: unwrapped['type'] as String?,
      enumValues: (unwrapped['enum'] as List?)?.whereType<String>().toList(
        growable: false,
      ),
      description:
          (unwrapped['description'] as String?) ??
          spec['description'] as String?,
      defaultValue: unwrapped['default']?.toString(),
      required: required,
    );
  }

  /// When a property is declared as `anyOf: [{ ...typed... }, { type: 'string',
  /// pattern: '^\{\{...\}\}$' }]`, return the typed branch so the form picks
  /// a real editor; otherwise return the spec verbatim.
  Map<String, dynamic> _unwrapAnyOf(Map<String, dynamic> spec) {
    final any = spec['anyOf'];
    if (any is! List) return spec;
    Map<String, dynamic>? typed;
    for (final alt in any) {
      if (alt is! Map) continue;
      final altMap = Map<String, dynamic>.from(alt);
      final pattern = altMap['pattern'];
      if (pattern is String && pattern.contains(r'\{\{')) continue;
      typed = altMap;
      break;
    }
    return typed ?? spec;
  }
}
