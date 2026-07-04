/// Flow board (B2) — process runs as cards moving through step columns.
///
/// One swimlane per process definition: columns = the process's steps in
/// order + a final Done column; each run card sits at its `currentStep`
/// (running=accent, waitingApproval=warn ⏳ with the approver, blocked=err,
/// completed/cancelled=Done column). READ-ONLY view over the behavior
/// engine's state — dragging cards does not drive transitions by design.
/// Data: `processBoardRunsProvider` (4s poll — run state has no change
/// tick). Design: `docs/makemind_ops/ops-flow-views.md`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../registries/process_registry.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';

class ProcessBoard extends ConsumerWidget {
  const ProcessBoard({super.key, required this.wsId});

  final String wsId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final processesAsync = ref.watch(workspaceProcessesProvider(wsId));
    final runsAsync = ref.watch(processBoardRunsProvider(wsId));
    return processesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (processes) {
        if (processes.isEmpty) {
          return const Center(
            child: Text('No processes — add one to see its flow.'),
          );
        }
        final runsByProcess =
            runsAsync.value ?? const <String, List<ProcessRun>>{};
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            for (final p in processes)
              _Swimlane(
                process: p,
                runs: runsByProcess[p.id] ?? const [],
              ),
          ],
        );
      },
    );
  }
}

class _Swimlane extends StatelessWidget {
  const _Swimlane({required this.process, required this.runs});

  final Process process;
  final List<ProcessRun> runs;

  @override
  Widget build(BuildContext context) {
    final doneStates = {
      ProcessRunState.completed,
      ProcessRunState.cancelled,
    };
    List<ProcessRun> at(String stepId) => [
          for (final r in runs)
            if (!doneStates.contains(r.state) && r.currentStep == stepId) r,
        ];
    final done = [
      for (final r in runs)
        if (doneStates.contains(r.state)) r,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 2),
            child: Row(
              children: [
                Text(
                  process.title,
                  style: TextStyle(
                    fontSize: OpsType.lg,
                    fontWeight: OpsType.semibold,
                    color: OpsColors.text,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${runs.length} run${runs.length == 1 ? '' : 's'}',
                  style: TextStyle(
                    fontSize: OpsType.xs,
                    fontFamily: OpsType.mono,
                    color: OpsColors.text3,
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final s in process.steps)
                  _StepColumn(
                    title: s.stepId,
                    subtitle: s.assigneeId,
                    runs: at(s.stepId),
                  ),
                _StepColumn(title: 'Done', subtitle: null, runs: done),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StepColumn extends StatelessWidget {
  const _StepColumn({
    required this.title,
    required this.subtitle,
    required this.runs,
  });

  final String title;
  final String? subtitle;
  final List<ProcessRun> runs;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 190,
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: OpsColors.text.withValues(alpha: 0.03),
        border: Border.all(color: OpsColors.textMute.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: OpsType.sm,
              fontWeight: OpsType.semibold,
              color: OpsColors.text2,
            ),
          ),
          if (subtitle != null)
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: OpsType.xs,
                fontFamily: OpsType.mono,
                color: OpsColors.text3,
              ),
            ),
          const SizedBox(height: 6),
          if (runs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '—',
                style: TextStyle(color: OpsColors.textMute),
              ),
            ),
          for (final r in runs) _RunCard(run: r),
        ],
      ),
    );
  }
}

class _RunCard extends StatelessWidget {
  const _RunCard({required this.run});

  final ProcessRun run;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (run.state) {
      ProcessRunState.waitingApproval => (
          OpsColors.warn,
          '⏳ ${run.pendingApproval?.approverId ?? 'approval'}',
        ),
      ProcessRunState.blocked => (OpsColors.app, 'blocked'),
      ProcessRunState.completed => (OpsColors.textMute, 'completed'),
      ProcessRunState.cancelled => (OpsColors.textMute, 'cancelled'),
      _ => (OpsColors.protocol, 'running'),
    };
    final hhmm =
        '${run.startedAt.hour.toString().padLeft(2, '0')}:'
        '${run.startedAt.minute.toString().padLeft(2, '0')}';
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.8), width: 1.2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            run.runId,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: OpsType.xs,
              fontFamily: OpsType.mono,
              color: OpsColors.text2,
            ),
          ),
          Text(
            '$label · $hhmm',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: OpsType.xs, color: color),
          ),
        ],
      ),
    );
  }
}
