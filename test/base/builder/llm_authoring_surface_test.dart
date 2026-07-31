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
