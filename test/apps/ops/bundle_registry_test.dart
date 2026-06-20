/// BundleRegistry — unit tests for all unit-testable paths.
///
/// BundleRegistry operates purely on the file system (no KvStoragePort, no
/// KnowledgeSystem) and is fully unit-testable with injected temp directories.
///
/// Scenarios:
///   b1  list — returns empty when rootDir does not exist
///   b2  list — returns empty when rootDir has no sub-dirs with manifest.yaml
///   b3  list — loads one bundle correctly (all fields)
///   b4  list — loads multiple bundles sorted by id
///   b5  list — skips dirs without manifest.yaml (no crash)
///   b6  list — skips dirs whose manifest.yaml is malformed YAML (no crash)
///   b7  get — returns bundle by id, null for unknown
///   b8  reload — picks up new bundles after re-drop
///   b9  list filterType='project' — returns only bundles targeting project
///   b10 list filterType='org' — returns only bundles targeting org
///   b11 list filterType='personal' — returns only bundles targeting personal
///   b12 Bundle.supports — 'any' matches all WorkspaceType values
///   b13 Bundle._fromYaml — capabilities / dependencies lists preserved
///   b14 Bundle._fromYaml — contents map preserved (YamlMap form)
///   b15 Bundle._fromYaml — name / version defaults when omitted
///   b16 Bundle._fromYaml — description / provider / author defaults
///   b17 BundleRegistry list — caches result (second call does not re-read disk)
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/registries/bundle_registry.dart';
import 'package:appplayer_studio/src/apps/ops/registries/workspace_registry.dart'
    show WorkspaceType;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Create a bundle directory under [root] with the given manifest YAML.
Future<Directory> _makeBundle(
  Directory root,
  String dirName,
  String manifestYaml,
) async {
  final dir = Directory('${root.path}/$dirName');
  await dir.create(recursive: true);
  await File('${dir.path}/manifest.yaml').writeAsString(manifestYaml);
  return dir;
}

/// Minimal valid manifest YAML for a given [id].
String _minimalManifest(String id) => '''
id: $id
name: Bundle ${id.toUpperCase()}
version: "1.0.0"
type: application
targetWorkspaceType: any
''';

String _typedManifest(String id, String targetType) => '''
id: $id
name: $id Bundle
version: "0.1.0"
targetWorkspaceType: $targetType
''';

void main() {
  group('BundleRegistry — list', () {
    // --- b1: rootDir does not exist ---
    test('b1 list returns empty list when rootDir does not exist', () async {
      final reg = BundleRegistry(rootDir: '/tmp/__nonexistent_bundle_reg_b1__');
      final list = await reg.list();
      expect(list, isEmpty);
    });

    // --- b2: rootDir exists but no manifest dirs ---
    test(
      'b2 list returns empty list when no sub-dirs have manifest.yaml',
      () async {
        final tmp = await Directory.systemTemp.createTemp('bundle_b2_');
        addTearDown(() async {
          if (await tmp.exists()) await tmp.delete(recursive: true);
        });
        // Create an empty sub-dir (no manifest.yaml).
        await Directory('${tmp.path}/empty_dir').create(recursive: true);

        final reg = BundleRegistry(rootDir: tmp.path);
        final list = await reg.list();
        expect(list, isEmpty);
      },
    );

    // --- b3: loads one bundle correctly ---
    test('b3 list loads one bundle with all fields correctly', () async {
      final tmp = await Directory.systemTemp.createTemp('bundle_b3_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      await _makeBundle(tmp, 'alpha_bundle', '''
id: alpha
name: Alpha Bundle
version: "2.1.0"
type: application
description: "The alpha app bundle"
provider: acme
author: alice
capabilities:
  - cap_a
  - cap_b
dependencies:
  - dep_x
targetWorkspaceType: project
contents:
  ui: ./ui
  skills: ./skills
''');

      final reg = BundleRegistry(rootDir: tmp.path);
      final list = await reg.list();
      expect(list.length, 1);

      final b = list.first;
      expect(b.id, 'alpha');
      expect(b.name, 'Alpha Bundle');
      expect(b.version, '2.1.0');
      expect(b.type, 'application');
      expect(b.description, 'The alpha app bundle');
      expect(b.provider, 'acme');
      expect(b.author, 'alice');
      expect(b.capabilities, containsAll(['cap_a', 'cap_b']));
      expect(b.dependencies, containsAll(['dep_x']));
      expect(b.targetWorkspaceType, 'project');
      expect(b.contents['ui'], './ui');
      expect(b.contents['skills'], './skills');
      expect(b.path, isNotEmpty);
    });

    // --- b4: loads multiple bundles sorted by id ---
    test('b4 list loads multiple bundles sorted by id', () async {
      final tmp = await Directory.systemTemp.createTemp('bundle_b4_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      await _makeBundle(tmp, 'zzz_dir', _minimalManifest('zzz'));
      await _makeBundle(tmp, 'aaa_dir', _minimalManifest('aaa'));
      await _makeBundle(tmp, 'mmm_dir', _minimalManifest('mmm'));

      final reg = BundleRegistry(rootDir: tmp.path);
      final list = await reg.list();
      expect(list.length, 3);
      final ids = list.map((b) => b.id).toList();
      expect(ids, containsAllInOrder(['aaa', 'mmm', 'zzz']));
    });

    // --- b5: skips dirs without manifest.yaml ---
    test('b5 list skips sub-dirs without manifest.yaml', () async {
      final tmp = await Directory.systemTemp.createTemp('bundle_b5_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      await _makeBundle(tmp, 'valid_dir', _minimalManifest('valid'));
      // A dir without manifest.yaml.
      await Directory('${tmp.path}/no_manifest').create(recursive: true);

      final reg = BundleRegistry(rootDir: tmp.path);
      final list = await reg.list();
      expect(list.length, 1);
      expect(list.first.id, 'valid');
    });

    // --- b6: malformed YAML does not crash ---
    test(
      'b6 list skips bundles with malformed manifest.yaml without crashing',
      () async {
        final tmp = await Directory.systemTemp.createTemp('bundle_b6_');
        addTearDown(() async {
          if (await tmp.exists()) await tmp.delete(recursive: true);
        });

        await _makeBundle(tmp, 'good', _minimalManifest('good_bundle'));
        // Malformed YAML (missing `id:` key entirely — fromYaml will throw on cast).
        final badDir = Directory('${tmp.path}/bad');
        await badDir.create(recursive: true);
        await File(
          '${badDir.path}/manifest.yaml',
        ).writeAsString('- not: a map');

        final reg = BundleRegistry(rootDir: tmp.path);
        final list = await reg.list();
        // Only the good bundle should be present.
        expect(list.length, 1);
        expect(list.first.id, 'good_bundle');
      },
    );
  });

  group('BundleRegistry — get', () {
    // --- b7: get by id ---
    test('b7 get returns bundle by id, null for unknown', () async {
      final tmp = await Directory.systemTemp.createTemp('bundle_b7_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      await _makeBundle(tmp, 'b7_dir', _minimalManifest('find_me'));
      final reg = BundleRegistry(rootDir: tmp.path);

      final found = await reg.get('find_me');
      expect(found, isNotNull);
      expect(found!.id, 'find_me');

      final missing = await reg.get('nonexistent_id');
      expect(missing, isNull);
    });
  });

  group('BundleRegistry — reload', () {
    // --- b8: reload picks up new bundles ---
    test('b8 reload picks up new bundles dropped after initial load', () async {
      final tmp = await Directory.systemTemp.createTemp('bundle_b8_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      await _makeBundle(tmp, 'orig', _minimalManifest('original'));
      final reg = BundleRegistry(rootDir: tmp.path);

      // Initial load.
      var list = await reg.list();
      expect(list.length, 1);

      // Drop a new bundle on disk.
      await _makeBundle(tmp, 'new_bundle', _minimalManifest('new_bundle'));

      // Without reload the cache is still 1.
      list = await reg.list();
      expect(list.length, 1);

      // After reload it should see 2.
      await reg.reload();
      list = await reg.list();
      expect(list.length, 2);
      expect(
        list.map((b) => b.id).toSet(),
        containsAll(['original', 'new_bundle']),
      );
    });
  });

  group('BundleRegistry — filterType', () {
    late Directory tmp;
    late BundleRegistry reg;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('bundle_filter_');
      await _makeBundle(
        tmp,
        'proj_b',
        _typedManifest('proj_bundle', 'project'),
      );
      await _makeBundle(tmp, 'org_b', _typedManifest('org_bundle', 'org'));
      await _makeBundle(
        tmp,
        'pers_b',
        _typedManifest('pers_bundle', 'personal'),
      );
      await _makeBundle(tmp, 'any_b', _typedManifest('any_bundle', 'any'));
      reg = BundleRegistry(rootDir: tmp.path);
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    // --- b9: filterType project ---
    test(
      'b9 list filterType=project returns project and any bundles',
      () async {
        final list = await reg.list(filterType: WorkspaceType.project);
        final ids = list.map((b) => b.id).toSet();
        expect(ids, contains('proj_bundle'));
        expect(ids, contains('any_bundle'));
        expect(ids, isNot(contains('org_bundle')));
        expect(ids, isNot(contains('pers_bundle')));
      },
    );

    // --- b10: filterType org ---
    test('b10 list filterType=org returns org and any bundles', () async {
      final list = await reg.list(filterType: WorkspaceType.org);
      final ids = list.map((b) => b.id).toSet();
      expect(ids, contains('org_bundle'));
      expect(ids, contains('any_bundle'));
      expect(ids, isNot(contains('proj_bundle')));
    });

    // --- b11: filterType personal ---
    test(
      'b11 list filterType=personal returns personal and any bundles',
      () async {
        final list = await reg.list(filterType: WorkspaceType.personal);
        final ids = list.map((b) => b.id).toSet();
        expect(ids, contains('pers_bundle'));
        expect(ids, contains('any_bundle'));
        expect(ids, isNot(contains('proj_bundle')));
      },
    );
  });

  group('Bundle model', () {
    // --- b12: supports 'any' ---
    test(
      'b12 Bundle.supports returns true for all types when targetType is any',
      () async {
        final tmp = await Directory.systemTemp.createTemp('bundle_b12_');
        addTearDown(() async {
          if (await tmp.exists()) await tmp.delete(recursive: true);
        });

        await _makeBundle(tmp, 'any_b', _typedManifest('any_b', 'any'));
        final reg = BundleRegistry(rootDir: tmp.path);
        final bundle = (await reg.list()).first;

        expect(bundle.supports(WorkspaceType.project), isTrue);
        expect(bundle.supports(WorkspaceType.org), isTrue);
        expect(bundle.supports(WorkspaceType.personal), isTrue);
      },
    );

    // --- b13: capabilities / dependencies ---
    test('b13 capabilities and dependencies lists are preserved', () async {
      final tmp = await Directory.systemTemp.createTemp('bundle_b13_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      await _makeBundle(tmp, 'cap_b', '''
id: cap_test
capabilities:
  - llm.complete
  - browser.navigate
dependencies:
  - knowledge_base_v2
targetWorkspaceType: any
''');
      final reg = BundleRegistry(rootDir: tmp.path);
      final b = (await reg.list()).first;
      expect(b.capabilities, containsAll(['llm.complete', 'browser.navigate']));
      expect(b.dependencies, contains('knowledge_base_v2'));
    });

    // --- b14: contents map ---
    test('b14 contents map is preserved from YamlMap form', () async {
      final tmp = await Directory.systemTemp.createTemp('bundle_b14_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      await _makeBundle(tmp, 'cont_b', '''
id: contents_test
targetWorkspaceType: any
contents:
  ui: ./ui
  agents: ./agents
  knowledge: ./kb
''');
      final reg = BundleRegistry(rootDir: tmp.path);
      final b = (await reg.list()).first;
      expect(b.contents['ui'], './ui');
      expect(b.contents['agents'], './agents');
      expect(b.contents['knowledge'], './kb');
    });

    // --- b15: name / version defaults ---
    test(
      'b15 name defaults to id and version defaults to empty string',
      () async {
        final tmp = await Directory.systemTemp.createTemp('bundle_b15_');
        addTearDown(() async {
          if (await tmp.exists()) await tmp.delete(recursive: true);
        });

        await _makeBundle(
          tmp,
          'min_b',
          'id: minimal_id\ntargetWorkspaceType: any\n',
        );
        final reg = BundleRegistry(rootDir: tmp.path);
        final b = (await reg.list()).first;
        expect(b.name, 'minimal_id'); // defaults to id
        expect(b.version, '');
      },
    );

    // --- b16: description / provider / author defaults ---
    test('b16 description/provider/author default to empty string', () async {
      final tmp = await Directory.systemTemp.createTemp('bundle_b16_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      await _makeBundle(
        tmp,
        'empty_b',
        'id: empty_fields\ntargetWorkspaceType: any\n',
      );
      final reg = BundleRegistry(rootDir: tmp.path);
      final b = (await reg.list()).first;
      expect(b.description, '');
      expect(b.provider, '');
      expect(b.author, '');
    });
  });

  group('BundleRegistry — cache', () {
    // --- b17: second call does not re-read disk ---
    test(
      'b17 list is cached — second call returns same instance list',
      () async {
        final tmp = await Directory.systemTemp.createTemp('bundle_b17_');
        addTearDown(() async {
          if (await tmp.exists()) await tmp.delete(recursive: true);
        });

        await _makeBundle(tmp, 'cached_b', _minimalManifest('cached'));
        final reg = BundleRegistry(rootDir: tmp.path);

        final first = await reg.list();
        expect(first.length, 1);

        // Drop a new bundle (should NOT be visible without reload).
        await _makeBundle(tmp, 'new_b', _minimalManifest('new_cached'));

        final second = await reg.list();
        // Still 1 — loaded flag prevents re-scan.
        expect(second.length, 1);
      },
    );
  });
}
