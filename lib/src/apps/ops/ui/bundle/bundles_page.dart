import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../registries/bundle_registry.dart';
import '../../state/providers.dart';

/// Manage bundle installations inside the active workspace.
class BundlesPage extends ConsumerWidget {
  const BundlesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wsId = ref.watch(activeWorkspaceIdProvider);
    if (wsId == null) {
      return const Center(child: Text('Select a workspace'));
    }
    final installed = ref.watch(installedBundlesProvider(wsId));
    final available = ref.watch(bundleListProvider);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Bundles · $wsId',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Install bundle'),
                onPressed: () => _showInstallDialog(context, ref, wsId),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: installed.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Error: $e')),
            data:
                (records) => available.when(
                  loading:
                      () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Center(child: Text('Error: $e')),
                  data: (bundles) {
                    if (records.isEmpty) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No installed bundles.\nAdd one with the Install bundle button.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    }
                    return ListView.builder(
                      itemCount: records.length,
                      itemBuilder: (_, i) {
                        final rec = records[i];
                        Bundle? src;
                        try {
                          src = bundles.firstWhere((b) => b.id == rec.bundleId);
                        } catch (_) {
                          src = null;
                        }
                        return Card(
                          margin: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: ListTile(
                            leading: const Icon(Icons.inventory_2_outlined),
                            title: Text(src?.name ?? rec.bundleId),
                            subtitle: Text(
                              'id=${rec.bundleId} · v${rec.version} · '
                              '${rec.copied.length} files · '
                              '${rec.installedAt.toLocal().toString().split(".").first}',
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: 'Uninstall',
                              onPressed: () async {
                                await ref
                                    .read(knowledgeInitProvider)
                                    .registries
                                    .bundleInstaller
                                    .uninstall(
                                      bundleId: rec.bundleId,
                                      workspaceId: wsId,
                                    );
                                ref.invalidate(installedBundlesProvider(wsId));
                                ref.invalidate(workspaceMembersProvider(wsId));
                                ref.invalidate(workspaceTasksProvider(wsId));
                                ref.invalidate(
                                  workspaceProcessesProvider(wsId),
                                );
                              },
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
          ),
        ),
      ],
    );
  }
}

Future<void> _showInstallDialog(
  BuildContext context,
  WidgetRef ref,
  String wsId,
) async {
  final bundles = await ref.read(bundleListProvider.future);
  if (!context.mounted) return;
  final selected = <String>{};

  await showDialog(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder:
              (ctx, setState) => AlertDialog(
                title: const Text('Select bundles to install (multi-select)'),
                content: SizedBox(
                  width: 480,
                  child: ListView(
                    shrinkWrap: true,
                    children:
                        bundles
                            .map(
                              (b) => CheckboxListTile(
                                title: Text('${b.name}  (${b.id})'),
                                subtitle: Text(
                                  '${b.description}\nTarget: ${b.targetWorkspaceType} · '
                                  'v${b.version}',
                                ),
                                isThreeLine: true,
                                value: selected.contains(b.id),
                                onChanged:
                                    (v) => setState(() {
                                      if (v == true) {
                                        selected.add(b.id);
                                      } else {
                                        selected.remove(b.id);
                                      }
                                    }),
                              ),
                            )
                            .toList(),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () async {
                      final init = ref.read(knowledgeInitProvider);
                      for (final id in selected) {
                        final b = await init.registries.bundle.get(id);
                        if (b == null) continue;
                        await init.registries.bundleInstaller.install(
                          bundle: b,
                          workspaceId: wsId,
                        );
                      }
                      ref.invalidate(installedBundlesProvider(wsId));
                      ref.invalidate(workspaceMembersProvider(wsId));
                      ref.invalidate(workspaceTasksProvider(wsId));
                      ref.invalidate(workspaceProcessesProvider(wsId));
                      if (context.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('Install'),
                  ),
                ],
              ),
        ),
  );
}
