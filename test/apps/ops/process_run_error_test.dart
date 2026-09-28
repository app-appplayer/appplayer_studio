/// A background process run that stops on a thrown error keeps the error on
/// its run record — `blocked` alone leaves the cause recoverable only by
/// re-running synchronously.
library;

import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart' show KnowledgeSystem;
import 'package:appplayer_studio/src/apps/ops/registries/process_registry.dart';
import 'package:brain_kernel/brain_kernel.dart' show KvStoragePortAdapter;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('ProcessRun carries error through JSON and copyWith', () {
    final run = ProcessRun(
      runId: 'r1',
      processId: 'p1',
      workspaceId: 'project/ws1',
      startedAt: DateTime.utc(2026, 9, 14),
      currentStep: 's1',
      state: ProcessRunState.blocked,
      error: 'behavior not found: x.project.p1',
    );
    final restored = ProcessRun.fromJson(run.toJson());
    expect(restored.error, 'behavior not found: x.project.p1');
    expect(restored.copyWith(currentStep: 's2').error, run.error);
    final clean = ProcessRun.fromJson(
      (run.toJson()..remove('error')),
    );
    expect(clean.error, isNull);
    expect(clean.toJson().containsKey('error'), isFalse);
  });

  test('a background run that throws is blocked with the error', () async {
    final tmp = await Directory.systemTemp.createTemp('proc_run_error_');
    addTearDown(() => tmp.delete(recursive: true));
    final kv = KvStoragePortAdapter(
      rootDir: p.join(tmp.path, 'kv'),
      workspaceId: 'project/ws1',
    );
    final reg = ProcessRegistry(
      kv: kv,
      knowledgeSystem: KnowledgeSystem.stub(),
      rootDir: tmp.path,
    );
    await reg.create(
      Process(
        id: 'pipeline',
        workspaceId: 'project/ws1',
        title: 'Pipeline',
        steps: [
          ProcessStep(
            stepId: 'plan',
            assigneeId: 'chief',
            skillId: 'skill.plan',
          ),
        ],
        gates: const [],
        trigger: ProcessTrigger.manual,
      ),
    );

    final started = await reg.start('pipeline', background: true);
    expect(started.state, ProcessRunState.running);

    ProcessRun? last;
    for (var i = 0; i < 100; i++) {
      final runs = await reg.listRuns('pipeline');
      last = runs.where((r) => r.runId == started.runId).firstOrNull;
      if (last != null && last.state != ProcessRunState.running) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(last, isNotNull);
    expect(last!.state, ProcessRunState.blocked);
    expect(last.error, isNotNull);
    expect(last.error, isNotEmpty);
    expect(last.startedAt, started.startedAt);
  });
}
