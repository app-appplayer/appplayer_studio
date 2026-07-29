/// Living-org-chart overlay — the real-time layer over the static chart.
///
/// The chart geometry (`orgChartInputsProvider` → `buildOrgChartModel`)
/// rebuilds only on registry mutations; activity lives in stores that emit
/// NO change tick (FactGraph facts, KV process runs), so this layer is
/// fed by a polling provider instead (see `orgOverlayProvider`) and is
/// resolved against the chart inputs here.
library;

import 'package:mcp_bundle/mcp_bundle.dart' as bundle;

import '../../core/inbox_query.dart';
import '../../init/knowledge_init.dart';
import 'org_chart_model.dart';

/// How recent an `agent.invoked` fact must be to count as "working now".
const Duration kOrgWorkingWindow = Duration(seconds: 120);

/// How recent an `agent.routed` fact must be to draw a delegation edge.
const Duration kOrgRouteWindow = Duration(seconds: 90);

/// Raw per-poll snapshot (store ids, unresolved).
class OrgOverlayData {
  const OrgOverlayData({
    this.workingAgentIds = const <String>{},
    this.outputTodayByUnit = const <String, int>{},
    this.pendingByUnit = const <String, int>{},
    this.routes = const <OrgRouteEvent>[],
  });

  /// `content.agentId` values of `agent.invoked` facts inside the window.
  final Set<String> workingAgentIds;

  /// wsId → count of `agent.invoked` facts since local midnight.
  final Map<String, int> outputTodayByUnit;

  /// wsId → waiting-approval process runs.
  final Map<String, int> pendingByUnit;

  /// Recent `agent.routed` facts (delegation from→to).
  final List<OrgRouteEvent> routes;
}

class OrgRouteEvent {
  const OrgRouteEvent({
    required this.fromId,
    required this.toId,
    required this.wsId,
    required this.at,
  });

  /// Bare member id or qualified agent id, as recorded by `agent_route`.
  final String fromId;
  final String toId;
  final String wsId;
  final DateTime at;
}

/// One poll over existing read APIs — no new collection beyond the
/// `agent.routed` fact `agent_route` now writes.
Future<OrgOverlayData> pollOrgOverlay(KnowledgeInit init) async {
  final now = DateTime.now();
  final midnight = DateTime(now.year, now.month, now.day);
  final working = <String>{};
  final outputToday = <String, int>{};
  final routes = <OrgRouteEvent>[];

  final wsList = await init.registries.workspace.list();
  for (final ws in wsList) {
    List<bundle.FactRecord> invoked;
    try {
      invoked = await init.registries.knowledge.query(
        '',
        typeFilter: 'agent.invoked',
        workspaceId: ws.id,
        limit: 300,
      );
    } catch (_) {
      continue; // unbound / mid-switch — skip this unit for the tick
    }
    for (final f in invoked) {
      if (f.type != 'agent.invoked') continue;
      final agentId = f.content['agentId'];
      if (agentId is! String || agentId.isEmpty) continue;
      final at = f.createdAt;
      if (at.isAfter(midnight)) {
        outputToday[ws.id] = (outputToday[ws.id] ?? 0) + 1;
      }
      if (now.difference(at) <= kOrgWorkingWindow) working.add(agentId);
    }
    try {
      final routed = await init.registries.knowledge.query(
        '',
        typeFilter: 'agent.routed',
        workspaceId: ws.id,
        limit: 50,
      );
      for (final f in routed) {
        if (f.type != 'agent.routed') continue;
        if (now.difference(f.createdAt) > kOrgRouteWindow) continue;
        final from = f.content['fromAgentId'];
        final to = f.content['targetAgentId'];
        if (from is! String || to is! String) continue;
        routes.add(
          OrgRouteEvent(fromId: from, toId: to, wsId: ws.id, at: f.createdAt),
        );
      }
    } catch (_) {
      // Route trail is decoration — a failed read never blocks the tick.
    }
  }

  final pending = <String, int>{};
  try {
    for (final a in await pendingApprovals(init)) {
      final wsId = a['workspace'];
      if (wsId is String) pending[wsId] = (pending[wsId] ?? 0) + 1;
    }
  } catch (_) {
    // Same: badge decoration only.
  }

  return OrgOverlayData(
    workingAgentIds: working,
    outputTodayByUnit: outputToday,
    pendingByUnit: pending,
    routes: routes,
  );
}

/// Overlay resolved to chart-node ids — what the painter consumes.
class OrgChartOverlay {
  const OrgChartOverlay({
    this.pendingByUnit = const <String, int>{},
    this.outputTodayByUnit = const <String, int>{},
    this.activeNodeIds = const <String>{},
    this.routeEdges = const <OrgRouteEdge>[],
  });

  final Map<String, int> pendingByUnit;
  final Map<String, int> outputTodayByUnit;

  /// Chart node ids (`ag:<ws>:<agentId>`) with activity inside the window.
  final Set<String> activeNodeIds;
  final List<OrgRouteEdge> routeEdges;

  bool get isEmpty =>
      pendingByUnit.isEmpty &&
      outputTodayByUnit.isEmpty &&
      activeNodeIds.isEmpty &&
      routeEdges.isEmpty;
}

class OrgRouteEdge {
  const OrgRouteEdge({
    required this.fromNodeId,
    required this.toNodeId,
    required this.strength,
  });

  final String fromNodeId;
  final String toNodeId;

  /// 1.0 = just happened → 0.0 = window edge (drives arrow fade).
  final double strength;
}

/// Resolve store ids to chart node ids. Route facts carry bare member ids
/// (the caller's terms — see `agent_route`), invocation facts carry
/// qualified agent ids; both are joined through the chart inputs, which
/// hold `memberId` AND `agentId` per chip.
OrgChartOverlay resolveOrgOverlay(
  List<OrgWsInput> inputs,
  OrgOverlayData raw, {
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  // (wsId, bare-or-qualified id) → node id, plus a global fallback keyed on
  // the qualified agent id (a route may name an agent outside its own unit).
  final inUnit = <String, String>{};
  final global = <String, String>{};
  for (final ws in inputs) {
    for (final a in ws.agents) {
      final nodeId = 'ag:${ws.id}:${a.agentId}';
      inUnit['${ws.id}|${a.agentId}'] = nodeId;
      final m = a.memberId;
      if (m != null && m.isNotEmpty) inUnit['${ws.id}|$m'] = nodeId;
      global.putIfAbsent(a.agentId, () => nodeId);
      if (m != null && m.isNotEmpty) global.putIfAbsent(m, () => nodeId);
    }
  }

  final active = <String>{
    for (final id in raw.workingAgentIds)
      if (global[id] != null) global[id]!,
  };

  final edges = <OrgRouteEdge>[];
  for (final r in raw.routes) {
    final from = inUnit['${r.wsId}|${r.fromId}'] ?? global[r.fromId];
    final to = inUnit['${r.wsId}|${r.toId}'] ?? global[r.toId];
    if (from == null || to == null || from == to) continue;
    final age = at.difference(r.at).inMilliseconds /
        kOrgRouteWindow.inMilliseconds;
    edges.add(
      OrgRouteEdge(
        fromNodeId: from,
        toNodeId: to,
        strength: (1.0 - age).clamp(0.15, 1.0),
      ),
    );
  }

  return OrgChartOverlay(
    pendingByUnit: raw.pendingByUnit,
    outputTodayByUnit: raw.outputTodayByUnit,
    activeNodeIds: active,
    routeEdges: edges,
  );
}
