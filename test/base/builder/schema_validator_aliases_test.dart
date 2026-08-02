// Two ways the authoring check disagreed with the registry it validates
// against, both found by driving the real surface after the 1.4 registry
// started declaring what it had always meant:
//
//  - §17.3.2 registers alternate spellings (`child` for `dragTarget.builder`,
//    `content` for `markdown.text`). The check only knew the canonical name,
//    so a document the runtime renders was rejected — and for a REQUIRED
//    property it was rejected as "missing" while the value sat there under
//    its other name.
//  - The registry declares element shapes as flattened paths
//    (`columns[].key`, 21 of them across 1.4). Those are not keys on the node.
//    Treating them as node keys made `dataTable` unauthorable: no document can
//    carry a property literally named `columns[].key`.
//
// The yaml is written to a temp specs root so the loader is exercised too —
// the alias only reaches the checker if the loader carries it across.

import 'dart:io';

import 'package:appplayer_studio/src/base/builder/builder_catalog_service.dart';
import 'package:appplayer_studio/src/base/builder/dsl_spec_loader.dart';
import 'package:appplayer_studio/src/base/builder/schema_validator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late SchemaValidator validator;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('alias_spec_');
    final dir = Directory(
      p.join(tmp.path, 'mcp_ui_dsl', 'spec', kDslSpecVersion, 'widgets', 'test'),
    )..createSync(recursive: true);
    File(p.join(dir.path, 'probe.yaml')).writeAsStringSync('''
type: probe
category: test
description: probe widget
properties:
  builder:
    type: "Widget"
    required: true
    description: "Drop surface."
    aliases:
      - child
  text:
    type: "string"
    description: "Body."
    aliases:
      - content
''');
    File(p.join(dir.path, 'probeTable.yaml')).writeAsStringSync('''
type: probeTable
category: test
description: probe table
properties:
  columns:
    type: "array<Column>"
    required: true
    description: "Column definitions"
  columns[].key:
    type: "string"
    required: true
    description: "Row field key"
''');
    validator = SchemaValidator(BuilderCatalogService(
      dsl: DslSpecLoader(specsRoot: tmp.path),
    ));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('a1: a required property is satisfied by its registered alias',
      () async {
    final canonical = await validator.validateNode(<String, dynamic>{
      'type': 'probe',
      'builder': <String, dynamic>{'type': 'text'},
    });
    expect(canonical.ok, isTrue, reason: '${canonical.rejection}');

    final aliased = await validator.validateNode(<String, dynamic>{
      'type': 'probe',
      'child': <String, dynamic>{'type': 'text'},
    });
    expect(aliased.ok, isTrue,
        reason: 'the registry declares `child` as a spelling of `builder`: '
            '${aliased.rejection}');
  });

  test('a2: still required when no spelling is present', () async {
    final r = await validator.validateNode(<String, dynamic>{'type': 'probe'});
    expect(r.ok, isFalse);
    expect(r.rejection?['code'], 'missingRequired');
  });

  test('a3: a non-tree alias is not reported as an extra property', () async {
    final r = await validator.validateNode(<String, dynamic>{
      'type': 'probe',
      'builder': <String, dynamic>{'type': 'text'},
      'content': 'hi',
    });
    expect(r.ok, isTrue, reason: '${r.rejection}');
  });

  test('a4: an element-path declaration is not a key on the node', () async {
    final r = await validator.validateNode(<String, dynamic>{
      'type': 'probeTable',
      'columns': <Object>[
        <String, dynamic>{'key': 'a', 'label': 'A'},
      ],
    });
    expect(r.ok, isTrue,
        reason: 'no node can carry a property named `columns[].key`: '
            '${r.rejection}');
  });
}
