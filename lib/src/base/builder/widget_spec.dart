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
    this.legacyValues = const <String>[],
    this.aliases = const <String>[],
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

  /// Spellings the spec still ACCEPTS but no longer teaches — the kebab
  /// `space-between` for `linear.distribution`, `light`/`dark` for
  /// `codeEditor.theme`. Kept apart from [enumValues] rather than merged into
  /// it because the two answer different questions: what may a document
  /// contain (both), and what should an author be offered (only [enumValues]).
  ///
  /// Folding them together would put undocumented spellings in the palette and
  /// the generated tables; dropping them instead makes the authoring surface
  /// REJECT documents the runtime renders, and validation runs at load, so a
  /// published bundle using the old spelling stops opening. See
  /// [allowedValues], which is what a check must consult.
  final List<String> legacyValues;

  /// Every value a document may carry here. The check uses this; anything that
  /// SUGGESTS a value uses [enumValues].
  List<String> get allowedValues => <String>[...enumValues, ...legacyValues];

  /// Spellings §17.3.2 registers for this property (`child` for
  /// `dragTarget.builder`, `content` for `markdown.text`). The runtime
  /// resolves them, so a checker that only knows [key] rejects documents
  /// the runtime renders — and for a required property it rejects them as
  /// "missing" while the value is sitting right there under its other name.
  final List<String> aliases;

  /// Every spelling that satisfies this property.
  List<String> get spellings => <String>[key, ...aliases];

  /// Element-shape declarations (`columns[].key`) describe items INSIDE an
  /// array property, not a key on the node. Treating them as node keys made
  /// every `dataTable` unauthorable: the check demanded a property literally
  /// named `columns[].key`.
  bool get isElementPath => key.contains('[]') || key.contains('.');

  Map<String, dynamic> toJson() => <String, dynamic>{
    'key': key,
    'type': type,
    'description': description,
    if (defaultValue != null) 'default': defaultValue,
    if (required) 'required': true,
    if (enumValues.isNotEmpty) 'enum': enumValues,
    if (aliases.isNotEmpty) 'aliases': aliases,
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
    this.aliases = const <String>[],
    this.properties = const <WidgetPropSpec>[],
    this.examples = const <WidgetExampleSpec>[],
  });

  /// Widget type as it appears in DSL — `linear` / `VbuTabStrip` /
  /// `markdown`. PascalCase for vbu atoms, lowerCamel for standard.
  final String type;

  /// Other spellings of this same widget, declared by the spec's
  /// widget-level `aliases:` (`box` is also `container`, `decoratedBox`;
  /// `mediaPlayer` is also `video`, `audio`).
  ///
  /// These are the names the runtime registers alongside the canonical one,
  /// so a document may carry any of them. They were parsed for PROPERTIES
  /// long before they were parsed here, which is why authoring rejected
  /// `{"type": "container"}` as an unknown type while the runtime drew it —
  /// 31 widgets declare them and the catalogue read none.
  final List<String> aliases;

  /// Every name this widget answers to, canonical first.
  List<String> get spellings => <String>[type, ...aliases];

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
    // Listed rather than given rows of their own: an alias is the same widget,
    // and a catalogue that repeats it teaches a vocabulary bigger than the
    // one the spec defines.
    if (aliases.isNotEmpty) 'aliases': aliases,
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
    if (aliases.isNotEmpty) 'aliases': aliases,
    if (profile != null) 'profile': profile,
    if (since != null) 'since': since,
    'properties': <Map<String, dynamic>>[
      for (final p in properties) p.toJson(),
    ],
    if (withExamples)
      'examples': <Map<String, dynamic>>[for (final e in examples) e.toJson()],
  };
}
