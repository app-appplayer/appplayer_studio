/// Parsed widget definition used by the studio builder catalogue
/// (`studio.builder.ui.catalog.*`). One [WidgetSpec] = one widget type
/// the author can drop into a `ui/app.json` tree.
///
/// Two sources feed the catalogue and both share this model:
///
/// - **standard** = `specs/mcp_ui_dsl/spec/<version>/widgets/<category>/<name>.yaml`
/// - **custom**   = `vibe_studio_ui/dart/lib/src/atoms/<name>.yaml`
///   (sits next to the inert atom body — `vbu_*.dart` — so the
///   widget's self-description ships with the widget itself.)
///
/// The model is intentionally small: type / category / description /
/// properties / examples / source. Child constraints surface today as
/// a property whose `type` is `"Widget"` or `"Array<Widget>"` — that
/// mirrors the spec yaml's current shape and avoids inventing a
/// parallel arity field before the spec itself adds one.
library;

/// Where the spec was loaded from.
enum WidgetSource {
  /// `specs/mcp_ui_dsl/spec/<version>/widgets/<category>/<name>.yaml`.
  standard,

  /// `vibe_studio_ui/dart/lib/src/atoms/<name>.yaml` (vbu atom).
  custom,
}

/// One property entry on a widget.
class WidgetPropSpec {
  WidgetPropSpec({
    required this.key,
    required this.type,
    required this.description,
    this.defaultValue,
    this.required = false,
    this.enumValues = const <String>[],
  });

  /// Property name as it appears in DSL JSON (e.g. `direction`).
  final String key;

  /// Declared type — `string` / `number` / `boolean` / `Action` /
  /// `Widget` / `Array<Widget>` / `enum<...>` / etc. Kept as the raw
  /// yaml string so callers can decide how strictly to interpret it.
  final String type;

  /// Description text from the yaml. May start with `required | ...`
  /// in the legacy 1.3 spec shape; [required] is parsed from that.
  final String description;

  /// Default value, or null if none. Type is whatever yaml parsed
  /// (string / num / bool / List / Map / null).
  final Object? defaultValue;

  /// True if the prop is required. Parsed from either an explicit
  /// `required: true` field (future) or the legacy `required | ...`
  /// description prefix.
  final bool required;

  /// Allowed enum values if [type] is `enum<...>` or the prop yaml
  /// declared an `enum` list. Empty otherwise.
  final List<String> enumValues;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'key': key,
    'type': type,
    'description': description,
    if (defaultValue != null) 'default': defaultValue,
    if (required) 'required': true,
    if (enumValues.isNotEmpty) 'enum': enumValues,
  };
}

/// One usage example for a widget — surfaced when the LLM caller asks
/// for `catalog.schema({withExamples: true})`.
class WidgetExampleSpec {
  WidgetExampleSpec({required this.name, required this.dsl});

  /// Short label (e.g. `prose_example_0` from the legacy spec, or a
  /// hand-written name from a vbu atom yaml).
  final String name;

  /// DSL fragment as a raw string. Caller may parse it with their
  /// preferred yaml/json reader — keeping it as a string preserves
  /// the original formatting.
  final String dsl;

  Map<String, dynamic> toJson() => <String, dynamic>{'name': name, 'dsl': dsl};
}

/// One widget type registered on the catalogue.
class WidgetSpec {
  WidgetSpec({
    required this.type,
    required this.category,
    required this.source,
    required this.description,
    this.profile,
    this.since,
    this.properties = const <WidgetPropSpec>[],
    this.examples = const <WidgetExampleSpec>[],
  });

  /// Widget type as it appears in DSL — `linear` / `VbuTabStrip` /
  /// `markdown`. PascalCase for vbu atoms, lowerCamel for standard.
  final String type;

  /// Category bucket — `layout` / `atom` / `form` / `chrome` / etc.
  /// Read from the yaml `category` field (no host-side classifier).
  final String category;

  /// Source registry (`standard` or `custom`).
  final WidgetSource source;

  /// Human-readable description, multiline.
  final String description;

  /// Optional `profile` field (e.g. `Core`).
  final String? profile;

  /// Optional `since` version tag (e.g. `v1.0`).
  final String? since;

  /// Property entries.
  final List<WidgetPropSpec> properties;

  /// Usage examples (empty when the loader was asked for a summary).
  final List<WidgetExampleSpec> examples;

  /// Short summary used by `catalog.list` — first line of [description].
  String get summary {
    if (description.isEmpty) return '';
    final firstNewline = description.indexOf('\n');
    return firstNewline < 0
        ? description.trim()
        : description.substring(0, firstNewline).trim();
  }

  /// JSON shape used by `catalog.list` (no properties / no examples
  /// — those land in `catalog.schema`).
  Map<String, dynamic> toListJson() => <String, dynamic>{
    'type': type,
    'category': category,
    'source': source.name,
    'summary': summary,
  };

  /// JSON shape used by `catalog.schema`. [withExamples] mirrors the
  /// tool's input flag — drops the examples array when false to keep
  /// the response small.
  Map<String, dynamic> toSchemaJson({
    bool withExamples = false,
  }) => <String, dynamic>{
    'type': type,
    'category': category,
    'source': source.name,
    'description': description,
    if (profile != null) 'profile': profile,
    if (since != null) 'since': since,
    'properties': <Map<String, dynamic>>[
      for (final p in properties) p.toJson(),
    ],
    if (withExamples)
      'examples': <Map<String, dynamic>>[for (final e in examples) e.toJson()],
  };
}
