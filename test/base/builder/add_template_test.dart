/// Unit coverage for `BuilderUiWriteService.addTemplate` — the
/// template-register layer behind `studio.builder.lib.placeAsTemplate`.
///
/// Validates the documented branches:
///   1. Fresh register (no `templates` object yet) — creates the
///      object and adds the entry.
///   2. Add to existing `templates` — second entry coexists with the
///      first (N≥2 accumulation regression, memory
///      feedback_accumulation_test_gap).
///   3. Same name + same JSON → idempotent no-op (registered=false).
///   4. Same name + different JSON + force=false → FormatException
///      `already exists`.
///   5. Same name + different JSON + force=true → replace
///      (replaced=true).
///   6. dryRun → no disk write.
///   7. Non-Map root → FormatException.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart';

void main() {
  late Directory projectDir;
  late String mbdPath;
  late BuilderUiWriteService writer;

  setUp(() async {
    projectDir = await Directory.systemTemp.createTemp('add_tpl_test_');
    final mbdDir = Directory(p.join(projectDir.path, 'sample.mbd'));
    await mbdDir.create(recursive: true);
    mbdPath = mbdDir.path;
    final uiDir = Directory(p.join(mbdPath, 'ui'));
    await uiDir.create(recursive: true);
    writer = BuilderUiWriteService();
  });

  tearDown(() async {
    if (projectDir.existsSync()) {
      await projectDir.delete(recursive: true);
    }
  });

  Future<void> writeApp(Object root) async {
    final file = File(p.join(mbdPath, 'ui', 'app.json'));
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(root));
  }

  Future<Object?> readApp() async {
    final file = File(p.join(mbdPath, 'ui', 'app.json'));
    return jsonDecode(await file.readAsString());
  }

  // ── 1. Fresh register — no `templates` object yet ──
  test('fresh register — creates templates object + adds entry', () async {
    await writeApp(<String, Object?>{
      'type': 'application',
      'routes': <String, Object?>{},
    });
    final entry = <String, Object?>{
      'content': <String, Object?>{'type': 'text', 'text': '{{label}}'},
    };
    final r = await writer.addTemplate(
      mbdPath: mbdPath,
      name: 'badge',
      entry: entry,
    );
    expect(r['ok'], true);
    expect(r['registered'], true);
    expect(r['replaced'], false);

    final app = await readApp() as Map<String, Object?>;
    expect(app['templates'], isA<Map>());
    final templates = app['templates'] as Map;
    expect(templates['badge'], entry);
  });

  // ── 2. N≥2 accumulation — second entry coexists ──
  test('N≥2 accumulation — second register adds alongside the first', () async {
    await writeApp(<String, Object?>{
      'type': 'application',
      'routes': <String, Object?>{},
    });
    final first = <String, Object?>{
      'content': <String, Object?>{'type': 'box'},
    };
    final second = <String, Object?>{
      'content': <String, Object?>{'type': 'text', 'text': 'hi'},
    };
    await writer.addTemplate(mbdPath: mbdPath, name: 'card', entry: first);
    final r2 = await writer.addTemplate(
      mbdPath: mbdPath,
      name: 'label',
      entry: second,
    );

    expect(r2['registered'], true);
    expect(r2['replaced'], false);

    final app = await readApp() as Map<String, Object?>;
    final templates = app['templates'] as Map;
    expect(templates.keys, containsAll(<String>['card', 'label']));
    expect(templates['card'], first);
    expect(templates['label'], second);
  });

  // ── 3. Idempotent no-op for same JSON ──
  test('same name + same JSON → idempotent no-op', () async {
    await writeApp(<String, Object?>{
      'type': 'application',
      'routes': <String, Object?>{},
    });
    final entry = <String, Object?>{
      'content': <String, Object?>{'type': 'icon', 'icon': 'star'},
    };
    final r1 = await writer.addTemplate(
      mbdPath: mbdPath,
      name: 'star',
      entry: entry,
    );
    expect(r1['registered'], true);

    final r2 = await writer.addTemplate(
      mbdPath: mbdPath,
      name: 'star',
      // Same logical JSON — different Map instance.
      entry: <String, Object?>{
        'content': <String, Object?>{'type': 'icon', 'icon': 'star'},
      },
    );
    expect(r2['registered'], false);
    expect(r2['replaced'], false);
  });

  // ── 4. Reject on conflict without force ──
  test('same name + different JSON + force=false → FormatException', () async {
    await writeApp(<String, Object?>{
      'type': 'application',
      'routes': <String, Object?>{},
    });
    await writer.addTemplate(
      mbdPath: mbdPath,
      name: 'conflict',
      entry: <String, Object?>{
        'content': <String, Object?>{'type': 'box'},
      },
    );
    expect(
      () => writer.addTemplate(
        mbdPath: mbdPath,
        name: 'conflict',
        entry: <String, Object?>{
          'content': <String, Object?>{'type': 'text', 'text': 'x'},
        },
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('already exists'),
        ),
      ),
    );
  });

  // ── 5. Force replace ──
  test('same name + different JSON + force=true → replace', () async {
    await writeApp(<String, Object?>{
      'type': 'application',
      'routes': <String, Object?>{},
    });
    await writer.addTemplate(
      mbdPath: mbdPath,
      name: 'shape',
      entry: <String, Object?>{
        'content': <String, Object?>{'type': 'box'},
      },
    );
    final newer = <String, Object?>{
      'content': <String, Object?>{'type': 'text', 'text': 'updated'},
    };
    final r = await writer.addTemplate(
      mbdPath: mbdPath,
      name: 'shape',
      entry: newer,
      force: true,
    );
    expect(r['registered'], true);
    expect(r['replaced'], true);

    final app = await readApp() as Map<String, Object?>;
    final templates = app['templates'] as Map;
    expect(templates['shape'], newer);
  });

  // ── 6. dryRun must not touch disk ──
  test('dryRun=true → no disk write', () async {
    final initial = <String, Object?>{
      'type': 'application',
      'routes': <String, Object?>{},
    };
    await writeApp(initial);
    final r = await writer.addTemplate(
      mbdPath: mbdPath,
      name: 'preview',
      entry: <String, Object?>{
        'content': <String, Object?>{'type': 'box'},
      },
      dryRun: true,
    );
    expect(r['ok'], true);
    expect(r['dryRun'], true);

    // Disk unchanged — no `templates` key.
    final app = await readApp() as Map<String, Object?>;
    expect(app.containsKey('templates'), isFalse);
  });

  // ── 7. Non-Map root rejected ──
  test('non-Map root → FormatException', () async {
    // app.json with a list root (malformed but possible).
    final file = File(p.join(mbdPath, 'ui', 'app.json'));
    await file.writeAsString(jsonEncode(<Object>['oops']));
    expect(
      () => writer.addTemplate(
        mbdPath: mbdPath,
        name: 'x',
        entry: <String, Object?>{'content': <String, Object?>{}},
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Map root'),
        ),
      ),
    );
  });

  // ── 8. Existing templates preserved on register ──
  test('register preserves pre-existing templates entries', () async {
    await writeApp(<String, Object?>{
      'type': 'application',
      'routes': <String, Object?>{},
      'templates': <String, Object?>{
        'preExisting': <String, Object?>{
          'content': <String, Object?>{'type': 'box'},
        },
      },
    });
    await writer.addTemplate(
      mbdPath: mbdPath,
      name: 'added',
      entry: <String, Object?>{
        'content': <String, Object?>{'type': 'text', 'text': 'new'},
      },
    );
    final app = await readApp() as Map<String, Object?>;
    final templates = app['templates'] as Map;
    expect(templates.keys, containsAll(<String>['preExisting', 'added']));
  });
}
