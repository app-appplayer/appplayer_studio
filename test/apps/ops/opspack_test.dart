/// Opspack — unit tests for all unit-testable paths.
///
/// `Opspack.exportWorkspace` / `importWorkspace` use real temp dirs and the
/// archive package (no boot). `previewBytes` uses the same. All pure static
/// helpers (_isSensitive, _isFacts, _suggestRenamed) are exercised via the
/// higher-level observable behaviour.
///
/// Scenarios:
///   op1  OpspackManifest — toJson / fromJson round-trip
///   op2  OpspackManifest.fromJson — default workspaceType 'unknown'
///   op3  OpspackManifest.fromJson — includeFacts defaults to false
///   op4  OpspackManifest.fromJson — contents defaults to []
///   op5  exportWorkspace — archive contains manifest.json + workspace/ files
///   op6  exportWorkspace — sensitive files are excluded (.key / .pem / secrets.yaml)
///   op7  exportWorkspace — auth/ subtree is excluded
///   op8  exportWorkspace — facts/ subtree excluded when includeFacts=false
///   op9  exportWorkspace — facts/ included when includeFacts=true
///   op10 previewBytes — returns manifest + file count
///   op11 previewBytes — rejects pack whose formatVersion > current
///   op12 importWorkspace — extracts workspace files into target dir
///   op13 importWorkspace — conflictRename adds -imported-N suffix on collision
///   op14 importWorkspace — conflictOverwrite replaces existing dir
///   op15 importWorkspace — conflictSkip returns original id on collision
///   op16 exportWorkspace throws when workspace dir not found
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/portability/opspack.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<File> _packDir(
  Directory wsDir,
  String wsId, {
  bool includeFacts = false,
}) async {
  final bundle = await Opspack.exportWorkspace(
    workspaceDir: wsDir,
    workspaceId: wsId,
    includeFacts: includeFacts,
  );
  final packFile = File(
    '${wsDir.path}/../${wsId.replaceAll('/', '_')}.opspack',
  );
  await packFile.writeAsBytes(bundle.bytes);
  return packFile;
}

/// Write a file relative to [root].
Future<void> _writeFile(String root, String rel, String content) async {
  final f = File('$root/$rel');
  await f.parent.create(recursive: true);
  await f.writeAsString(content);
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('opspack_test_');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  // ===========================================================================
  // OpspackManifest
  // ===========================================================================
  group('OpspackManifest', () {
    // op1
    test('op1 toJson / fromJson round-trip', () {
      final original = OpspackManifest(
        formatVersion: 1,
        sourceWorkspaceId: 'org/test',
        workspaceType: 'org',
        createdAt: DateTime.utc(2026, 6, 1, 12),
        includeFacts: true,
        contents: ['workspace.yaml', 'members/alice.yaml'],
      );
      final json = original.toJson();
      final restored = OpspackManifest.fromJson(json);
      expect(restored.formatVersion, 1);
      expect(restored.sourceWorkspaceId, 'org/test');
      expect(restored.workspaceType, 'org');
      expect(restored.includeFacts, true);
      expect(restored.contents, ['workspace.yaml', 'members/alice.yaml']);
    });

    // op2
    test('op2 fromJson defaults workspaceType to "unknown" when missing', () {
      final m = OpspackManifest.fromJson({
        'formatVersion': 1,
        'sourceWorkspaceId': 'org/x',
        'createdAt': '2026-01-01T00:00:00.000Z',
        'includeFacts': false,
        'contents': <String>[],
      });
      expect(m.workspaceType, 'unknown');
    });

    // op3
    test('op3 fromJson defaults includeFacts to false when missing', () {
      final m = OpspackManifest.fromJson({
        'formatVersion': 1,
        'sourceWorkspaceId': 'org/x',
        'createdAt': '2026-01-01T00:00:00.000Z',
        'contents': <String>[],
      });
      expect(m.includeFacts, false);
    });

    // op4
    test('op4 fromJson defaults contents to [] when missing', () {
      final m = OpspackManifest.fromJson({
        'formatVersion': 1,
        'sourceWorkspaceId': 'org/x',
        'createdAt': '2026-01-01T00:00:00.000Z',
      });
      expect(m.contents, isEmpty);
    });
  });

  // ===========================================================================
  // exportWorkspace
  // ===========================================================================
  group('Opspack.exportWorkspace', () {
    // op5
    test('op5 archive contains manifest.json and workspace/ files', () async {
      final wsDir = Directory('${tmp.path}/ws_op5');
      await wsDir.create(recursive: true);
      await _writeFile(wsDir.path, 'workspace.yaml', 'id: test');
      await _writeFile(wsDir.path, 'members/alice.yaml', 'id: alice');

      final bundle = await Opspack.exportWorkspace(
        workspaceDir: wsDir,
        workspaceId: 'test',
      );
      final archive = ZipDecoder().decodeBytes(bundle.bytes);
      final names = archive.map((e) => e.name).toSet();
      expect(names.contains('manifest.json'), isTrue);
      expect(names.contains('workspace/workspace.yaml'), isTrue);
      expect(names.contains('workspace/members/alice.yaml'), isTrue);
    });

    // op6
    test('op6 sensitive files are excluded', () async {
      final wsDir = Directory('${tmp.path}/ws_op6');
      await wsDir.create(recursive: true);
      await _writeFile(wsDir.path, 'workspace.yaml', 'id: test');
      await _writeFile(wsDir.path, 'secrets.yaml', 'apiKey: secret');
      await _writeFile(wsDir.path, 'my_key.pem', 'CERT');
      await _writeFile(wsDir.path, 'auth/cookie.json', '{}');
      await _writeFile(wsDir.path, 'private.key', 'KEY');

      final bundle = await Opspack.exportWorkspace(
        workspaceDir: wsDir,
        workspaceId: 'test_sens',
      );
      final archive = ZipDecoder().decodeBytes(bundle.bytes);
      final names = archive.map((e) => e.name).toSet();
      expect(names.contains('workspace/secrets.yaml'), isFalse);
      expect(names.contains('workspace/my_key.pem'), isFalse);
      expect(names.contains('workspace/auth/cookie.json'), isFalse);
      expect(names.contains('workspace/private.key'), isFalse);
      // Safe file should be included.
      expect(names.contains('workspace/workspace.yaml'), isTrue);
    });

    // op7
    test('op7 auth/ subtree excluded', () async {
      final wsDir = Directory('${tmp.path}/ws_op7');
      await wsDir.create(recursive: true);
      await _writeFile(wsDir.path, 'workspace.yaml', 'id: test');
      await _writeFile(wsDir.path, 'auth/profile.json', '{}');

      final bundle = await Opspack.exportWorkspace(
        workspaceDir: wsDir,
        workspaceId: 'auth_test',
      );
      final archive = ZipDecoder().decodeBytes(bundle.bytes);
      final names = archive.map((e) => e.name).toSet();
      expect(names.contains('workspace/auth/profile.json'), isFalse);
    });

    // op8
    test('op8 facts/ excluded when includeFacts=false', () async {
      final wsDir = Directory('${tmp.path}/ws_op8');
      await wsDir.create(recursive: true);
      await _writeFile(wsDir.path, 'workspace.yaml', 'id: test');
      await _writeFile(wsDir.path, 'facts/entry.json', '{}');

      final bundle = await Opspack.exportWorkspace(
        workspaceDir: wsDir,
        workspaceId: 'facts_excl',
        includeFacts: false,
      );
      final archive = ZipDecoder().decodeBytes(bundle.bytes);
      final names = archive.map((e) => e.name).toSet();
      expect(names.contains('workspace/facts/entry.json'), isFalse);
    });

    // op9
    test('op9 facts/ included when includeFacts=true', () async {
      final wsDir = Directory('${tmp.path}/ws_op9');
      await wsDir.create(recursive: true);
      await _writeFile(wsDir.path, 'workspace.yaml', 'id: test');
      await _writeFile(wsDir.path, 'facts/entry.json', '{}');

      final bundle = await Opspack.exportWorkspace(
        workspaceDir: wsDir,
        workspaceId: 'facts_incl',
        includeFacts: true,
      );
      final archive = ZipDecoder().decodeBytes(bundle.bytes);
      final names = archive.map((e) => e.name).toSet();
      expect(names.contains('workspace/facts/entry.json'), isTrue);
    });

    // op16
    test(
      'op16 exportWorkspace throws StateError when workspace dir not found',
      () async {
        final missing = Directory('${tmp.path}/does_not_exist');
        expect(
          () => Opspack.exportWorkspace(
            workspaceDir: missing,
            workspaceId: 'missing',
          ),
          throwsA(isA<StateError>()),
        );
      },
    );
  });

  // ===========================================================================
  // previewBytes
  // ===========================================================================
  group('Opspack.previewBytes', () {
    // op10
    test('op10 previewBytes returns manifest + fileCount', () async {
      final wsDir = Directory('${tmp.path}/ws_op10');
      await wsDir.create(recursive: true);
      await _writeFile(wsDir.path, 'workspace.yaml', 'id: test');
      await _writeFile(wsDir.path, 'members/bob.yaml', 'id: bob');

      final bundle = await Opspack.exportWorkspace(
        workspaceDir: wsDir,
        workspaceId: 'preview_test',
      );
      final preview = Opspack.previewBytes(bundle.bytes);
      expect(preview.manifest.sourceWorkspaceId, 'preview_test');
      expect(preview.fileCount, greaterThan(0));
      expect(preview.bytes, bundle.bytes.length);
    });

    // op11
    test('op11 previewBytes rejects formatVersion > current', () {
      // Build a minimal ZIP with manifest.json whose formatVersion is too new.
      final manifest = {
        'formatVersion': OpspackManifest.currentFormatVersion + 1,
        'sourceWorkspaceId': 'future',
        'workspaceType': 'org',
        'createdAt': '2030-01-01T00:00:00.000Z',
        'includeFacts': false,
        'contents': <String>[],
      };
      final archive = Archive();
      final bytes = utf8.encode(
        const JsonEncoder.withIndent('  ').convert(manifest),
      );
      archive.addFile(ArchiveFile('manifest.json', bytes.length, bytes));
      final raw = ZipEncoder().encode(archive)!;
      expect(() => Opspack.previewBytes(raw), throwsA(isA<StateError>()));
    });

    test('op11b previewBytes throws StateError when manifest.json missing', () {
      final archive = Archive();
      archive.addFile(
        ArchiveFile('unrelated.txt', 3, [104, 101, 121]),
      ); // 'hey'
      final raw = ZipEncoder().encode(archive)!;
      expect(() => Opspack.previewBytes(raw), throwsA(isA<StateError>()));
    });
  });

  // ===========================================================================
  // importWorkspace
  // ===========================================================================
  group('Opspack.importWorkspace', () {
    // op12
    test(
      'op12 importWorkspace extracts workspace files into target dir',
      () async {
        final wsDir = Directory('${tmp.path}/ws_op12');
        await wsDir.create(recursive: true);
        await _writeFile(wsDir.path, 'workspace.yaml', 'id: myws');
        await _writeFile(wsDir.path, 'members/alice.yaml', 'id: alice');

        final packFile = await _packDir(wsDir, 'myws');
        final wsRoot = Directory('${tmp.path}/import_root');
        await wsRoot.create(recursive: true);

        final targetId = await Opspack.importWorkspace(
          packFile: packFile,
          workspacesRoot: wsRoot,
        );
        expect(targetId, 'myws');
        expect(
          await File('${wsRoot.path}/myws/workspace.yaml').exists(),
          isTrue,
        );
        expect(
          await File('${wsRoot.path}/myws/members/alice.yaml').exists(),
          isTrue,
        );
      },
    );

    // op13
    test('op13 conflictRename adds -imported-N suffix on collision', () async {
      final wsDir = Directory('${tmp.path}/ws_op13');
      await wsDir.create(recursive: true);
      await _writeFile(wsDir.path, 'workspace.yaml', 'id: cws');

      final packFile = await _packDir(wsDir, 'cws');
      final wsRoot = Directory('${tmp.path}/import_rename');
      await wsRoot.create(recursive: true);
      // Pre-create the collision dir.
      await Directory('${wsRoot.path}/cws').create(recursive: true);

      final targetId = await Opspack.importWorkspace(
        packFile: packFile,
        workspacesRoot: wsRoot,
        conflictPolicy: Opspack.conflictRename,
      );
      // Should be cws-imported-2 (or higher) since cws exists.
      expect(targetId, isNot('cws'));
      expect(targetId, startsWith('cws-imported-'));
    });

    // op14
    test('op14 conflictOverwrite replaces existing dir', () async {
      final wsDir = Directory('${tmp.path}/ws_op14');
      await wsDir.create(recursive: true);
      await _writeFile(wsDir.path, 'workspace.yaml', 'id: ows');

      final packFile = await _packDir(wsDir, 'ows');
      final wsRoot = Directory('${tmp.path}/import_overwrite');
      await wsRoot.create(recursive: true);
      // Pre-create a collision dir with different content.
      await _writeFile('${wsRoot.path}/ows', 'old.yaml', 'old content');

      final targetId = await Opspack.importWorkspace(
        packFile: packFile,
        workspacesRoot: wsRoot,
        conflictPolicy: Opspack.conflictOverwrite,
      );
      expect(targetId, 'ows');
      // Old file should be gone (dir was deleted + re-created).
      expect(await File('${wsRoot.path}/ows/old.yaml').exists(), isFalse);
      expect(await File('${wsRoot.path}/ows/workspace.yaml').exists(), isTrue);
    });

    // op15
    test(
      'op15 conflictSkip returns original id without modifying existing dir',
      () async {
        final wsDir = Directory('${tmp.path}/ws_op15');
        await wsDir.create(recursive: true);
        await _writeFile(wsDir.path, 'workspace.yaml', 'id: sws');

        final packFile = await _packDir(wsDir, 'sws');
        final wsRoot = Directory('${tmp.path}/import_skip');
        await wsRoot.create(recursive: true);
        // Pre-create collision with sentinel file.
        await _writeFile('${wsRoot.path}/sws', 'sentinel.yaml', 'original');

        final targetId = await Opspack.importWorkspace(
          packFile: packFile,
          workspacesRoot: wsRoot,
          conflictPolicy: Opspack.conflictSkip,
        );
        expect(targetId, 'sws');
        // Sentinel must still be there — no overwrite.
        expect(await File('${wsRoot.path}/sws/sentinel.yaml').exists(), isTrue);
      },
    );
  });

  // ===========================================================================
  // Project FactGraph carrier — opspack embeds/extracts the serialized graph
  // snapshot (produced by the knowledge_persistence recipe's exportProject),
  // keeping opspack itself decoupled from the recipe. See system_tools
  // _exportOpspack / _importOpspack for the real wiring.
  // ===========================================================================
  group('FactGraph carrier', () {
    // A snapshot shaped exactly like the recipe's exportProject output:
    // a map of collection-name -> list of records.
    Map<String, List<Map<String, dynamic>>> sampleGraph() => {
          'facts': [
            {
              'id': 'f1',
              'workspaceId': 'proj1',
              'type': 'note',
              'content': {'text': 'alpha'},
            },
          ],
          'entities': [
            {'id': 'e1', 'workspaceId': 'proj1', 'name': 'Acme'},
          ],
        };

    // op17
    test('op17 includeFacts + factGraph embeds factgraph/graph.json', () async {
      final wsDir = Directory('${tmp.path}/ws_op17');
      await wsDir.create(recursive: true);
      await _writeFile(wsDir.path, 'workspace.yaml', 'id: proj1');

      final bundle = await Opspack.exportWorkspace(
        workspaceDir: wsDir,
        workspaceId: 'proj1',
        includeFacts: true,
        factGraph: sampleGraph(),
      );
      final archive = ZipDecoder().decodeBytes(bundle.bytes);
      expect(archive.findFile('factgraph/graph.json'), isNotNull);
      expect(bundle.manifest.contents, contains('factgraph/graph.json'));
    });

    // op18
    test('op18 extractFactGraph round-trips the snapshot', () async {
      final wsDir = Directory('${tmp.path}/ws_op18');
      await wsDir.create(recursive: true);
      await _writeFile(wsDir.path, 'workspace.yaml', 'id: proj1');

      final bundle = await Opspack.exportWorkspace(
        workspaceDir: wsDir,
        workspaceId: 'proj1',
        includeFacts: true,
        factGraph: sampleGraph(),
      );
      final got = Opspack.extractFactGraph(bundle.bytes);
      expect(got, isNotNull);
      expect(got!['facts']!.single['id'], 'f1');
      expect((got['facts']!.single['content'] as Map)['text'], 'alpha');
      expect(got['entities']!.single['name'], 'Acme');
    });

    // op19
    test('op19 no factgraph entry when includeFacts is false', () async {
      final wsDir = Directory('${tmp.path}/ws_op19');
      await wsDir.create(recursive: true);
      await _writeFile(wsDir.path, 'workspace.yaml', 'id: proj1');

      final bundle = await Opspack.exportWorkspace(
        workspaceDir: wsDir,
        workspaceId: 'proj1',
        includeFacts: false,
        factGraph: sampleGraph(),
      );
      expect(
        ZipDecoder()
            .decodeBytes(bundle.bytes)
            .findFile('factgraph/graph.json'),
        isNull,
      );
      expect(Opspack.extractFactGraph(bundle.bytes), isNull);
    });

    // op20
    test('op20 extractFactGraph returns null for a graphless pack', () async {
      final wsDir = Directory('${tmp.path}/ws_op20');
      await wsDir.create(recursive: true);
      await _writeFile(wsDir.path, 'workspace.yaml', 'id: proj1');

      final bundle = await Opspack.exportWorkspace(
        workspaceDir: wsDir,
        workspaceId: 'proj1',
      );
      expect(Opspack.extractFactGraph(bundle.bytes), isNull);
    });

    // op21 — empty graph carries nothing even when includeFacts is on.
    test('op21 empty factGraph map embeds no entry', () async {
      final wsDir = Directory('${tmp.path}/ws_op21');
      await wsDir.create(recursive: true);
      await _writeFile(wsDir.path, 'workspace.yaml', 'id: proj1');

      final bundle = await Opspack.exportWorkspace(
        workspaceDir: wsDir,
        workspaceId: 'proj1',
        includeFacts: true,
        factGraph: const {},
      );
      expect(Opspack.extractFactGraph(bundle.bytes), isNull);
    });
  });
}
