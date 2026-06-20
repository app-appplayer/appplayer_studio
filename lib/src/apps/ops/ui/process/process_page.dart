import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../registries/process_registry.dart';
import '../../registries/workspace_registry.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../ops_builtin.dart' show OpsBuiltInApp;
import '../../widgets/ops_form.dart';
import '../../widgets/process_flow_view.dart';

const _processYamlTemplate = '''id: my-process
title: "My Process"
trigger: manual
steps:
  - stepId: step-1
    assigneeId: agent-id
    skillId: skill-id
    inputs: {}
gates: []
''';

/// Process list. Scope is driven by [globalScopeProvider] (the shell-level
/// globe toggle). The header chip mirrors and can also flip the same
/// provider.
class ProcessPage extends ConsumerWidget {
  const ProcessPage({super.key});

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
                      ? 'Processes · All'
                      : 'Processes · ${wsId ?? "none selected"}',
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
                  label: const Text('Add process'),
                  onPressed:
                      () => _showYamlEditor(
                        context,
                        ref,
                        wsId,
                        initialYaml: _processYamlTemplate,
                        title: 'Add process (YAML)',
                        enableClone: true,
                      ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child:
              globalScope
                  ? const _GlobalProcessList()
                  : const _WorkspaceProcessList(),
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
        avatar: Icon(
          value ? Icons.public : Icons.account_tree_outlined,
          size: 18,
        ),
        label: Text(value ? 'All' : 'This workspace'),
        selected: value,
        onSelected: onChanged,
      ),
    );
  }
}

class _WorkspaceProcessList extends ConsumerWidget {
  const _WorkspaceProcessList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wsId = ref.watch(activeWorkspaceIdProvider);
    if (wsId == null) return const Center(child: Text('Select a workspace'));
    final processesAsync = ref.watch(workspaceProcessesProvider(wsId));
    return processesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (processes) {
        if (processes.isEmpty) {
          return const Center(
            child: Text('No processes · create one from the top right'),
          );
        }
        return ListView.builder(
          itemCount: processes.length,
          itemBuilder:
              (_, i) => _ProcessTile(
                process: processes[i],
                wsId: wsId,
                showWorkspace: false,
              ),
        );
      },
    );
  }
}

class _GlobalProcessList extends ConsumerWidget {
  const _GlobalProcessList();

  Future<List<Process>> _load(dynamic init, List<Workspace> wsList) async {
    final out = <Process>[];
    for (final ws in wsList) {
      final list = await init.registries.process.list(wsId: ws.id);
      out.addAll(list.cast<Process>());
    }
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(processChangesProvider);
    final init = ref.watch(knowledgeInitProvider);
    final wsAsync = ref.watch(workspaceListProvider);
    return wsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data:
          (wsList) => FutureBuilder<List<Process>>(
            future: _load(init, wsList),
            builder: (_, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final list = snap.data ?? const <Process>[];
              if (list.isEmpty)
                return const Center(child: Text('No processes'));
              return ListView.builder(
                itemCount: list.length,
                itemBuilder:
                    (_, i) => _ProcessTile(
                      process: list[i],
                      wsId: list[i].workspaceId,
                      showWorkspace: true,
                    ),
              );
            },
          ),
    );
  }
}

class _ProcessTile extends ConsumerWidget {
  const _ProcessTile({
    required this.process,
    required this.wsId,
    required this.showWorkspace,
  });
  final Process process;
  final String wsId;
  final bool showWorkspace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Color.alphaBlend(
                      OpsColors.domain.withValues(alpha: 0.16),
                      OpsColors.surface2,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.account_tree_outlined,
                    size: 16,
                    color: OpsColors.domain,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        process.title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: OpsType.semibold,
                          color: OpsColors.text2,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${process.id} · ${process.steps.length} steps · '
                        '${process.trigger.name}'
                        '${showWorkspace ? " · ws: $wsId" : ""}'
                        '${process.gates.isEmpty ? "" : " · ${process.gates.length} gates"}',
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
                IconButton(
                  icon: const Icon(Icons.play_arrow, size: 16),
                  tooltip: 'Run',
                  onPressed: () async {
                    try {
                      await opsCallTool(ref, 'process_start', <String, dynamic>{
                        'id': process.id,
                      });
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Start failed: $e')),
                        );
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
                          value: 'edit',
                          child: Text('Edit (YAML)'),
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
          if (process.steps.isNotEmpty)
            ProcessFlowView(
              process: process,
              onApprove: (node) => _approveGate(context, ref),
              onReject:
                  (node) => ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Gate rejected · $node')),
                  ),
            ),
        ],
      ),
    );
  }

  /// Approve the process's run that is awaiting approval, via the
  /// `process_approve` tool. The behavior engine resumes from the gate.
  Future<void> _approveGate(BuildContext context, WidgetRef ref) async {
    final init = OpsBuiltInApp.liveInit ?? ref.read(knowledgeInitProvider)!;
    final runs = await init.registries.process.listRuns(process.id);
    final waiting =
        runs.where((r) => r.state == ProcessRunState.waitingApproval).toList();
    if (waiting.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No run is awaiting approval')),
        );
      }
      return;
    }
    final approver =
        (process.gates
                .firstWhere(
                  (g) => g.kind == GateKind.approval,
                  orElse: () => process.gates.first,
                )
                .params['approverId']
            as String?) ??
        'admin';
    await opsCallTool(ref, 'process_approve', <String, dynamic>{
      'runId': waiting.last.runId,
      'approverId': approver,
    });
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Approval submitted')));
    }
  }

  Future<void> _handleAction(
    BuildContext context,
    WidgetRef ref,
    String action,
  ) async {
    final init = ref.read(knowledgeInitProvider);
    if (action == 'edit') {
      final yamlText =
          await init.registries.process.readYaml(wsId, process.id) ?? '';
      if (!context.mounted) return;
      await _showYamlEditor(
        context,
        ref,
        wsId,
        initialYaml: yamlText,
        title: 'Edit process · ${process.id}',
      );
    } else if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Delete process'),
              content: Text('Delete ${process.title}. This cannot be undone.'),
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
        await opsCallTool(ref, 'process_delete', <String, dynamic>{
          'id': process.id,
          'workspaceId': wsId,
        });
      }
    }
  }
}

List<OpsField> _processSchema(WidgetRef ref, String wsId) {
  List<OpsFieldOption> memberOptions() {
    final members = ref
        .read(workspaceMembersProvider(wsId))
        .maybeWhen(data: (l) => l, orElse: () => const []);
    return [
      for (final m in members)
        OpsFieldOption(value: m.id, label: '${m.displayName} · ${m.id}'),
    ];
  }

  List<OpsFieldOption> skillOptions() {
    final ids = ref.read(appSkillListProvider);
    return [for (final id in ids) OpsFieldOption(value: id, label: id)];
  }

  return [
    const OpsField(
      name: 'id',
      type: OpsFieldType.text,
      label: 'ID',
      required: true,
      placeholder: 'unique-process-id',
    ),
    const OpsField(
      name: 'title',
      type: OpsFieldType.text,
      label: 'Title',
      required: true,
    ),
    const OpsField(
      name: 'trigger',
      type: OpsFieldType.select,
      label: 'Trigger',
      required: true,
      options: [
        OpsFieldOption(value: 'manual', label: 'manual'),
        OpsFieldOption(value: 'event', label: 'event'),
        OpsFieldOption(value: 'task', label: 'task'),
      ],
    ),
    OpsField(
      name: 'steps',
      type: OpsFieldType.array,
      label: 'Steps',
      itemSchema: [
        const OpsField(
          name: 'stepId',
          type: OpsFieldType.text,
          label: 'Step ID',
          required: true,
        ),
        OpsField(
          name: 'assigneeId',
          type: OpsFieldType.select,
          label: 'Assignee',
          required: true,
          description: 'Workspace member that owns this step',
          optionsBuilder: memberOptions,
        ),
        OpsField(
          name: 'skillId',
          type: OpsFieldType.select,
          label: 'Skill',
          required: true,
          optionsBuilder: skillOptions,
        ),
        const OpsField(
          name: 'inputs',
          type: OpsFieldType.keyValue,
          label: 'Inputs',
        ),
      ],
    ),
    const OpsField(
      name: 'gates',
      type: OpsFieldType.array,
      label: 'Gates',
      itemSchema: [
        OpsField(
          name: 'afterStep',
          type: OpsFieldType.text,
          label: 'After step',
          required: true,
          description: 'stepId or "*" to match every step',
        ),
        OpsField(
          name: 'kind',
          type: OpsFieldType.select,
          label: 'Kind',
          required: true,
          options: [
            OpsFieldOption(value: 'philosophy', label: 'philosophy'),
            OpsFieldOption(value: 'quality', label: 'quality'),
            OpsFieldOption(value: 'approval', label: 'approval'),
          ],
        ),
        OpsField(name: 'params', type: OpsFieldType.keyValue, label: 'Params'),
      ],
    ),
  ];
}

Future<void> _showYamlEditor(
  BuildContext context,
  WidgetRef ref,
  String wsId, {
  required String initialYaml,
  required String title,
  bool enableClone = false,
}) async {
  final ctrl = TextEditingController(text: initialYaml);
  Map<String, dynamic> formValue = parseYamlToMap(initialYaml);
  int viewMode = 0; // 0 = form, 1 = YAML

  // Clone-mode state (only used when enableClone is true — i.e. on the
  // "new" button, not the "edit existing" flow).
  int mode = 0; // 0 = blank/new, 1 = clone from existing
  List<Process> cloneCandidates = const [];
  bool cloneLoaded = false;
  String? selectedSourceId;

  Future<void> ensureClones(void Function(void Function()) setState) async {
    if (cloneLoaded) return;
    final init = ref.read(knowledgeInitProvider);
    final wsList = await init.registries.workspace.list();
    final out = <Process>[];
    for (final ws in wsList) {
      final list = await init.registries.process.list(wsId: ws.id);
      out.addAll(list.cast<Process>());
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

  Future<void> loadSourceYaml(String srcKey) async {
    final parts = srcKey.split('::');
    final srcWs = parts[0];
    final srcId = parts[1];
    final yaml =
        await ref
            .read(knowledgeInitProvider)
            .registries
            .process
            .readYaml(srcWs, srcId) ??
        '';
    ctrl.text = yaml;
  }

  await showDialog<void>(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              title: Text(title),
              content: SizedBox(
                width: 680,
                height: 560,
                child: Column(
                  children: [
                    if (enableClone)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: SegmentedButton<int>(
                          segments: const [
                            ButtonSegment(
                              value: 0,
                              label: Text('Write new'),
                              icon: Icon(Icons.note_add_outlined),
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
                            if (next == 1) {
                              ensureClones(setState);
                            } else {
                              ctrl.text = _processYamlTemplate;
                            }
                          },
                        ),
                      ),
                    if (enableClone && mode == 1) ...[
                      if (!cloneLoaded)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: LinearProgressIndicator(),
                        )
                      else
                        DropdownButtonFormField<String>(
                          value: selectedSourceId,
                          decoration: const InputDecoration(
                            labelText: 'Source process (workspace/id)',
                          ),
                          items: [
                            for (final p in cloneCandidates)
                              DropdownMenuItem(
                                value: '${p.workspaceId}::${p.id}',
                                child: Text(
                                  '${p.workspaceId} / ${p.id} — ${p.title}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) async {
                            setState(() => selectedSourceId = v);
                            if (v != null) await loadSourceYaml(v);
                            setState(() {});
                          },
                        ),
                      const SizedBox(height: 4),
                      const Text(
                        'The source YAML is loaded. Change the id to a value unique within this workspace before saving.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const SizedBox(height: 8),
                    ],
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(
                            value: 0,
                            label: Text('Form'),
                            icon: Icon(Icons.list_alt_outlined),
                          ),
                          ButtonSegment(
                            value: 1,
                            label: Text('Advanced (YAML)'),
                            icon: Icon(Icons.code),
                          ),
                        ],
                        selected: {viewMode},
                        onSelectionChanged: (s) {
                          final next = s.first;
                          if (next == 1) {
                            ctrl.text = mapToYaml(formValue);
                          } else {
                            formValue = parseYamlToMap(ctrl.text);
                          }
                          setState(() => viewMode = next);
                        },
                      ),
                    ),
                    Expanded(
                      child:
                          viewMode == 0
                              ? SingleChildScrollView(
                                child: OpsYamlEditor(
                                  value: formValue,
                                  partialSchema: _processSchema(ref, wsId),
                                  onChanged:
                                      (v) => setState(() => formValue = v),
                                ),
                              )
                              : TextField(
                                controller: ctrl,
                                maxLines: null,
                                expands: true,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                ),
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  alignLabelWithHint: true,
                                ),
                              ),
                    ),
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
                    try {
                      final yamlText =
                          viewMode == 0 ? mapToYaml(formValue) : ctrl.text;
                      await ref
                          .read(knowledgeInitProvider)
                          .registries
                          .process
                          .saveFromYaml(yamlText, wsId);
                      if (context.mounted) Navigator.pop(ctx);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          SnackBar(content: Text('Save failed: $e')),
                        );
                      }
                    }
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        ),
  );
}
