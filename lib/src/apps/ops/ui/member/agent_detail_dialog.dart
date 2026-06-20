import 'package:appplayer_studio/builtin_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../init/knowledge_init.dart';
import '../../ops_builtin.dart' show OpsBuiltInApp;
import '../../state/providers.dart';
import '../../util/llm_model_catalog.dart';

/// Detail view for one [Agent] — shows the four axis cards (skill /
/// profile / philosophy / facts) listing every owned fork along with the
/// growth counters and the lineage / source label of each entry.
///
/// "Composed by 4-axis units, not by agent unit" — each card surfaces
/// the owned instances (forks this agent currently carries and evolves)
/// and exposes transfer to another agent or detach (unassign) from this
/// agent.
Future<void> showAgentDetailDialog(
  BuildContext context,
  WidgetRef ref, {
  required String agentId,
  required String displayName,
}) async {
  // `showDialog` mounts its builder under the root navigator, which is
  // outside the [ProviderScope] override subtree — `ref.watch` inside the
  // dialog throws `UnimplementedError: KnowledgeInit not yet bootstrapped`.
  // Read the engine handle here (where the override is in scope) and pass
  // it down as a plain prop.
  //
  // Prefer the live boot init over the ProviderScope override: the override
  // is captured at first shell build and goes stale after a `project.open`
  // re-boot. A stale init carries the previous boot's in-memory FactGraph,
  // so lifecycle facts written to the live engine (visible via
  // `knowledge_fact_query`) would render as an empty timeline.
  final init = OpsBuiltInApp.liveInit ?? ref.read(knowledgeInitProvider)!;
  await showDialog<void>(
    context: context,
    builder:
        (ctx) => Dialog(
          child: SizedBox(
            width: 640,
            height: 720,
            child: AgentDetailView(
              init: init,
              agentId: agentId,
              displayName: displayName,
            ),
          ),
        ),
  );
}

class AgentDetailView extends StatelessWidget {
  const AgentDetailView({
    super.key,
    required this.init,
    required this.agentId,
    required this.displayName,
  });

  final KnowledgeInit init;
  final String agentId;
  final String displayName;

  @override
  Widget build(BuildContext context) {
    if (!init.system.isAgentSubsystemActivated) {
      return const Center(child: Text('Agent Subsystem not activated'));
    }
    return FutureBuilder<Agent?>(
      future: init.system.agents.getAgent(agentId),
      builder: (context, snap) {
        final agent = snap.data;
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (agent == null) {
          return Center(
            child: Text('Agent "$agentId" not found in flowbrain registry'),
          );
        }
        return Column(
          children: [
            _Header(agent: agent, displayName: displayName),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  _AxisCard(
                    init: init,
                    agentId: agentId,
                    axis: AgentAxis.skill,
                    title: 'Skills',
                    icon: Icons.flash_on_outlined,
                    count: agent.growth.skillCandidateCount,
                    countLabel: 'candidates',
                  ),
                  const SizedBox(height: 12),
                  _AxisCard(
                    init: init,
                    agentId: agentId,
                    axis: AgentAxis.profile,
                    title: 'Profile',
                    icon: Icons.face_outlined,
                    count: agent.growth.profileAdjustmentCount,
                    countLabel: 'adjustments',
                  ),
                  const SizedBox(height: 12),
                  _AxisCard(
                    init: init,
                    agentId: agentId,
                    axis: AgentAxis.philosophy,
                    title: 'Philosophy',
                    icon: Icons.balance_outlined,
                    count: agent.growth.philosophyRevisionCount,
                    countLabel: 'revisions',
                  ),
                  const SizedBox(height: 12),
                  _AxisCard(
                    init: init,
                    agentId: agentId,
                    axis: AgentAxis.facts,
                    title: 'Facts',
                    icon: Icons.fact_check_outlined,
                    count: agent.growth.factsAccumulationCount,
                    countLabel: 'snapshots',
                  ),
                  const SizedBox(height: 12),
                  _LifecycleTimelineCard(
                    init: init,
                    agentId: agentId,
                    workspaceId: agent.workspaceId,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Reads the agent's lifecycle facts (entityId == agentId) in reverse chrono
/// and renders a compact timeline. Each row carries the fact type, axis (or
/// turn index), and a short detail line. Hosts that disable
/// `recordLifecycleAsFacts` see an empty timeline — that is the contract.
class _LifecycleTimelineCard extends StatelessWidget {
  const _LifecycleTimelineCard({
    required this.init,
    required this.agentId,
    required this.workspaceId,
  });

  final KnowledgeInit init;
  final String agentId;
  final String workspaceId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(Icons.timeline, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Lifecycle timeline',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                Text(
                  '$workspaceId · entityId=$agentId',
                  style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    color: scheme.outline,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          FutureBuilder<List<dynamic>>(
            future: _loadFacts(),
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final facts = snap.data ?? const [];
              if (facts.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No lifecycle facts yet — the agent has not been assigned, '
                    'invoked, or evolved since boot. Either '
                    '`recordLifecycleAsFacts` is disabled in `AgentConfig`, or '
                    'no events have occurred.',
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
                );
              }
              return Column(
                children: [
                  for (final f in facts)
                    _TimelineRow(fact: f as Map<String, dynamic>),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<List<dynamic>> _loadFacts() async {
    try {
      final results = await init.registries.knowledge.query(
        agentId,
        workspaceId: workspaceId,
        entityId: agentId,
        limit: 50,
      );
      // Most recent first.
      final sorted = [...results]
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return [
        for (final r in sorted)
          {'type': r.type, 'createdAt': r.createdAt, 'content': r.content},
      ];
    } catch (_) {
      return const [];
    }
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.fact});
  final Map<String, dynamic> fact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final type = (fact['type'] as String?) ?? '?';
    final content =
        (fact['content'] as Map?)?.cast<String, dynamic>() ?? const {};
    final createdAt = fact['createdAt'] as DateTime;
    final detail = _detailFor(type, content);
    final color = _colorFor(type, scheme);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(top: 6, right: 8),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      type,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: color,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _formatTime(createdAt),
                      style: TextStyle(fontSize: 10, color: scheme.outline),
                    ),
                  ],
                ),
                if (detail.isNotEmpty)
                  Text(detail, style: const TextStyle(fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _detailFor(String type, Map<String, dynamic> content) {
    switch (type) {
      case 'agent.fork.assigned':
        final axis = content['axis'] ?? '';
        final source = content['source'] ?? '';
        return '$axis ← $source';
      case 'agent.fork.evolved':
        final axis = content['axis'] ?? '';
        final kind = content['kind'] ?? '';
        return '$axis · $kind';
      case 'agent.invoked':
        final model = content['model'] ?? '';
        final turn = content['turnIndex'] ?? 0;
        final ok = content['success'] == true ? '✓' : '✗';
        return 'turn $turn · $model $ok';
      case 'agent.deleted':
        return 'agent removed';
      default:
        return '';
    }
  }

  Color _colorFor(String type, ColorScheme scheme) {
    switch (type) {
      case 'agent.fork.assigned':
        return scheme.primary;
      case 'agent.fork.evolved':
        return scheme.tertiary;
      case 'agent.invoked':
        return scheme.secondary;
      case 'agent.deleted':
        return scheme.error;
      default:
        return scheme.outline;
    }
  }

  String _formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '${t.month}/${t.day} $h:$m';
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.agent, required this.displayName});
  final Agent agent;
  final String displayName;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  displayName,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              _RoleChip(role: agent.role),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'id: ${agent.id} · ${_modelLabel(agent.model)} · workspace: ${agent.workspaceId}',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          if (agent.systemPrompt != null && agent.systemPrompt!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                agent.systemPrompt!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _modelLabel(ModelSpec spec) {
  // Render the dropdown label when the (provider, model) pair lives in the
  // catalog ("Claude · Sonnet 4.6"); fall back to "provider/model" for ids
  // typed into the Custom… field or persisted from older configs.
  final provider = findProviderOption(spec.provider);
  final model = findModelOption(spec.provider, spec.model);
  if (provider != null && model != null) {
    return '${provider.label} · ${model.label}';
  }
  return '${spec.provider}/${spec.model}';
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.role});
  final AgentRole role;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (role) {
      AgentRole.manager => scheme.primary,
      AgentRole.reviewer => scheme.tertiary,
      AgentRole.worker => scheme.secondary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(role.name, style: TextStyle(fontSize: 10, color: color)),
    );
  }
}

class _AxisCard extends StatefulWidget {
  const _AxisCard({
    required this.init,
    required this.agentId,
    required this.axis,
    required this.title,
    required this.icon,
    required this.count,
    required this.countLabel,
  });

  final KnowledgeInit init;
  final String agentId;
  final AgentAxis axis;
  final String title;
  final IconData icon;
  final int count;
  final String countLabel;

  @override
  State<_AxisCard> createState() => _AxisCardState();
}

class _AxisCardState extends State<_AxisCard> {
  late Future<List<({String sourceRef, String forkedRef})>> _entriesF;

  @override
  void initState() {
    super.initState();
    _entriesF =
        widget.init.system.agentRegistry == null
            ? Future.value(const [])
            : _loadEntries();
  }

  Future<List<({String sourceRef, String forkedRef})>> _loadEntries() async {
    final reg = widget.init.system.agentRegistry;
    if (reg == null) return const [];
    return reg.listOwned(widget.agentId, widget.axis);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(widget.icon, size: 18),
                const SizedBox(width: 8),
                Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                Text(
                  '${widget.count} ${widget.countLabel}',
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          FutureBuilder<List<({String sourceRef, String forkedRef})>>(
            future: _entriesF,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final entries = snap.data ?? const [];
              if (entries.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No ${widget.title.toLowerCase()} attached. '
                    'Attach from the workspace ${widget.title.toLowerCase()} list.',
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
                );
              }
              return Column(
                children: [
                  for (final e in entries)
                    _OwnedEntryRow(
                      init: widget.init,
                      agentId: widget.agentId,
                      axis: widget.axis,
                      sourceRef: e.sourceRef,
                      forkedRef: e.forkedRef,
                      onDetached:
                          () => setState(() {
                            _entriesF = _loadEntries();
                          }),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _OwnedEntryRow extends StatelessWidget {
  const _OwnedEntryRow({
    required this.init,
    required this.agentId,
    required this.axis,
    required this.sourceRef,
    required this.forkedRef,
    required this.onDetached,
  });

  final KnowledgeInit init;
  final String agentId;
  final AgentAxis axis;
  final String sourceRef;
  final String forkedRef;
  final VoidCallback onDetached;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  forkedRef,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
                Text(
                  'source: $sourceRef',
                  style: TextStyle(fontSize: 10, color: scheme.outline),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Detach (unassign)',
            icon: const Icon(Icons.link_off, size: 16),
            onPressed: () async {
              await init.system.agents.unassign(agentId, axis, forkedRef);
              onDetached();
            },
          ),
        ],
      ),
    );
  }
}
