// Step state on the process flow view before and after the first run.
//
// A freshly saved process has no run; showing its first step as "in
// progress" put work on screen that had not started (R12 TC-OP-092). Every
// step is queued until a run exists; with a running run the current step is
// in progress and earlier ones done.

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/registries/process_registry.dart';
import 'package:appplayer_studio/src/apps/ops/widgets/ops_models.dart'
    show PipelineState;
import 'package:appplayer_studio/src/apps/ops/widgets/process_flow_view.dart';

Process _proc({List<ProcessRun> runs = const []}) => Process(
  id: 'p1',
  workspaceId: 'ws',
  title: 'My Process',
  steps: [
    ProcessStep(stepId: 's1', assigneeId: 'a', skillId: 'k'),
    ProcessStep(stepId: 's2', assigneeId: 'a', skillId: 'k'),
  ],
  gates: const [],
  trigger: ProcessTrigger.manual,
  runs: runs,
);

void main() {
  test('no run yet — every step is queued', () {
    final steps = stepsForProcess(_proc());
    expect(steps.map((s) => s.state), [
      PipelineState.pending,
      PipelineState.pending,
    ]);
    expect(steps.first.timeLabel, 'queued');
  });

  test('running run — first step done, second in progress', () {
    final run = ProcessRun(
      runId: 'r1',
      processId: 'p1',
      workspaceId: 'ws',
      startedAt: DateTime(2026, 9, 5),
      currentStep: 's2',
      state: ProcessRunState.running,
    );
    final steps = stepsForProcess(_proc(runs: [run]));
    expect(steps.map((s) => s.state), [
      PipelineState.done,
      PipelineState.running,
    ]);
    expect(steps[1].timeLabel, 'in progress');
  });
}
