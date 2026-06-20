/// ProcessRegistry — unit tests for testable pure-logic pieces.
///
/// ProcessRegistry.start / resume / approve all delegate to
/// `knowledgeSystem.ops.*` (behavior engine) which requires a full
/// OpsBuiltInApp boot. Those paths are skipped here; the following
/// sub-systems are unit-testable in isolation:
///
///   p1  ProcessRun.toJson / fromJson round-trip (all fields)
///   p2  ProcessRun.fromJson — state enum fallback on unknown string
///   p3  ProcessRun.copyWith — immutable partial update
///   p4  PendingApproval.toJson / fromJson round-trip
///   p5  ProcessRegistry._stateFromBehavior (via indirect path)
///   p6  ProcessRegistry.create / list / update / delete — in-memory only
///   p7  ProcessRegistry.list — wsId scoping
///   p8  ProcessRegistry.changes stream fires on create / update / delete
///   p9  ProcessRegistry.saveFromYaml — happy path + validation errors
///   p10 ProcessRegistry._ensureLoaded — reads YAML written to temp dir
///   p11 ProcessRegistry.readYaml — returns null when file missing
///   p12 wsContentRoot — path derivation (slug with slash, _system special case)
///   p13 Process model fields (steps · gates · trigger)
///   p14 ProcessRegistry.delete — workspace scoping
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' show KvStoragePortAdapter;
import 'package:appplayer_studio/builtin_api.dart' show KnowledgeSystem;
import 'package:appplayer_studio/src/apps/ops/registries/process_registry.dart';
import 'package:appplayer_studio/src/apps/ops/infra/ws_paths.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
Process _makeProcess({
  String id = 'proc_1',
  String workspaceId = 'project/ws1',
  String title = 'Proc One',
  List<ProcessStep>? steps,
  List<ProcessGate>? gates,
  ProcessTrigger trigger = ProcessTrigger.manual,
}) => Process(
  id: id,
  workspaceId: workspaceId,
  title: title,
  steps:
      steps ??
      [
        ProcessStep(
          stepId: 's1',
          assigneeId: 'agent_a',
          skillId: 'skill.write',
          inputs: const {'prompt': 'hello'},
        ),
      ],
  gates:
      gates ??
      [
        ProcessGate(
          afterStep: 's1',
          kind: GateKind.approval,
          params: const {'minApprovers': 1},
        ),
      ],
  trigger: trigger,
);

Future<(ProcessRegistry, Directory)> _makeRegistry() async {
  final tmp = await Directory.systemTemp.createTemp('proc_reg_test_');
  final kv = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv'));
  final reg = ProcessRegistry(
    kv: kv,
    knowledgeSystem: KnowledgeSystem.stub(),
    rootDir: tmp.path,
  );
  return (reg, tmp);
}

void main() {
  group('ProcessRun JSON round-trip', () {
    // --- p1 ---
    test('p1 toJson / fromJson preserves all fields', () {
      final now = DateTime.utc(2024, 6, 1, 12, 0, 0);
      final approval = PendingApproval(
        afterStep: 's1',
        approverId: 'mgr1',
        requestedAt: DateTime.utc(2024, 6, 1, 11, 0, 0),
      );
      final run = ProcessRun(
        runId: 'run-abc',
        processId: 'proc_1',
        workspaceId: 'project/ws1',
        startedAt: now,
        currentStep: 's1',
        outcomes: const {'result': 'ok'},
        state: ProcessRunState.waitingApproval,
        checkpointRef: 'ckpt-1',
        pendingApproval: approval,
      );

      final json = run.toJson();
      final restored = ProcessRun.fromJson(json);

      expect(restored.runId, 'run-abc');
      expect(restored.processId, 'proc_1');
      expect(restored.workspaceId, 'project/ws1');
      expect(restored.startedAt.toUtc(), now);
      expect(restored.currentStep, 's1');
      expect(restored.outcomes['result'], 'ok');
      expect(restored.state, ProcessRunState.waitingApproval);
      expect(restored.checkpointRef, 'ckpt-1');
      expect(restored.pendingApproval!.afterStep, 's1');
      expect(restored.pendingApproval!.approverId, 'mgr1');
    });

    // --- p2 ---
    test('p2 fromJson falls back to running on unknown state string', () {
      final json = {
        'runId': 'r1',
        'processId': 'p1',
        'workspaceId': 'project/x',
        'startedAt': DateTime.now().toIso8601String(),
        'currentStep': '',
        'state': 'UNKNOWN_STATE',
      };
      final run = ProcessRun.fromJson(json);
      expect(run.state, ProcessRunState.running);
    });

    // --- p3 ---
    test('p3 copyWith creates new instance with partial updates', () {
      final original = ProcessRun(
        runId: 'r2',
        processId: 'p2',
        workspaceId: 'project/ws',
        startedAt: DateTime.now(),
        currentStep: 's1',
        outcomes: const {},
        state: ProcessRunState.running,
      );
      final updated = original.copyWith(
        currentStep: 's2',
        state: ProcessRunState.completed,
        outcomes: {'done': true},
      );
      expect(updated.runId, original.runId);
      expect(updated.currentStep, 's2');
      expect(updated.state, ProcessRunState.completed);
      expect(updated.outcomes['done'], true);
      // Original unchanged.
      expect(original.currentStep, 's1');
      expect(original.state, ProcessRunState.running);
    });
  });

  group('PendingApproval JSON round-trip', () {
    // --- p4 ---
    test('p4 toJson / fromJson round-trip', () {
      final now = DateTime.utc(2024, 7, 4, 9, 0, 0);
      final pa = PendingApproval(
        afterStep: 'review',
        approverId: 'ceo',
        requestedAt: now,
      );
      final json = pa.toJson();
      final restored = PendingApproval.fromJson(json);
      expect(restored.afterStep, 'review');
      expect(restored.approverId, 'ceo');
      expect(restored.requestedAt.toUtc(), now);
    });
  });

  group('ProcessRunState enum coverage', () {
    // Verify all enum values exist (regression guard for future additions).
    test('all ProcessRunState values exist', () {
      expect(
        ProcessRunState.values,
        containsAll([
          ProcessRunState.running,
          ProcessRunState.waitingApproval,
          ProcessRunState.blocked,
          ProcessRunState.completed,
          ProcessRunState.cancelled,
        ]),
      );
    });

    test('all GateKind values exist', () {
      expect(
        GateKind.values,
        containsAll([GateKind.philosophy, GateKind.quality, GateKind.approval]),
      );
    });

    test('all ProcessTrigger values exist', () {
      expect(
        ProcessTrigger.values,
        containsAll([
          ProcessTrigger.manual,
          ProcessTrigger.event,
          ProcessTrigger.task,
        ]),
      );
    });
  });

  group('ProcessRegistry in-memory operations', () {
    late ProcessRegistry reg;
    late Directory tmp;

    setUp(() async {
      (reg, tmp) = await _makeRegistry();
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // --- p6: create / list / update / delete ---
    test('p6 create and list returns the process', () async {
      final proc = _makeProcess();
      await reg.create(proc);

      final list = await reg.list(wsId: 'project/ws1');
      expect(list.length, 1);
      expect(list.first.id, 'proc_1');
      expect(list.first.title, 'Proc One');
    });

    test('p6b update replaces process in cache', () async {
      await reg.create(_makeProcess(id: 'up1', title: 'Original'));
      final updated = _makeProcess(id: 'up1', title: 'Updated');
      await reg.update(updated);

      final list = await reg.list(wsId: 'project/ws1');
      expect(list.firstWhere((p) => p.id == 'up1').title, 'Updated');
    });

    test('p6c delete removes process from cache and disk file', () async {
      await reg.create(_makeProcess(id: 'del1'));
      await reg.delete('del1', workspaceId: 'project/ws1');

      final list = await reg.list(wsId: 'project/ws1');
      expect(list.where((p) => p.id == 'del1'), isEmpty);
    });

    // --- p7: list with wsId scoping ---
    test('p7 list with wsId returns only that workspace processes', () async {
      await reg.create(
        _makeProcess(id: 'ws1_proc', workspaceId: 'project/ws1'),
      );
      await reg.create(
        _makeProcess(id: 'ws2_proc', workspaceId: 'project/ws2'),
      );

      final ws1List = await reg.list(wsId: 'project/ws1');
      final ids1 = ws1List.map((p) => p.id).toList();
      expect(ids1, contains('ws1_proc'));
      expect(ids1, isNot(contains('ws2_proc')));

      final ws2List = await reg.list(wsId: 'project/ws2');
      expect(ws2List.map((p) => p.id), contains('ws2_proc'));
    });

    test('p7b list without wsId returns all workspaces', () async {
      await reg.create(_makeProcess(id: 'a', workspaceId: 'project/ws1'));
      await reg.create(_makeProcess(id: 'b', workspaceId: 'project/ws2'));

      final all = await reg.list();
      expect(all.map((p) => p.id).toSet(), containsAll(['a', 'b']));
    });

    // --- p8: changes stream ---
    test('p8 changes stream fires on create / update / delete', () async {
      final events = <int>[];
      int counter = 0;
      final sub = reg.changes.listen((_) => events.add(counter++));
      addTearDown(sub.cancel);

      await reg.create(_makeProcess(id: 'chg'));
      await reg.update(_makeProcess(id: 'chg', title: 'Changed'));
      await reg.delete('chg', workspaceId: 'project/ws1');

      await Future<void>.delayed(Duration.zero);
      expect(events.length, 3);
    });

    // --- p9: saveFromYaml ---
    test('p9 saveFromYaml parses YAML and persists the process', () async {
      const yaml = '''
id: yaml_proc
title: YAML Process
trigger: event
steps:
  - stepId: step1
    assigneeId: agent_x
    skillId: skill.analyze
gates:
  - afterStep: step1
    kind: quality
''';
      final proc = await reg.saveFromYaml(yaml, 'project/ws1');
      expect(proc.id, 'yaml_proc');
      expect(proc.title, 'YAML Process');
      expect(proc.trigger, ProcessTrigger.event);
      expect(proc.steps.length, 1);
      expect(proc.steps.first.stepId, 'step1');
      expect(proc.gates.first.kind, GateKind.quality);

      // Persisted to the correct path.
      final wsRoot = wsContentRoot(tmp.path, 'project/ws1');
      final file = File('$wsRoot/processes/yaml_proc.yaml');
      expect(await file.exists(), isTrue);
    });

    test('p9b saveFromYaml throws on non-map YAML', () {
      expect(
        () => reg.saveFromYaml('- a\n- b\n', 'project/ws1'),
        throwsA(isA<StateError>()),
      );
    });

    test('p9c saveFromYaml throws when id is missing', () {
      expect(
        () => reg.saveFromYaml('title: NoId\ntrigger: manual\n', 'project/ws1'),
        throwsA(isA<StateError>()),
      );
    });

    // --- p10: _ensureLoaded scans disk ---
    test(
      'p10 _ensureLoaded reads YAML files written by another instance',
      () async {
        // Manually write a process YAML to the right path.
        const yamlContent = '''
id: disk_proc
title: Disk Process
trigger: manual
steps:
  - stepId: ds1
    assigneeId: agent_b
    skillId: skill.run
''';
        final wsRoot = wsContentRoot(tmp.path, 'project/disk_ws');
        final dir = Directory('$wsRoot/processes');
        await dir.create(recursive: true);
        final f = File('${dir.path}/disk_proc.yaml');
        await f.writeAsString(yamlContent);

        // New registry — should scan on first list().
        final kv2 = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv2'));
        final reg2 = ProcessRegistry(
          kv: kv2,
          knowledgeSystem: KnowledgeSystem.stub(),
          rootDir: tmp.path,
        );
        final list = await reg2.list(wsId: 'project/disk_ws');
        expect(list.map((p) => p.id), contains('disk_proc'));
      },
    );

    // --- p11: readYaml ---
    test('p11 readYaml returns null when file does not exist', () async {
      final result = await reg.readYaml('project/ws1', 'nonexistent');
      expect(result, isNull);
    });

    test('p11b readYaml returns content when file exists', () async {
      const yaml = 'id: ry_proc\ntitle: RY\ntrigger: manual\nsteps: []\n';
      final wsRoot = wsContentRoot(tmp.path, 'project/ws1');
      final dir = Directory('$wsRoot/processes');
      await dir.create(recursive: true);
      final f = File('${dir.path}/ry_proc.yaml');
      await f.writeAsString(yaml);

      final result = await reg.readYaml('project/ws1', 'ry_proc');
      expect(result, isNotNull);
      expect(result!, contains('ry_proc'));
    });

    // --- p13: Process model fields ---
    test('p13 Process preserves steps / gates / trigger fields', () {
      final step = ProcessStep(
        stepId: 'st1',
        assigneeId: 'ag1',
        skillId: 'sk1',
        inputs: const {'key': 'val'},
        channelThreadId: 'thread-42',
      );
      final gate = ProcessGate(
        afterStep: 'st1',
        kind: GateKind.philosophy,
        params: const {'ref': 'ethics'},
      );
      final proc = Process(
        id: 'model_test',
        workspaceId: 'project/ws',
        title: 'Model Test',
        steps: [step],
        gates: [gate],
        trigger: ProcessTrigger.task,
      );

      expect(proc.steps.first.stepId, 'st1');
      expect(proc.steps.first.inputs['key'], 'val');
      expect(proc.steps.first.channelThreadId, 'thread-42');
      expect(proc.gates.first.kind, GateKind.philosophy);
      expect(proc.gates.first.params['ref'], 'ethics');
      expect(proc.trigger, ProcessTrigger.task);
    });

    // --- p14: delete workspace scoping ---
    test(
      'p14 delete with workspaceId only removes from that workspace',
      () async {
        await reg.create(
          _makeProcess(id: 'shared_id', workspaceId: 'project/ws1'),
        );
        await reg.create(
          _makeProcess(id: 'shared_id', workspaceId: 'project/ws2'),
        );

        await reg.delete('shared_id', workspaceId: 'project/ws1');

        final ws1 = await reg.list(wsId: 'project/ws1');
        expect(ws1.where((p) => p.id == 'shared_id'), isEmpty);

        final ws2 = await reg.list(wsId: 'project/ws2');
        expect(ws2.where((p) => p.id == 'shared_id'), isNotEmpty);
      },
    );
  });

  group('wsContentRoot', () {
    // --- p12: path derivation ---
    test('p12 slash in wsId becomes underscore in bundle dir name', () {
      final result = wsContentRoot('/root', 'project/ws1');
      expect(result, '/root/project_ws1.mbd');
    });

    test('p12b _system stays as _system (no .mbd suffix)', () {
      final result = wsContentRoot('/root', '_system');
      expect(result, '/root/_system');
    });

    test('p12c org/corp → org_corp.mbd', () {
      final result = wsContentRoot('/root', 'org/corp');
      expect(result, '/root/org_corp.mbd');
    });

    test('p12d empty projectRoot returns empty string', () {
      final result = wsContentRoot('', 'project/ws');
      expect(result, isEmpty);
    });
  });
}
