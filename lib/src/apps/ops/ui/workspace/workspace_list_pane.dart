import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../registries/bundle_registry.dart';
import '../../registries/workspace_registry.dart';
import '../../state/providers.dart';

class WorkspaceListPane extends ConsumerWidget {
  const WorkspaceListPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wsAsync = ref.watch(workspaceListProvider);
    final activeId = ref.watch(activeWorkspaceIdProvider);

    return Column(
      children: [
        const ListTile(
          dense: true,
          title: Text(
            'Workspaces',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: wsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Error: $e')),
            data: (list) {
              if (list.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'No workspaces yet.\nCreate one with the button below.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                );
              }
              return ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final ws = list[i];
                  final hasMeta =
                      (ws.parentId?.isNotEmpty ?? false) ||
                      ws.shares.isNotEmpty;
                  return ListTile(
                    leading: Icon(_iconFor(ws.type)),
                    title: Text(ws.title),
                    isThreeLine: hasMeta,
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(ws.id, style: const TextStyle(fontSize: 11)),
                        if (hasMeta)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 3,
                              children: [
                                // Org hierarchy (G2): the parent this reports to.
                                if (ws.parentId?.isNotEmpty ?? false)
                                  _MetaChip(
                                    icon: Icons.arrow_upward,
                                    label: ws.parentId!,
                                  ),
                                // Formal shares (G4): scopes exposed to others.
                                for (final s in ws.shares)
                                  _MetaChip(
                                    icon: Icons.ios_share,
                                    label: '${s.toWorkspaceId}:${s.scope}',
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                    selected: ws.id == activeId,
                    onTap: () async {
                      await ref
                          .read(knowledgeInitProvider)
                          .switchWorkspace(ws.id);
                      ref.read(activeWorkspaceIdProvider.notifier).state =
                          ws.id;
                    },
                    trailing: PopupMenuButton<String>(
                      tooltip: 'Edit',
                      onSelected:
                          (action) =>
                              _handleTileAction(context, ref, ws, action),
                      itemBuilder:
                          (_) => const [
                            PopupMenuItem(
                              height: 32,
                              value: 'edit',
                              child: Text('Edit'),
                            ),
                            PopupMenuItem(
                              height: 32,
                              value: 'rename',
                              child: Text('Rename (slug)'),
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
                  );
                },
              );
            },
          ),
        ),
        const Divider(height: 1),
        SizedBox(
          height: 48,
          child: Center(
            child: TextButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('New workspace'),
              onPressed: () => _showCreationDialog(context, ref),
            ),
          ),
        ),
      ],
    );
  }

  IconData _iconFor(WorkspaceType t) => switch (t) {
    WorkspaceType.org => Icons.apartment,
    WorkspaceType.personal => Icons.person,
    WorkspaceType.project => Icons.flag_outlined,
  };

  Future<void> _handleTileAction(
    BuildContext context,
    WidgetRef ref,
    Workspace ws,
    String action,
  ) async {
    switch (action) {
      case 'edit':
        await _showEditDialog(context, ref, ws);
        break;
      case 'rename':
        await _showRenameDialog(context, ref, ws);
        break;
      case 'delete':
        await _showDeleteDialog(context, ref, ws);
        break;
    }
  }

  Future<void> _showEditDialog(
    BuildContext context,
    WidgetRef ref,
    Workspace ws,
  ) async {
    final titleCtrl = TextEditingController(text: ws.title);
    final localeCtrl = TextEditingController(text: ws.locale);
    final tzCtrl = TextEditingController(text: ws.timezone);
    final tagsCtrl = TextEditingController(
      text: ws.tags.entries.map((e) => '${e.key}=${e.value}').join(', '),
    );
    await showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text('Edit workspace · ${ws.id}'),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: titleCtrl,
                    decoration: const InputDecoration(labelText: 'title'),
                  ),
                  TextField(
                    controller: localeCtrl,
                    decoration: const InputDecoration(
                      labelText: 'locale (e.g. ko)',
                    ),
                  ),
                  TextField(
                    controller: tzCtrl,
                    decoration: const InputDecoration(
                      labelText: 'timezone (e.g. Asia/Seoul)',
                    ),
                  ),
                  TextField(
                    controller: tagsCtrl,
                    decoration: const InputDecoration(
                      labelText: 'tags (k=v, k=v ...)',
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
                  final tags = <String, String>{};
                  for (final part in tagsCtrl.text.split(',')) {
                    final p = part.trim();
                    if (p.isEmpty) continue;
                    final eq = p.indexOf('=');
                    if (eq <= 0) continue;
                    tags[p.substring(0, eq).trim()] =
                        p.substring(eq + 1).trim();
                  }
                  await opsCallTool(ref, 'workspace_update', <String, dynamic>{
                    'id': ws.id,
                    if (titleCtrl.text.trim().isNotEmpty)
                      'title': titleCtrl.text.trim(),
                    if (localeCtrl.text.trim().isNotEmpty)
                      'locale': localeCtrl.text.trim(),
                    if (tzCtrl.text.trim().isNotEmpty)
                      'timezone': tzCtrl.text.trim(),
                    'tags': tags,
                  });
                  if (context.mounted) Navigator.pop(ctx);
                },
                child: const Text('Save'),
              ),
            ],
          ),
    );
  }

  Future<void> _showRenameDialog(
    BuildContext context,
    WidgetRef ref,
    Workspace ws,
  ) async {
    final currentSlug = ws.id.contains('/') ? ws.id.split('/').last : ws.id;
    final slugCtrl = TextEditingController(text: currentSlug);
    await showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text('Change slug · ${ws.id}'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'New id: ${ws.type.name}/<slug>',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  TextField(
                    controller: slugCtrl,
                    decoration: const InputDecoration(labelText: 'New slug'),
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
                  final newSlug = slugCtrl.text.trim();
                  if (newSlug.isEmpty || newSlug == currentSlug) {
                    Navigator.pop(ctx);
                    return;
                  }
                  final newId = '${ws.type.name}/$newSlug';
                  try {
                    await ref
                        .read(knowledgeInitProvider)
                        .registries
                        .workspace
                        .rename(ws.id, newId);
                    if (context.mounted) Navigator.pop(ctx);
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Rename failed: $e')),
                      );
                    }
                  }
                },
                child: const Text('Change'),
              ),
            ],
          ),
    );
  }

  Future<void> _showDeleteDialog(
    BuildContext context,
    WidgetRef ref,
    Workspace ws,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Delete workspace'),
            content: Text(
              'Delete ${ws.id}.\n'
              'Both the directory and the KV partition are removed. This cannot be undone.',
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
    await opsCallTool(ref, 'workspace_delete', <String, dynamic>{'id': ws.id});
  }

  Future<void> _showCreationDialog(BuildContext context, WidgetRef ref) async {
    final slugCtrl = TextEditingController();
    final titleCtrl = TextEditingController();
    WorkspaceType type = WorkspaceType.project;
    final selectedBundles = <String>{};
    List<Bundle> bundles = const [];

    try {
      bundles = await ref.read(bundleListProvider.future);
    } catch (_) {
      // If bundle listing fails we still let the user create an empty workspace.
    }
    if (!context.mounted) return;

    await showDialog(
      context: context,
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, setState) => AlertDialog(
                  title: const Text('New workspace'),
                  content: SizedBox(
                    width: 520,
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        DropdownButtonFormField<WorkspaceType>(
                          value: type,
                          decoration: const InputDecoration(labelText: 'Type'),
                          items:
                              WorkspaceType.values
                                  .map(
                                    (t) => DropdownMenuItem(
                                      value: t,
                                      child: Text(t.name),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (v) => setState(() => type = v ?? type),
                        ),
                        TextField(
                          controller: slugCtrl,
                          decoration: const InputDecoration(labelText: 'slug'),
                        ),
                        TextField(
                          controller: titleCtrl,
                          decoration: const InputDecoration(labelText: 'title'),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Bundles to install right after creation (multi-select; empty if none)',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        if (bundles.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              '(no installable bundles)',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ...bundles
                            .where((b) => b.supports(type))
                            .map(
                              (b) => CheckboxListTile(
                                title: Text('${b.name}  (${b.id})'),
                                subtitle: Text(
                                  'v${b.version} — ${b.description}',
                                ),
                                value: selectedBundles.contains(b.id),
                                onChanged:
                                    (v) => setState(() {
                                      if (v == true) {
                                        selectedBundles.add(b.id);
                                      } else {
                                        selectedBundles.remove(b.id);
                                      }
                                    }),
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
                        final result = await opsCallTool(
                          ref,
                          'workspace_create',
                          <String, dynamic>{
                            'type': type.name,
                            'slug': slugCtrl.text,
                            'title':
                                titleCtrl.text.isEmpty
                                    ? slugCtrl.text
                                    : titleCtrl.text,
                          },
                        );
                        final newWsId = result['id'] as String?;
                        // No `id` means the tool reported a soft error (e.g. no
                        // project bound) — leave the dialog open, mirroring the
                        // old throw-before-pop behaviour.
                        if (newWsId == null) return;
                        for (final id in selectedBundles) {
                          await opsCallTool(
                            ref,
                            'bundle_install',
                            <String, dynamic>{
                              'bundleId': id,
                              'workspaceId': newWsId,
                            },
                          );
                        }
                        ref.invalidate(workspaceListProvider);
                        ref.invalidate(installedBundlesProvider(newWsId));
                        if (context.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('Create'),
                    ),
                  ],
                ),
          ),
    );
  }
}

/// Compact metadata badge for a workspace tile — org parent (↑) and formal
/// share grants (→). Read straight off the `Workspace` (G2 `parentId` / G4
/// `shares`); no async, no logic.
class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: c.primary),
          const SizedBox(width: 3),
          Text(label, style: const TextStyle(fontSize: 10)),
        ],
      ),
    );
  }
}
