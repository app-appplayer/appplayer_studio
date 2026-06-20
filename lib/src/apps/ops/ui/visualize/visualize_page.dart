// 4-axis radar + knowledge graph viewer. PRD §FM-COMPARE-02 / 03.
//
// Two side-by-side surfaces:
//
//   1. Radar — for the selected agent, plot per-axis owned-fork count
//      (skills, profile maturity proxy, philosophy revisions, facts).
//      Custom-painted polygon — no chart dep needed.
//
//   2. Graph — workspace FactGraph rendered as a force-positioned node
//      cloud (deterministic seeded layout to keep frame churn low).

import 'dart:math' as math;

import 'package:appplayer_studio/builtin_api.dart' show AgentAxis;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../registries/member_registry.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';

class VisualizePage extends ConsumerStatefulWidget {
  const VisualizePage({super.key});

  @override
  ConsumerState<VisualizePage> createState() => _VisualizePageState();
}

class _VisualizePageState extends ConsumerState<VisualizePage> {
  String? _agentId;

  @override
  Widget build(BuildContext context) {
    final wsId = ref.watch(activeWorkspaceIdProvider);
    if (wsId == null) {
      return Center(
        child: Text(
          'No active workspace.',
          style: TextStyle(color: OpsColors.text3),
        ),
      );
    }
    final membersAsync = ref.watch(workspaceMembersProvider(wsId));
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Visualize', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            '4-axis radar shows how skills / profile / philosophy / facts have '
            'evolved per agent. The graph below renders the workspace '
            'FactGraph as a node cloud — entity types color-coded.',
            style: TextStyle(color: OpsColors.text2),
          ),
          const SizedBox(height: 12),
          membersAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error:
                (e, _) => Text(
                  'Member list error: $e',
                  style: TextStyle(color: OpsColors.danger),
                ),
            data: (members) {
              final agents = members.whereType<AgentMember>().toList();
              if (agents.isEmpty) {
                return Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No agents in this workspace — radar requires at least one.',
                    style: TextStyle(color: OpsColors.text3),
                  ),
                );
              }
              _agentId ??= agents.first.id;
              return DropdownButtonFormField<String>(
                initialValue: _agentId,
                decoration: const InputDecoration(labelText: 'Agent'),
                items: [
                  for (final a in agents)
                    DropdownMenuItem(value: a.id, child: Text(a.displayName)),
                ],
                onChanged: (v) => setState(() => _agentId = v),
              );
            },
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child:
                      _agentId == null
                          ? const SizedBox.shrink()
                          : _RadarCard(agentId: _agentId!, workspaceId: wsId),
                ),
                const SizedBox(width: 12),
                Expanded(child: _GraphCard(workspaceId: wsId)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RadarCard extends ConsumerWidget {
  const _RadarCard({required this.agentId, required this.workspaceId});
  final String agentId;
  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final init = ref.watch(knowledgeInitProvider);
    if (!init.system.isAgentSubsystemActivated) {
      return _Card(
        title: '4-axis radar',
        child: Center(
          child: Text(
            'Agent subsystem not activated.',
            style: TextStyle(color: OpsColors.text3),
          ),
        ),
      );
    }
    return FutureBuilder<List<int>>(
      future: _loadCounts(init, agentId),
      builder: (ctx, snap) {
        final values = snap.data ?? const [0, 0, 0, 0];
        return _Card(
          title: '4-axis radar — $agentId',
          child: CustomPaint(painter: _RadarPainter(values: values)),
        );
      },
    );
  }

  Future<List<int>> _loadCounts(dynamic init, String agentId) async {
    final agents = init.system.agents;
    int safe(Future<List<dynamic>> f) =>
        0; // helper below assigns from awaited list
    final skillsRaw =
        await agents.listOwned(agentId, AgentAxis.skill) as List<dynamic>;
    final profileRaw =
        await agents.listOwned(agentId, AgentAxis.profile) as List<dynamic>;
    final philoRaw =
        await agents.listOwned(agentId, AgentAxis.philosophy) as List<dynamic>;
    // Facts: query the workspace FactGraph for entityId == agentId — rough
    // proxy for "facts this agent owns"; refine when AgentAxis.facts has a
    // direct facade.
    int factCount = 0;
    try {
      final all = await init.registries.knowledge.query(
        agentId,
        workspaceId: workspaceId,
        limit: 200,
      );
      factCount = all.length;
    } catch (_) {
      /* ignore */
    }
    safe; // silence linter for unused helper
    return [skillsRaw.length, profileRaw.length, philoRaw.length, factCount];
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({required this.values});
  final List<int> values; // [skills, profile, philosophy, facts]

  static const labels = ['skills', 'profile', 'philosophy', 'facts'];

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final radius = math.min(cx, cy) - 36;
    final maxVal = values.fold<int>(0, math.max).clamp(1, 1 << 30);

    final ringPaint =
        Paint()
          ..color = OpsColors.border
          ..style = PaintingStyle.stroke;
    for (var ring = 1; ring <= 4; ring += 1) {
      final r = radius * ring / 4;
      final path = Path();
      for (var i = 0; i < 4; i += 1) {
        final ang = -math.pi / 2 + i * math.pi * 2 / 4;
        final x = cx + r * math.cos(ang);
        final y = cy + r * math.sin(ang);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      path.close();
      canvas.drawPath(path, ringPaint);
    }

    // Spokes + labels.
    final labelStyle = TextStyle(
      fontFamily: OpsType.mono,
      fontSize: 10,
      color: OpsColors.text3,
    );
    for (var i = 0; i < 4; i += 1) {
      final ang = -math.pi / 2 + i * math.pi * 2 / 4;
      final x = cx + radius * math.cos(ang);
      final y = cy + radius * math.sin(ang);
      canvas.drawLine(Offset(cx, cy), Offset(x, y), ringPaint);
      final tp = TextPainter(
        text: TextSpan(text: '${labels[i]}\n${values[i]}', style: labelStyle),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout();
      final lx = cx + (radius + 12) * math.cos(ang) - tp.width / 2;
      final ly = cy + (radius + 12) * math.sin(ang) - tp.height / 2;
      tp.paint(canvas, Offset(lx, ly));
    }

    // Polygon fill.
    final fillPath = Path();
    for (var i = 0; i < 4; i += 1) {
      final ang = -math.pi / 2 + i * math.pi * 2 / 4;
      final r = radius * values[i] / maxVal;
      final x = cx + r * math.cos(ang);
      final y = cy + r * math.sin(ang);
      if (i == 0) {
        fillPath.moveTo(x, y);
      } else {
        fillPath.lineTo(x, y);
      }
    }
    fillPath.close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..color = OpsColors.accent.withValues(alpha: 0.18)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      fillPath,
      Paint()
        ..color = OpsColors.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.values.length != values.length ||
      List.generate(
        values.length,
        (i) => old.values[i] != values[i],
      ).any((b) => b);
}

class _GraphCard extends ConsumerWidget {
  const _GraphCard({required this.workspaceId});
  final String workspaceId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final factsAsync = ref.watch(workspaceFactsProvider(0));
    return _Card(
      title: 'Knowledge graph',
      child: factsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error:
            (e, _) => Center(
              child: Text(
                'Facts query error: $e',
                style: TextStyle(color: OpsColors.danger),
              ),
            ),
        data: (facts) {
          if (facts.isEmpty) {
            return Center(
              child: Text(
                'No facts yet — interact with the workspace to populate.',
                style: TextStyle(color: OpsColors.text3),
              ),
            );
          }
          return CustomPaint(painter: _GraphPainter(facts: facts));
        },
      ),
    );
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter({required this.facts});
  final List<dynamic> facts;

  @override
  void paint(Canvas canvas, Size size) {
    final rng = math.Random(42);
    final positions = <Offset>[];
    final labels = <String>[];
    final colors = <Color>[];
    final colorMap = <String, Color>{};
    final palette = [
      OpsColors.protocol,
      OpsColors.io,
      OpsColors.domain,
      OpsColors.knowledge,
      OpsColors.ui,
      OpsColors.app,
    ];
    for (final f in facts.take(80)) {
      final type =
          (() {
            try {
              return (f as dynamic).type as String? ?? 'fact';
            } catch (_) {
              return 'fact';
            }
          })();
      final label =
          (() {
            try {
              final raw = (f as dynamic).entityId;
              if (raw is String && raw.isNotEmpty) {
                return raw.length > 20 ? '${raw.substring(0, 17)}…' : raw;
              }
            } catch (_) {
              /* ignore */
            }
            return type;
          })();
      labels.add(label);
      colors.add(
        colorMap.putIfAbsent(
          type,
          () => palette[colorMap.length % palette.length],
        ),
      );
      positions.add(
        Offset(rng.nextDouble() * size.width, rng.nextDouble() * size.height),
      );
    }

    // Draw faint edges between adjacent indexes (proxy for relations
    // until a real relation accessor lands on the fact API).
    final edge =
        Paint()
          ..color = OpsColors.border
          ..strokeWidth = 0.5;
    for (var i = 1; i < positions.length; i += 1) {
      canvas.drawLine(positions[i - 1], positions[i], edge);
    }

    final nodePaint = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < positions.length; i += 1) {
      nodePaint.color = colors[i];
      canvas.drawCircle(positions[i], 5, nodePaint);
      final tp = TextPainter(
        text: TextSpan(
          text: labels[i],
          style: TextStyle(
            fontFamily: OpsType.mono,
            fontSize: 9,
            color: OpsColors.text2,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 100);
      tp.paint(canvas, positions[i] + const Offset(7, -4));
    }
  }

  @override
  bool shouldRepaint(_GraphPainter old) => old.facts.length != facts.length;
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: OpsColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: OpsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontFamily: OpsType.sans,
              fontSize: 13,
              fontWeight: OpsType.semibold,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(child: child),
        ],
      ),
    );
  }
}
