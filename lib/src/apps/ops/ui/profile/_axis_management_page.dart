import 'package:appplayer_studio/builtin_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ops_builtin.dart' show OpsBuiltInApp;
import '../../registries/member_registry.dart' show MemberKind;
import '../../state/providers.dart';

/// Reusable management page body for any 4-axis (skill / profile /
/// philosophy / facts). Renders the workspace-level integrated list — pool
/// seeds and every agent's owned (in-progress) instance side-by-side — and
/// provides per-entry "attach to agent" and "transfer to agent" actions.
///
/// The page is intentionally non-axis-specific: differences (icon, title,
/// empty-state copy) are passed in by the axis-specific page wrapper
/// (`SkillsPage` / `ProfilesPage` / `PhilosophiesPage` / future `FactsPage`).
class AxisManagementPage extends ConsumerWidget {
  const AxisManagementPage({
    super.key,
    required this.axis,
    required this.title,
    required this.icon,
    required this.list,
  });

  final AgentAxis axis;
  final String title;
  final IconData icon;
  final AsyncValue<List<IntegratedAxisEntry>> list;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (entries) {
        final pool = entries.where((e) => e.isPool).toList();
        final owned = entries.where((e) => e.isAgentOwned).toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(icon, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$title · ${pool.length} pool · ${owned.length} attached',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child:
                  entries.isEmpty
                      ? Center(
                        child: Text(
                          'No ${title.toLowerCase()} yet — seed one in the '
                          'workspace pool, then assign it to an agent to start '
                          'evolving an attached instance.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      )
                      : ListView(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        children: [
                          if (pool.isNotEmpty) ...[
                            _SectionHeader(
                              label: 'Pool seeds (${pool.length})',
                            ),
                            for (final e in pool)
                              _EntryRow(entry: e, axis: axis, icon: icon),
                          ],
                          if (owned.isNotEmpty) ...[
                            _SectionHeader(
                              label: 'Attached & evolving (${owned.length})',
                            ),
                            for (final e in owned)
                              _EntryRow(entry: e, axis: axis, icon: icon),
                          ],
                        ],
                      ),
            ),
          ],
        );
      },
    );
  }
}

class _AttachButton extends ConsumerWidget {
  const _AttachButton({
    required this.wsId,
    required this.onAttach,
    this.isTransfer = false,
  });
  final String wsId;
  final Future<void> Function(String agentId) onAttach;

  /// True when the source entry is another agent's owned fork — picking a
  /// target transfers that grown instance rather than forking the pool seed.
  final bool isTransfer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(workspaceMembersProvider(wsId));
    final tip = isTransfer ? 'Transfer to agent…' : 'Attach to agent…';
    final glyph = isTransfer ? Icons.swap_horiz : Icons.add_circle_outline;
    return members.when(
      loading: () => Icon(glyph, color: Colors.grey),
      error:
          (_, __) => const Icon(Icons.error_outline, color: Colors.redAccent),
      data: (list) {
        final agents = list.where((m) => m.kind == MemberKind.agent).toList();
        if (agents.isEmpty) {
          return Icon(glyph, color: Colors.grey);
        }
        return PopupMenuButton<String>(
          tooltip: tip,
          icon: Icon(glyph),
          onSelected: onAttach,
          itemBuilder:
              (_) => [
                for (final m in agents)
                  PopupMenuItem<String>(
                    value: m.id,
                    child: Text(m.displayName),
                  ),
              ],
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _EntryRow extends ConsumerWidget {
  const _EntryRow({
    required this.entry,
    required this.axis,
    required this.icon,
  });

  final IntegratedAxisEntry entry;
  final AgentAxis axis;
  final IconData icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = entry.source;
    final lineageLabel =
        entry.lineage.isEmpty ? null : entry.lineage.join(' → ');
    return ListTile(
      leading: Icon(
        icon,
        color:
            source is AgentForkSource
                ? Theme.of(context).colorScheme.primary
                : null,
      ),
      title: Text(entry.displayLabel),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'source: ${source.encode()}',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          if (lineageLabel != null)
            Text(
              'lineage: $lineageLabel',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
        ],
      ),
      trailing: Builder(
        builder: (context) {
          final wsId = ref.read(activeWorkspaceIdProvider);
          if (wsId == null) {
            return const Icon(Icons.add_circle_outline, color: Colors.grey);
          }
          return _AttachButton(
            wsId: wsId,
            isTransfer: entry.source is AgentForkSource,
            onAttach: (agentId) => _attachToAgent(ref, agentId),
          );
        },
      ),
    );
  }

  Future<void> _attachToAgent(WidgetRef ref, String agentId) async {
    // Live boot init over the (re-boot-stale) ProviderScope override, and
    // best-effort `tryAssign*` (returns false instead of throwing) so an
    // unresolved pool/agent source is a no-op, not an exception. When the
    // source is an `AgentForkSource` this is a transfer (one agent's grown
    // owned fork → another agent); a pool source is a fresh attach.
    final init = OpsBuiltInApp.liveInit ?? ref.read(knowledgeInitProvider)!;
    if (!init.system.isAgentSubsystemActivated) return;
    final source = entry.source;
    switch (axis) {
      case AgentAxis.skill:
        await init.system.agents.tryAssignSkill(agentId, source);
        break;
      case AgentAxis.profile:
        await init.system.agents.tryAssignProfile(agentId, source);
        break;
      case AgentAxis.philosophy:
        await init.system.agents.tryAssignPhilosophy(agentId, source);
        break;
      case AgentAxis.facts:
        // Facts pool source needs a FactQuery — only supported via the
        // dedicated `assignFacts` entry point. Agent-source facts (a
        // transfer) go through `assignFactsFromAgent`.
        if (source is AgentForkSource) {
          await init.system.agents.assignFactsFromAgent(agentId, source);
        }
        break;
    }
  }
}
