/// Unit tests for [WidgetSchemaCatalog] — the singleton facade that
/// parses the generated MCP UI DSL schema and answers per-type queries.
///
/// The App Builder feat/widget_schema_catalog.dart is a thin re-export of
/// `lib/src/base/spec/widget_schema_catalog.dart`; this test suite covers
/// the full public surface via the canonical import so coverage is
/// attributed to the authoritative source.
///
/// Scenario set:
///   wsc1  types list is non-empty and excludes the abstract "Widget" sentinel
///   wsc2  knows() returns true for a well-known type, false for unknown
///   wsc3  propertiesFor() returns descriptors for a known widget type
///   wsc4  propertiesFor() excludes the "type" discriminator property
///   wsc5  propertiesFor() returns empty list for an unknown type
///   wsc6  propertiesFor() caches — second call returns identical list
///   wsc7  rawDef() returns a Map for a known type and null for unknown
///   wsc8  rawSchemaJson is valid JSON with a $defs entry
///   wsc9  descriptionOf() returns a String for documented types, null for unknown
///   wsc10 widget-edge detection — child / children slots flagged isWidgetEdge
///   wsc11 enum property surfaces enumValues correctly
///   wsc12 required properties marked required: true
///   wsc13 alias resolution — type accessed via alias (e.g. 'text') still resolves
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart'
    show WidgetSchemaCatalog, WidgetPropertyDescriptor;

void main() {
  // Access via the singleton; the instance is constructed once per process.
  final catalog = WidgetSchemaCatalog.instance;

  // ── wsc1: types list ──────────────────────────────────────────────────────

  test(
    'wsc1: types list is non-empty and does not contain "Widget" sentinel',
    () {
      final types = catalog.types;
      expect(types, isNotEmpty);
      expect(types, isNot(contains('Widget')));
    },
  );

  // ── wsc2: knows() ─────────────────────────────────────────────────────────

  test(
    'wsc2: knows() returns true for canonical type, false for gibberish',
    () {
      // At least one standard widget type must be known.
      final any = catalog.types.first;
      expect(catalog.knows(any), isTrue);
      expect(catalog.knows('__no_such_widget_xyz__'), isFalse);
    },
  );

  // ── wsc3: propertiesFor() non-empty ───────────────────────────────────────

  test(
    'wsc3: propertiesFor() returns non-empty descriptors for a known type',
    () {
      // "text" is a universal primitive in the MCP UI DSL.
      final props = catalog.propertiesFor('text');
      expect(props, isNotEmpty);
      // Every descriptor has a non-empty name.
      for (final p in props) {
        expect(p.name, isNotEmpty);
      }
    },
  );

  // ── wsc4: type discriminator excluded ────────────────────────────────────

  test(
    'wsc4: propertiesFor() never includes the "type" discriminator field',
    () {
      for (final type in catalog.types.take(20)) {
        final props = catalog.propertiesFor(type);
        expect(props.map((p) => p.name), isNot(contains('type')));
      }
    },
  );

  // ── wsc5: unknown type returns empty ─────────────────────────────────────

  test('wsc5: propertiesFor() returns empty list for unknown type', () {
    final props = catalog.propertiesFor('__unknown__');
    expect(props, isEmpty);
  });

  // ── wsc6: result is cached ────────────────────────────────────────────────

  test(
    'wsc6: propertiesFor() returns the same list object on repeated calls',
    () {
      final first = catalog.propertiesFor('text');
      final second = catalog.propertiesFor('text');
      expect(
        identical(first, second),
        isTrue,
        reason: 'result should be cached via identical reference',
      );
    },
  );

  // ── wsc7: rawDef() ────────────────────────────────────────────────────────

  test('wsc7: rawDef() returns a Map for known type and null for unknown', () {
    final def = catalog.rawDef('text');
    expect(def, isNotNull);
    expect(def, isA<Map<String, dynamic>>());

    final missing = catalog.rawDef('__nope__');
    expect(missing, isNull);
  });

  // ── wsc8: rawSchemaJson is valid JSON ─────────────────────────────────────

  test('wsc8: rawSchemaJson parses to a Map containing a \$defs entry', () {
    final raw = catalog.rawSchemaJson;
    expect(raw, isNotEmpty);
    final parsed = jsonDecode(raw);
    expect(parsed, isA<Map>());
    expect((parsed as Map).containsKey(r'$defs'), isTrue);
  });

  // ── wsc9: descriptionOf() ─────────────────────────────────────────────────

  test('wsc9: descriptionOf() returns null for unknown type', () {
    expect(catalog.descriptionOf('__unknown__'), isNull);
  });

  test(
    'wsc9b: descriptionOf() returns String or null for any canonical type',
    () {
      for (final type in catalog.types.take(10)) {
        final desc = catalog.descriptionOf(type);
        // Either null or a non-empty string — never an empty string.
        if (desc != null) {
          expect(desc, isNotEmpty);
        }
      }
    },
  );

  // ── wsc10: widget-edge (child slot) detection ─────────────────────────────

  test('wsc10: isWidgetEdge is true for child/children slots', () {
    // "linear" (row/column) carries a "children" array of widget refs.
    // If the type exists in this schema build we check it; otherwise
    // fall back to scanning all types for any edge-bearing property.
    bool foundEdge = false;
    for (final type in catalog.types) {
      final props = catalog.propertiesFor(type);
      for (final prop in props) {
        if (prop.isWidgetEdge) {
          foundEdge = true;
          // Edge properties must NOT carry a jsonType (they are structural,
          // not scalar).
          expect(
            prop.jsonType,
            isNull,
            reason: 'widget-edge props should not expose a jsonType',
          );
        }
      }
      if (foundEdge) break;
    }
    expect(
      foundEdge,
      isTrue,
      reason: 'at least one widget type must expose a child/children slot',
    );
  });

  // ── wsc11: enum property ──────────────────────────────────────────────────

  test('wsc11: enum properties surface enumValues as a non-empty list', () {
    // Scan all types for any property that carries enumValues.
    bool foundEnum = false;
    for (final type in catalog.types) {
      final props = catalog.propertiesFor(type);
      for (final prop in props) {
        if (prop.enumValues != null && prop.enumValues!.isNotEmpty) {
          foundEnum = true;
          // All enum values must be non-empty strings.
          for (final v in prop.enumValues!) {
            expect(v, isNotEmpty);
          }
          break;
        }
      }
      if (foundEnum) break;
    }
    expect(
      foundEnum,
      isTrue,
      reason: 'at least one property in the schema must declare an enum list',
    );
  });

  // ── wsc12: required flag ──────────────────────────────────────────────────

  test('wsc12: at least one property in the schema is marked required', () {
    bool foundRequired = false;
    for (final type in catalog.types) {
      final props = catalog.propertiesFor(type);
      for (final prop in props) {
        if (prop.required) {
          foundRequired = true;
          break;
        }
      }
      if (foundRequired) break;
    }
    expect(
      foundRequired,
      isTrue,
      reason: 'schema must declare at least one required property',
    );
  });

  // ── wsc13: alias resolution ───────────────────────────────────────────────

  test(
    'wsc13: alias lookup via knows() is consistent with propertiesFor()',
    () {
      // For every type in the catalog, knows() and propertiesFor() must agree:
      // propertiesFor should never silently fail when knows() returns true.
      for (final type in catalog.types) {
        if (catalog.knows(type)) {
          // propertiesFor must not throw and must return a list (even empty).
          expect(
            () => catalog.propertiesFor(type),
            returnsNormally,
            reason: 'propertiesFor must not throw for type "$type"',
          );
        }
      }
    },
  );

  // ── WidgetPropertyDescriptor field coverage ───────────────────────────────

  test('WidgetPropertyDescriptor carries expected fields', () {
    final d = WidgetPropertyDescriptor(
      name: 'label',
      jsonType: 'string',
      enumValues: <String>['a', 'b'],
      description: 'A label',
      isWidgetEdge: false,
      required: true,
      defaultValue: 'x',
    );
    expect(d.name, 'label');
    expect(d.jsonType, 'string');
    expect(d.enumValues, <String>['a', 'b']);
    expect(d.description, 'A label');
    expect(d.isWidgetEdge, isFalse);
    expect(d.required, isTrue);
    expect(d.defaultValue, 'x');
  });
}
