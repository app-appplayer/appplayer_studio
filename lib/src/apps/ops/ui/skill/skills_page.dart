import 'package:appplayer_studio/builtin_api.dart' show AgentAxis;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/ops_form.dart';
import '../profile/_axis_management_page.dart';

/// Skills library — app-level catalog across template / workspace / agent
/// scopes. Skills are inherently cross-workspace so there's no scope toggle;
/// this page shows everything the skill registry currently has loaded, with
/// in-place edit/delete for workspace-scoped skills.
class SkillsPage extends ConsumerWidget {
  const SkillsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(skillChangesProvider);
    final init = ref.watch(knowledgeInitProvider);
    final skills = init.skills.list();
    final rows = [...skills]..sort((a, b) => a.id.compareTo(b.id));
    final integrated = ref.watch(integratedAxisProvider(AgentAxis.skill));

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Skills',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('New skill (workspace)'),
                  onPressed:
                      () => _showSkillEditor(
                        context,
                        ref,
                        initialYaml: _skillYamlTemplate,
                        title: 'New skill (workspace scope)',
                      ),
                ),
              ],
            ),
          ),
          const TabBar(
            isScrollable: false,
            tabs: [
              Tab(
                text: 'Pool definitions',
                icon: Icon(Icons.edit_note, size: 16),
              ),
              Tab(
                text: 'Integrated (with attached)',
                icon: Icon(Icons.merge_type, size: 16),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              children: [
                // ── Tab 1: pool definitions (entry to yaml editor) ──────────
                rows.isEmpty
                    ? EmptyState(
                      icon: Icons.flash_on_outlined,
                      headline: 'No skills loaded',
                      hint:
                          'Skills are MCP tool wrappers. Install a Bundle or write a skill yaml in the workspace.',
                      actionLabel: 'Open Bundles',
                      onAction:
                          () =>
                              ref.read(shellRouteProvider.notifier).state =
                                  'bundles',
                    )
                    : ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final s = rows[i];
                        return ListTile(
                          leading: const Icon(Icons.flash_on_outlined),
                          title: Text(s.id),
                          subtitle: Text(
                            '${s.description.isEmpty ? "(no description)" : s.description}'
                            '${s.tags.isEmpty ? "" : " · ${s.tags.join(", ")}"}',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('v${s.version}'),
                              PopupMenuButton<String>(
                                onSelected:
                                    (action) => _handleSkillAction(
                                      context,
                                      ref,
                                      s.id,
                                      action,
                                    ),
                                itemBuilder:
                                    (_) => const [
                                      PopupMenuItem(
                                        height: 32,
                                        value: 'edit-ws',
                                        child: Text('Edit workspace scope'),
                                      ),
                                      PopupMenuDivider(),
                                      PopupMenuItem(
                                        height: 32,
                                        value: 'delete-ws',
                                        child: Text(
                                          'Delete workspace scope',
                                          style: TextStyle(color: Colors.red),
                                        ),
                                      ),
                                    ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                // ── Tab 2: integrated view (pool seed + assigned agent owned) ──
                AxisManagementPage(
                  axis: AgentAxis.skill,
                  title: 'Skills',
                  icon: Icons.flash_on_outlined,
                  list: integrated,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleSkillAction(
    BuildContext context,
    WidgetRef ref,
    String skillId,
    String action,
  ) async {
    if (action == 'edit-ws') {
      final existing = ref.read(knowledgeInitProvider).skills.get(skillId);
      final initialYaml =
          existing == null
              ? _skillYamlTemplate.replaceFirst('my-skill', skillId)
              : 'id: ${existing.id}\nversion: ${existing.version}\n'
                  'description: "${existing.description}"\n'
                  '${existing.tags.isEmpty ? "" : "tags:\n${existing.tags.map((t) => "  - $t").join("\n")}\n"}'
                  '# Edit the full YAML directly, then save.\n';
      await _showSkillEditor(
        context,
        ref,
        initialYaml: initialYaml,
        title: 'Edit skill · $skillId (save to workspace scope)',
      );
    } else if (action == 'delete-ws') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Delete skill'),
              content: Text(
                'Delete $skillId from the workspace scope. '
                '(The app-bundled template scope is unaffected.)',
              ),
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
      if (confirmed != true) return;
      final init = ref.read(knowledgeInitProvider);
      final result = await init.skillExecutor.callHostToolJson('skill_delete', {
        'id': skillId,
        'scope': 'workspace',
      });
      if (result['error'] != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: ${result['error']}')),
        );
      }
    }
  }
}

const _skillYamlTemplate = '''id: my-skill
version: 1
description: "Short one-line description"
tags: []
inputSchema:
  type: object
  properties: {}
outputSchema:
  type: object
  properties: {}
actionBody:
  kind: prompt
  steps:
    - role: system
      content: "System message"
    - role: user
      content: "\${input}"
''';

/// Form schema covers the metadata sections only (id / version /
/// description / tags). Deeply structured `actionBody` / `inputSchema` /
/// `outputSchema` stay in YAML — toggle Advanced to edit them.
const List<OpsField> _skillSchema = [
  OpsField(
    name: 'id',
    type: OpsFieldType.text,
    label: 'ID',
    required: true,
    placeholder: 'unique-skill-id',
  ),
  OpsField(
    name: 'version',
    type: OpsFieldType.number,
    label: 'Version',
    required: true,
    placeholder: '1',
  ),
  OpsField(
    name: 'description',
    type: OpsFieldType.multiline,
    label: 'Description',
    lines: 2,
  ),
  OpsField(
    name: 'tags',
    type: OpsFieldType.array,
    label: 'Tags',
    description: 'Free-form labels',
  ),
];

Future<void> _showSkillEditor(
  BuildContext context,
  WidgetRef ref, {
  required String initialYaml,
  required String title,
}) async {
  final ctrl = TextEditingController(text: initialYaml);
  Map<String, dynamic> formValue = parseYamlToMap(initialYaml);
  int viewMode = 0;

  await showDialog<void>(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder:
              (ctx, setState) => AlertDialog(
                title: Text(title),
                content: SizedBox(
                  width: 680,
                  height: 560,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
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
                      if (viewMode == 0)
                        Expanded(
                          child: SingleChildScrollView(
                            child: OpsYamlEditor(
                              value: formValue,
                              partialSchema: _skillSchema,
                              onChanged: (v) => setState(() => formValue = v),
                            ),
                          ),
                        )
                      else
                        Expanded(
                          child: TextField(
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
                      // OpsYamlEditor edits the full structure (including
                      // actionBody / schemas), so the form value is the source
                      // of truth in form mode.
                      final yamlText =
                          viewMode == 0 ? mapToYaml(formValue) : ctrl.text;
                      final init = ref.read(knowledgeInitProvider);
                      final result = await init.skillExecutor.callHostToolJson(
                        'skill_save',
                        {'yaml': yamlText, 'scope': 'workspace'},
                      );
                      if (result['error'] != null) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(
                              content: Text('Save failed: ${result['error']}'),
                            ),
                          );
                        }
                        return;
                      }
                      if (context.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('Save'),
                  ),
                ],
              ),
        ),
  );
}
