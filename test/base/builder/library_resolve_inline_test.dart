/// Unit coverage for `BuilderLibraryService.resolveInline` — the
/// param-substitution layer behind `studio.builder.lib.placeInline`.
///
/// Validates the three documented substitution rules:
///   1. Whole-string `{{x}}` returns the param value as-is so
///      non-string params keep their type (numbers, maps, lists).
///   2. Embedded `{{x}}` inside a longer string is replaced via
///      `toString()`.
///   3. Unresolved placeholders collapse to an empty string and are
///      surfaced in the returned `warnings` list.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart';

void main() {
  late Directory projectDir;
  late String mbdPath;
  late BuilderLibraryService svc;

  setUp(() async {
    projectDir = await Directory.systemTemp.createTemp('lib_inline_test_');
    final mbdDir = Directory(p.join(projectDir.path, 'sample.mbd'));
    await mbdDir.create(recursive: true);
    mbdPath = mbdDir.path;
    svc = BuilderLibraryService();
  });

  tearDown(() async {
    if (projectDir.existsSync()) {
      await projectDir.delete(recursive: true);
    }
  });

  Future<void> seed(String id, Object tree) async {
    // Library sits at project root (parent of the .mbd), matching
    // production placement: <projectPath>/library/<id>.json.
    final dir = Directory(p.join(projectDir.path, 'library'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    final file = File(p.join(dir.path, '$id.json'));
    await file.writeAsString(jsonEncode(tree));
  }

  test('library sits at <projectPath>/library, not inside the .mbd', () async {
    await seed('marker', <String, Object?>{'type': 'box'});
    final libIn = Directory(p.join(mbdPath, 'library'));
    final libAt = Directory(p.join(projectDir.path, 'library'));
    expect(
      libIn.existsSync(),
      isFalse,
      reason: 'library must not be authored inside the .mbd',
    );
    expect(
      libAt.existsSync(),
      isTrue,
      reason: 'library should live at project root, parent of .mbd',
    );
    final ids = await svc.list(mbdPath);
    expect(ids, contains('marker'));
  });

  test('whole-string {{x}} keeps the param value type', () async {
    await seed('card', <String, Object?>{
      'type': 'box',
      'width': '{{width}}',
      'decoration': <String, Object?>{'color': '{{color}}'},
    });
    final r = await svc.resolveInline(mbdPath, 'card', <String, Object?>{
      'width': 168,
      'color': '#5FA8FF',
    });
    expect(r.warnings, isEmpty);
    expect(r.tree, isA<Map<String, Object?>>());
    final tree = r.tree as Map<String, Object?>;
    expect(tree['width'], 168);
    expect((tree['decoration'] as Map)['color'], '#5FA8FF');
  });

  test('embedded {{x}} is toString-replaced', () async {
    await seed('label', <String, Object?>{
      'type': 'text',
      'text': '{{idx}} - {{name}}',
    });
    final r = await svc.resolveInline(mbdPath, 'label', <String, Object?>{
      'idx': 3,
      'name': 'Components',
    });
    expect(r.warnings, isEmpty);
    expect((r.tree as Map)['text'], '3 - Components');
  });

  test('unresolved params collapse to empty + surface in warnings', () async {
    await seed('mix', <String, Object?>{
      'type': 'text',
      'text': '{{label}}',
      'misc': 'prefix-{{unknown}}-suffix',
    });
    final r = await svc.resolveInline(mbdPath, 'mix', const <String, Object?>{
      'label': 'OK',
    });
    expect((r.tree as Map)['text'], 'OK');
    expect((r.tree as Map)['misc'], 'prefix--suffix');
    expect(r.warnings, containsAll(<String>['unresolved param: unknown']));
  });

  test('rejects unknown id with FormatException', () async {
    expect(
      () => svc.resolveInline(mbdPath, 'missing', const {}),
      throwsA(isA<FormatException>()),
    );
  });

  test('walks lists and nested maps', () async {
    await seed('strip', <String, Object?>{
      'type': 'linear',
      'children': <Object?>[
        <String, Object?>{'type': 'text', 'text': '{{a}}'},
        <String, Object?>{'type': 'text', 'text': '{{b}}'},
      ],
    });
    final r = await svc.resolveInline(mbdPath, 'strip', const <String, Object?>{
      'a': 'one',
      'b': 'two',
    });
    final children = (r.tree as Map)['children'] as List;
    expect((children[0] as Map)['text'], 'one');
    expect((children[1] as Map)['text'], 'two');
  });
}
