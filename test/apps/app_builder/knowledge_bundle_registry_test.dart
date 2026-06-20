/// Unit tests for [KnowledgeBundleRegistry] and [KnowledgeBundleEntry].
///
/// Scenario set:
///   kb1  KnowledgeBundleEntry.toJson / fromJson round-trip
///   kb2  list — returns empty when no file exists (lazy load)
///   kb3  load — empty when file absent
///   kb4  upsert — adds new entry, persists
///   kb5  upsert — second call with same path updates namespace + timestamp
///   kb6  list — returns all entries after multiple upserts
///   kb7  remove — removes existing entry, returns true
///   kb8  remove — no-op on unknown path, returns false
///   kb9  persists across instances (new registry, same storageDir)
///   kb10 load — corrupt file recovers to empty (no crash)
///   kb11 upsert then remove then list — removes correct entry
///   kb12 storage file has stable name
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/apps/app_builder/infra/knowledge_bundle_registry.dart';

KnowledgeBundleRegistry _registry(String dir) =>
    KnowledgeBundleRegistry(storageDir: dir);

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kb_registry_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // ── kb1 KnowledgeBundleEntry round-trip ─────────────────────────────
  group('kb1 KnowledgeBundleEntry toJson/fromJson', () {
    test('round-trips all fields', () {
      final entry = KnowledgeBundleEntry(
        mbdPath: '/path/to/bundle.mbd',
        namespace: 'my-kb',
        installedAt: '2026-06-01T00:00:00.000Z',
      );
      final restored = KnowledgeBundleEntry.fromJson(entry.toJson());
      expect(restored.mbdPath, '/path/to/bundle.mbd');
      expect(restored.namespace, 'my-kb');
      expect(restored.installedAt, '2026-06-01T00:00:00.000Z');
    });
  });

  // ── kb2 list when no file ────────────────────────────────────────────
  group('kb2 list no file', () {
    test('returns empty list when storage file absent', () async {
      final reg = _registry(tmp.path);
      final entries = await reg.list();
      expect(entries, isEmpty);
    });
  });

  // ── kb3 load empty ───────────────────────────────────────────────────
  group('kb3 load empty', () {
    test('load on missing file yields empty list', () async {
      final reg = _registry(tmp.path);
      await reg.load();
      expect(await reg.list(), isEmpty);
    });
  });

  // ── kb4 upsert new entry ─────────────────────────────────────────────
  group('kb4 upsert new entry', () {
    test('adds entry and it appears in list', () async {
      final reg = _registry(tmp.path);
      final entry = await reg.upsert(
        mbdPath: '/bundles/alpha.mbd',
        namespace: 'alpha',
      );
      expect(entry.mbdPath, '/bundles/alpha.mbd');
      expect(entry.namespace, 'alpha');
      expect(entry.installedAt, isNotEmpty);
      final list = await reg.list();
      expect(list, hasLength(1));
      expect(list.first.mbdPath, '/bundles/alpha.mbd');
    });

    test('storage file is created after upsert', () async {
      final reg = _registry(tmp.path);
      await reg.upsert(mbdPath: '/x.mbd', namespace: 'x');
      final file = File(p.join(tmp.path, KnowledgeBundleRegistry.storageFile));
      expect(await file.exists(), isTrue);
    });
  });

  // ── kb5 upsert updates existing ──────────────────────────────────────
  group('kb5 upsert update', () {
    test('second upsert with same path updates namespace', () async {
      final reg = _registry(tmp.path);
      await reg.upsert(mbdPath: '/b.mbd', namespace: 'old');
      await reg.upsert(mbdPath: '/b.mbd', namespace: 'new');
      final list = await reg.list();
      expect(list, hasLength(1));
      expect(list.first.namespace, 'new');
    });

    test(
      'entry count stays at 1 after repeated upsert with same path',
      () async {
        final reg = _registry(tmp.path);
        for (var i = 0; i < 3; i++) {
          await reg.upsert(mbdPath: '/same.mbd', namespace: 'ns$i');
        }
        expect(await reg.list(), hasLength(1));
      },
    );
  });

  // ── kb6 list multiple entries ────────────────────────────────────────
  group('kb6 list multiple', () {
    test('all upserted entries present', () async {
      final reg = _registry(tmp.path);
      await reg.upsert(mbdPath: '/a.mbd', namespace: 'a');
      await reg.upsert(mbdPath: '/b.mbd', namespace: 'b');
      await reg.upsert(mbdPath: '/c.mbd', namespace: 'c');
      final list = await reg.list();
      expect(list, hasLength(3));
      final paths = list.map((e) => e.mbdPath).toSet();
      expect(paths, containsAll(['/a.mbd', '/b.mbd', '/c.mbd']));
    });
  });

  // ── kb7 remove existing ──────────────────────────────────────────────
  group('kb7 remove existing', () {
    test('returns true and entry is gone', () async {
      final reg = _registry(tmp.path);
      await reg.upsert(mbdPath: '/rm.mbd', namespace: 'rm');
      final removed = await reg.remove('/rm.mbd');
      expect(removed, isTrue);
      expect(await reg.list(), isEmpty);
    });
  });

  // ── kb8 remove unknown ───────────────────────────────────────────────
  group('kb8 remove unknown', () {
    test('returns false when path not in registry', () async {
      final reg = _registry(tmp.path);
      final removed = await reg.remove('/nonexistent.mbd');
      expect(removed, isFalse);
    });
  });

  // ── kb9 persistence across instances ────────────────────────────────
  group('kb9 cross-instance persistence', () {
    test('entries survive registry re-instantiation', () async {
      final reg1 = _registry(tmp.path);
      await reg1.upsert(mbdPath: '/persist.mbd', namespace: 'ns');
      // New registry instance, same storageDir.
      final reg2 = _registry(tmp.path);
      final list = await reg2.list();
      expect(list, hasLength(1));
      expect(list.first.namespace, 'ns');
    });
  });

  // ── kb10 corrupt file recovers ───────────────────────────────────────
  group('kb10 corrupt file', () {
    test('load recovers to empty list without throwing', () async {
      final file = File(p.join(tmp.path, KnowledgeBundleRegistry.storageFile));
      await file.parent.create(recursive: true);
      await file.writeAsString('{not json!}');
      final reg = _registry(tmp.path);
      await reg.load();
      final list = await reg.list();
      expect(list, isEmpty);
    });

    test('upsert after corrupt load succeeds', () async {
      final file = File(p.join(tmp.path, KnowledgeBundleRegistry.storageFile));
      await file.parent.create(recursive: true);
      await file.writeAsString('null');
      final reg = _registry(tmp.path);
      await reg.upsert(mbdPath: '/after-corrupt.mbd', namespace: 'ok');
      expect(await reg.list(), hasLength(1));
    });
  });

  // ── kb11 upsert → remove sequence ───────────────────────────────────
  group('kb11 upsert then remove', () {
    test('removes correct entry leaving others', () async {
      final reg = _registry(tmp.path);
      await reg.upsert(mbdPath: '/keep.mbd', namespace: 'keep');
      await reg.upsert(mbdPath: '/del.mbd', namespace: 'del');
      await reg.remove('/del.mbd');
      final list = await reg.list();
      expect(list, hasLength(1));
      expect(list.first.mbdPath, '/keep.mbd');
    });
  });

  // ── kb12 storage file name ───────────────────────────────────────────
  group('kb12 storage file name stable', () {
    test('storageFile constant is knowledge_bundles.json', () {
      expect(KnowledgeBundleRegistry.storageFile, 'knowledge_bundles.json');
    });

    test('written file uses that name', () async {
      final reg = _registry(tmp.path);
      await reg.upsert(mbdPath: '/z.mbd', namespace: 'z');
      final file = File(p.join(tmp.path, KnowledgeBundleRegistry.storageFile));
      expect(await file.exists(), isTrue);
      // Sanity: file is parseable JSON array.
      final content = await file.readAsString();
      final decoded = jsonDecode(content);
      expect(decoded, isA<List>());
    });
  });
}
