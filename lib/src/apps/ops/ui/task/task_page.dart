import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../registries/task_registry.dart';
import '../../registries/workspace_registry.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_with_action.dart';

/// Task list. Scope is driven by [globalScopeProvider] (the shell-level
/// globe toggle). The header chip mirrors and can also flip the same
/// provider.
class TaskPage extends ConsumerWidget {
  const TaskPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final globalScope = ref.watch(globalScopeProvider);
    final wsId = ref.watch(activeWorkspaceIdProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  globalScope
                      ? 'Tasks · All'
                      : 'Tasks · ${wsId ?? "none selected"}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              _ScopeToggle(
                value: globalScope,
                onChanged:
                    (v) => ref.read(globalScopeProvider.notifier).state = v,
              ),
              const SizedBox(width: 12),
              if (!globalScope && wsId != null)
                FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('New task'),
                  onPressed: () => _showCreateDialog(context, ref, wsId),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child:
              globalScope
                  ? const _GlobalTaskList()
                  : const _WorkspaceTaskList(),
        ),
      ],
    );
  }
}

class _ScopeToggle extends StatelessWidget {
  const _ScopeToggle({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message:
          value
              ? 'Switch to current workspace only'
              : 'Switch to all workspaces',
      child: FilterChip(
        avatar: Icon(value ? Icons.public : Icons.task_alt_outlined, size: 18),
        label: Text(value ? 'All' : 'This workspace'),
        selected: value,
        onSelected: onChanged,
      ),
    );
  }
}

// --- Workspace-scoped task list ----------------------------------------

class _WorkspaceTaskList extends ConsumerWidget {
  const _WorkspaceTaskList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wsId = ref.watch(activeWorkspaceIdProvider);
    if (wsId == null) {
      return const EmptyState(
        icon: Icons.folder_open_outlined,
        headline: 'Select a workspace',
        hint: 'Pick or create a workspace from the sidebar to see its tasks.',
      );
    }
    final tasksAsync = ref.watch(workspaceTasksProvider(wsId));
    return tasksAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error:
          (e, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: ErrorWithAction(
              message: 'Could not load tasks.',
              detail: '$e',
              actions: [
                ErrorAction(
                  label: 'Retry',
                  icon: Icons.refresh,
                  primary: true,
                  onPressed: () => ref.invalidate(workspaceTasksProvider(wsId)),
                ),
              ],
            ),
          ),
      data: (tasks) {
        if (tasks.isEmpty) {
          return const EmptyState(
            icon: Icons.checklist_outlined,
            headline: 'No tasks yet',
            hint:
                'Create a task from the top-right button — once a task has a skill assigned, agents can pick it up.',
          );
        }
        return ListView.builder(
          itemCount: tasks.length,
          itemBuilder:
              (_, i) => _TaskTile(task: tasks[i], showWorkspace: false),
        );
      },
    );
  }
}

// --- Global task list --------------------------------------------------

class _GlobalTaskList extends ConsumerWidget {
  const _GlobalTaskList();

  Future<List<Task>> _load(dynamic init, List<Workspace> wsList) async {
    final out = <Task>[];
    for (final ws in wsList) {
      final tasks = await init.registries.task.list(wsId: ws.id);
      out.addAll(tasks.cast<Task>());
    }
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(taskChangesProvider);
    final init = ref.watch(knowledgeInitProvider);
    final wsAsync = ref.watch(workspaceListProvider);
    return wsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data:
          (wsList) => FutureBuilder<List<Task>>(
            future: _load(init, wsList),
            builder: (_, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final tasks = snap.data ?? const <Task>[];
              if (tasks.isEmpty) return const Center(child: Text('No tasks'));
              return ListView.builder(
                itemCount: tasks.length,
                itemBuilder:
                    (_, i) => _TaskTile(task: tasks[i], showWorkspace: true),
              );
            },
          ),
    );
  }
}

// --- Task tile ---------------------------------------------------------

class _TaskTile extends ConsumerWidget {
  const _TaskTile({required this.task, required this.showWorkspace});
  final Task task;
  final bool showWorkspace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                  OpsColors.protocol.withValues(alpha: 0.16),
                  OpsColors.surface2,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(
                _iconFor(task.kind),
                size: 16,
                color: OpsColors.accent,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: OpsType.semibold,
                      color: OpsColors.text2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${task.id} · ${task.kind.name} · ${task.state.name}'
                    '${showWorkspace ? " · ws: ${task.workspaceId}" : ""}'
                    '${task.schedule != null ? " · ${task.schedule!.cron}" : ""}'
                    '${task.skillIds.isEmpty ? "" : " · skills: ${task.skillIds.join(", ")}"}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: OpsType.mono,
                      fontSize: 10,
                      color: OpsColors.text3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (task.state != TaskState.inProgress)
              IconButton(
                icon: const Icon(Icons.play_arrow, size: 16),
                tooltip: 'Run',
                onPressed: () async {
                  try {
                    await opsCallTool(ref, 'task_run', <String, dynamic>{
                      'id': task.id,
                    });
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text('Run failed: $e')));
                    }
                  }
                },
              ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz, size: 16),
              onSelected: (action) => _handleAction(context, ref, action),
              itemBuilder:
                  (_) => const [
                    PopupMenuItem(
                      height: 32,
                      value: 'cancel',
                      child: Text('Mark as cancelled'),
                    ),
                    PopupMenuDivider(),
                    PopupMenuItem(
                      height: 32,
                      value: 'delete',
                      child: Text(
                        'Delete',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleAction(
    BuildContext context,
    WidgetRef ref,
    String action,
  ) async {
    if (action == 'cancel') {
      await opsCallTool(ref, 'task_cancel', <String, dynamic>{'id': task.id});
    } else if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Delete task'),
              content: Text('Delete ${task.title}. This cannot be undone.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Delete'),
                ),
              ],
            ),
      );
      if (confirmed == true) {
        await opsCallTool(ref, 'task_delete', <String, dynamic>{'id': task.id});
      }
    }
  }

  IconData _iconFor(TaskKind k) => switch (k) {
    TaskKind.oneOff => Icons.task_alt,
    TaskKind.recurring => Icons.autorenew,
    TaskKind.sustained => Icons.schedule,
  };
}

// --- Create dialog -----------------------------------------------------

Future<void> _showCreateDialog(
  BuildContext context,
  WidgetRef ref,
  String wsId,
) async {
  // Two modes: author a brand-new task, or clone an existing task from
  // any workspace (carries over skills/assignees/inputs/schedule; only
  // id + workspaceId are fresh).
  final idCtrl = TextEditingController();
  final titleCtrl = TextEditingController();
  final descCtrl = TextEditingController();
  final cronCtrl = TextEditingController();
  TaskKind kind = TaskKind.oneOff;
  final selectedSkills = <String>{};
  final selectedAssignees = <String>{};

  final skills = ref.read(appSkillListProvider);
  final members = await ref.read(workspaceMembersProvider(wsId).future);

  // Clone-mode state
  int mode = 0; // 0 = new, 1 = clone
  List<Task> cloneCandidates = const [];
  bool cloneLoaded = false;
  String? selectedSourceId;
  final cloneIdCtrl = TextEditingController();

  Future<void> ensureClones(void Function(void Function()) setState) async {
    if (cloneLoaded) return;
    final init = ref.read(knowledgeInitProvider);
    final wsList = await init.registries.workspace.list();
    final out = <Task>[];
    for (final ws in wsList) {
      final list = await init.registries.task.list(wsId: ws.id);
      out.addAll(list.cast<Task>());
    }
    out.sort(
      (a, b) =>
          '${a.workspaceId}/${a.id}'.compareTo('${b.workspaceId}/${b.id}'),
    );
    setState(() {
      cloneCandidates = out;
      cloneLoaded = true;
    });
  }

  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              title: const Text('Add task'),
              content: SizedBox(
                width: 560,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(
                            value: 0,
                            label: Text('New task'),
                            icon: Icon(Icons.add),
                          ),
                          ButtonSegment(
                            value: 1,
                            label: Text('Clone from existing'),
                            icon: Icon(Icons.copy_outlined),
                          ),
                        ],
                        selected: {mode},
                        onSelectionChanged: (s) {
                          final next = s.first;
                          setState(() => mode = next);
                          if (next == 1) ensureClones(setState);
                        },
                      ),
                    ),
                    if (mode == 0) ...[
                      TextField(
                        controller: idCtrl,
                        decoration: const InputDecoration(
                          labelText: 'id (e.g. daily-report)',
                        ),
                      ),
                      TextField(
                        controller: titleCtrl,
                        decoration: const InputDecoration(labelText: 'title'),
                      ),
                      TextField(
                        controller: descCtrl,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: 'description (optional)',
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<TaskKind>(
                        value: kind,
                        decoration: const InputDecoration(labelText: 'kind'),
                        items:
                            TaskKind.values
                                .map(
                                  (k) => DropdownMenuItem(
                                    value: k,
                                    child: Text(k.name),
                                  ),
                                )
                                .toList(),
                        onChanged: (v) => setState(() => kind = v ?? kind),
                      ),
                      if (kind == TaskKind.recurring)
                        TextField(
                          controller: cronCtrl,
                          decoration: const InputDecoration(
                            labelText: 'cron (e.g. 0 9 * * *)',
                          ),
                        ),
                      const SizedBox(height: 12),
                      const Text(
                        'Skills (one or more)',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      if (skills.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            '(no registered skills)',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ),
                      ...skills.map(
                        (s) => CheckboxListTile(
                          dense: true,
                          title: Text(s),
                          value: selectedSkills.contains(s),
                          onChanged:
                              (v) => setState(() {
                                if (v == true) {
                                  selectedSkills.add(s);
                                } else {
                                  selectedSkills.remove(s);
                                }
                              }),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Assignees (optional)',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      if (members.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            '(no members in this workspace)',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ),
                      ...members.map(
                        (m) => CheckboxListTile(
                          dense: true,
                          title: Text('${m.displayName} · ${m.id}'),
                          subtitle: Text(
                            m.kind.name,
                            style: const TextStyle(fontSize: 11),
                          ),
                          value: selectedAssignees.contains(m.id),
                          onChanged:
                              (v) => setState(() {
                                if (v == true) {
                                  selectedAssignees.add(m.id);
                                } else {
                                  selectedAssignees.remove(m.id);
                                }
                              }),
                        ),
                      ),
                    ] else ...[
                      if (!cloneLoaded)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (cloneCandidates.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            'No existing tasks to clone.',
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                      else ...[
                        DropdownButtonFormField<String>(
                          value: selectedSourceId,
                          decoration: const InputDecoration(
                            labelText: 'Source task (workspace/id)',
                          ),
                          items: [
                            for (final t in cloneCandidates)
                              DropdownMenuItem(
                                value: '${t.workspaceId}::${t.id}',
                                child: Text(
                                  '${t.workspaceId} / ${t.id} — ${t.title}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged:
                              (v) => setState(() => selectedSourceId = v),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: cloneIdCtrl,
                          decoration: const InputDecoration(
                            labelText: 'New id (unique within this workspace)',
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'The source task\'s title, kind, skills, assignees, inputs, and schedule '
                          'are copied as is.',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    if (mode == 0) {
                      if (idCtrl.text.trim().isEmpty ||
                          titleCtrl.text.trim().isEmpty ||
                          selectedSkills.isEmpty) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(
                            content: Text('id, title, and skills are required'),
                          ),
                        );
                        return;
                      }
                      try {
                        await opsCallTool(ref, 'task_create', <String, dynamic>{
                          'id': idCtrl.text.trim(),
                          'kind': kind.name,
                          'title': titleCtrl.text.trim(),
                          if (descCtrl.text.trim().isNotEmpty)
                            'description': descCtrl.text.trim(),
                          'assigneeIds': selectedAssignees.toList(),
                          'skillIds': selectedSkills.toList(),
                          if (kind == TaskKind.recurring &&
                              cronCtrl.text.trim().isNotEmpty)
                            'cron': cronCtrl.text.trim(),
                        });
                        if (context.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text('Create failed: $e')),
                          );
                        }
                      }
                    } else {
                      final srcKey = selectedSourceId;
                      final newId = cloneIdCtrl.text.trim();
                      if (srcKey == null || newId.isEmpty) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(
                            content: Text('Source and new id are required'),
                          ),
                        );
                        return;
                      }
                      final parts = srcKey.split('::');
                      final srcWs = parts[0];
                      final srcId = parts[1];
                      final src = cloneCandidates.firstWhere(
                        (t) => t.workspaceId == srcWs && t.id == srcId,
                      );
                      try {
                        await opsCallTool(ref, 'task_create', <String, dynamic>{
                          'id': newId,
                          'kind': src.kind.name,
                          'title': src.title,
                          if (src.description != null &&
                              src.description!.isNotEmpty)
                            'description': src.description,
                          'assigneeIds': src.assigneeIds,
                          'skillIds': src.skillIds,
                          if (src.inputs.isNotEmpty) 'inputs': src.inputs,
                          if (src.schedule != null) 'cron': src.schedule!.cron,
                          if (src.dueAt != null)
                            'dueAt': src.dueAt!.toIso8601String(),
                        });
                        if (context.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text('Clone failed: $e')),
                          );
                        }
                      }
                    }
                  },
                  child: Text(mode == 0 ? 'Create' : 'Clone'),
                ),
              ],
            );
          },
        ),
  );
}
