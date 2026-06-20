/// TaskRegistry — unit tests for all unit-testable paths.
///
/// TaskRegistry.run requires a `SkillDispatch` callback wired at boot time
/// (behavior engine). The dispatch path is tested via a lightweight stub
/// that does not need OpsBuiltInApp.ensureBoot.
///
/// Scenarios:
///   t1  Task.copyWith — immutable partial update (state / runs)
///   t2  TaskRunRef.toJson — serializes all fields
///   t3  TaskRegistry.create / list — happy path, persists yaml to disk
///   t4  TaskRegistry.list — wsId scoping
///   t5  TaskRegistry.list — states filter (pending / completed)
///   t6  TaskRegistry.list — no wsId returns all workspaces
///   t7  TaskRegistry.get — finds task, returns null for unknown
///   t8  TaskRegistry.update — replaces cached entry + disk file
///   t9  TaskRegistry.delete — removes from cache + disk
///   t10 TaskRegistry._ensureLoaded — reads YAML written by another instance
///   t11 TaskRegistry._fromYaml — kind / state fallback on unknown strings
///   t12 TaskRegistry._fromYaml — schedule + dueAt round-trip via disk
///   t13 TaskRegistry._fromYaml — inputs map preserved through yaml
///   t14 TaskRegistry.create with empty rootDir throws StateError
///   t15 TaskRegistry.changes stream fires on create / update / delete / cancel
///   t16 TaskRegistry.cancel — sets state to cancelled
///   t17 TaskRegistry.run — happy path with stub dispatch (completes)
///   t18 TaskRegistry.run — dispatch throws → state becomes blocked
///   t19 TaskRegistry.run — throws when dispatch not attached
///   t20 TaskRegistry.run — throws when task has no skillIds
///   t21 TaskRegistry.run — throws StateError for unknown task id
///   t22 TaskKind enum coverage
///   t23 TaskState enum coverage
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' show KvStoragePortAdapter;
import 'package:appplayer_studio/builtin_api.dart' show KnowledgeSystem;
import 'package:appplayer_studio/src/apps/ops/registries/task_registry.dart';
import 'package:appplayer_studio/src/apps/ops/infra/ws_paths.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Task _makeTask({
  String id = 'task_1',
  String workspaceId = 'project/ws1',
  String title = 'Task One',
  TaskKind kind = TaskKind.oneOff,
  List<String> assigneeIds = const ['ag1'],
  List<String> skillIds = const ['skill.run'],
  Map<String, dynamic> inputs = const {},
  TaskState state = TaskState.pending,
}) => Task(
  id: id,
  workspaceId: workspaceId,
  kind: kind,
  title: title,
  assigneeIds: assigneeIds,
  skillIds: skillIds,
  inputs: inputs,
  state: state,
  createdAt: DateTime.utc(2024, 1, 1),
);

Future<(TaskRegistry, Directory)> _makeRegistry() async {
  final tmp = await Directory.systemTemp.createTemp('task_reg_test_');
  final kv = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv'));
  final reg = TaskRegistry(
    kv: kv,
    knowledgeSystem: KnowledgeSystem.stub(),
    rootDir: tmp.path,
  );
  return (reg, tmp);
}

void main() {
  group('Task model', () {
    // --- t1: copyWith ---
    test('t1 Task.copyWith creates new instance with partial updates', () {
      final original = _makeTask();
      final ref = TaskRunRef(
        runId: 'run-1',
        startedAt: DateTime.now(),
        endState: TaskState.completed,
      );
      final updated = original.copyWith(
        state: TaskState.completed,
        runs: [ref],
      );

      expect(updated.id, original.id);
      expect(updated.state, TaskState.completed);
      expect(updated.runs.length, 1);
      expect(updated.runs.first.runId, 'run-1');

      // Original unchanged.
      expect(original.state, TaskState.pending);
      expect(original.runs, isEmpty);
    });

    // --- t2: TaskRunRef.toJson ---
    test('t2 TaskRunRef.toJson serializes all fields', () {
      final now = DateTime.utc(2024, 3, 15, 9, 30, 0);
      final ended = DateTime.utc(2024, 3, 15, 9, 31, 0);
      final ref = TaskRunRef(
        runId: 'r42',
        startedAt: now,
        endedAt: ended,
        endState: TaskState.completed,
        summary: 'all good',
        errorCode: null,
      );
      final json = ref.toJson();
      expect(json['runId'], 'r42');
      expect(json['startedAt'], now.toIso8601String());
      expect(json['endedAt'], ended.toIso8601String());
      expect(json['endState'], 'completed');
      expect(json['summary'], 'all good');
      expect(json.containsKey('errorCode'), isFalse);
    });

    test('t2b TaskRunRef.toJson omits optional null fields', () {
      final ref = TaskRunRef(
        runId: 'r0',
        startedAt: DateTime.now(),
        endState: TaskState.inProgress,
      );
      final json = ref.toJson();
      expect(json.containsKey('endedAt'), isFalse);
      expect(json.containsKey('summary'), isFalse);
      expect(json.containsKey('errorCode'), isFalse);
    });
  });

  group('TaskRegistry — CRUD', () {
    late TaskRegistry reg;
    late Directory tmp;

    setUp(() async {
      (reg, tmp) = await _makeRegistry();
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- t3: create / list happy path ---
    test(
      't3 create and list returns the task, persists yaml to disk',
      () async {
        final task = _makeTask();
        await reg.create(task);

        final list = await reg.list(wsId: 'project/ws1');
        expect(list.length, 1);
        expect(list.first.id, 'task_1');
        expect(list.first.title, 'Task One');

        // File must exist on disk.
        final dir = Directory(
          '${wsContentRoot(tmp.path, 'project/ws1')}/tasks',
        );
        expect(await File('${dir.path}/task_1.yaml').exists(), isTrue);
      },
    );

    // --- t4: list wsId scoping ---
    test('t4 list with wsId returns only that workspace tasks', () async {
      await reg.create(_makeTask(id: 'ws1_task', workspaceId: 'project/ws1'));
      await reg.create(_makeTask(id: 'ws2_task', workspaceId: 'project/ws2'));

      final ws1 = await reg.list(wsId: 'project/ws1');
      expect(ws1.map((t) => t.id), contains('ws1_task'));
      expect(ws1.map((t) => t.id), isNot(contains('ws2_task')));
    });

    // --- t5: list states filter ---
    test('t5 list states filter returns only matching tasks', () async {
      await reg.create(_makeTask(id: 'pend', state: TaskState.pending));
      await reg.create(
        _makeTask(
          id: 'done',
          state: TaskState.completed,
          workspaceId: 'project/ws1',
        ),
      );

      final pending = await reg.list(
        wsId: 'project/ws1',
        states: {TaskState.pending},
      );
      final completed = await reg.list(
        wsId: 'project/ws1',
        states: {TaskState.completed},
      );

      expect(pending.map((t) => t.id), contains('pend'));
      expect(pending.map((t) => t.id), isNot(contains('done')));
      expect(completed.map((t) => t.id), contains('done'));
    });

    // --- t6: list without wsId returns all ---
    test('t6 list without wsId returns tasks from all workspaces', () async {
      await reg.create(_makeTask(id: 'a', workspaceId: 'project/ws1'));
      await reg.create(_makeTask(id: 'b', workspaceId: 'project/ws2'));

      final all = await reg.list();
      expect(all.map((t) => t.id).toSet(), containsAll(['a', 'b']));
    });

    // --- t7: get ---
    test('t7 get finds task, returns null for unknown', () async {
      await reg.create(_makeTask(id: 'find_me'));

      final found = await reg.get('find_me');
      expect(found, isNotNull);
      expect(found!.title, 'Task One');

      final missing = await reg.get('nonexistent');
      expect(missing, isNull);
    });

    // --- t8: update ---
    test('t8 update replaces cached entry and rewrites disk file', () async {
      await reg.create(_makeTask(id: 'upd_task', title: 'Original'));
      final updated = _makeTask(
        id: 'upd_task',
        title: 'Updated',
        state: TaskState.inProgress,
      );
      await reg.update(updated);

      final fetched = await reg.get('upd_task');
      expect(fetched?.title, 'Updated');
      expect(fetched?.state, TaskState.inProgress);
    });

    // --- t9: delete ---
    test('t9 delete removes from cache and disk', () async {
      await reg.create(_makeTask(id: 'del_task'));

      final dir = Directory('${wsContentRoot(tmp.path, 'project/ws1')}/tasks');
      expect(await File('${dir.path}/del_task.yaml').exists(), isTrue);

      await reg.delete('del_task');

      final list = await reg.list(wsId: 'project/ws1');
      expect(list.where((t) => t.id == 'del_task'), isEmpty);
      expect(await File('${dir.path}/del_task.yaml').exists(), isFalse);
    });

    // --- t14: empty rootDir throws ---
    test('t14 create with empty rootDir throws StateError', () async {
      final kv = KvStoragePortAdapter(rootDir: '/tmp/kv_empty_task');
      final emptyReg = TaskRegistry(
        kv: kv,
        knowledgeSystem: KnowledgeSystem.stub(),
        rootDir: '',
      );
      expect(() => emptyReg.create(_makeTask()), throwsA(isA<StateError>()));
    });
  });

  group('TaskRegistry — disk round-trip', () {
    // --- t10: _ensureLoaded ---
    test('t10 fresh registry reads YAML written by another instance', () async {
      final tmp = await Directory.systemTemp.createTemp('task_disk_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      // Write via first registry.
      final kv1 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv1'));
      final reg1 = TaskRegistry(
        kv: kv1,
        knowledgeSystem: KnowledgeSystem.stub(),
        rootDir: tmp.path,
      );
      await reg1.create(_makeTask(id: 'disk_task', workspaceId: 'project/dws'));

      // New registry from same rootDir.
      final kv2 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv2'));
      final reg2 = TaskRegistry(
        kv: kv2,
        knowledgeSystem: KnowledgeSystem.stub(),
        rootDir: tmp.path,
      );
      final list = await reg2.list(wsId: 'project/dws');
      expect(list.map((t) => t.id), contains('disk_task'));
    });

    // --- t11: _fromYaml kind/state fallback ---
    test(
      't11 _fromYaml unknown kind defaults to oneOff, unknown state to pending',
      () async {
        final tmp = await Directory.systemTemp.createTemp('task_yaml_fb_');
        addTearDown(() async {
          if (await tmp.exists()) await tmp.delete(recursive: true);
        });

        const yamlContent = '''
id: fallback_task
kind: UNKNOWN_KIND
title: Fallback Task
assigneeIds: []
skillIds: []
state: UNKNOWN_STATE
createdAt: 2024-01-01T00:00:00.000Z
''';
        final wsRoot = wsContentRoot(tmp.path, 'project/fb_ws');
        final dir = Directory('$wsRoot/tasks');
        await dir.create(recursive: true);
        await File('${dir.path}/fallback_task.yaml').writeAsString(yamlContent);

        final kv = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv'));
        final reg = TaskRegistry(
          kv: kv,
          knowledgeSystem: KnowledgeSystem.stub(),
          rootDir: tmp.path,
        );
        final list = await reg.list(wsId: 'project/fb_ws');
        expect(list.length, 1);
        expect(list.first.kind, TaskKind.oneOff);
        expect(list.first.state, TaskState.pending);
      },
    );

    // --- t12: schedule + dueAt round-trip ---
    test(
      't12 schedule and dueAt survive yaml round-trip through disk',
      () async {
        final tmp = await Directory.systemTemp.createTemp('task_sched_');
        addTearDown(() async {
          if (await tmp.exists()) await tmp.delete(recursive: true);
        });

        final dueAt = DateTime.utc(2025, 12, 31, 23, 59, 0);
        final kv1 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv1'));
        final reg1 = TaskRegistry(
          kv: kv1,
          knowledgeSystem: KnowledgeSystem.stub(),
          rootDir: tmp.path,
        );

        final task = Task(
          id: 'sched_task',
          workspaceId: 'project/sws',
          kind: TaskKind.recurring,
          title: 'Recurring',
          assigneeIds: const ['ag1'],
          skillIds: const ['skill.run'],
          schedule: TaskSchedule(cron: '0 9 * * MON', timezone: 'Asia/Seoul'),
          dueAt: dueAt,
          state: TaskState.pending,
          createdAt: DateTime.utc(2024, 6, 1),
        );
        await reg1.create(task);

        final kv2 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv2'));
        final reg2 = TaskRegistry(
          kv: kv2,
          knowledgeSystem: KnowledgeSystem.stub(),
          rootDir: tmp.path,
        );
        final list = await reg2.list(wsId: 'project/sws');
        expect(list.length, 1);
        final loaded = list.first;
        expect(loaded.kind, TaskKind.recurring);
        expect(loaded.schedule?.cron, '0 9 * * MON');
        expect(loaded.schedule?.timezone, 'Asia/Seoul');
        expect(loaded.dueAt?.toUtc().day, dueAt.day);
      },
    );

    // --- t13: inputs map preserved ---
    test('t13 inputs map round-trips through YAML', () async {
      final tmp = await Directory.systemTemp.createTemp('task_inputs_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      final kv1 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv1'));
      final reg1 = TaskRegistry(
        kv: kv1,
        knowledgeSystem: KnowledgeSystem.stub(),
        rootDir: tmp.path,
      );
      await reg1.create(
        _makeTask(
          id: 'input_task',
          workspaceId: 'project/iws',
          inputs: {'prompt': 'hello world', 'max': 100},
        ),
      );

      final kv2 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv2'));
      final reg2 = TaskRegistry(
        kv: kv2,
        knowledgeSystem: KnowledgeSystem.stub(),
        rootDir: tmp.path,
      );
      final list = await reg2.list(wsId: 'project/iws');
      expect(list.length, 1);
      expect(list.first.inputs['prompt'], 'hello world');
    });
  });

  group('TaskRegistry — changes stream', () {
    late TaskRegistry reg;
    late Directory tmp;

    setUp(() async {
      (reg, tmp) = await _makeRegistry();
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- t15: changes stream ---
    test(
      't15 changes stream fires on create / update / delete / cancel',
      () async {
        final events = <int>[];
        int counter = 0;
        final sub = reg.changes.listen((_) => events.add(counter++));
        addTearDown(sub.cancel);

        await reg.create(_makeTask(id: 'chg'));
        await reg.update(_makeTask(id: 'chg', title: 'Changed'));
        await reg.cancel('chg');
        await reg.delete('chg');

        await Future<void>.delayed(Duration.zero);
        expect(events.length, 4);
      },
    );
  });

  group('TaskRegistry — cancel', () {
    late TaskRegistry reg;
    late Directory tmp;

    setUp(() async {
      (reg, tmp) = await _makeRegistry();
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- t16: cancel ---
    test('t16 cancel sets state to cancelled', () async {
      await reg.create(_makeTask(id: 'can_task'));
      await reg.cancel('can_task');

      final t = await reg.get('can_task');
      expect(t?.state, TaskState.cancelled);
    });

    test('t16b cancel on unknown id is a no-op (no throw)', () async {
      // Should not throw.
      await reg.cancel('ghost_task');
    });
  });

  group('TaskRegistry — run (stub dispatch)', () {
    late TaskRegistry reg;
    late Directory tmp;

    setUp(() async {
      (reg, tmp) = await _makeRegistry();
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- t17: run happy path ---
    test(
      't17 run with stub dispatch completes and returns TaskRunRef',
      () async {
        reg.dispatch = (skillId, args) async => {'status': 'ok'};

        await reg.create(_makeTask(id: 'run_task'));
        final ref = await reg.run('run_task');

        expect(ref.endState, TaskState.completed);
        expect(ref.runId, isNotEmpty);
        expect(ref.endedAt, isNotNull);

        // Task state should be completed.
        final t = await reg.get('run_task');
        expect(t?.state, TaskState.completed);
      },
    );

    // --- t18: run — dispatch throws ---
    test('t18 run dispatch throws → state becomes blocked', () async {
      reg.dispatch = (skillId, args) async => throw Exception('skill error');

      await reg.create(_makeTask(id: 'fail_task'));
      final ref = await reg.run('fail_task');

      expect(ref.endState, TaskState.blocked);
      expect(ref.errorCode, isNotNull);
    });

    // --- t19: run without dispatch attached ---
    test('t19 run throws StateError when dispatch not attached', () async {
      await reg.create(_makeTask(id: 'no_dispatch'));
      expect(() => reg.run('no_dispatch'), throwsA(isA<StateError>()));
    });

    // --- t20: run with no skillIds ---
    test('t20 run throws StateError when task has no skillIds', () async {
      reg.dispatch = (skillId, args) async => {};
      await reg.create(_makeTask(id: 'no_skills', skillIds: const []));
      expect(() => reg.run('no_skills'), throwsA(isA<StateError>()));
    });

    // --- t21: run unknown task ---
    test('t21 run throws StateError for unknown task id', () async {
      reg.dispatch = (skillId, args) async => {};
      expect(() => reg.run('ghost_task'), throwsA(isA<StateError>()));
    });
  });

  group('Enum coverage', () {
    // --- t22: TaskKind ---
    test('t22 TaskKind has oneOff / recurring / sustained', () {
      expect(
        TaskKind.values,
        containsAll([TaskKind.oneOff, TaskKind.recurring, TaskKind.sustained]),
      );
    });

    // --- t23: TaskState ---
    test('t23 TaskState has all expected values', () {
      expect(
        TaskState.values,
        containsAll([
          TaskState.pending,
          TaskState.inProgress,
          TaskState.blocked,
          TaskState.completed,
          TaskState.cancelled,
        ]),
      );
    });
  });
}
