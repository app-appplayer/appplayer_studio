// Two things the authoring checker did not consume from the spec, both of
// which let a document pass and then render nothing:
//
//  - **Primitives.** A slot typed `Color` accepted any string, so
//    `box {color: "notacolor"}` was reported as fine and the widget fell back
//    to its default. The contract is in `configs/_primitive/Color.yaml`; the
//    checker now reads it instead of carrying a copy.
//  - **Element-path declarations.** The registry declares `columns[].key` and
//    `options.legend.position` (21 of them in 1.4). The checker skipped every
//    one, so a `dataTable` row without its key and a legend position the spec
//    does not allow both passed.
//
// Fixtures are written to a temp specs root so the loaders are exercised end
// to end — a contract that only holds in a hand-built object is not the one
// the studio runs.

import 'dart:io';

import 'package:appplayer_studio/src/base/builder/builder_catalog_service.dart';
import 'package:appplayer_studio/src/base/builder/dsl_primitive_loader.dart';
import 'package:appplayer_studio/src/base/builder/dsl_spec_loader.dart';
import 'package:appplayer_studio/src/base/builder/schema_validator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late SchemaValidator validator;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('prim_nested_');
    final specDir = p.join(tmp.path, 'mcp_ui_dsl', 'spec', kDslSpecVersion);
    Directory(p.join(specDir, 'widgets', 'test')).createSync(recursive: true);
    Directory(p.join(specDir, 'configs', '_primitive'))
        .createSync(recursive: true);

    File(p.join(specDir, 'configs', '_primitive', 'Tint.yaml'))
        .writeAsStringSync('''
name: Tint
description: probe primitive
definition:
  {
    "oneOf": [
      { "type": "string", "pattern": "^#[0-9a-fA-F]{6}\$" },
      { "enum": ["primary", "secondary"] },
      { "\$ref": "#/\$defs/Binding" }
    ]
  }
''');
    File(p.join(specDir, 'widgets', 'test', 'probe.yaml')).writeAsStringSync('''
type: probe
category: test
description: probe widget
properties:
  tint:
    type: "Tint"
    description: "A tint."
  columns:
    type: "array<Column>"
    description: "Column definitions."
  columns[].key:
    type: "string"
    required: true
    description: "Row field key."
  options:
    type: "object"
    description: "Chart options."
  options.legend.position:
    type: "string"
    enum: ["top", "bottom"]
    description: "Legend placement."
''');

    validator = SchemaValidator(
      BuilderCatalogService(dsl: DslSpecLoader(specsRoot: tmp.path)),
      primitives: DslPrimitiveLoader(specsRoot: tmp.path),
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<bool> ok(Map<String, dynamic> node) async =>
      (await validator.validateNode(node)).ok;

  Future<String?> code(Map<String, dynamic> node) async =>
      (await validator.validateNode(node)).rejection?['code'] as String?;

  group('primitives', () {
    test('p1: every spelling the primitive declares is accepted', () async {
      expect(await ok({'type': 'probe', 'tint': '#a1b2c3'}), isTrue);
      expect(await ok({'type': 'probe', 'tint': 'primary'}), isTrue);
      expect(await ok({'type': 'probe', 'tint': '{{state.tint}}'}), isTrue);
    });

    test('p2: a value no branch accepts is rejected', () async {
      expect(await code({'type': 'probe', 'tint': 'notatint'}),
          'primitiveOutOfRange',
          reason: 'this used to pass and render the default silently');
    });
  });

  group('element-path declarations', () {
    test('n1: a required key inside array entries is enforced', () async {
      expect(
          await ok({
            'type': 'probe',
            'columns': [
              {'key': 'a'},
            ],
          }),
          isTrue);
      expect(
          await code({
            'type': 'probe',
            'columns': [
              {'label': 'A'},
            ],
          }),
          'missingRequired');
    });

    test('n2: a dotted path is walked and its enum enforced', () async {
      expect(
          await ok({
            'type': 'probe',
            'options': {
              'legend': {'position': 'bottom'},
            },
          }),
          isTrue);
      expect(
          await code({
            'type': 'probe',
            'options': {
              'legend': {'position': 'nowhere'},
            },
          }),
          'enumOutOfRange',
          reason: 'the declaration existed; nothing read it');
    });

    test('n3: an absent container is not an error', () async {
      expect(await ok({'type': 'probe'}), isTrue);
    });

    test('n4: a container of the wrong shape is reported', () async {
      expect(await code({'type': 'probe', 'columns': 'not-a-list'}),
          'propTypeMismatch');
    });
  });
}
