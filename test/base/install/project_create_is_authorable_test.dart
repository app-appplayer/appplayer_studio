/// A created project must be authorable by the very next call.
///
/// `studio.project.create` laid out the folders and left the bundle without a
/// manifest, so `studio.builder.writeUI` — the tool a caller reaches for
/// immediately after — refused it. Worse, the refusal arrived AFTER the page
/// had been written: `ok:false` with `ui/app.json` already on disk, which reads
/// to any caller as "nothing happened".
///
/// Both halves are pinned here because either one alone still leaves the
/// generate→author path broken.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/src/base/install/project_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('proj_create_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('the created bundle carries a loadable manifest', () async {
    final r = await createProjectFolder(name: 'probe', parent: tmp.path);
    expect(r['ok'], isTrue);

    final manifest = File(p.join(r['bundlePath'] as String, 'manifest.json'));
    expect(manifest.existsSync(), isTrue,
        reason: 'the next mutator loads this file and refuses without it');

    final doc = jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
    // The loader reports `Missing field "manifest"` on a bundle whose top level
    // has no manifest block — an id/name/version alone at the root is not it.
    expect(doc['manifest'], isA<Map<String, dynamic>>());
    final m = doc['manifest'] as Map<String, dynamic>;
    expect(m['id'], 'probe.project');
    expect(m['name'], 'probe');
    expect(m['version'], isNotNull);
    expect(m['type'], isNotNull);
  });

  test('a caller-supplied manifest still wins', () async {
    final r = await createProjectFolder(
      name: 'probe',
      parent: tmp.path,
      initialFiles: <Map<String, dynamic>>[
        <String, dynamic>{
          'path': p.join('probe.mbd', 'manifest.json'),
          'content': <String, dynamic>{
            'schemaVersion': '1.0.0',
            'manifest': <String, dynamic>{
              'id': 'domain.custom',
              'name': 'custom',
              'version': '9.9.9',
              'type': 'library',
            },
          },
        },
      ],
    );
    expect(r['ok'], isTrue);

    final doc = jsonDecode(
      File(p.join(r['bundlePath'] as String, 'manifest.json'))
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    // Domain wrappers seed their own bundle kind through `initialFiles`; the
    // seed must not overwrite them, or every wrapper silently becomes an
    // `application` named after its folder.
    expect((doc['manifest'] as Map)['id'], 'domain.custom');
    expect((doc['manifest'] as Map)['type'], 'library');
  });

  test('the seed is inside the bundle, not the project root', () async {
    final r = await createProjectFolder(name: 'probe', parent: tmp.path);
    expect(
      File(p.join(r['projectPath'] as String, 'manifest.json')).existsSync(),
      isFalse,
      reason: 'a manifest at the project root is not part of the bundle',
    );
  });
}
