/// Node-click detail for the organization org-chart (pipeline flow).
///
/// Routes by node kind: workspace → a summary panel built from the chart
/// model (type · parent · children · process / participant counts + charter +
/// lessons); step / agent / sign-off → the existing `showAgentDetailDialog`
/// (4-axis owned forks + lineage) for the assignee / approver; gate → a compact
/// checkpoint card. Dialogs mount under the root navigator (outside the
/// per-project ProviderScope), so — like `agent_detail_dialog.dart` — we read
/// data once from the model / passed handles and never `ref.watch` inside the
/// dialog.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../init/knowledge_init.dart';
import '../../ops_builtin.dart' show OpsBuiltInApp;
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../member/agent_detail_dialog.dart' show showAgentDetailDialog;
import 'org_chart_model.dart';

Future<void> showOrgNodeDetail(
  BuildContext context,
  WidgetRef ref,
  OrgNode node,
  OrgChartModel model,
) async {
  switch (node.kind) {
    case OrgNodeKind.step:
    case OrgNodeKind.signoff:
    case OrgNodeKind.agent:
      // The assignee / approver behind the node — open the agent detail when
      // it resolves to a flowbrain agent; otherwise a compact card.
      final agentId = node.agentId;
      if (agentId == null || agentId.isEmpty) {
        await _showCardDialog(context, _stepDetail(node));
        return;
      }
      // Strip the sign-off "✓ " prefix from the display name.
      final name = node.label.startsWith('✓ ')
          ? node.label.substring(2)
          : node.label;
      await showAgentDetailDialog(
        context,
        ref,
        agentId: agentId,
        displayName: name,
      );
    case OrgNodeKind.workspace:
      // Dialog mounts under the root navigator (outside the ProviderScope) —
      // read the live init once, pass it down (same rule as agent_detail).
      final init = OpsBuiltInApp.liveInit ?? ref.read(knowledgeInitProvider);
      await _showCardDialog(context, _workspaceDetail(node, model, init));
    case OrgNodeKind.process:
      await _showCardDialog(context, _processDetail(node, model));
    case OrgNodeKind.knowledge:
      await _showCardDialog(context, _knowledgeDetail(node, model));
    case OrgNodeKind.role:
      // Role-group header — no detail dialog (it's a label, not an entity).
      break;
    case OrgNodeKind.gate:
    case OrgNodeKind.more:
      await _showCardDialog(context, _stepDetail(node));
  }
}

Future<void> _showCardDialog(BuildContext context, Widget body) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: OpsColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: OpsRadius.all_md),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(padding: const EdgeInsets.all(OpsSpace.s8), child: body),
      ),
    ),
  );
}

Widget _workspaceDetail(OrgNode node, OrgChartModel model, KnowledgeInit? init) {
  final wsId = node.wsId;
  // Distinct participants = every assignee/approver in the lanes + roster.
  final participants = model.nodes
      .where(
        (n) =>
            n.wsId == wsId &&
            (n.kind == OrgNodeKind.step ||
                n.kind == OrgNodeKind.signoff ||
                n.kind == OrgNodeKind.agent) &&
            (n.agentId?.isNotEmpty ?? false),
      )
      .map((n) => n.agentId!)
      .toSet();
  final processes = model.nodes
      .where((n) => n.kind == OrgNodeKind.process && n.wsId == wsId)
      .map((n) => n.label)
      .toList();
  final gates = model.nodes
      .where((n) => n.kind == OrgNodeKind.gate && n.wsId == wsId)
      .length;
  // Parent / children from hierarchy edges.
  final parent = model.edges
      .where((e) => e.kind == OrgEdgeKind.hierarchy && e.toId == node.id)
      .map((e) => e.fromId.replaceFirst('ws:', ''))
      .join();
  final children = model.edges
      .where((e) => e.kind == OrgEdgeKind.hierarchy && e.fromId == node.id)
      .map((e) => e.toId.replaceFirst('ws:', ''))
      .toList();

  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        node.label,
        style: TextStyle(
          fontSize: OpsType.xxl,
          fontWeight: OpsType.semibold,
          color: OpsColors.text,
        ),
      ),
      const SizedBox(height: OpsSpace.s1),
      Text(
        wsId,
        style: TextStyle(
          fontSize: OpsType.sm,
          fontFamily: OpsType.mono,
          color: OpsColors.text3,
        ),
      ),
      const SizedBox(height: OpsSpace.s6),
      _kv('type', node.sublabel?.split(' · ').first ?? '—'),
      _kv('parent', parent.isEmpty ? '— (top)' : parent),
      _kv('children', children.isEmpty ? '—' : children.join(', ')),
      _kv('processes',
          processes.isEmpty ? '0' : '${processes.length} · ${processes.join(', ')}'),
      _kv('participants', '${participants.length}'),
      _kv('gates', '$gates'),
      if (init != null) _CharterSection(init: init, wsId: wsId),
      if (init != null) _LessonsLine(init: init, wsId: wsId),
    ],
  );
}

/// Process card detail — trigger, step count, sign-offs, charter gates, and
/// any event chaining (this process triggers / is triggered by another).
Widget _processDetail(OrgNode node, OrgChartModel model) {
  final pid = node.processId;
  final steps = model.nodes
      .where((n) => n.kind == OrgNodeKind.step && n.processId == pid)
      .length;
  final signoffs = model.nodes
      .where((n) => n.kind == OrgNodeKind.signoff && n.processId == pid)
      .map((n) => n.label.startsWith('✓ ') ? n.label.substring(2) : n.label)
      .toList();
  final gates = model.nodes
      .where((n) => n.kind == OrgNodeKind.gate && n.processId == pid)
      .map((n) => n.label)
      .toList();
  // Event chaining via process→process edges.
  final triggeredBy = model.edges
      .where((e) => e.kind == OrgEdgeKind.event && e.toId == node.id)
      .map((e) => e.fromId.replaceFirst(RegExp(r'^pc:[^:]*:'), ''))
      .toList();
  final triggers = model.edges
      .where((e) => e.kind == OrgEdgeKind.event && e.fromId == node.id)
      .map((e) => e.toId.replaceFirst(RegExp(r'^pc:[^:]*:'), ''))
      .toList();

  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        node.label,
        style: TextStyle(
          fontSize: OpsType.xl,
          fontWeight: OpsType.semibold,
          color: OpsColors.text,
        ),
      ),
      const SizedBox(height: OpsSpace.s1),
      Text(
        pid ?? '',
        style: TextStyle(
          fontSize: OpsType.sm,
          fontFamily: OpsType.mono,
          color: OpsColors.text3,
        ),
      ),
      const SizedBox(height: OpsSpace.s6),
      _kv('trigger', node.badge ?? 'manual'),
      _kv('steps', '$steps'),
      _kv('sign-offs', signoffs.isEmpty ? '—' : signoffs.join(', ')),
      _kv('charter gates', gates.isEmpty ? '—' : gates.join(', ')),
      _kv('triggered by', triggeredBy.isEmpty ? '— (entry point)' : triggeredBy.join(', ')),
      _kv('triggers', triggers.isEmpty ? '—' : triggers.join(', ')),
    ],
  );
}

/// Knowledge node detail — the axis + which members reference it (resolved
/// from ownership edges in the model).
Widget _knowledgeDetail(OrgNode node, OrgChartModel model) {
  final owners = model.edges
      .where((e) => e.kind == OrgEdgeKind.ownership && e.toId == node.id)
      .map((e) => model.nodes
          .firstWhere((n) => n.id == e.fromId,
              orElse: () => node)
          .label)
      .toSet()
      .toList()
    ..sort();
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        node.label,
        style: TextStyle(
          fontSize: OpsType.xl,
          fontWeight: OpsType.semibold,
          color: OpsColors.text,
        ),
      ),
      const SizedBox(height: OpsSpace.s5),
      _kv('axis', node.sublabel ?? '—'),
      _kv('workspace', node.wsId),
      _kv('referenced by',
          owners.isEmpty ? '—' : '${owners.length} · ${owners.join(', ')}'),
    ],
  );
}

/// Org-memory count — how many org lessons this workspace has accumulated
/// (per-ws `category:"org_lesson"` facts; survive member churn).
class _LessonsLine extends StatelessWidget {
  const _LessonsLine({required this.init, required this.wsId});
  final KnowledgeInit init;
  final String wsId;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<int>(
      future: () async {
        try {
          final facts = await init.registries.knowledge
              .graphFactsForWorkspace(wsId, category: 'org_lesson', limit: 500);
          return facts.length;
        } catch (_) {
          return 0;
        }
      }(),
      builder: (ctx, snap) => _kv('lessons', '${snap.data ?? 0}'),
    );
  }
}

/// Org charter section — shows the workspace's charter (mission + governing
/// prohibitions) when its charter is the per-project active ethos. Reads the
/// active ethos once (no `ref.watch` — dialog is outside the ProviderScope).
class _CharterSection extends StatelessWidget {
  const _CharterSection({required this.init, required this.wsId});
  final KnowledgeInit init;
  final String wsId;

  Future<Map<String, dynamic>?> _charter() async {
    try {
      final phil = init.system.philosophy;
      if (!phil.isAvailable) return null;
      final ethos = await phil.getEthosById(null); // active
      final c = ethos.metadata.context;
      if (c == null || c.isEmpty) return null;
      final ctx = jsonDecode(c) as Map<String, dynamic>;
      if (ctx['kind'] != 'charter' || ctx['workspaceId'] != wsId) return null;
      return <String, dynamic>{
        'mission': ctx['mission'],
        'northStar': ctx['northStar'],
        'prohibitions': [for (final p in ethos.prohibitions) p.statement],
      };
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _charter(),
      builder: (ctx, snap) {
        final ch = snap.data;
        if (ch == null) {
          return _kv('charter', '— (set via workspace_set_charter)');
        }
        final prohibitions = (ch['prohibitions'] as List?)?.cast<String>() ??
            const <String>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: OpsSpace.s4),
            const Text(
              'CHARTER',
              style: TextStyle(
                fontSize: OpsType.xs,
                fontFamily: OpsType.mono,
                letterSpacing: OpsType.mono06,
                color: OpsColors.knowledge,
              ),
            ),
            const SizedBox(height: OpsSpace.s2),
            if ((ch['mission'] as String?)?.isNotEmpty ?? false)
              _kv('mission', ch['mission'] as String),
            if ((ch['northStar'] as String?)?.isNotEmpty ?? false)
              _kv('northStar', ch['northStar'] as String),
            _kv('rules', prohibitions.isEmpty ? '—' : prohibitions.join(' · ')),
          ],
        );
      },
    );
  }
}

/// Compact card for a node without an agent behind it — a charter/quality
/// gate checkpoint, or a step whose assignee did not resolve to an agent.
Widget _stepDetail(OrgNode node) {
  final kindLabel = switch (node.kind) {
    OrgNodeKind.gate => 'checkpoint',
    OrgNodeKind.step => 'pipeline step',
    OrgNodeKind.signoff => 'sign-off',
    _ => 'node',
  };
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        node.label,
        style: TextStyle(
          fontSize: OpsType.xl,
          fontWeight: OpsType.semibold,
          color: OpsColors.text,
        ),
      ),
      const SizedBox(height: OpsSpace.s5),
      _kv('kind', kindLabel),
      _kv('workspace', node.wsId),
      if (node.sublabel != null) _kv('skill', node.sublabel!),
      if (node.agentId != null && node.agentId!.isNotEmpty)
        _kv('assignee', node.agentId!),
    ],
  );
}

Widget _kv(String k, String v) => Padding(
  padding: const EdgeInsets.symmetric(vertical: OpsSpace.s1),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 96,
        child: Text(
          k,
          style: TextStyle(
            fontSize: OpsType.sm,
            fontFamily: OpsType.mono,
            color: OpsColors.text3,
          ),
        ),
      ),
      Expanded(
        child: Text(
          v,
          style: TextStyle(fontSize: OpsType.md, color: OpsColors.text),
        ),
      ),
    ],
  ),
);
