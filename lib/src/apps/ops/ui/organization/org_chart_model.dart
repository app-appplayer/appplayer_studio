/// Organization org-chart model + deterministic layout — **event topology**.
///
/// Pure (no Flutter, no providers, no I/O) so the layout is unit testable.
/// The chart is coordination-centric, not a conveyor: a workspace holds one or
/// more **processes** drawn as independent unit cards (with a trigger badge —
/// manual / event / task). Cards are connected by **event edges** when one
/// process's completion triggers another (`triggerSource`); processes with no
/// incoming event sit side by side (parallel). Inside each card the steps are
/// laid out by their `dependsOn` DAG: steps in the same topological level —
/// i.e. with no ordering between them — stack vertically as **parallel
/// branches** instead of a forced left→right line. Approval gates render as a
/// sign-off marker (✓ approver) above the gated step; philosophy / quality
/// gates as an inline charter checkpoint (◇). Agents not used by any process
/// appear in a roster row. Deterministic — no RNG.
library;

import 'dart:ui' show Offset, Rect, Size;

/// The lens the chart is drawn through — same data, different relationships.
///   workflow  → processes: handoff / parallel / event topology.
///   structure → org-unit (workspace) tree + members grouped by role.
///   knowledge → members ↔ owned/referenced skill / profile / philosophy.
enum OrgViewMode { workflow, structure, knowledge }

enum OrgNodeKind {
  workspace,
  process,
  step,
  gate,
  signoff,
  agent,
  role, // role-group header (structure lens)
  knowledge, // skill / profile / philosophy node (knowledge lens)
  more,
}

enum OrgEdgeKind { hierarchy, reports, event, dep, signoff, ownership, containment }

class OrgStepInput {
  const OrgStepInput({
    required this.stepId,
    required this.assigneeId,
    required this.assigneeLabel,
    this.assigneeAgentId,
    this.skillId = '',
    this.dependsOn = const [],
  });
  final String stepId;

  /// Member id (the process YAML's `assigneeId`) — the key used to match a
  /// step's assignee against the workspace roster.
  final String assigneeId;
  final String assigneeLabel;

  /// flowbrain agent id for the detail dialog (`system.agents.getAgent`).
  /// Falls back to [assigneeId] when the assignee isn't a registered agent.
  final String? assigneeAgentId;
  final String skillId;

  /// Step ids this step depends on. Empty ⇒ depends on the textually-previous
  /// step (the default linear chain) — mirrors the behavior compiler. Steps
  /// sharing a level (no ordering) render as parallel branches.
  final List<String> dependsOn;

  String get agentKey =>
      (assigneeAgentId == null || assigneeAgentId!.isEmpty)
          ? assigneeId
          : assigneeAgentId!;
}

/// A gate after [afterStep]. kind = 'approval' | 'philosophy' | 'quality'.
/// Approval gates carry an [approverId]/[approverLabel] (the signer).
class OrgGateInput {
  const OrgGateInput({
    required this.afterStep,
    required this.kind,
    this.approverId,
    this.approverLabel,
    this.approverAgentId,
  });
  final String afterStep;
  final String kind;
  final String? approverId;
  final String? approverLabel;
  final String? approverAgentId;

  String? get approverKey =>
      (approverAgentId == null || approverAgentId!.isEmpty)
          ? approverId
          : approverAgentId;
}

class OrgProcessInput {
  const OrgProcessInput({
    required this.id,
    required this.title,
    this.trigger = 'manual',
    this.triggerSource,
    this.steps = const [],
    this.gates = const [],
  });
  final String id;
  final String title;

  /// 'manual' | 'event' | 'task' — how the process starts.
  final String trigger;

  /// id of the process whose completion auto-starts this one (event chaining).
  final String? triggerSource;
  final List<OrgStepInput> steps;
  final List<OrgGateInput> gates;
}

class OrgAgentInput {
  const OrgAgentInput({
    required this.agentId,
    required this.displayName,
    this.memberId,
    this.role = 'agent',
    this.isAgent = true,
    this.skillRefs = const [],
    this.profileRef,
    this.philosophyRef,
  });
  final String agentId;
  final String displayName;
  final String? memberId;
  final String role;

  /// true = AI agent, false = human (person). Drawn as a 🤖 / 👤 icon.
  final bool isAgent;

  /// Referenced knowledge (the knowledge lens). Quick-display refs carried on
  /// the member; empty when the member references none.
  final List<String> skillRefs;
  final String? profileRef;
  final String? philosophyRef;

  String get memberKey =>
      (memberId == null || memberId!.isEmpty) ? agentId : memberId!;
}

class OrgWsInput {
  const OrgWsInput({
    required this.id,
    required this.title,
    required this.type,
    this.parentId,
    this.leadMemberId,
    this.agents = const [],
    this.processes = const [],
  });
  final String id;
  final String title;
  final String type;
  final String? parentId;

  /// Member id of this org unit's lead (팀장). Drawn at the top of the unit's
  /// hierarchy in the structure lens, with reporting edges to its members.
  final String? leadMemberId;
  final List<OrgAgentInput> agents;
  final List<OrgProcessInput> processes;
}

class OrgNode {
  OrgNode({
    required this.id,
    required this.kind,
    required this.label,
    required this.wsId,
    required this.rect,
    this.sublabel,
    this.agentId,
    this.badge,
    this.processId,
    this.isAgent = true,
    this.isLead = false,
    this.isContainer = false,
  });
  final String id;
  final OrgNodeKind kind;
  final String label;
  final String? sublabel;
  final String wsId;
  final Rect rect;

  /// step / signoff / agent nodes → the agent id for the detail dialog.
  final String? agentId;

  /// process nodes → trigger badge text ('manual' / 'event' / 'task').
  final String? badge;

  /// step / gate / signoff nodes → the owning process id.
  final String? processId;

  /// agent nodes → AI (true) vs human (false), drawn as a 🤖 / 👤 icon.
  final bool isAgent;

  /// agent nodes → this member is the org unit's lead (팀장).
  final bool isLead;

  /// workspace nodes → draw as a framing container enclosing its members
  /// (structure lens) rather than a small header box.
  final bool isContainer;
}

class OrgEdge {
  const OrgEdge({required this.fromId, required this.toId, required this.kind});
  final String fromId;
  final String toId;
  final OrgEdgeKind kind;
}

class OrgChartModel {
  OrgChartModel({required this.nodes, required this.edges, required this.size});
  final List<OrgNode> nodes;
  final List<OrgEdge> edges;
  final Size size;

  OrgNode? hitTest(Offset p) {
    // Reverse order so steps / gates (added after their process card) win over
    // the card body beneath them.
    for (var i = nodes.length - 1; i >= 0; i--) {
      if (nodes[i].rect.contains(p)) return nodes[i];
    }
    return null;
  }
}

abstract class OrgChartMetrics {
  // Generous, consistent rhythm — whitespace is what makes the chart read as
  // composed rather than cramped. Gaps are tuned so labels / sublabels never
  // touch the next element.
  static const double pad = 32; // outer canvas margin
  static const double boxW = 232;
  static const double boxH = 54;
  static const double indentX = 36;
  static const double laneTop = 28; // gap below ws box before first card

  // Process card.
  static const double cardPad = 18; // inner padding around the step grid
  static const double headerH = 36; // title + trigger badge strip
  static const double signoffBandH = 38; // band above steps for sign-off nodes
  static const double cardGapX = 88; // between event-level columns (event arrow)
  static const double cardGapY = 32; // between stacked cards in one level

  // Steps inside a card.
  static const double stepW = 148;
  static const double stepH = 48;
  static const double stepGapX = 52; // between dep levels (dep arrow)
  static const double stepGapY = 22; // between parallel lanes

  static const double gateW = 22; // inline checkpoint diamond

  // Roster / chips.
  static const double rosterGapY = 26;
  static const double chipH = 34;
  static const double chipGapY = 18; // row stride leaves room for the sublabel
  static const double chipGapX = 20;
  static const double bandGapY = 40; // between workspaces

  // Structure / knowledge lenses.
  static const double roleHeaderH = 24;
  static const double roleHeaderGap = 14; // header → first chip row
  static const double roleGapY = 28; // between role groups
  static const int chipsPerRow = 4;
  static const double knowledgeColGapX = 168; // member col → knowledge col
  static const double knowledgeW = 176;
}

/// Build the chart from per-workspace inputs for the given [mode]. Pure +
/// deterministic — same (inputs, mode) → identical geometry.
OrgChartModel buildOrgChartModel(
  List<OrgWsInput> workspaces, {
  OrgViewMode mode = OrgViewMode.workflow,
}) {
  final byId = {for (final w in workspaces) w.id: w};
  final children = <String, List<String>>{};
  final roots = <String>[];
  for (final w in workspaces) {
    final pid = w.parentId;
    if (pid != null && pid.isNotEmpty && byId.containsKey(pid)) {
      (children[pid] ??= []).add(w.id);
    } else {
      roots.add(w.id);
    }
  }
  roots.sort();
  for (final l in children.values) {
    l.sort();
  }
  final ordered = <({String id, int depth})>[];
  void walk(String id, int depth) {
    ordered.add((id: id, depth: depth));
    for (final c in (children[id] ?? const [])) {
      walk(c, depth + 1);
    }
  }

  for (final r in roots) {
    walk(r, 0);
  }

  final nodes = <OrgNode>[];
  final edges = <OrgEdge>[];
  final wsNodeById = <String, OrgNode>{};
  double runningY = OrgChartMetrics.pad;
  double maxRight = OrgChartMetrics.pad + OrgChartMetrics.boxW;

  for (final entry in ordered) {
    final w = byId[entry.id]!;
    final boxX = OrgChartMetrics.pad + entry.depth * OrgChartMetrics.indentX;
    final pid = w.parentId;

    if (mode == OrgViewMode.structure) {
      // Structure lens: the org unit is a framing **container** — lay out its
      // lead + members first, then wrap them in a workspace box whose header
      // strip carries the unit title. Nested units = separate containers
      // joined by hierarchy edges.
      final contentX = boxX + OrgChartMetrics.cardPad;
      final contentTop =
          runningY + OrgChartMetrics.headerH + OrgChartMetrics.cardPad;
      final sband = _layoutStructure(w, contentX, contentTop, nodes, edges);
      final right = sband.right + OrgChartMetrics.cardPad;
      final minRight = boxX + OrgChartMetrics.boxW;
      final containerRight = right < minRight ? minRight : right;
      final containerBottom = sband.bottom + OrgChartMetrics.cardPad;
      final wsNode = OrgNode(
        id: 'ws:${w.id}',
        kind: OrgNodeKind.workspace,
        label: w.title,
        sublabel: '${w.type} · ${w.agents.length} members',
        wsId: w.id,
        isContainer: true,
        rect: Rect.fromLTRB(boxX, runningY, containerRight, containerBottom),
      );
      nodes.add(wsNode);
      wsNodeById[w.id] = wsNode;
      if (pid != null && wsNodeById.containsKey(pid)) {
        edges.add(
          OrgEdge(fromId: 'ws:$pid', toId: wsNode.id, kind: OrgEdgeKind.hierarchy),
        );
      }
      if (containerRight > maxRight) maxRight = containerRight;
      runningY = containerBottom + OrgChartMetrics.bandGapY;
      continue;
    }

    // Workflow / knowledge: small header box, then the band below it.
    final wsNode = OrgNode(
      id: 'ws:${w.id}',
      kind: OrgNodeKind.workspace,
      label: w.title,
      sublabel: '${w.type} · ${w.agents.length} agents · '
          '${w.processes.length} processes',
      wsId: w.id,
      rect: Rect.fromLTWH(
        boxX,
        runningY,
        OrgChartMetrics.boxW,
        OrgChartMetrics.boxH,
      ),
    );
    nodes.add(wsNode);
    wsNodeById[w.id] = wsNode;
    if (pid != null && wsNodeById.containsKey(pid)) {
      edges.add(
        OrgEdge(fromId: 'ws:$pid', toId: wsNode.id, kind: OrgEdgeKind.hierarchy),
      );
    }

    final laneX0 = boxX + OrgChartMetrics.indentX;
    final cardTop = runningY + OrgChartMetrics.boxH + OrgChartMetrics.laneTop;

    final ({double right, double bottom}) band;
    switch (mode) {
      case OrgViewMode.workflow:
        final assignedInProcess = <String>{};
        final pband = _layoutProcesses(
          w,
          laneX0,
          cardTop,
          nodes,
          edges,
          assignedInProcess,
        );
        // Roster — agents not used by any process step (matched by member id).
        final roster = w.agents
            .where((a) => !assignedInProcess.contains(a.memberKey))
            .toList();
        var rb = pband.bottom;
        var rr = pband.right;
        if (roster.isNotEmpty) {
          rb += OrgChartMetrics.rosterGapY;
          for (var i = 0; i < roster.length; i++) {
            final a = roster[i];
            nodes.add(
              OrgNode(
                id: 'ag:${w.id}:${a.agentId}',
                kind: OrgNodeKind.agent,
                label: a.displayName,
                sublabel: a.role,
                wsId: w.id,
                agentId: a.agentId,
                isAgent: a.isAgent,
                rect: Rect.fromLTWH(
                  laneX0,
                  rb + i * (OrgChartMetrics.chipH + OrgChartMetrics.chipGapY),
                  OrgChartMetrics.stepW,
                  OrgChartMetrics.chipH,
                ),
              ),
            );
          }
          rb += roster.length *
              (OrgChartMetrics.chipH + OrgChartMetrics.chipGapY);
          final rosterRight = laneX0 + OrgChartMetrics.stepW;
          if (rosterRight > rr) rr = rosterRight;
        }
        band = (right: rr, bottom: rb);
      case OrgViewMode.knowledge:
        band = _layoutKnowledge(w, laneX0, cardTop, nodes, edges);
      case OrgViewMode.structure:
        band = (right: laneX0, bottom: cardTop); // unreachable (handled above)
    }
    if (band.right > maxRight) maxRight = band.right;
    final y = band.bottom;

    runningY =
        (y > runningY + OrgChartMetrics.boxH ? y : runningY + OrgChartMetrics.boxH) +
        OrgChartMetrics.bandGapY;
  }

  return OrgChartModel(
    nodes: nodes,
    edges: edges,
    size: Size(maxRight + OrgChartMetrics.pad, runningY + OrgChartMetrics.pad),
  );
}

/// Lay out a workspace's processes as event-topology cards starting at
/// ([laneX0], [top]). Appends process / step / gate / signoff nodes and dep /
/// event / signoff edges. Returns the band's right/bottom extent.
({double right, double bottom}) _layoutProcesses(
  OrgWsInput w,
  double laneX0,
  double top,
  List<OrgNode> nodes,
  List<OrgEdge> edges,
  Set<String> assignedInProcess,
) {
  final procs = [...w.processes]..sort((a, b) => a.id.compareTo(b.id));
  if (procs.isEmpty) return (right: laneX0, bottom: top);
  final procById = {for (final p in procs) p.id: p};

  // Event level = depth in the triggerSource chain (root processes = 0).
  final eventLevel = <String, int>{};
  int levelOf(String id, [Set<String>? seen]) {
    final cached = eventLevel[id];
    if (cached != null) return cached;
    final guard = seen ?? <String>{};
    if (!guard.add(id)) return 0; // cycle guard
    final p = procById[id];
    final src = p?.triggerSource;
    final lvl =
        (src != null && src.isNotEmpty && procById.containsKey(src))
            ? levelOf(src, guard) + 1
            : 0;
    eventLevel[id] = lvl;
    return lvl;
  }

  for (final p in procs) {
    levelOf(p.id);
  }

  // Pre-compute each card's size from its step DAG.
  final sizeById = <String, ({double w, double h, Map<String, ({int lvl, int lane})> pos, int levels})>{};
  for (final p in procs) {
    sizeById[p.id] = _cardSize(p);
  }

  // Column (event-level) widths and x offsets.
  final byLevel = <int, List<OrgProcessInput>>{};
  for (final p in procs) {
    (byLevel[eventLevel[p.id]!] ??= []).add(p);
  }
  final levels = byLevel.keys.toList()..sort();
  final colX = <int, double>{};
  var x = laneX0;
  for (final lvl in levels) {
    colX[lvl] = x;
    final colW = byLevel[lvl]!
        .map((p) => sizeById[p.id]!.w)
        .fold<double>(0, (a, b) => a > b ? a : b);
    x += colW + OrgChartMetrics.cardGapX;
  }

  var maxRight = laneX0;
  var maxBottom = top;
  final cardRect = <String, Rect>{};

  for (final lvl in levels) {
    final col = byLevel[lvl]!..sort((a, b) => a.id.compareTo(b.id));
    var cy = top;
    for (final p in col) {
      final sz = sizeById[p.id]!;
      final cx = colX[lvl]!;
      final rect = Rect.fromLTWH(cx, cy, sz.w, sz.h);
      cardRect[p.id] = rect;
      nodes.add(
        OrgNode(
          id: 'pc:${w.id}:${p.id}',
          kind: OrgNodeKind.process,
          label: p.title,
          sublabel: '${p.steps.length} steps',
          badge: p.trigger,
          processId: p.id,
          wsId: w.id,
          rect: rect,
        ),
      );
      _placeSteps(w, p, rect, sz.pos, nodes, edges, assignedInProcess);
      if (rect.right > maxRight) maxRight = rect.right;
      cy = rect.bottom + OrgChartMetrics.cardGapY;
      if (rect.bottom > maxBottom) maxBottom = rect.bottom;
    }
  }

  // Event edges between cards (source completion → triggered process).
  for (final p in procs) {
    final src = p.triggerSource;
    if (src == null || src.isEmpty) continue;
    if (cardRect.containsKey(src) && cardRect.containsKey(p.id)) {
      edges.add(
        OrgEdge(
          fromId: 'pc:${w.id}:$src',
          toId: 'pc:${w.id}:${p.id}',
          kind: OrgEdgeKind.event,
        ),
      );
    }
  }

  return (right: maxRight, bottom: maxBottom);
}

/// Topological level + lane assignment for a process's steps (effective deps:
/// explicit `dependsOn`, else the textually-previous step). Returns card size
/// and per-step (level, lane) cells.
({double w, double h, Map<String, ({int lvl, int lane})> pos, int levels})
    _cardSize(OrgProcessInput p) {
  final stepIds = [for (final s in p.steps) s.stepId];
  final idx = {for (var i = 0; i < p.steps.length; i++) p.steps[i].stepId: i};
  final effDeps = <String, List<String>>{};
  for (var i = 0; i < p.steps.length; i++) {
    final s = p.steps[i];
    if (s.dependsOn.isNotEmpty) {
      effDeps[s.stepId] =
          s.dependsOn.where((d) => idx.containsKey(d)).toList();
    } else {
      effDeps[s.stepId] = i > 0 ? [p.steps[i - 1].stepId] : const [];
    }
  }
  final level = <String, int>{};
  int lvlOf(String id, [Set<String>? seen]) {
    final c = level[id];
    if (c != null) return c;
    final guard = seen ?? <String>{};
    if (!guard.add(id)) return 0;
    final deps = effDeps[id] ?? const [];
    var mx = -1;
    for (final d in deps) {
      final dl = lvlOf(d, guard);
      if (dl > mx) mx = dl;
    }
    final lv = mx + 1;
    level[id] = lv;
    return lv;
  }

  for (final sid in stepIds) {
    lvlOf(sid);
  }
  // Lanes: within each level, order by step index, assign 0,1,2…
  final byLvl = <int, List<String>>{};
  for (final sid in stepIds) {
    (byLvl[level[sid]!] ??= []).add(sid);
  }
  final pos = <String, ({int lvl, int lane})>{};
  var maxLane = 0;
  for (final lvl in byLvl.keys) {
    final col = byLvl[lvl]!..sort((a, b) => idx[a]!.compareTo(idx[b]!));
    for (var i = 0; i < col.length; i++) {
      pos[col[i]] = (lvl: lvl, lane: i);
    }
    if (col.length > maxLane) maxLane = col.length;
  }
  final numLevels = byLvl.isEmpty ? 1 : (byLvl.keys.reduce((a, b) => a > b ? a : b) + 1);
  final lanes = maxLane == 0 ? 1 : maxLane;
  final innerW = numLevels * OrgChartMetrics.stepW + (numLevels - 1) * OrgChartMetrics.stepGapX;
  final innerH = lanes * OrgChartMetrics.stepH + (lanes - 1) * OrgChartMetrics.stepGapY;
  final w = OrgChartMetrics.cardPad * 2 + innerW;
  final h = OrgChartMetrics.headerH + OrgChartMetrics.signoffBandH + innerH + OrgChartMetrics.cardPad;
  return (w: w, h: h, pos: pos, levels: numLevels);
}

/// Place a process's step / gate / signoff nodes inside [card] using the
/// pre-computed (level, lane) cells, and add dep / signoff edges.
void _placeSteps(
  OrgWsInput w,
  OrgProcessInput p,
  Rect card,
  Map<String, ({int lvl, int lane})> pos,
  List<OrgNode> nodes,
  List<OrgEdge> edges,
  Set<String> assignedInProcess,
) {
  final stepsX = card.left + OrgChartMetrics.cardPad;
  final stepsY = card.top + OrgChartMetrics.headerH + OrgChartMetrics.signoffBandH;
  final idx = {for (var i = 0; i < p.steps.length; i++) p.steps[i].stepId: i};

  Rect cellOf(String stepId) {
    final c = pos[stepId] ?? (lvl: 0, lane: 0);
    final x = stepsX + c.lvl * (OrgChartMetrics.stepW + OrgChartMetrics.stepGapX);
    final y = stepsY + c.lane * (OrgChartMetrics.stepH + OrgChartMetrics.stepGapY);
    return Rect.fromLTWH(x, y, OrgChartMetrics.stepW, OrgChartMetrics.stepH);
  }

  final stepRect = <String, Rect>{};
  for (final s in p.steps) {
    assignedInProcess.add(s.assigneeId);
    final r = cellOf(s.stepId);
    stepRect[s.stepId] = r;
    nodes.add(
      OrgNode(
        id: 'st:${w.id}:${p.id}:${s.stepId}',
        kind: OrgNodeKind.step,
        label: s.assigneeLabel,
        sublabel: s.skillId.isEmpty ? null : s.skillId,
        wsId: w.id,
        processId: p.id,
        agentId: s.agentKey,
        rect: r,
      ),
    );
  }

  // Dependency edges (effective deps: explicit else previous step).
  for (var i = 0; i < p.steps.length; i++) {
    final s = p.steps[i];
    final deps = s.dependsOn.isNotEmpty
        ? s.dependsOn.where((d) => idx.containsKey(d))
        : (i > 0 ? [p.steps[i - 1].stepId] : const <String>[]);
    for (final d in deps) {
      edges.add(
        OrgEdge(
          fromId: 'st:${w.id}:${p.id}:$d',
          toId: 'st:${w.id}:${p.id}:${s.stepId}',
          kind: OrgEdgeKind.dep,
        ),
      );
    }
  }

  // Gates.
  final gatesByStep = <String, List<OrgGateInput>>{};
  for (final g in p.gates) {
    (gatesByStep[g.afterStep] ??= []).add(g);
  }
  for (final entry in gatesByStep.entries) {
    final r = stepRect[entry.key];
    if (r == null) continue;
    for (final g in entry.value) {
      if (g.kind == 'approval') {
        final soNode = OrgNode(
          id: 'so:${w.id}:${p.id}:${entry.key}',
          kind: OrgNodeKind.signoff,
          label: '✓ ${g.approverLabel ?? g.approverId ?? 'approver'}',
          wsId: w.id,
          processId: p.id,
          agentId: g.approverKey,
          rect: Rect.fromLTWH(
            r.left,
            r.top - OrgChartMetrics.signoffBandH + 2,
            OrgChartMetrics.stepW,
            OrgChartMetrics.signoffBandH - 8,
          ),
        );
        nodes.add(soNode);
        edges.add(
          OrgEdge(
            fromId: soNode.id,
            toId: 'st:${w.id}:${p.id}:${entry.key}',
            kind: OrgEdgeKind.signoff,
          ),
        );
      } else {
        // philosophy / quality → inline checkpoint diamond at the step's
        // right edge.
        nodes.add(
          OrgNode(
            id: 'gt:${w.id}:${p.id}:${entry.key}',
            kind: OrgNodeKind.gate,
            label: g.kind == 'philosophy' ? 'charter' : g.kind,
            wsId: w.id,
            processId: p.id,
            rect: Rect.fromLTWH(
              r.right - OrgChartMetrics.gateW / 2,
              r.top - OrgChartMetrics.gateW / 2,
              OrgChartMetrics.gateW,
              OrgChartMetrics.gateW,
            ),
          ),
        );
      }
    }
  }
}

/// Structure lens — the org-unit's **hierarchy**: the lead (팀장) on top, the
/// rest of the members in a grid below, joined by reporting edges (lead →
/// member). The unit-of-units hierarchy itself is the workspace tree (drawn by
/// the outer loop's ws boxes + hierarchy edges) — nesting workspaces composes
/// teams into larger units. When no lead is set, falls back to a flat member
/// grid grouped by role.
({double right, double bottom}) _layoutStructure(
  OrgWsInput w,
  double laneX0,
  double top,
  List<OrgNode> nodes,
  List<OrgEdge> edges,
) {
  if (w.agents.isEmpty) return (right: laneX0, bottom: top);

    // A member's role = their PROFILE (the persona axis; profile IS the role).
    // Falls back to the free-text role tag, then 'member'.
    String roleOf(OrgAgentInput a) {
      final pr = a.profileRef;
      if (pr != null && pr.isNotEmpty && pr != 'profiles/default') {
        return pr.replaceFirst('profiles/', '');
      }
      return a.role.isEmpty ? 'member' : a.role;
    }

    OrgNode chip(OrgAgentInput a, Rect rect, {bool isLead = false}) => OrgNode(
          id: 'ag:${w.id}:${a.agentId}',
          kind: OrgNodeKind.agent,
          label: a.displayName,
          // Role = profile (shown under every member; 'lead' prefix on the head).
          sublabel: isLead ? 'lead · ${roleOf(a)}' : roleOf(a),
          wsId: w.id,
          agentId: a.agentId,
          isAgent: a.isAgent,
          isLead: isLead,
          rect: rect,
        );

  OrgAgentInput? lead;
  if (w.leadMemberId != null && w.leadMemberId!.isNotEmpty) {
    for (final a in w.agents) {
      if (a.memberKey == w.leadMemberId) {
        lead = a;
        break;
      }
    }
  }

  // Place the member grid (everything except the lead) and connect to [leadId]
  // when present. Returns the band extent.
  ({double right, double bottom}) grid(
    List<OrgAgentInput> members,
    double gridTop,
    String? leadId,
  ) {
    final sorted = [...members]..sort((a, b) => a.memberKey.compareTo(b.memberKey));
    var maxRight = laneX0;
    for (var i = 0; i < sorted.length; i++) {
      final a = sorted[i];
      final col = i % OrgChartMetrics.chipsPerRow;
      final row = i ~/ OrgChartMetrics.chipsPerRow;
      final x = laneX0 + col * (OrgChartMetrics.stepW + OrgChartMetrics.chipGapX);
      final cy = gridTop + row * (OrgChartMetrics.chipH + OrgChartMetrics.chipGapY);
      final rect = Rect.fromLTWH(x, cy, OrgChartMetrics.stepW, OrgChartMetrics.chipH);
      nodes.add(chip(a, rect));
      if (leadId != null) {
        edges.add(
          OrgEdge(
            fromId: leadId,
            toId: 'ag:${w.id}:${a.agentId}',
            kind: OrgEdgeKind.reports,
          ),
        );
      }
      if (x + OrgChartMetrics.stepW > maxRight) maxRight = x + OrgChartMetrics.stepW;
    }
    final rows = (sorted.length + OrgChartMetrics.chipsPerRow - 1) ~/ OrgChartMetrics.chipsPerRow;
    return (right: maxRight, bottom: gridTop + rows * (OrgChartMetrics.chipH + OrgChartMetrics.chipGapY));
  }

  if (lead != null) {
    final leadV = lead;
    // Members in a SINGLE ROW below the lead — the canonical org-chart shape.
    // A single row means every reporting elbow shares one horizontal bus level
    // (see painter `_reportLine`: lead → down to busY → across → down to each
    // member's top-center), so the connector never crosses a member box. A
    // wrapping grid would route later-row drops through earlier-row boxes.
    // The row can get wide; the canvas pans/zooms.
    final others =
        w.agents.where((a) => a.memberKey != leadV.memberKey).toList()
          ..sort((a, b) => a.memberKey.compareTo(b.memberKey));
    final n = others.length;
    final rowW = n <= 0
        ? OrgChartMetrics.stepW
        : n * OrgChartMetrics.stepW + (n - 1) * OrgChartMetrics.chipGapX;
    // Lead centered over the row.
    final leadX = laneX0 + (rowW - OrgChartMetrics.stepW) / 2;
    nodes.add(chip(
      leadV,
      Rect.fromLTWH(leadX > laneX0 ? leadX : laneX0, top, OrgChartMetrics.stepW, OrgChartMetrics.chipH),
      isLead: true,
    ));
    final rowTop = top + OrgChartMetrics.chipH + OrgChartMetrics.roleGapY;
    final leadId = 'ag:${w.id}:${leadV.agentId}';
    var maxRight = laneX0 + OrgChartMetrics.stepW;
    for (var i = 0; i < n; i++) {
      final a = others[i];
      final x = laneX0 + i * (OrgChartMetrics.stepW + OrgChartMetrics.chipGapX);
      nodes.add(chip(a, Rect.fromLTWH(x, rowTop, OrgChartMetrics.stepW, OrgChartMetrics.chipH)));
      edges.add(OrgEdge(
        fromId: leadId,
        toId: 'ag:${w.id}:${a.agentId}',
        kind: OrgEdgeKind.reports,
      ));
      if (x + OrgChartMetrics.stepW > maxRight) maxRight = x + OrgChartMetrics.stepW;
    }
    final right = maxRight > laneX0 + rowW ? maxRight : laneX0 + rowW;
    return (right: right, bottom: rowTop + OrgChartMetrics.chipH);
  }

  // No lead — flat grid grouped by role (= profile; header + chips).
  final byRole = <String, List<OrgAgentInput>>{};
  for (final a in w.agents) {
    (byRole[roleOf(a)] ??= []).add(a);
  }
  final roles = byRole.keys.toList()..sort();
  var y = top;
  var maxRight = laneX0;
  for (final role in roles) {
    final members = byRole[role]!;
    nodes.add(
      OrgNode(
        id: 'role:${w.id}:$role',
        kind: OrgNodeKind.role,
        label: role,
        sublabel: '${members.length}',
        wsId: w.id,
        rect: Rect.fromLTWH(laneX0, y, OrgChartMetrics.stepW, OrgChartMetrics.roleHeaderH),
      ),
    );
    y += OrgChartMetrics.roleHeaderH + OrgChartMetrics.roleHeaderGap;
    final b = grid(members, y, null);
    if (b.right > maxRight) maxRight = b.right;
    y = b.bottom + OrgChartMetrics.roleGapY;
  }
  return (right: maxRight, bottom: y);
}

/// Knowledge lens — members in a left column, the distinct knowledge they
/// reference (skill / profile / philosophy) in a right column, joined by
/// ownership edges. Surfaces "who carries which capability / doctrine".
({double right, double bottom}) _layoutKnowledge(
  OrgWsInput w,
  double laneX0,
  double top,
  List<OrgNode> nodes,
  List<OrgEdge> edges,
) {
  if (w.agents.isEmpty) return (right: laneX0, bottom: top);
  final members = [...w.agents]..sort((a, b) => a.memberKey.compareTo(b.memberKey));

  // Distinct knowledge nodes, deterministic order: axis then label.
  final refs = <({String axis, String label})>{};
  for (final a in members) {
    for (final s in a.skillRefs) {
      refs.add((axis: 'skill', label: s));
    }
    if (a.profileRef != null && a.profileRef!.isNotEmpty) {
      refs.add((axis: 'profile', label: a.profileRef!));
    }
    if (a.philosophyRef != null && a.philosophyRef!.isNotEmpty) {
      refs.add((axis: 'philosophy', label: a.philosophyRef!));
    }
  }
  final knowledge = refs.toList()
    ..sort((a, b) {
      final c = a.axis.compareTo(b.axis);
      return c != 0 ? c : a.label.compareTo(b.label);
    });
  String knId(({String axis, String label}) k) => 'kn:${w.id}:${k.axis}:${k.label}';

  final knX = laneX0 + OrgChartMetrics.stepW + OrgChartMetrics.knowledgeColGapX;
  final knRect = <String, Rect>{};
  for (var i = 0; i < knowledge.length; i++) {
    final k = knowledge[i];
    final rect = Rect.fromLTWH(
      knX,
      top + i * (OrgChartMetrics.chipH + OrgChartMetrics.chipGapY),
      OrgChartMetrics.knowledgeW,
      OrgChartMetrics.chipH,
    );
    knRect[knId(k)] = rect;
    nodes.add(
      OrgNode(
        id: knId(k),
        kind: OrgNodeKind.knowledge,
        label: k.label,
        sublabel: k.axis,
        wsId: w.id,
        rect: rect,
      ),
    );
  }

  for (var i = 0; i < members.length; i++) {
    final a = members[i];
    final rect = Rect.fromLTWH(
      laneX0,
      top + i * (OrgChartMetrics.chipH + OrgChartMetrics.chipGapY),
      OrgChartMetrics.stepW,
      OrgChartMetrics.chipH,
    );
    nodes.add(
      OrgNode(
        id: 'ag:${w.id}:${a.agentId}',
        kind: OrgNodeKind.agent,
        label: a.displayName,
        wsId: w.id,
        agentId: a.agentId,
        isAgent: a.isAgent,
        rect: rect,
      ),
    );
    final owned = <({String axis, String label})>[
      for (final s in a.skillRefs) (axis: 'skill', label: s),
      if (a.profileRef != null && a.profileRef!.isNotEmpty)
        (axis: 'profile', label: a.profileRef!),
      if (a.philosophyRef != null && a.philosophyRef!.isNotEmpty)
        (axis: 'philosophy', label: a.philosophyRef!),
    ];
    for (final k in owned) {
      if (knRect.containsKey(knId(k))) {
        edges.add(
          OrgEdge(
            fromId: 'ag:${w.id}:${a.agentId}',
            toId: knId(k),
            kind: OrgEdgeKind.ownership,
          ),
        );
      }
    }
  }

  final rows = members.length > knowledge.length ? members.length : knowledge.length;
  final bottom = top + rows * (OrgChartMetrics.chipH + OrgChartMetrics.chipGapY);
  return (right: knX + OrgChartMetrics.knowledgeW, bottom: bottom);
}
