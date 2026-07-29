/// "Today's flow" (B4) — the morning briefing as a picture: one horizontal
/// time axis (local midnight → now) with four event lanes bucketed by hour:
/// invocations (mint) · delegations (teal) · approval waits (amber) ·
/// process runs started (blue). Dot size = count. Pure render over existing
/// records — facts and run records emit no change tick, so the card is fed
/// by a poll provider (`todayFlowProvider`).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../init/knowledge_init.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/ops_atoms.dart';

/// Hour-bucketed counts (0-23) per lane, for the active workspace, today.
class TodayFlowData {
  const TodayFlowData({
    this.invoked = const <int, int>{},
    this.routed = const <int, int>{},
    this.approvals = const <int, int>{},
    this.runsStarted = const <int, int>{},
  });

  final Map<int, int> invoked;
  final Map<int, int> routed;
  final Map<int, int> approvals;
  final Map<int, int> runsStarted;

  bool get isEmpty =>
      invoked.isEmpty &&
      routed.isEmpty &&
      approvals.isEmpty &&
      runsStarted.isEmpty;
}

Future<TodayFlowData> pollTodayFlow(KnowledgeInit init, String? wsId) async {
  if (wsId == null) return const TodayFlowData();
  final now = DateTime.now();
  final midnight = DateTime(now.year, now.month, now.day);
  final invoked = <int, int>{};
  final routed = <int, int>{};
  final approvals = <int, int>{};
  final runsStarted = <int, int>{};
  void bump(Map<int, int> lane, DateTime at) {
    final local = at.toLocal();
    if (local.isBefore(midnight)) return;
    lane[local.hour] = (lane[local.hour] ?? 0) + 1;
  }

  try {
    for (final f in await init.registries.knowledge.query(
      '',
      typeFilter: 'agent.invoked',
      workspaceId: wsId,
      limit: 500,
    )) {
      if (f.type == 'agent.invoked') bump(invoked, f.createdAt);
    }
    for (final f in await init.registries.knowledge.query(
      '',
      typeFilter: 'agent.routed',
      workspaceId: wsId,
      limit: 200,
    )) {
      if (f.type == 'agent.routed') bump(routed, f.createdAt);
    }
    final procs = await init.registries.process.list(wsId: wsId);
    for (final p in procs) {
      for (final r in await init.registries.process.listRuns(
        p.id,
        workspaceId: wsId,
      )) {
        bump(runsStarted, r.startedAt);
        final requested = r.pendingApproval?.requestedAt;
        if (requested != null) bump(approvals, requested);
      }
    }
  } catch (_) {
    // Mid-switch/unbound — an empty tick, never an error card.
  }
  return TodayFlowData(
    invoked: invoked,
    routed: routed,
    approvals: approvals,
    runsStarted: runsStarted,
  );
}

class TodayFlowCard extends ConsumerWidget {
  const TodayFlowCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(todayFlowProvider);
    final data = async.value ?? const TodayFlowData();
    final nowHour = DateTime.now().hour;
    return OpsCard(
      header: const OpsCardHeader(
        title: "Today's flow",
        sub: 'invocations · delegations · approvals · runs, by hour',
      ),
      body: data.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No activity yet today.',
                style: TextStyle(color: OpsColors.text3),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Lane(
                  label: 'invoked',
                  color: OpsColors.success,
                  counts: data.invoked,
                  nowHour: nowHour,
                ),
                _Lane(
                  label: 'delegated',
                  color: OpsColors.io,
                  counts: data.routed,
                  nowHour: nowHour,
                ),
                _Lane(
                  label: 'approvals',
                  color: OpsColors.warn,
                  counts: data.approvals,
                  nowHour: nowHour,
                ),
                _Lane(
                  label: 'runs',
                  color: OpsColors.protocol,
                  counts: data.runsStarted,
                  nowHour: nowHour,
                ),
                const SizedBox(height: 4),
                _HourAxis(nowHour: nowHour),
              ],
            ),
    );
  }
}

class _Lane extends StatelessWidget {
  const _Lane({
    required this.label,
    required this.color,
    required this.counts,
    required this.nowHour,
  });

  final String label;
  final Color color;
  final Map<int, int> counts;
  final int nowHour;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 74,
            child: Text(
              label,
              style: TextStyle(
                fontSize: OpsType.xs,
                fontFamily: OpsType.mono,
                color: OpsColors.text3,
              ),
            ),
          ),
          Expanded(
            child: Row(
              children: [
                for (var h = 0; h <= nowHour; h++)
                  Expanded(
                    child: Center(
                      child: _dot(counts[h] ?? 0),
                    ),
                  ),
                // Future hours keep the axis to scale for the whole day.
                for (var h = nowHour + 1; h < 24; h++)
                  const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dot(int count) {
    if (count == 0) {
      return Container(
        width: 3,
        height: 3,
        decoration: BoxDecoration(
          color: OpsColors.textMute.withValues(alpha: 0.25),
          shape: BoxShape.circle,
        ),
      );
    }
    final d = 6.0 + 3.0 * math.min(4, count - 1);
    return Tooltip(
      message: '$count',
      child: Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.85),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _HourAxis extends StatelessWidget {
  const _HourAxis({required this.nowHour});

  final int nowHour;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 74),
        Expanded(
          child: Row(
            children: [
              for (var h = 0; h < 24; h++)
                Expanded(
                  child: h % 6 == 0 || h == nowHour
                      ? Text(
                          h == nowHour ? 'now' : '${h}h',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: OpsType.xs,
                            fontFamily: OpsType.mono,
                            color: h == nowHour
                                ? OpsColors.text2
                                : OpsColors.textMute,
                          ),
                        )
                      : const SizedBox(),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
