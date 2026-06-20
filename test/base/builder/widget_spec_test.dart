/// Unit coverage for `widget_spec.dart` — WidgetPropSpec, WidgetExampleSpec,
/// and WidgetSpec value classes including `summary`, `toListJson`, and
/// `toSchemaJson`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart';

void main() {
  // ---------------------------------------------------------------------------
  // WidgetSource enum
  // ---------------------------------------------------------------------------
  group('WidgetSource', () {
    test('has exactly two values', () {
      expect(WidgetSource.values, hasLength(2));
      expect(
        WidgetSource.values,
        containsAll(<WidgetSource>[WidgetSource.standard, WidgetSource.custom]),
      );
    });

    test('names are stable', () {
      expect(WidgetSource.standard.name, 'standard');
      expect(WidgetSource.custom.name, 'custom');
    });
  });

  // ---------------------------------------------------------------------------
  // WidgetPropSpec
  // ---------------------------------------------------------------------------
  group('WidgetPropSpec', () {
    test('minimal construction — required fields only', () {
      final p = WidgetPropSpec(
        key: 'label',
        type: 'string',
        description: 'The text label.',
      );
      expect(p.key, 'label');
      expect(p.type, 'string');
      expect(p.description, 'The text label.');
      expect(p.required, isFalse);
      expect(p.enumValues, isEmpty);
      expect(p.defaultValue, isNull);
    });

    test('toJson includes required and enum when set', () {
      final p = WidgetPropSpec(
        key: 'axis',
        type: 'string',
        description: 'Layout axis.',
        required: true,
        enumValues: <String>['horizontal', 'vertical'],
        defaultValue: 'horizontal',
      );
      final j = p.toJson();
      expect(j['key'], 'axis');
      expect(j['required'], isTrue);
      expect(j['enum'], <String>['horizontal', 'vertical']);
      expect(j['default'], 'horizontal');
    });

    test('toJson omits required key when false', () {
      final p = WidgetPropSpec(key: 'x', type: 'number', description: '');
      expect(p.toJson().containsKey('required'), isFalse);
    });

    test('toJson omits enum key when empty', () {
      final p = WidgetPropSpec(key: 'x', type: 'number', description: '');
      expect(p.toJson().containsKey('enum'), isFalse);
    });

    test('toJson omits default key when null', () {
      final p = WidgetPropSpec(key: 'x', type: 'number', description: '');
      expect(p.toJson().containsKey('default'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // WidgetExampleSpec
  // ---------------------------------------------------------------------------
  group('WidgetExampleSpec', () {
    test('construction and toJson', () {
      final ex = WidgetExampleSpec(
        name: 'basic_pill',
        dsl: '{"type":"VbuPill","label":"hello"}',
      );
      expect(ex.name, 'basic_pill');
      expect(ex.dsl, contains('VbuPill'));
      final j = ex.toJson();
      expect(j['name'], 'basic_pill');
      expect(j['dsl'], ex.dsl);
    });
  });

  // ---------------------------------------------------------------------------
  // WidgetSpec
  // ---------------------------------------------------------------------------
  group('WidgetSpec', () {
    WidgetSpec _spec({
      String type = 'VbuPill',
      String category = 'atom',
      WidgetSource source = WidgetSource.custom,
      String description = 'First line.\nSecond line.',
      List<WidgetPropSpec>? props,
      List<WidgetExampleSpec>? examples,
    }) => WidgetSpec(
      type: type,
      category: category,
      source: source,
      description: description,
      properties: props ?? const <WidgetPropSpec>[],
      examples: examples ?? const <WidgetExampleSpec>[],
    );

    test('summary returns first line of description', () {
      final s = _spec(description: 'Short summary.\nLonger detail here.');
      expect(s.summary, 'Short summary.');
    });

    test('summary returns full description when single-line', () {
      final s = _spec(description: 'Only one line.');
      expect(s.summary, 'Only one line.');
    });

    test('summary returns empty string for empty description', () {
      final s = _spec(description: '');
      expect(s.summary, '');
    });

    test('toListJson shape — no properties or examples', () {
      final s = _spec(
        type: 'box',
        category: 'layout',
        source: WidgetSource.standard,
      );
      final j = s.toListJson();
      expect(j['type'], 'box');
      expect(j['category'], 'layout');
      expect(j['source'], 'standard');
      expect(j.containsKey('properties'), isFalse);
      expect(j.containsKey('examples'), isFalse);
      expect(j['summary'], isA<String>());
    });

    test('toSchemaJson without examples omits examples key', () {
      final p = WidgetPropSpec(key: 'label', type: 'string', description: '');
      final s = _spec(props: <WidgetPropSpec>[p]);
      final j = s.toSchemaJson(withExamples: false);
      expect(j['properties'], isA<List>());
      expect((j['properties'] as List), hasLength(1));
      expect(j.containsKey('examples'), isFalse);
    });

    test('toSchemaJson with examples includes examples list', () {
      final ex = WidgetExampleSpec(name: 'e1', dsl: '{}');
      final s = _spec(examples: <WidgetExampleSpec>[ex]);
      final j = s.toSchemaJson(withExamples: true);
      expect(j['examples'], isA<List>());
      expect((j['examples'] as List), hasLength(1));
    });

    test('toSchemaJson includes profile and since when provided', () {
      final s = WidgetSpec(
        type: 'markdown',
        category: 'atom',
        source: WidgetSource.standard,
        description: 'Renders markdown.',
        profile: 'Core',
        since: 'v1.3',
      );
      final j = s.toSchemaJson();
      expect(j['profile'], 'Core');
      expect(j['since'], 'v1.3');
    });

    test('toSchemaJson omits profile and since when null', () {
      final s = _spec();
      final j = s.toSchemaJson();
      expect(j.containsKey('profile'), isFalse);
      expect(j.containsKey('since'), isFalse);
    });
  });
}
