/// WorkspaceRegistry — unit tests against a real temp dir + injected
/// KvStoragePortAdapter (no OpsBuiltInApp boot required).
///
/// Scenarios:
///   r1  create — happy path: id, type, title, dir on disk
///   r2  create — duplicate id throws
///   r3  create — empty rootDir throws
///   r4  list — excludes reserved ids by default, includes with flag
///   r5  get — returns workspace after create, null for unknown id
///   r6  setActive — updates activeId + kv.workspaceId + fires changes
///   r7  delete — removes from cache, removes dir, clears activeId when active
///   r8  rename — moves dir, rewrites config, updates cache + activeId
///   r9  rename — collision throws (target id already exists)
///   r10 update — mutable fields (title · locale · timezone · tags)
///   r11 update — unknown id throws
///   r12 share — adds toId to sharedWith, idempotent
///   r13 ensureSystemWorkspace — creates _system, idempotent
///   r14 changes stream — fires on create / delete / rename / update / share
///   r15 Workspace.fromYaml — round-trip through toYamlMap
///   r16 _ensureLoaded — scans disk on first access (fresh registry)
///   r17 WorkspaceType slug derivation in id (`type.name/slug`)
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' show KvStoragePortAdapter;
import 'package:appplayer_studio/src/apps/ops/registries/workspace_registry.dart';

/// Creates a temp directory and an in-memory-backed registry.
/// Caller owns cleanup via [addTearDown] registered inside.
Future<(WorkspaceRegistry, Directory)> _makeRegistry() async {
  final tmp = await Directory.systemTemp.createTemp('ws_reg_test_');
  final kv = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv'));
  final reg = WorkspaceRegistry(kv: kv, rootDir: tmp.path);
  return (reg, tmp);
}

void main() {
  group('WorkspaceRegistry', () {
    late WorkspaceRegistry reg;
    late Directory tmp;

    setUp(() async {
      (reg, tmp) = await _makeRegistry();
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- r1: create happy path ---
    test('r1 create returns correct id / type / title', () async {
      final ws = await reg.create(
        type: WorkspaceType.project,
        slug: 'alpha',
        title: 'Alpha Project',
      );
      expect(ws.id, 'project/alpha');
      expect(ws.type, WorkspaceType.project);
      expect(ws.title, 'Alpha Project');
      expect(ws.locale, 'ko');
      expect(ws.timezone, 'Asia/Seoul');

      // Directory must exist on disk.
      final dir = Directory(p.join(tmp.path, 'project', 'alpha'));
      expect(await dir.exists(), isTrue);

      // config.yaml must exist.
      final cfg = File(p.join(dir.path, 'config.yaml'));
      expect(await cfg.exists(), isTrue);
    });

    // --- r2: duplicate id ---
    test('r2 create duplicate id throws StateError', () async {
      await reg.create(type: WorkspaceType.project, slug: 'dup', title: 'Dup');
      expect(
        () => reg.create(
          type: WorkspaceType.project,
          slug: 'dup',
          title: 'Dup 2',
        ),
        throwsA(isA<StateError>()),
      );
    });

    // --- r3: empty rootDir ---
    test('r3 create with empty rootDir throws StateError', () async {
      final kv = KvStoragePortAdapter(rootDir: '/tmp/kv_empty');
      final emptyReg = WorkspaceRegistry(kv: kv, rootDir: '');
      expect(
        () => emptyReg.create(
          type: WorkspaceType.project,
          slug: 'test',
          title: 'Test',
        ),
        throwsA(isA<StateError>()),
      );
    });

    // --- r4: list excludes reserved by default ---
    test('r4 list excludes reserved ids by default', () async {
      await reg.create(
        type: WorkspaceType.project,
        slug: 'visible',
        title: 'Visible',
      );
      await reg.ensureSystemWorkspace();

      final visible = await reg.list();
      expect(visible.map((w) => w.id), contains('project/visible'));
      expect(visible.map((w) => w.id), isNot(contains('_system')));

      final all = await reg.list(includeReserved: true);
      expect(all.map((w) => w.id), contains('_system'));
    });

    // --- r5: get ---
    test('r5 get returns workspace after create, null for unknown', () async {
      await reg.create(type: WorkspaceType.org, slug: 'acme', title: 'Acme');
      final ws = await reg.get('org/acme');
      expect(ws, isNotNull);
      expect(ws!.title, 'Acme');

      final missing = await reg.get('personal/nobody');
      expect(missing, isNull);
    });

    // --- r6: setActive ---
    test(
      'r6 setActive updates activeId and kv.workspaceId and fires changes',
      () async {
        final ws = await reg.create(
          type: WorkspaceType.project,
          slug: 'beta',
          title: 'Beta',
        );
        final received = <void>[];
        final sub = reg.changes.listen((_) => received.add(null));
        addTearDown(sub.cancel);

        await reg.setActive(ws.id);
        expect(reg.activeId, 'project/beta');
        expect((reg.kv).workspaceId, 'project/beta');
        expect(received, isNotEmpty);
      },
    );

    // --- r7: delete ---
    test(
      'r7 delete removes from cache and disk, clears activeId when active',
      () async {
        final ws = await reg.create(
          type: WorkspaceType.project,
          slug: 'gamma',
          title: 'Gamma',
        );
        await reg.setActive(ws.id);
        expect(reg.activeId, 'project/gamma');

        final dir = Directory(p.join(tmp.path, 'project', 'gamma'));
        expect(await dir.exists(), isTrue);

        await reg.delete('project/gamma');

        expect(await reg.get('project/gamma'), isNull);
        expect(await dir.exists(), isFalse);
        expect(reg.activeId, isNull);
      },
    );

    test('r7b delete non-active does not clear activeId', () async {
      final ws1 = await reg.create(
        type: WorkspaceType.project,
        slug: 'keep',
        title: 'Keep',
      );
      final ws2 = await reg.create(
        type: WorkspaceType.project,
        slug: 'drop',
        title: 'Drop',
      );
      await reg.setActive(ws1.id);

      await reg.delete(ws2.id);
      expect(reg.activeId, 'project/keep');
    });

    // --- r8: rename ---
    test(
      'r8 rename moves dir, updates cache, updates activeId when active',
      () async {
        final ws = await reg.create(
          type: WorkspaceType.project,
          slug: 'old',
          title: 'Old',
        );
        await reg.setActive(ws.id);

        final renamed = await reg.rename(
          'project/old',
          'project/new',
          newTitle: 'New Title',
        );

        expect(renamed.id, 'project/new');
        expect(renamed.title, 'New Title');
        expect(await reg.get('project/old'), isNull);
        expect((await reg.get('project/new'))!.title, 'New Title');
        expect(reg.activeId, 'project/new');

        final newDir = Directory(p.join(tmp.path, 'project', 'new'));
        expect(await newDir.exists(), isTrue);
        final oldDir = Directory(p.join(tmp.path, 'project', 'old'));
        expect(await oldDir.exists(), isFalse);
      },
    );

    // --- r9: rename collision ---
    test('r9 rename to existing id throws StateError', () async {
      await reg.create(type: WorkspaceType.project, slug: 'src', title: 'Src');
      await reg.create(type: WorkspaceType.project, slug: 'dst', title: 'Dst');
      expect(
        () => reg.rename('project/src', 'project/dst'),
        throwsA(isA<StateError>()),
      );
    });

    test('r9b rename non-existent source throws StateError', () async {
      expect(
        () => reg.rename('project/ghost', 'project/newname'),
        throwsA(isA<StateError>()),
      );
    });

    // --- r10: update ---
    test('r10 update modifies title/locale/timezone/tags', () async {
      await reg.create(
        type: WorkspaceType.project,
        slug: 'upd',
        title: 'Original',
      );
      final updated = await reg.update(
        'project/upd',
        title: 'Updated',
        locale: 'en',
        timezone: 'UTC',
        tags: {'env': 'prod'},
      );
      expect(updated.title, 'Updated');
      expect(updated.locale, 'en');
      expect(updated.timezone, 'UTC');
      expect(updated.tags['env'], 'prod');

      // Verify persisted to disk.
      final cached = await reg.get('project/upd');
      expect(cached!.title, 'Updated');
    });

    // --- r11: update unknown id ---
    test('r11 update unknown id throws StateError', () {
      expect(
        () => reg.update('project/ghost', title: 'X'),
        throwsA(isA<StateError>()),
      );
    });

    // --- r12: share ---
    test('r12 share appends toId, second call is idempotent', () async {
      await reg.create(
        type: WorkspaceType.project,
        slug: 'sharer',
        title: 'Sharer',
      );
      await reg.share('project/sharer', 'project/other');
      final ws1 = await reg.get('project/sharer');
      expect(ws1!.sharedWith, contains('project/other'));

      // Idempotent — calling again should not duplicate entry.
      await reg.share('project/sharer', 'project/other');
      final ws2 = await reg.get('project/sharer');
      expect(ws2!.sharedWith.where((s) => s == 'project/other').length, 1);
    });

    // --- r13: ensureSystemWorkspace ---
    test(
      'r13 ensureSystemWorkspace creates _system workspace, idempotent',
      () async {
        final sys1 = await reg.ensureSystemWorkspace();
        expect(sys1.id, '_system');
        expect(sys1.type, WorkspaceType.project);
        expect(sys1.tags['ops:reserved'], 'system');

        // Calling again must not throw and returns the same id.
        final sys2 = await reg.ensureSystemWorkspace();
        expect(sys2.id, '_system');

        final dir = Directory(p.join(tmp.path, '_system'));
        expect(await dir.exists(), isTrue);
      },
    );

    // --- r14: changes stream fires on all mutating operations ---
    test(
      'r14 changes stream fires on create / delete / rename / update / share',
      () async {
        final fired = <int>[];
        int counter = 0;
        // Subscribe BEFORE any mutations so all events are captured.
        final sub = reg.changes.listen((_) => fired.add(counter++));
        addTearDown(sub.cancel);

        await reg.create(
          type: WorkspaceType.project,
          slug: 'ev',
          title: 'Ev',
        ); // fires 1
        await reg.update('project/ev', title: 'Ev2'); // fires 2
        await reg.share('project/ev', 'other'); // fires 3
        await reg.rename('project/ev', 'project/ev_renamed'); // fires 4
        await reg.delete('project/ev_renamed'); // fires 5

        // Allow any trailing microtask-queued notifications to drain.
        await Future<void>.delayed(Duration.zero);
        expect(fired.length, 5);
      },
    );

    test('r14b setActive fires changes', () async {
      final ws = await reg.create(
        type: WorkspaceType.project,
        slug: 'chg',
        title: 'Chg',
      );
      final received = <void>[];
      final sub = reg.changes.listen((_) => received.add(null));
      addTearDown(sub.cancel);

      await reg.setActive(ws.id);
      expect(received.length, greaterThanOrEqualTo(1));
    });

    // --- r15: Workspace.fromYaml round-trip ---
    test(
      'r15 Workspace.toYamlMap / fromYaml round-trip preserves all fields',
      () {
        final original = Workspace(
          id: 'project/round',
          type: WorkspaceType.project,
          title: 'Round Trip',
          locale: 'ja',
          timezone: 'Asia/Tokyo',
          createdAt: DateTime.utc(2024, 1, 15, 10, 0, 0),
          members: ['alice', 'bob'],
          sharedWith: ['project/other'],
          tags: {'env': 'staging', 'region:key': 'us-east'},
        );

        final map = original.toYamlMap();
        final restored = Workspace.fromYaml(map);

        expect(restored.id, original.id);
        expect(restored.type, original.type);
        expect(restored.title, original.title);
        expect(restored.locale, original.locale);
        expect(restored.timezone, original.timezone);
        expect(restored.members, containsAll(original.members));
        expect(restored.sharedWith, containsAll(original.sharedWith));
        expect(restored.tags['region:key'], 'us-east');
      },
    );

    test('r15b Workspace.fromYaml fallback defaults for missing fields', () {
      final ws = Workspace.fromYaml({'id': 'project/minimal'});
      expect(ws.id, 'project/minimal');
      expect(ws.title, 'project/minimal'); // fallback to id
      expect(ws.locale, 'ko');
      expect(ws.timezone, 'Asia/Seoul');
      expect(ws.type, WorkspaceType.project);
      expect(ws.members, isEmpty);
      expect(ws.sharedWith, isEmpty);
    });

    // --- r16: _ensureLoaded scans disk ---
    test(
      'r16 fresh registry re-reads workspaces written by another instance',
      () async {
        // Write via first registry.
        await reg.create(
          type: WorkspaceType.personal,
          slug: 'persist',
          title: 'Persistent',
        );

        // New registry pointing at the same rootDir — should scan on first access.
        final kv2 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv2'));
        final reg2 = WorkspaceRegistry(kv: kv2, rootDir: tmp.path);
        final list = await reg2.list();
        expect(list.map((w) => w.id), contains('personal/persist'));
      },
    );

    // --- r17: WorkspaceType slug in id ---
    test('r17 org type produces org/<slug> id', () async {
      final ws = await reg.create(
        type: WorkspaceType.org,
        slug: 'corp',
        title: 'Corp',
      );
      expect(ws.id, 'org/corp');
      expect(ws.type, WorkspaceType.org);
    });

    test('r17b personal type produces personal/<slug> id', () async {
      final ws = await reg.create(
        type: WorkspaceType.personal,
        slug: 'me',
        title: 'Me',
      );
      expect(ws.id, 'personal/me');
    });

    // --- list is sorted by id ---
    test('list returns workspaces sorted by id', () async {
      await reg.create(type: WorkspaceType.project, slug: 'zzz', title: 'Z');
      await reg.create(type: WorkspaceType.project, slug: 'aaa', title: 'A');
      await reg.create(type: WorkspaceType.project, slug: 'mmm', title: 'M');

      final list = await reg.list();
      final ids = list.map((w) => w.id).toList();
      expect(
        ids,
        containsAllInOrder(['project/aaa', 'project/mmm', 'project/zzz']),
      );
    });

    // --- WorkspaceType.values ---
    test('WorkspaceType has org / personal / project variants', () {
      expect(
        WorkspaceType.values,
        containsAll([
          WorkspaceType.org,
          WorkspaceType.personal,
          WorkspaceType.project,
        ]),
      );
    });
  });
}
