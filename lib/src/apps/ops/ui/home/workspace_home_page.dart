import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../registries/member_registry.dart' as reg show Member, AgentMember;
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/ops_activity_row.dart';
import '../../widgets/ops_atoms.dart';
import '../../widgets/ops_kpi_tile.dart';
import '../../widgets/ops_knowledge_card.dart';
import '../../widgets/ops_member_row.dart';
import '../../widgets/ops_models.dart';
import '../../widgets/ops_pipeline_node.dart';
import '../../widgets/process_flow_view.dart';

/// Workspace landing page. KPI strip, activity feed, member roster +
/// pipeline preview, and a knowledge band. All counts and entries
/// derive from live registries — no design-system mock fallback
/// (the `OpsFixtures` showcase was deleted with `ops_mocks.dart`).
class WorkspaceHomePage extends ConsumerWidget {
  const WorkspaceHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wsId = ref.watch(activeWorkspaceIdProvider);
    final taskCount =
        wsId == null
            ? 0
            : ref
                .watch(workspaceTasksProvider(wsId))
                .maybeWhen(data: (l) => l.length, orElse: () => 0);
    final processCount =
        wsId == null
            ? 0
            : ref
                .watch(workspaceProcessesProvider(wsId))
                .maybeWhen(data: (l) => l.length, orElse: () => 0);
    final memberCount =
        wsId == null
            ? 0
            : ref
                .watch(workspaceMembersProvider(wsId))
                .maybeWhen(data: (l) => l.length, orElse: () => 0);

    final factCount = ref
        .watch(knowledgeCountsProvider)
        .maybeWhen(data: (c) => c.facts, orElse: () => 0);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(),
            const SizedBox(height: 22),
            _KpiRow(
              tasks: taskCount,
              processes: processCount,
              members: memberCount,
              facts: factCount,
            ),
            const SizedBox(height: 24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 14, child: _ActivityCard()),
                const SizedBox(width: 12),
                Expanded(
                  flex: 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _MembersCard(memberCount: memberCount),
                      const SizedBox(height: 12),
                      _PipelinePreviewCard(),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _KnowledgeBandCard(),
          ],
        ),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  Future<void> _showFilterMenu(BuildContext buttonContext) async {
    // Position the menu just below the actual button widget (not the
    // header row), so it appears next to the Filter button.
    final box = buttonContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    final overlay =
        Overlay.of(buttonContext).context.findRenderObject() as RenderBox;
    final topRight = box.localToGlobal(
      box.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final picked = await showMenu<String>(
      context: buttonContext,
      position: RelativeRect.fromLTRB(
        topRight.dx - 200,
        topRight.dy + 4,
        topRight.dx,
        topRight.dy + 4,
      ),
      items: const [
        PopupMenuItem(height: 32, value: '24h', child: Text('Last 24 hours')),
        PopupMenuItem(height: 32, value: '7d', child: Text('Last 7 days')),
        PopupMenuItem(height: 32, value: '30d', child: Text('Last 30 days')),
        PopupMenuDivider(),
        PopupMenuItem(height: 32, value: 'all', child: Text('All time')),
      ],
    );
    if (picked != null && buttonContext.mounted) {
      ScaffoldMessenger.of(buttonContext).showSnackBar(
        SnackBar(
          content: Text(
            'Filter: $picked',
            style: const TextStyle(fontFamily: OpsType.mono),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const OpsCrumb('Workspace'),
            const SizedBox(height: 4),
            Text('Home', style: Theme.of(context).textTheme.displayMedium),
          ],
        ),
        const Spacer(),
        Builder(
          builder:
              (btnCtx) => OutlinedButton.icon(
                onPressed: () => _showFilterMenu(btnCtx),
                icon: const Icon(Icons.filter_list, size: 14),
                label: const Text('Filter'),
              ),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed:
              () => ref.read(shellRouteProvider.notifier).state = 'tasks',
          icon: const Icon(Icons.add, size: 14),
          label: const Text('New task'),
        ),
      ],
    );
  }
}

class _KpiRow extends StatelessWidget {
  const _KpiRow({
    required this.tasks,
    required this.processes,
    required this.members,
    required this.facts,
  });
  final int tasks;
  final int processes;
  final int members;
  final int facts;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: OpsKpiTile(label: 'Open tasks', value: '$tasks')),
        const SizedBox(width: 12),
        Expanded(
          child: OpsKpiTile(label: 'Running processes', value: '$processes'),
        ),
        const SizedBox(width: 12),
        Expanded(child: OpsKpiTile(label: 'Members online', value: '$members')),
        const SizedBox(width: 12),
        Expanded(child: OpsKpiTile(label: 'Facts captured', value: '$facts')),
      ],
    );
  }
}

class _ActivityCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(activityFilterProvider);
    final async = ref.watch(recentActivityProvider);
    return async.when(
      loading:
          () => OpsCard(
            header: const OpsCardHeader(
              title: 'Recent activity',
              sub: 'derived from workspace state',
              trailing: _ActivityFilters(),
            ),
            body: const _LoadingText(),
          ),
      error:
          (e, _) => OpsCard(
            header: const OpsCardHeader(title: 'Recent activity'),
            body: _EmptyText('Error: $e'),
          ),
      data: (entries) {
        final filtered =
            entries.where((row) {
              switch (filter) {
                case ActorKindFilter.all:
                  return true;
                case ActorKindFilter.agents:
                  return row.actorKind == 'agent';
                case ActorKindFilter.humans:
                  return row.actorKind == 'human';
                case ActorKindFilter.processes:
                  return row.actorKind == 'process';
              }
            }).toList();
        return OpsCard(
          header: const OpsCardHeader(
            title: 'Recent activity',
            sub: 'derived from workspace state',
            trailing: _ActivityFilters(),
          ),
          flushBody: true,
          body:
              filtered.isEmpty
                  ? Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                    child: Text(
                      'No matching activity for this filter',
                      style: TextStyle(
                        fontFamily: OpsType.mono,
                        fontSize: 11,
                        color: OpsColors.text3,
                      ),
                    ),
                  )
                  : Column(
                    children: [
                      for (var i = 0; i < filtered.length; i++)
                        InkWell(
                          onTap:
                              () =>
                                  ref.read(shellRouteProvider.notifier).state =
                                      filtered[i].route,
                          child: OpsActivityRow(
                            actor: ActivityActor(
                              kind: _kindFor(filtered[i].actorKind),
                              label: filtered[i].actorLabel,
                            ),
                            headline: TextSpan(
                              children: [
                                TextSpan(
                                  text: filtered[i].actorLabel,
                                  style: const TextStyle(
                                    fontWeight: OpsType.semibold,
                                  ),
                                ),
                                const TextSpan(text: ' · '),
                                TextSpan(text: filtered[i].headline),
                              ],
                            ),
                            meta: filtered[i].meta,
                            isLast: i == filtered.length - 1,
                          ),
                        ),
                    ],
                  ),
        );
      },
    );
  }
}

ActorKind _kindFor(String tag) => switch (tag) {
  'agent' => ActorKind.agent,
  'human' => ActorKind.human,
  'process' => ActorKind.process,
  _ => ActorKind.agent,
};

class _ActivityFilters extends ConsumerWidget {
  const _ActivityFilters();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activityFilterProvider);
    final entries = <({ActorKindFilter value, String label})>[
      (value: ActorKindFilter.all, label: 'All'),
      (value: ActorKindFilter.agents, label: 'Agents'),
      (value: ActorKindFilter.humans, label: 'Humans'),
      (value: ActorKindFilter.processes, label: 'Processes'),
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final e in entries)
          _FilterChip(
            label: e.label,
            selected: e.value == active,
            onTap:
                () => ref.read(activityFilterProvider.notifier).state = e.value,
          ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = selected ? OpsColors.accentSoft : Colors.transparent;
    final border = selected ? OpsColors.accent : OpsColors.border;
    final fg = selected ? OpsColors.accent : OpsColors.text2;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        hoverColor: OpsColors.surface2,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: OpsType.mono,
              fontSize: 10,
              fontWeight: selected ? OpsType.semibold : OpsType.regular,
              color: fg,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ),
    );
  }
}

class _MembersCard extends ConsumerWidget {
  const _MembersCard({required this.memberCount});
  final int memberCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wsId = ref.watch(activeWorkspaceIdProvider);
    void goToMembers() =>
        ref.read(shellRouteProvider.notifier).state = 'members';

    if (wsId == null) {
      return OpsCard(
        header: const OpsCardHeader(title: 'Members'),
        body: const _EmptyText('Select a workspace'),
      );
    }
    final async = ref.watch(workspaceMembersProvider(wsId));
    return async.when(
      loading:
          () => OpsCard(
            header: const OpsCardHeader(title: 'Members'),
            body: const _LoadingText(),
          ),
      error:
          (e, _) => OpsCard(
            header: const OpsCardHeader(title: 'Members'),
            body: _EmptyText('Error: $e'),
          ),
      data: (members) {
        if (members.isEmpty) {
          return OpsCard(
            header: const OpsCardHeader(title: 'Members'),
            body: const _EmptyText('No members yet'),
          );
        }
        final rows = members.take(6).map(_toMemberSummary).toList();
        return OpsCard(
          header: OpsCardHeader(title: 'Members', sub: '$memberCount total'),
          flushBody: true,
          body: Column(
            children: [
              for (var i = 0; i < rows.length; i++)
                OpsMemberRow(
                  member: rows[i],
                  isLast: i == rows.length - 1,
                  onTap: goToMembers,
                ),
            ],
          ),
        );
      },
    );
  }
}

MemberSummary _toMemberSummary(reg.Member m) {
  final isAgent = m is reg.AgentMember;
  return MemberSummary(
    actor: ActivityActor(
      kind: isAgent ? ActorKind.agent : ActorKind.human,
      label: m.displayName,
    ),
    name: m.displayName,
    subtitle: isAgent ? '${(m).skillIds.length} skills · ${m.id}' : m.id,
    kind: isAgent ? MemberKind.ai : MemberKind.human,
    online: isAgent,
    layerProgress: const [1.0, 0.5, 0.2],
  );
}

class _EmptyText extends StatelessWidget {
  const _EmptyText(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 16),
      child: Center(
        child: Text(
          text,
          style: TextStyle(
            fontFamily: OpsType.mono,
            fontSize: 11,
            color: OpsColors.text3,
          ),
        ),
      ),
    );
  }
}

class _LoadingText extends StatelessWidget {
  const _LoadingText();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _PipelinePreviewCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wsId = ref.watch(activeWorkspaceIdProvider);
    void goToProcesses() =>
        ref.read(shellRouteProvider.notifier).state = 'processes';
    void notify(String msg) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg, style: const TextStyle(fontFamily: OpsType.mono)),
          duration: const Duration(seconds: 2),
        ),
      );
    }

    if (wsId == null) {
      return OpsCard(
        header: const OpsCardHeader(title: 'Process'),
        body: const _EmptyText('Select a workspace'),
      );
    }
    final async = ref.watch(workspaceProcessesProvider(wsId));
    return async.when(
      loading:
          () => OpsCard(
            header: const OpsCardHeader(title: 'Process'),
            body: const _LoadingText(),
          ),
      error:
          (e, _) => OpsCard(
            header: const OpsCardHeader(title: 'Process'),
            body: _EmptyText('Error: $e'),
          ),
      data: (procs) {
        if (procs.isEmpty) {
          return OpsCard(
            header: const OpsCardHeader(title: 'Process'),
            body: const _EmptyText('No processes yet'),
          );
        }
        final p = procs.first;
        final steps = stepsForProcess(p);
        final stateLabel =
            '${p.steps.length} steps · '
            '${p.trigger.name}'
            '${p.gates.isEmpty ? "" : " · ${p.gates.length} gates"}';
        return OpsCard(
          header: OpsCardHeader(
            title: 'Process · ${p.title}',
            sub: stateLabel,
            trailing: TextButton(
              onPressed: goToProcesses,
              child: const Text('Open'),
            ),
          ),
          flushBody: true,
          body: Column(
            children: [
              for (var i = 0; i < steps.length; i++)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Column(
                    children: [
                      OpsPipelineNode(
                        step: steps[i],
                        onApprove:
                            () => notify('Gate approved · ${steps[i].name}'),
                        onReject:
                            () => notify('Gate rejected · ${steps[i].name}'),
                      ),
                      if (i < steps.length - 1) const OpsPipelineConnector(),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }
}

// Process → pipeline step mapping moved to `widgets/process_flow_view.dart`
// (`stepsForProcess`), shared with the Work/process page.

class _KnowledgeBandCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void goToKnowledge() =>
        ref.read(shellRouteProvider.notifier).state = 'knowledge';
    final async = ref.watch(recentKvFactsProvider);
    final entries = async.maybeWhen(
      data: (facts) {
        if (facts.isEmpty) return const <KnowledgeEntry>[];
        return [
          for (final f in facts.take(3))
            KnowledgeEntry(
              kind: KnowledgeKind.fact,
              title: f.value.toString(),
              body: 'category: ${f.category} · key: ${f.key}',
              meta: () {
                final ts = f.savedAt;
                if (ts is String && ts.isNotEmpty) {
                  return 'saved ${ts.length >= 16 ? ts.substring(0, 16) : ts}';
                }
                if (ts is DateTime) {
                  return 'saved ${ts.toIso8601String().substring(0, 16)}';
                }
                return '—';
              }(),
            ),
        ];
      },
      orElse: () => const <KnowledgeEntry>[],
    );
    if (entries.isEmpty) {
      return OpsCard(
        header: const OpsCardHeader(
          title: 'Recent knowledge',
          sub: 'facts · patterns · summaries',
        ),
        body: const _EmptyText('No knowledge entries yet'),
      );
    }
    return OpsCard(
      header: const OpsCardHeader(
        title: 'Recent knowledge',
        sub: 'facts · patterns · summaries',
      ),
      body: Row(
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            Expanded(
              child: OpsKnowledgeCard(entry: entries[i], onTap: goToKnowledge),
            ),
            if (i < entries.length - 1) const SizedBox(width: 12),
          ],
        ],
      ),
    );
  }
}
