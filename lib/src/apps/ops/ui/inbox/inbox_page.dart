import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/inbox_query.dart';
import '../../init/knowledge_init.dart';
import '../../state/providers.dart';

/// Inbox — the human work queue. Surfaces what is waiting for a person:
///   * **Approvals** — process runs parked on an approval gate. The gate's
///     designated approver (or an org-ancestor, via escalation) acts here.
///   * **Tasks** — `skillId: human` steps a person must do, then submit.
///
/// Mirrors [pendingApprovals] / [pendingTasks] (the same source the
/// `approvals_pending` / `tasks_pending` MCP tools use — UI + wiring only, no
/// logic of its own). Acting only advances that one run; other work keeps
/// running.
class InboxPage extends ConsumerStatefulWidget {
  const InboxPage({super.key});

  @override
  ConsumerState<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends ConsumerState<InboxPage> {
  int _gen = 0;
  void _reload() => setState(() => _gen++);

  Future<
    ({List<Map<String, dynamic>> approvals, List<Map<String, dynamic>> tasks})
  >
  _load(KnowledgeInit init) async {
    final approvals = await pendingApprovals(init);
    final tasks = await pendingTasks(init);
    return (approvals: approvals, tasks: tasks);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(processChangesProvider);
    final init = ref.watch(knowledgeInitProvider);
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Inbox · waiting for a person',
                  style: theme.textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: _reload,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: FutureBuilder(
            key: ValueKey(_gen),
            future: _load(init),
            builder: (_, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final data = snap.data;
              final approvals = data?.approvals ?? const [];
              final tasks = data?.tasks ?? const [];
              if (approvals.isEmpty && tasks.isEmpty) {
                return const Center(child: Text('Nothing waiting.'));
              }
              return ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                children: [
                  _SectionHeader(
                    icon: Icons.how_to_reg_outlined,
                    label: 'Approvals (${approvals.length})',
                  ),
                  for (final a in approvals)
                    _ApprovalCard(entry: a, init: init, onDone: _reload),
                  const SizedBox(height: 16),
                  _SectionHeader(
                    icon: Icons.assignment_ind_outlined,
                    label: 'Tasks (${tasks.length})',
                  ),
                  for (final t in tasks)
                    _TaskCard(entry: t, init: init, onDone: _reload),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(label, style: theme.textTheme.titleSmall),
        ],
      ),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({
    required this.entry,
    required this.init,
    required this.onDone,
  });
  final Map<String, dynamic> entry;
  final KnowledgeInit init;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final approver = entry['requiredApprover']?.toString() ?? '';
    final escalation = entry['viaEscalation'] == true;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: const Icon(Icons.how_to_reg_outlined),
        title: Text('${entry['processId']} · after ${entry['afterStep']}'),
        subtitle: Text(
          'approver: $approver'
          '${escalation ? '  (escalation)' : ''}'
          '\nworkspace: ${entry['workspace']}',
          style: theme.textTheme.bodySmall,
        ),
        isThreeLine: true,
        trailing: FilledButton(
          onPressed: () async {
            try {
              await init.registries.process.approve(
                entry['runId'] as String,
                approverId: approver,
              );
            } catch (_) {
              // Surface nothing fancy here — the row refreshes either way.
            }
            onDone();
          },
          child: const Text('Approve'),
        ),
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.entry,
    required this.init,
    required this.onDone,
  });
  final Map<String, dynamic> entry;
  final KnowledgeInit init;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final assignee = entry['assignee']?.toString() ?? '';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: const Icon(Icons.assignment_ind_outlined),
        title: Text('${entry['processId']} · ${entry['stepId']}'),
        subtitle: Text(
          '${entry['task']}\nassignee: $assignee · workspace: ${entry['workspace']}',
          style: theme.textTheme.bodySmall,
        ),
        isThreeLine: true,
        trailing: FilledButton.tonal(
          onPressed: () => _submit(context, assignee),
          child: const Text('Submit'),
        ),
      ),
    );
  }

  /// Capture the person's work (a result / notes) before completing the step.
  /// The result is recorded under `<stepId>_result` in the run state so later
  /// steps and guards can read what the person produced.
  Future<void> _submit(BuildContext context, String assignee) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text('Submit · ${entry['stepId']}'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry['task']?.toString() ?? '',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: ctrl,
                    maxLines: 4,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Result / notes (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Submit'),
              ),
            ],
          ),
    );
    if (ok != true) return;
    try {
      await init.registries.process.submitStep(
        entry['runId'] as String,
        entry['stepId'] as String,
        by: assignee,
        result: ctrl.text.trim().isEmpty ? null : ctrl.text.trim(),
      );
    } catch (_) {
      // ignore — refresh reflects the new state.
    }
    onDone();
  }
}
