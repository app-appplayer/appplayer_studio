import 'dart:async';

import '../init/knowledge_init.dart';
import '../registries/process_registry.dart';

/// Shared inbox queries — the single source of truth for "what is waiting for
/// a person". Both the MCP tools (`approvals_pending` / `tasks_pending`) and
/// the Ops Inbox UI page call these, so the surface never re-implements the
/// scan logic (built-in = UI + wiring; the logic lives here next to the data).
///
/// Both scan every workspace's `ws/<wsId>/process_runs/*` partition for runs
/// suspended in `waitingApproval`. The distinction:
///   * an **approval** run carries a `pendingApproval` (a `gate_approval_*`
///     node) — surfaced by [pendingApprovals].
///   * a **human task** run is parked on a `skillId: human` step (its
///     `currentStep` resolves to a real step authored `human`/`manual`) —
///     surfaced by [pendingTasks].

/// Process runs waiting for approval. With [approverId] set, only the runs
/// that principal may act on: the gate's designated approver, plus (org
/// escalation) any gate whose approver is below them in the workspace tree.
Future<List<Map<String, dynamic>>> pendingApprovals(
  KnowledgeInit init, {
  String? approverId,
}) async {
  final workspaces = await init.registries.workspace.list(
    includeReserved: true,
  );
  final pending = <Map<String, dynamic>>[];
  for (final ws in workspaces) {
    final keys = await init.adapters.kv.keys(
      prefix: 'ws/${ws.id}/process_runs/',
    );
    for (final k in keys) {
      final raw = await init.adapters.kv.get(k);
      if (raw is! Map) continue;
      ProcessRun run;
      try {
        run = ProcessRun.fromJson(Map<String, dynamic>.from(raw));
      } catch (_) {
        continue;
      }
      if (run.state != ProcessRunState.waitingApproval) continue;
      final pa = run.pendingApproval;
      if (pa == null) continue;
      var include = approverId == null;
      var viaEscalation = false;
      if (approverId != null) {
        if (approverId == pa.approverId) {
          include = true;
        } else {
          final chain = await init.registries.workspace.ancestors(
            pa.approverId,
          );
          if (chain.contains(approverId)) {
            include = true;
            viaEscalation = true;
          }
        }
      }
      if (!include) continue;
      pending.add({
        'runId': run.runId,
        'processId': run.processId,
        'workspace': run.workspaceId,
        'afterStep': pa.afterStep,
        'requiredApprover': pa.approverId,
        'requestedAt': pa.requestedAt.toIso8601String(),
        if (viaEscalation) 'viaEscalation': true,
      });
    }
  }
  pending.sort(
    (a, b) =>
        (a['requestedAt'] as String).compareTo(b['requestedAt'] as String),
  );
  return pending;
}

/// Human-assigned process steps waiting for their assignee to do the work and
/// `step_submit`. With [assigneeId] set, only that person's tasks.
Future<List<Map<String, dynamic>>> pendingTasks(
  KnowledgeInit init, {
  String? assigneeId,
}) async {
  final workspaces = await init.registries.workspace.list(
    includeReserved: true,
  );
  final tasks = <Map<String, dynamic>>[];
  for (final ws in workspaces) {
    final keys = await init.adapters.kv.keys(
      prefix: 'ws/${ws.id}/process_runs/',
    );
    for (final k in keys) {
      final raw = await init.adapters.kv.get(k);
      if (raw is! Map) continue;
      ProcessRun run;
      try {
        run = ProcessRun.fromJson(Map<String, dynamic>.from(raw));
      } catch (_) {
        continue;
      }
      if (run.state != ProcessRunState.waitingApproval) continue;
      if (run.currentStep.isEmpty) continue;
      final p = await init.registries.process.get(run.processId);
      if (p == null) continue;
      ProcessStep? step;
      for (final s in p.steps) {
        if (s.stepId == run.currentStep) {
          step = s;
          break;
        }
      }
      if (step == null) continue;
      if (step.skillId != 'human' && step.skillId != 'manual') continue;
      if (assigneeId != null && step.assigneeId != assigneeId) continue;
      tasks.add({
        'runId': run.runId,
        'processId': run.processId,
        'workspace': run.workspaceId,
        'stepId': step.stepId,
        'assignee': step.assigneeId,
        'task':
            (step.inputs['task'] ?? step.inputs['message'] ?? step.stepId)
                .toString(),
      });
    }
  }
  return tasks;
}
