/// Flow-board column mapping — live-caught 2026-07-04: a run suspended on
/// an approval gate carries the VIRTUAL currentStep `gate_approval_<step>`
/// which matches no step column, so the waiting card vanished from the
/// board. Waiting runs must sit at the step their gate follows.
library;

import 'package:appplayer_studio/src/apps/ops/registries/process_registry.dart';
import 'package:appplayer_studio/src/apps/ops/ui/process/process_board.dart';
import 'package:flutter_test/flutter_test.dart';

ProcessRun _run({
  required String currentStep,
  required ProcessRunState state,
  PendingApproval? pending,
}) =>
    ProcessRun(
      runId: 'r1',
      processId: 'p1',
      workspaceId: 'org/dev',
      startedAt: DateTime(2026, 7, 4, 9),
      currentStep: currentStep,
      state: state,
      pendingApproval: pending,
    );

void main() {
  test('waitingApproval run sits at its gate\'s afterStep column', () {
    final run = _run(
      currentStep: 'gate_approval_draft',
      state: ProcessRunState.waitingApproval,
      pending: PendingApproval(
        afterStep: 'draft',
        approverId: 'dev-lead',
        requestedAt: DateTime(2026, 7, 4, 9, 1),
      ),
    );
    expect(boardColumnFor(run), 'draft');
  });

  test('gate_ prefix strips even without a pendingApproval record', () {
    final run = _run(
      currentStep: 'gate_approval_publish',
      state: ProcessRunState.running,
    );
    expect(boardColumnFor(run), 'publish');
  });

  test('plain step passes through', () {
    final run = _run(
      currentStep: 'inspect',
      state: ProcessRunState.running,
    );
    expect(boardColumnFor(run), 'inspect');
  });

  // ── placedBoardColumnFor — the column a run is actually placed in ──────────
  // Regression (konpi live re-verify, audit P2.8): a freshly-started background
  // run persists `running` with an EMPTY currentStep, so boardColumnFor='' and
  // it matched no column — the card (and its elapsed badge) vanished.

  Process _proc(List<String> stepIds) => Process(
        id: 'p1',
        workspaceId: 'org/dev',
        title: 'wiring',
        steps: [
          for (final s in stepIds)
            ProcessStep(stepId: s, assigneeId: 'a', skillId: 'noop'),
        ],
        gates: const [],
        trigger: ProcessTrigger.manual,
      );

  test('running run with EMPTY currentStep is placed at the first step', () {
    final run = _run(currentStep: '', state: ProcessRunState.running);
    expect(
      placedBoardColumnFor(run, _proc(['ticket', 'review', 'land'])),
      'ticket',
    );
  });

  test('running run with an unknown currentStep falls to the first step', () {
    final run = _run(currentStep: 'ghost', state: ProcessRunState.running);
    expect(placedBoardColumnFor(run, _proc(['ticket', 'review'])), 'ticket');
  });

  test('running run on a real step stays in that step column', () {
    final run = _run(currentStep: 'review', state: ProcessRunState.running);
    expect(placedBoardColumnFor(run, _proc(['ticket', 'review'])), 'review');
  });

  test('waitingApproval placement still honours the gate afterStep', () {
    final run = _run(
      currentStep: 'gate_approval_review',
      state: ProcessRunState.waitingApproval,
      pending: PendingApproval(
        afterStep: 'review',
        approverId: 'lead',
        requestedAt: DateTime(2026, 7, 4, 9, 1),
      ),
    );
    expect(placedBoardColumnFor(run, _proc(['ticket', 'review'])), 'review');
  });

  test('empty-currentStep run on a process with no steps returns raw', () {
    final run = _run(currentStep: '', state: ProcessRunState.running);
    expect(placedBoardColumnFor(run, _proc(const [])), '');
  });
}
