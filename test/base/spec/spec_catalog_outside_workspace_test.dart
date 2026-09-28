// Every schema kind the catalog lists must be readable when the studio
// runs outside the makemind workspace (installed app, cwd `/`): the
// hand-written kinds fall back to the embedded copies and the widget
// union comes from the runtime's generated constant.

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/src/base/spec/spec_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory outside;

  setUp(() => outside = Directory.systemTemp.createTempSync('spec_cat_'));
  tearDown(() => outside.deleteSync(recursive: true));

  test('no workspace is found from a temp directory', () async {
    expect(await SpecCatalog().resolveRepoRoot(outside.path), isNull);
  });

  for (final kind in SchemaKind.values) {
    test('${kind.name} schema text is served outside the workspace', () async {
      final raw = await SpecCatalog().readSchemaText(
        kind,
        anchor: outside.path,
      );
      final decoded = jsonDecode(raw);
      expect(decoded, isA<Map<String, dynamic>>());
    });
  }
}
