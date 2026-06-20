import 'package:flutter/material.dart';

import '../registries/process_registry.dart' as proc;
import 'ops_models.dart';
import 'ops_pipeline_node.dart';

/// Renders a process as a vertical step → gate flow using [OpsPipelineNode].
/// Shared by the home pipeline preview and the Work/process page so the flow
/// visual (step state, assignee, skill, gate approval) is single-source.
///
/// [onApprove] / [onReject] receive the node name; wire them to the
/// `process_approve` / gate tools. When null, gate nodes render read-only.
class ProcessFlowView extends StatelessWidget {
  const ProcessFlowView({
    super.key,
    required this.process,
    this.onApprove,
    this.onReject,
  });

  final proc.Process process;
  final void Function(String nodeName)? onApprove;
  final void Function(String nodeName)? onReject;

  @override
  Widget build(BuildContext context) {
    final steps = stepsForProcess(process);
    return Column(
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Column(
              children: [
                OpsPipelineNode(
                  step: steps[i],
                  onApprove:
                      onApprove == null
                          ? null
                          : () => onApprove!(steps[i].name),
                  onReject:
                      onReject == null ? null : () => onReject!(steps[i].name),
                ),
                if (i < steps.length - 1) const OpsPipelineConnector(),
              ],
            ),
          ),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// Maps a [proc.Process] to the [PipelineStep] list the flow widgets render —
/// one node per step plus a gate node after any step that has gates. Step
/// state is derived from the latest run (done / running / pending), and a
/// gate the run is waiting on is marked [PipelineState.gate] (awaiting
/// approval).
List<PipelineStep> stepsForProcess(proc.Process p) {
  // Determine progression from the latest run if any. Without run data,
  // default to step 0 = running, rest = pending.
  final latestRun = p.runs.isNotEmpty ? p.runs.last : null;
  final isWaitingApproval =
      latestRun?.state == proc.ProcessRunState.waitingApproval;
  final completedCount =
      latestRun == null
          ? 0
          : switch (latestRun.state) {
            proc.ProcessRunState.completed => p.steps.length,
            proc.ProcessRunState.cancelled => p.steps.length,
            proc.ProcessRunState.blocked => 1,
            proc.ProcessRunState.waitingApproval => 1,
            proc.ProcessRunState.running => 1,
          };

  // Map step index → list of gates that fire AFTER that step.
  final gatesByAfter = <int, List<proc.ProcessGate>>{};
  for (final g in p.gates) {
    final idx = p.steps.indexWhere((s) => s.stepId == g.afterStep);
    if (idx >= 0) {
      gatesByAfter.putIfAbsent(idx, () => []).add(g);
    }
  }

  final out = <PipelineStep>[];
  for (var i = 0; i < p.steps.length; i++) {
    final s = p.steps[i];
    PipelineState state;
    if (i < completedCount) {
      state = PipelineState.done;
    } else if (i == completedCount && !isWaitingApproval) {
      state =
          latestRun == null
              ? (i == 0 ? PipelineState.running : PipelineState.pending)
              : PipelineState.running;
    } else {
      state = PipelineState.pending;
    }
    out.add(
      PipelineStep(
        indexLabel: (i + 1).toString().padLeft(2, '0'),
        name: s.stepId,
        actorCaption: 'by ${s.assigneeId}',
        description: 'skill: ${s.skillId}',
        state: state,
        timeLabel: switch (state) {
          PipelineState.done => 'done',
          PipelineState.running => 'in progress',
          PipelineState.gate => 'awaiting',
          PipelineState.pending => 'queued',
        },
      ),
    );

    // Gate node fires after this step. If the run is waiting on approval at
    // this gate, mark it active; otherwise show as pending.
    final gates = gatesByAfter[i];
    if (gates != null) {
      for (final g in gates) {
        final reachable =
            i < completedCount || (i == completedCount && isWaitingApproval);
        out.add(
          PipelineStep(
            indexLabel: '⇲',
            name: 'Gate · ${g.kind.name}',
            actorCaption: 'after ${g.afterStep}',
            description:
                g.params.isEmpty
                    ? 'requires manual approval'
                    : g.params.entries
                        .map((e) => '${e.key}: ${e.value}')
                        .join(' · '),
            state:
                reachable && isWaitingApproval && i == completedCount
                    ? PipelineState.gate
                    : PipelineState.pending,
            timeLabel: reachable && isWaitingApproval ? 'awaiting' : 'queued',
          ),
        );
      }
    }
  }
  return out;
}
