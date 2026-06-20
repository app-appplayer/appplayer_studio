/// KnowledgeRegistry — unit tests for all unit-testable paths.
///
/// saveFact / query use `knowledgeSystem.facts` (behavior engine). Those paths
/// are not tested here because they require a live OpsBuiltInApp. The following
/// sub-systems are fully unit-testable with an injected temp dir:
///
///   k1  listFiles — empty when knowledge dir absent
///   k2  listFiles — returns sorted relative paths, recursive
///   k3  listFiles — subPath filter
///   k4  readFile — happy path returns content
///   k5  readFile — throws StateError when file missing
///   k6  readFile — throws ArgumentError when path does not start with "knowledge/"
///   k7  readFile — throws ArgumentError when path contains ".."
///   k8  writeFile — creates file + parent dirs, atomic
///   k9  writeFile — throws ArgumentError for bad path
///   k10 deleteFile — deletes existing file
///   k11 deleteFile — no-op when file absent
///   k12 listFiles + writeFile + readFile — full round-trip
///   k13 listKvFacts — empty when no facts stored
///   k14 listKvFacts — returns facts stored via kv.set (no LLM needed)
///   k15 listKvFacts — filter by substring in category / key / value
///   k16 KnowledgeFileEntry — fields populated correctly
///   k17 KvFactEntry — fields populated correctly
///   k18 loadSystemSchema — returns empty maps when system dir missing
///   k19 loadSystemSchema — reads url-map.yaml when present
///   k20 loadSystemSchema — reads extraction templates when present
///   k21 loadSystemSchema — reads auth-spec.yaml when present
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' show KvStoragePortAdapter;
import 'package:appplayer_studio/builtin_api.dart' show KnowledgeSystem;
import 'package:appplayer_studio/src/apps/ops/registries/knowledge_registry.dart';
import 'package:appplayer_studio/src/apps/ops/infra/ws_paths.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Creates a registry bound to a temp directory; [wsId] is set on the kv so
/// [saveFact] / [listKvFacts] can resolve the active workspace without an
/// OpsBuiltInApp.
Future<(KnowledgeRegistry, Directory)> _makeRegistry({
  String wsId = 'project/test_ws',
}) async {
  final tmp = await Directory.systemTemp.createTemp('know_reg_test_');
  final kv = KvStoragePortAdapter(
    rootDir: p.join(tmp.path, 'kv'),
    workspaceId: wsId,
  );
  final reg = KnowledgeRegistry(
    kv: kv,
    knowledgeSystem: KnowledgeSystem.stub(),
    rootDir: tmp.path,
  );
  return (reg, tmp);
}

/// Writes a file directly into the knowledge directory of [wsId] under [tmp].
Future<File> _writeKnowledgeFile(
  Directory tmp,
  String wsId,
  String relPath,
  String content,
) async {
  final f = File('${wsContentRoot(tmp.path, wsId)}/$relPath');
  await f.parent.create(recursive: true);
  await f.writeAsString(content);
  return f;
}

void main() {
  group('KnowledgeRegistry — listFiles', () {
    late KnowledgeRegistry reg;
    late Directory tmp;

    setUp(() async {
      (reg, tmp) = await _makeRegistry();
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- k1: empty when dir absent ---
    test(
      'k1 listFiles returns empty list when knowledge dir does not exist',
      () async {
        final list = await reg.listFiles('project/test_ws');
        expect(list, isEmpty);
      },
    );

    // --- k2: returns sorted relative paths ---
    test('k2 listFiles returns sorted KnowledgeFileEntry list', () async {
      await _writeKnowledgeFile(
        tmp,
        'project/test_ws',
        'knowledge/notes/b.md',
        'B',
      );
      await _writeKnowledgeFile(
        tmp,
        'project/test_ws',
        'knowledge/notes/a.md',
        'A',
      );
      await _writeKnowledgeFile(
        tmp,
        'project/test_ws',
        'knowledge/docs/c.txt',
        'C',
      );

      final list = await reg.listFiles('project/test_ws');
      expect(list.length, 3);
      final paths = list.map((e) => e.relativePath).toList();
      // Must be sorted.
      final sorted = [...paths]..sort();
      expect(paths, sorted);
    });

    // --- k3: subPath filter ---
    test(
      'k3 listFiles with subPath returns only files under that sub-dir',
      () async {
        await _writeKnowledgeFile(
          tmp,
          'project/test_ws',
          'knowledge/notes/note1.md',
          'N1',
        );
        await _writeKnowledgeFile(
          tmp,
          'project/test_ws',
          'knowledge/docs/doc1.md',
          'D1',
        );

        final notesList = await reg.listFiles(
          'project/test_ws',
          subPath: 'notes',
        );
        expect(notesList.length, 1);
        expect(notesList.first.relativePath, contains('note1.md'));
      },
    );
  });

  group('KnowledgeRegistry — readFile', () {
    late KnowledgeRegistry reg;
    late Directory tmp;

    setUp(() async {
      (reg, tmp) = await _makeRegistry();
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- k4: happy path ---
    test('k4 readFile returns file content', () async {
      await _writeKnowledgeFile(
        tmp,
        'project/test_ws',
        'knowledge/fact.md',
        'hello world',
      );

      final content = await reg.readFile(
        'project/test_ws',
        'knowledge/fact.md',
      );
      expect(content, 'hello world');
    });

    // --- k5: missing file ---
    test('k5 readFile throws StateError when file does not exist', () {
      expect(
        () => reg.readFile('project/test_ws', 'knowledge/absent.md'),
        throwsA(isA<StateError>()),
      );
    });

    // --- k6: bad path prefix ---
    test(
      'k6 readFile throws ArgumentError when path does not start with knowledge/',
      () {
        expect(
          () => reg.readFile('project/test_ws', 'docs/secret.md'),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    // --- k7: path traversal ---
    test('k7 readFile throws ArgumentError when path contains ".."', () {
      expect(
        () => reg.readFile('project/test_ws', 'knowledge/../etc/passwd'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('KnowledgeRegistry — writeFile', () {
    late KnowledgeRegistry reg;
    late Directory tmp;

    setUp(() async {
      (reg, tmp) = await _makeRegistry();
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- k8: creates file atomically ---
    test('k8 writeFile creates file and parent dirs', () async {
      await reg.writeFile(
        'project/test_ws',
        'knowledge/new/note.md',
        '# New Note',
      );

      final f = File(
        '${wsContentRoot(tmp.path, 'project/test_ws')}/knowledge/new/note.md',
      );
      expect(await f.exists(), isTrue);
      expect(await f.readAsString(), '# New Note');
    });

    // --- k9: bad path ---
    test('k9 writeFile throws ArgumentError for bad path', () {
      expect(
        () => reg.writeFile('project/test_ws', 'other/note.md', 'x'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('KnowledgeRegistry — deleteFile', () {
    late KnowledgeRegistry reg;
    late Directory tmp;

    setUp(() async {
      (reg, tmp) = await _makeRegistry();
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- k10: deletes existing file ---
    test('k10 deleteFile deletes an existing file', () async {
      await _writeKnowledgeFile(
        tmp,
        'project/test_ws',
        'knowledge/to_delete.md',
        'bye',
      );

      final f = File(
        '${wsContentRoot(tmp.path, 'project/test_ws')}/knowledge/to_delete.md',
      );
      expect(await f.exists(), isTrue);

      await reg.deleteFile('project/test_ws', 'knowledge/to_delete.md');
      expect(await f.exists(), isFalse);
    });

    // --- k11: no-op when file absent ---
    test('k11 deleteFile is a no-op when file does not exist', () async {
      // Should not throw.
      await reg.deleteFile('project/test_ws', 'knowledge/ghost.md');
    });
  });

  group('KnowledgeRegistry — full round-trip', () {
    // --- k12: write → list → read round-trip ---
    test('k12 write then list then read gives consistent content', () async {
      final (reg, tmp) = await _makeRegistry();
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      const content = '# Strategy\n\nKey decisions go here.';
      await reg.writeFile('project/test_ws', 'knowledge/strategy.md', content);

      final listed = await reg.listFiles('project/test_ws');
      expect(listed.any((e) => e.relativePath.endsWith('strategy.md')), isTrue);

      final read = await reg.readFile(
        'project/test_ws',
        'knowledge/strategy.md',
      );
      expect(read, content);
    });
  });

  group('KnowledgeRegistry — listKvFacts', () {
    late KnowledgeRegistry reg;
    late KvStoragePortAdapter kv;
    late Directory tmp;
    const wsId = 'project/kv_ws';

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('know_kv_test_');
      kv = KvStoragePortAdapter(
        rootDir: p.join(tmp.path, 'kv'),
        workspaceId: wsId,
      );
      reg = KnowledgeRegistry(
        kv: kv,
        knowledgeSystem: KnowledgeSystem.stub(),
        rootDir: tmp.path,
      );
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- k13: empty when no facts ---
    test('k13 listKvFacts returns empty list when no facts stored', () async {
      final list = await reg.listKvFacts();
      expect(list, isEmpty);
    });

    // --- k14: returns stored facts ---
    test('k14 listKvFacts returns facts stored directly via kv.set', () async {
      // Write a fact manually into the kv path that saveFact uses.
      await kv.set('ws/$wsId/registry/knowledge/market/trend', {
        'category': 'market',
        'key': 'trend',
        'value': 'growing',
        'savedAt': '2024-06-01T00:00:00.000Z',
      });
      await kv.set('ws/$wsId/registry/knowledge/tech/stack', {
        'category': 'tech',
        'key': 'stack',
        'value': 'flutter',
        'savedAt': '2024-06-02T00:00:00.000Z',
      });

      final list = await reg.listKvFacts();
      expect(list.length, 2);
      final categories = list.map((e) => e.category).toSet();
      expect(categories, containsAll(['market', 'tech']));
    });

    // --- k15: filter by substring ---
    test(
      'k15 listKvFacts filter matches category/key/value case-insensitively',
      () async {
        await kv.set('ws/$wsId/registry/knowledge/finance/revenue', {
          'category': 'finance',
          'key': 'revenue',
          'value': '1M USD',
          'savedAt': '2024-01-01T00:00:00.000Z',
        });
        await kv.set('ws/$wsId/registry/knowledge/hr/headcount', {
          'category': 'hr',
          'key': 'headcount',
          'value': '50 people',
          'savedAt': '2024-01-02T00:00:00.000Z',
        });

        final financeHits = await reg.listKvFacts(filter: 'FINANCE');
        expect(financeHits.length, 1);
        expect(financeHits.first.category, 'finance');

        final noHits = await reg.listKvFacts(filter: 'xyz_no_match');
        expect(noHits, isEmpty);
      },
    );
  });

  group('KnowledgeFileEntry / KvFactEntry models', () {
    // --- k16: KnowledgeFileEntry fields ---
    test('k16 KnowledgeFileEntry stores relativePath / size / modifiedAt', () {
      final now = DateTime.utc(2024, 7, 4);
      final entry = KnowledgeFileEntry(
        relativePath: 'knowledge/foo.md',
        size: 42,
        modifiedAt: now,
      );
      expect(entry.relativePath, 'knowledge/foo.md');
      expect(entry.size, 42);
      expect(entry.modifiedAt, now);
    });

    // --- k17: KvFactEntry fields ---
    test('k17 KvFactEntry stores all fields including metadata', () {
      final entry = KvFactEntry(
        storageKey: 'market/trend',
        category: 'market',
        key: 'trend',
        value: 'growing',
        metadata: {'source': 'survey'},
        savedAt: '2024-06-01T00:00:00.000Z',
      );
      expect(entry.storageKey, 'market/trend');
      expect(entry.category, 'market');
      expect(entry.key, 'trend');
      expect(entry.value, 'growing');
      expect(entry.metadata['source'], 'survey');
      expect(entry.savedAt, '2024-06-01T00:00:00.000Z');
    });
  });

  group('KnowledgeRegistry — loadSystemSchema', () {
    late KnowledgeRegistry reg;
    late Directory tmp;
    const wsId = 'project/schema_ws';

    setUp(() async {
      (reg, tmp) = await _makeRegistry(wsId: wsId);
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- k18: empty maps when system dir missing ---
    test(
      'k18 loadSystemSchema returns empty maps when system dir absent',
      () async {
        final schema = await reg.loadSystemSchema('nonexistent_system');
        expect(schema.systemId, 'nonexistent_system');
        expect(schema.urlMap, isEmpty);
        expect(schema.templates, isEmpty);
        expect(schema.authSpec, isNull);
      },
    );

    // --- k19: reads url-map.yaml ---
    test('k19 loadSystemSchema reads url-map.yaml and builds urlMap', () async {
      final base = '${wsContentRoot(tmp.path, wsId)}/knowledge/systems/github';
      await Directory(base).create(recursive: true);
      await File('$base/url-map.yaml').writeAsString('''
base: https://github.com
paths:
  repos: /user/repos
  issues: /issues
''');

      final schema = await reg.loadSystemSchema('github');
      expect(schema.urlMap['repos'], 'https://github.com/user/repos');
      expect(schema.urlMap['issues'], 'https://github.com/issues');
    });

    // --- k20: reads extraction templates ---
    test('k20 loadSystemSchema reads extraction templates', () async {
      final base =
          '${wsContentRoot(tmp.path, wsId)}/knowledge/systems/jira/extraction';
      await Directory(base).create(recursive: true);
      await File('$base/issue_template.yaml').writeAsString('''
name: issue
fields:
  - id
  - title
  - status
''');

      final schema = await reg.loadSystemSchema('jira');
      expect(schema.templates.length, 1);
      expect(schema.templates.first['name'], 'issue');
    });

    // --- k21: reads auth-spec.yaml ---
    test('k21 loadSystemSchema reads auth-spec.yaml', () async {
      final base = '${wsContentRoot(tmp.path, wsId)}/knowledge/systems/linear';
      await Directory(base).create(recursive: true);
      await File('$base/auth-spec.yaml').writeAsString('''
type: oauth2
authorizationUrl: https://linear.app/oauth/authorize
''');

      final schema = await reg.loadSystemSchema('linear');
      expect(schema.authSpec, isNotNull);
      expect(schema.authSpec!['type'], 'oauth2');
    });
  });
}
