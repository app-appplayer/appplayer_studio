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

  group(r'composed primitives ($ref)', () {
    // A `$ref` to another primitive used to be dropped, which made the
    // composed type STRICTER than the spec rather than merely unmodelled:
    // losing the referenced object form left one form behind, so ITS
    // `required` became enforceable. That is how `box.padding: {all: 8}` — a
    // spelling accepted since 1.4 — started failing authoring while it kept
    // rendering fine.
    void writeComposedSpec() {
      final specDir = p.join(tmp.path, 'mcp_ui_dsl', 'spec', kDslSpecVersion);
      File(p.join(specDir, 'configs', '_primitive', 'Inset.yaml'))
          .writeAsStringSync(r'''
name: Inset
description: probe inset
definition:
  {
    "anyOf": [
      { "type": "number" },
      {
        "type": "object",
        "properties": { "value": { "type": "number" } },
        "required": ["value"]
      },
      { "type": "object", "properties": { "all": { "type": "number" } } }
    ]
  }
''');
      File(p.join(specDir, 'configs', '_primitive', 'Spacing.yaml'))
          .writeAsStringSync(r'''
name: Spacing
description: probe spacing
definition:
  {
    "anyOf": [
      { "type": "string" },
      {
        "type": "object",
        "properties": { "token": { "type": "string" } },
        "required": ["token"]
      },
      { "$ref": "#/$defs/Inset" }
    ]
  }
''');
      File(p.join(specDir, 'widgets', 'test', 'probe.yaml'))
          .writeAsStringSync('''
type: probe
category: test
description: probe widget
properties:
  pad:
    type: "Spacing"
    description: "Composed inset."
  edge:
    type: "Inset"
    description: "Plain inset."
''');
    }

    test('r1: a referenced object form is honoured by the composed type',
        () async {
      writeComposedSpec();
      // `{all: 8}` satisfies Inset's second object form. Before the fix this
      // was rejected for missing `token` — a key only the OTHER form asks for.
      expect(await ok({'type': 'probe', 'pad': {'all': 8}}), isTrue);
      expect(await ok({'type': 'probe', 'pad': {'value': 8}}), isTrue);
    });

    test('r2: the composed type keeps its own branches too', () async {
      writeComposedSpec();
      expect(await ok({'type': 'probe', 'pad': 'md'}), isTrue);
      expect(await ok({'type': 'probe', 'pad': {'token': 'md'}}), isTrue);
      // The number branch arrives through the ref, not from Spacing itself.
      expect(await ok({'type': 'probe', 'pad': 8}), isTrue);
    });

    test('r3: the referenced primitive still enforces where declared alone',
        () async {
      writeComposedSpec();
      // Widening the composed type must not switch the plain one off — without
      // this, "everything passes" would read the same as the fix working.
      expect(await code({'type': 'probe', 'edge': 'hello world'}),
          'primitiveOutOfRange');
    });

    test('r5: a ref is the ONLY source of the object form', () async {
      // Spacing has an object branch of its own, so it cannot tell whether the
      // ref contributed one. This type has none: if the ref stops carrying the
      // object form across, `{all: 8}` has nothing left to satisfy.
      final specDir = p.join(tmp.path, 'mcp_ui_dsl', 'spec', kDslSpecVersion);
      File(p.join(specDir, 'configs', '_primitive', 'Inset.yaml'))
          .writeAsStringSync(r'''
name: Inset
description: probe inset
definition:
  {
    "anyOf": [
      { "type": "object", "properties": { "all": { "type": "number" } } }
    ]
  }
''');
      File(p.join(specDir, 'configs', '_primitive', 'Wrapped.yaml'))
          .writeAsStringSync(r'''
name: Wrapped
description: probe wrapper with no object form of its own
definition:
  {
    "anyOf": [
      { "enum": ["none"] },
      { "$ref": "#/$defs/Inset" }
    ]
  }
''');
      File(p.join(specDir, 'widgets', 'test', 'probe.yaml'))
          .writeAsStringSync('''
type: probe
category: test
description: probe widget
properties:
  gap:
    type: "Wrapped"
    description: "Wrapper whose object form comes only from the ref."
''');
      expect(await ok({'type': 'probe', 'gap': {'all': 8}}), isTrue);
      expect(await ok({'type': 'probe', 'gap': 'none'}), isTrue);
      expect(await code({'type': 'probe', 'gap': 'nope'}),
          'primitiveOutOfRange');
    });

    test('r6: a ref carries the enum/pattern that does the rejecting',
        () async {
      // The composed type declares nothing of its own, so every verdict here
      // is the ref's. If the ref stops contributing, the type has no modelled
      // branch left and goes PERMISSIVE — the failure mode is silent
      // acceptance, which is why this asserts a rejection rather than a pass.
      final specDir = p.join(tmp.path, 'mcp_ui_dsl', 'spec', kDslSpecVersion);
      File(p.join(specDir, 'configs', '_primitive', 'Alias.yaml'))
          .writeAsStringSync(r'''
name: Alias
description: probe alias with no branches of its own
definition:
  { "anyOf": [ { "$ref": "#/$defs/Tint" } ] }
''');
      File(p.join(specDir, 'widgets', 'test', 'probe.yaml'))
          .writeAsStringSync('''
type: probe
category: test
description: probe widget
properties:
  shade:
    type: "Alias"
    description: "Alias of Tint."
''');
      expect(await ok({'type': 'probe', 'shade': 'primary'}), isTrue,
          reason: "the ref's enum did not come across");
      expect(await ok({'type': 'probe', 'shade': '#aabbcc'}), isTrue,
          reason: "the ref's pattern did not come across");
      expect(await code({'type': 'probe', 'shade': 'nope'}),
          'primitiveOutOfRange');
    });

    test('r4: a self-referential primitive does not hang the loader', () async {
      final specDir = p.join(tmp.path, 'mcp_ui_dsl', 'spec', kDslSpecVersion);
      File(p.join(specDir, 'configs', '_primitive', 'Loop.yaml'))
          .writeAsStringSync(r'''
name: Loop
description: probe cycle
definition:
  { "anyOf": [ { "type": "number" }, { "$ref": "#/$defs/Loop" } ] }
''');
      File(p.join(specDir, 'widgets', 'test', 'probe.yaml'))
          .writeAsStringSync('''
type: probe
category: test
description: probe widget
properties:
  spin:
    type: "Loop"
    description: "Cyclic primitive."
''');
      expect(await ok({'type': 'probe', 'spin': 4}), isTrue);
    });
  });
}
