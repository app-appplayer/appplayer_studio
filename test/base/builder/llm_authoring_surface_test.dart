/// What an LLM authoring through `studio.builder.ui.*` can and cannot get
/// wrong. The surface is only as strict as the catalogue behind it, and two
/// holes made it reject valid work and accept broken work at the same time.
///
///   v1  the studio's own Vbu* widgets are IN the catalogue
///       (they were read off `tools/builder/vibe_studio_ui/…`, a path that
///       stopped existing, so `custom` was empty and every `Vbu*` node was
///       rejected as an unknown type — the surface refused to author with
///       the very widgets this studio ships)
///   v2  the loader resolves real asset keys, not an empty list
///   v3  a spec widget still validates (the fix did not displace the
///       standard catalogue)
///   v4  `children` must be a list of nodes
///   v5  `content` / `child` must be a single node
///   v6  a well-formed tree passes
///   v7  values the spec spells out in PROSE are enforced too — 16 string
///       properties document their allowed set in the description instead
///       of a schema `enum`, so nothing could reject a wrong value
///   v8  the derivation only fires on an unambiguous value list, and a real
///       schema `enum` always wins over it
library;

import 'package:appplayer_studio/base.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BuilderCatalogService catalog;
  late SchemaValidator validator;

  setUp(() {
    catalog = BuilderCatalogService();
    validator = SchemaValidator(catalog);
  });

  test('v1 the studio ships its own widgets INTO the catalogue', () async {
    final custom = await catalog.list(source: 'custom');
    expect(custom, isNotEmpty,
        reason: 'an empty custom catalogue means every Vbu* type is unknown '
            'to studio.builder.ui.addNode — the authoring surface would '
            'refuse the widgets this studio is built out of');
    expect(custom.length, greaterThan(20),
        reason: 'the atoms directory ships dozens of specs; a handful means '
            'only some were packaged');
    expect(await catalog.schema('VbuActivityBar'), isNotNull);
  });

  test('v2 the loader resolves real asset keys', () async {
    final diag = await catalog.diag();
    final keys = diag['customAssetKeys'] as List;
    expect(keys, isNotEmpty,
        reason: 'empty means the specs were not packaged — the silent '
            'failure that emptied the custom catalogue in the first place');
    expect(keys.every((k) => (k as String).endsWith('.yaml')), isTrue);
  });

  test('v3 the standard catalogue still resolves', () async {
    expect(await catalog.schema('button'), isNotNull);
    final r = await validator.validateNode(<String, dynamic>{
      'type': 'button',
      'label': 'Go',
    });
    expect(r.ok, isTrue);
  });

  test('v4 children must be a list of nodes', () async {
    final notList = await validator.validateNode(<String, dynamic>{
      'type': 'linear',
      'children': 'oops',
    });
    expect(notList.ok, isFalse);
    expect(notList.rejection!['code'], 'badTreeShape');

    final badEntry = await validator.validateNode(<String, dynamic>{
      'type': 'linear',
      'children': <dynamic>['oops'],
    });
    expect(badEntry.ok, isFalse);
    expect(badEntry.rejection!['path'], '/children/0');
  });

  test('v5 content / child must be a single node', () async {
    for (final k in <String>['content', 'child']) {
      final r = await validator.validateNode(<String, dynamic>{
        'type': 'box',
        k: 42,
      });
      expect(r.ok, isFalse, reason: '$k must be an object');
      expect(r.rejection!['code'], 'badTreeShape');
    }
  });

  test('v7 prose-documented values are enforced', () async {
    final bad = await validator.validateNode(<String, dynamic>{
      'type': 'button',
      'label': 'G',
      'variant': 'fancy',
    });
    expect(bad.ok, isFalse,
        reason: '`button.variant` lists its values in the description rather '
            'than a schema enum, so an invented value used to pass and be '
            'silently ignored at render time');
    expect(bad.rejection!['code'], 'enumOutOfRange');
    expect(bad.rejection!['expected'], contains('outlined'));

    final good = await validator.validateNode(<String, dynamic>{
      'type': 'button',
      'label': 'G',
      'variant': 'outlined',
    });
    expect(good.ok, isTrue, reason: 'a documented value must still pass');
  });

  test('v8 the derivation is conservative and defers to the schema', () async {
    // Unambiguous list -> derived.
    expect(documentedEnumValues('`a`, `b`, `c`.'), <String>['a', 'b', 'c']);
    expect(documentedEnumValues('Cross-axis alignment: `start`, `end`.'),
        <String>['start', 'end']);
    // Prose that merely mentions names -> NOT a value list. This is the
    // shape of `fileExplorer.items`, and treating it as an enum would
    // reject every valid value of that property.
    expect(
        documentedEnumValues(
            'Hierarchical `{ name, path, type, children? }` tree. Required '
            'when `rootPath`/`files`/`directories` legacy props are omitted.'),
        isEmpty);
    expect(documentedEnumValues('Text content. Supports binding.'), isEmpty);
    expect(documentedEnumValues('`only`'), isEmpty,
        reason: 'a single token is a mention, not a choice');

    // A property WITH a schema enum keeps the schema's list, so when the
    // spec eventually declares one for these the derivation retires itself.
    final text = await catalog.schema('text');
    final variant = text!.properties.firstWhere((p) => p.key == 'variant');
    expect(variant.enumValues, contains('titleLarge'));
  });

  test('v9 an enum slot takes a BINDING as well as a literal', () async {
    // Spec 1.4 widened enum string slots to "literal OR binding". The range
    // check ran on the raw string, so `"{{state.variant}}"` was measured
    // against the enum list and rejected — a form that renders correctly could
    // not be authored. A binding's value is not known until the runtime
    // resolves it, so there is nothing to range-check.
    final bound = await validator.validateNode(<String, dynamic>{
      'type': 'text',
      'text': 'x',
      'variant': '{{state.variant}}',
    });
    expect(bound.ok, isTrue, reason: 'a binding stands in for any literal');

    // The check still bites on a literal that is not in the set — widening it
    // to bindings must not widen it to anything else.
    final bad = await validator.validateNode(<String, dynamic>{
      'type': 'text',
      'text': 'x',
      'variant': 'fancy',
    });
    expect(bad.ok, isFalse);
    expect(bad.rejection!['code'], 'enumOutOfRange');

    // A string that merely mentions braces is not a binding.
    final notBinding = await validator.validateNode(<String, dynamic>{
      'type': 'text',
      'text': 'x',
      'variant': 'a {{b}} c',
    });
    expect(notBinding.ok, isFalse,
        reason: 'the whole value must be the binding expression');
  });

  test('v10 §2.6.0 shared input rows are part of every input widget', () async {
    // The section is normative and says the per-widget tables OMIT these rows.
    // Reading the yaml literally therefore concludes `binding` is not a
    // property of `checkbox` — and the surface rejected the canonical spelling
    // of two-way binding on every input widget while the runtime required it.
    const shared = <String>['binding', 'value', 'enabled', 'onChange'];

    final checkbox = await catalog.schema('checkbox');
    final keys = checkbox!.properties.map((p) => p.key).toSet();
    expect(keys, containsAll(shared));
    expect(keys, containsAll(<String>['label', 'change']),
        reason: 'the widget\'s own yaml rows must survive');

    final bound = await validator.validateNode(<String, dynamic>{
      'type': 'checkbox',
      'label': 'A',
      'binding': 'form.a',
    });
    expect(bound.ok, isTrue);

    // A legacy alias spelling the factory still reads is NOT canon: 1.3 took
    // it out of the spec and left it in code for compatibility, so authoring
    // keeps rejecting it. (`tristate` was the other half of this pair until
    // 1.4.1 judged it a feature rather than an alias — it has no other
    // spelling — and declared it, so it is canon now and checked as boolean.)
    final legacy = await validator.validateNode(<String, dynamic>{
      'type': 'checkbox',
      'label': 'A',
      'bindTo': 'f.a',
    });
    expect(legacy.ok, isFalse, reason: '`bindTo` is a compat read, not spec');
    expect(legacy.rejection!['code'], 'extraProperty');

    final tristate = await validator.validateNode(<String, dynamic>{
      'type': 'checkbox',
      'label': 'A',
      'tristate': true,
    });
    expect(tristate.ok, isTrue, reason: '1.4.1 declared `checkbox.tristate`');

    // §2.6.0 names its own exceptions — a button has no user-changeable value.
    final button = await catalog.schema('button');
    expect(button!.properties.map((p) => p.key), isNot(contains('binding')));

    // And the rows belong to §2.6 only — a layout widget does not take a
    // two-way binding, so injecting them everywhere would hand authors a
    // property the runtime never reads.
    final linear = await catalog.schema('linear');
    expect(linear!.properties.map((p) => p.key), isNot(contains('binding')));
    final onLayout = await validator.validateNode(<String, dynamic>{
      'type': 'linear',
      'direction': 'vertical',
      'binding': 'form.a',
      'children': <dynamic>[],
    });
    expect(onLayout.ok, isFalse);
    expect(onLayout.rejection!['code'], 'extraProperty');

    // Every other input widget carries them.
    final all = await catalog.list(source: 'standard');
    final inputs = all.where((w) =>
        w.category == 'input' &&
        !DslSpecLoader.kCommonInputRowExceptions.contains(w.type));
    expect(inputs, isNotEmpty);
    for (final w in inputs) {
      final spec = await catalog.schema(w.type);
      expect(spec!.properties.map((p) => p.key), containsAll(shared),
          reason: '${w.type} is an input widget');
    }
  });

  test('v11 a union honours its scalar branch as well as its primitive',
      () async {
    // `box.padding` is `["string", "EdgeInsets"]`: the spec takes an M3 spacing
    // token there (`md`, or any custom slot in `theme.spacing`) OR the inset
    // object. Once `EdgeInsets` became a named primitive the check ran on that
    // half alone and rejected `padding: "md"` — a spelling the spec documents.
    for (final ok in <Object>['md', 8, <String, dynamic>{'all': 8}]) {
      final r = await validator.validateNode(<String, dynamic>{
        'type': 'box',
        'padding': ok,
      });
      expect(r.ok, isTrue, reason: 'padding accepts $ok');
    }

    // `box.margin` took the same widening in the 1.4.1 follow-up — the widget
    // always resolved both slots through one helper, so declaring less there
    // only made the token unauthorable, never unrenderable. It accepts every
    // padding spelling now, the open string branch included.
    for (final ok in <Object>[
      'md',
      8,
      '{{layout.pad}}',
      <String, dynamic>{'all': 8},
    ]) {
      final r = await validator.validateNode(<String, dynamic>{
        'type': 'box',
        'margin': ok,
      });
      expect(r.ok, isTrue, reason: 'margin accepts $ok');
    }

    // The primitive verdict still STANDS where the spec declares `EdgeInsets`
    // alone — `linear.padding` has no scalar branch, so a bare word there is
    // rejected. Without this half, widening `box` would look identical to the
    // primitive check having stopped working altogether.
    final bad = await validator.validateNode(<String, dynamic>{
      'type': 'linear',
      'padding': 'hello world',
    });
    expect(bad.ok, isFalse);
    expect(bad.rejection!['code'], 'primitiveOutOfRange');
  });

  test('v12 an item-list slot must actually hold a list', () async {
    // `checkboxGroup.options` is `array<Option>`. Only `Array<Widget>` was
    // recognised as a list, so `options: "notalist"` authored clean while
    // `dataTable.columns` was caught — and only because it happens to carry a
    // nested `columns[].key` declaration. The shape check belongs to the slot,
    // not to whether something else declared its innards.
    final scalar = await validator.validateNode(<String, dynamic>{
      'type': 'checkboxGroup',
      'options': 'notalist',
    });
    expect(scalar.ok, isFalse);
    expect(scalar.rejection!['code'], 'propTypeMismatch');

    // Items stay permissive about EXTRA keys — a document may carry its own
    // bookkeeping — but the keys the shape requires still have to be there.
    for (final options in <Object>[
      <dynamic>[<String, dynamic>{'value': 'a', 'label': 'A'}],
      <dynamic>[<String, dynamic>{'value': 'a'}], // label falls back to value
      <dynamic>[<String, dynamic>{'value': 'a', 'mine': 1}], // extra key is fine
      <dynamic>['a', 'b'], // the scalar form is not an Option object
    ]) {
      final r = await validator.validateNode(<String, dynamic>{
        'type': 'checkboxGroup',
        'options': options,
      });
      expect(r.ok, isTrue, reason: 'options accepts $options');
    }

    // A misspelling is an extra key AND a missing required one. The runtime
    // turns a missing `value` into `''`, so two such entries answer to the
    // same value — it renders, and one click checks both.
    final typo = await validator.validateNode(<String, dynamic>{
      'type': 'checkboxGroup',
      'options': <dynamic>[<String, dynamic>{'lable': 'A'}],
    });
    expect(typo.ok, isFalse);
    expect(typo.rejection!['code'], 'missingRequired');

    // Widget lists keep the stricter element check.
    final badChild = await validator.validateNode(<String, dynamic>{
      'type': 'linear',
      'direction': 'vertical',
      'children': <dynamic>['not-a-node'],
    });
    expect(badChild.ok, isFalse);
  });

  test('v6 a well-formed tree passes', () async {
    final r = await validator.validateNode(<String, dynamic>{
      'type': 'linear',
      'direction': 'vertical',
      'children': <dynamic>[
        <String, dynamic>{'type': 'text', 'text': 'hi'},
      ],
    });
    expect(r.ok, isTrue, reason: 'the shape check must not reject valid trees');
  });
}
