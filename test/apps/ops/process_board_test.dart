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
}
