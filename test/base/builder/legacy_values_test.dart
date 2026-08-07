/// `legacyValues:` — spellings the spec still accepts but no longer teaches.
///
/// The two questions this separates are easy to collapse into one, and both
/// collapses are harmful. Merge legacy into `enum` and the palette starts
/// offering values the spec deliberately stopped documenting. Ignore legacy and
/// the authoring surface REJECTS what the runtime renders — and because
/// validation runs when a document loads, a published bundle carrying the old
/// spelling stops opening. That second failure is the reason this exists:
/// `linear.distribution: "space-between"` was rejected here while rendering
/// fine.
@TestOn('vm')
library;

import 'package:appplayer_studio/src/base/builder/dsl_spec_loader.dart';
import 'package:appplayer_studio/src/base/builder/widget_spec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WidgetPropSpec', () {
    final prop = WidgetPropSpec(
      key: 'distribution',
      type: 'string',
      description: '',
      enumValues: const <String>['start', 'spaceBetween'],
      legacyValues: const <String>['space-between'],
    );

    test('a check consults both sets', () {
      expect(prop.allowedValues, containsAll(<String>['start', 'spaceBetween', 'space-between']));
    });

    test('anything that suggests a value sees only the documented ones', () {
      expect(prop.enumValues, <String>['start', 'spaceBetween']);
      // `toJson` feeds `catalog.schema` — the surface an LLM authors against.
      // A legacy spelling leaking in here is how it gets taught and spread.
      expect(prop.toJson()['enum'], <String>['start', 'spaceBetween']);
      expect(prop.toJson().containsKey('legacyValues'), isFalse);
    });

    test('a property with no legacy set is unchanged', () {
      final plain = WidgetPropSpec(
        key: 'direction',
        type: 'string',
        description: '',
        enumValues: const <String>['vertical'],
      );
      expect(plain.allowedValues, <String>['vertical']);
    });
  });

  group('read from the live spec tree', () {
    test('linear.distribution keeps its kebab spelling as legacy', () async {
      final specs = await DslSpecLoader().load();
      final linear = specs.where((w) => w.type == 'linear').firstOrNull;
      // No specs tree beside a standalone clone — nothing to assert there.
      if (linear == null) return;
      final prop =
          linear.properties.where((p) => p.key == 'distribution').firstOrNull;
      if (prop == null) return;

      expect(prop.enumValues, contains('spaceBetween'));
      expect(prop.enumValues, isNot(contains('space-between')),
          reason: 'a legacy spelling reached the documented set');
      expect(prop.legacyValues, contains('space-between'),
          reason: 'legacyValues was not read off the spec');
      expect(prop.allowedValues, contains('space-between'));
    });
  });
}
