/// Knowledge → Graph tab. FactGraph visualization:
///
///   1. Type distribution (horizontal bars) — which kinds of facts and
///      how many.
///   2. Entity cluster (chip filter).
///   3. Timeline (createdAt desc, color per type).
///   4. Force-directed graph (entity nodes + evidenceRefs edges).
///
/// All client-side composition — the four views share one
/// `workspaceFactsProvider` query result. Clicking a Type / Entity
/// chip filters the timeline.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';

class GraphTab extends ConsumerStatefulWidget {
  const GraphTab({super.key, required this.wsId});
  final String wsId;

  @override
  ConsumerState<GraphTab> createState() => _GraphTabState();
}

class _GraphTabState extends ConsumerState<GraphTab> {
  String? _typeFilter;
  String? _entityFilter;

  @override
  Widget build(BuildContext context) {
    final factsAsync = ref.watch(workspaceFactsProvider(0));
    return factsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (facts) {
        if (facts.isEmpty) {
          return const Center(
            child: Text(
              'No facts in this workspace yet — '
              'agents must be assigned, invoked, or evolved to populate '
              'the graph.',
            ),
          );
        }
        final typeCounts = <String, int>{};
        final entityCounts = <String, int>{};
        for (final f in facts) {
          typeCounts[f.type] = (typeCounts[f.type] ?? 0) + 1;
          final eid = f.entityId as String?;
          if (eid != null && eid.isNotEmpty) {
            entityCounts[eid] = (entityCounts[eid] ?? 0) + 1;
          }
        }
        final filtered =
            facts.where((f) {
              if (_typeFilter != null && f.type != _typeFilter) return false;
              if (_entityFilter != null && f.entityId != _entityFilter)
                return false;
              return true;
            }).toList();

        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _SectionHeader(
              label: 'Type distribution',
              detail: '${typeCounts.length} types · ${facts.length} facts',
              onClear:
                  _typeFilter == null
                      ? null
                      : () => setState(() => _typeFilter = null),
            ),
            _TypeBars(
              counts: typeCounts,
              selected: _typeFilter,
              onSelect:
                  (t) => setState(
                    () => _typeFilter = (_typeFilter == t) ? null : t,
                  ),
            ),
            const SizedBox(height: 16),
            _SectionHeader(
              label: 'Entities',
              detail: '${entityCounts.length} unique',
              onClear:
                  _entityFilter == null
                      ? null
                      : () => setState(() => _entityFilter = null),
            ),
            _EntityChips(
              counts: entityCounts,
              selected: _entityFilter,
              onSelect:
                  (e) => setState(
                    () => _entityFilter = (_entityFilter == e) ? null : e,
                  ),
            ),
            const SizedBox(height: 16),
            _SectionHeader(
              label: 'Entity-relation graph',
              detail: 'evidenceRefs edges · drag node to rearrange',
            ),
            SizedBox(
              height: 320,
              child: _ForceGraphCanvas(
                facts: facts,
                highlightEntity: _entityFilter,
                highlightType: _typeFilter,
              ),
            ),
            const SizedBox(height: 16),
            _SectionHeader(
              label: 'Timeline',
              detail: '${filtered.length} matching · most recent first',
            ),
            ..._buildTimeline(context, filtered),
          ],
        );
      },
    );
  }

  List<Widget> _buildTimeline(BuildContext context, List<dynamic> facts) {
    final sorted = [...facts]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return [for (final f in sorted.take(80)) _TimelineRow(fact: f)];
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.label,
    required this.detail,
    this.onClear,
  });
  final String label;
  final String detail;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(width: 8),
          Text(
            detail,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const Spacer(),
          if (onClear != null)
            TextButton.icon(
              onPressed: onClear,
              icon: const Icon(Icons.close, size: 14),
              label: const Text('Clear filter'),
            ),
        ],
      ),
    );
  }
}

class _TypeBars extends StatelessWidget {
  const _TypeBars({
    required this.counts,
    required this.selected,
    required this.onSelect,
  });
  final Map<String, int> counts;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final entries =
        counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final maxCount = entries.isEmpty ? 1 : entries.first.value;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (final e in entries)
          InkWell(
            onTap: () => onSelect(e.key),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 180,
                    child: Text(
                      e.key,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        fontWeight:
                            e.key == selected
                                ? FontWeight.bold
                                : FontWeight.normal,
                        color:
                            e.key == selected
                                ? scheme.primary
                                : scheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: LayoutBuilder(
                      builder:
                          (_, c) => Container(
                            height: 14,
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                width: c.maxWidth * (e.value / maxCount),
                                decoration: BoxDecoration(
                                  color: _typeColor(e.key, scheme),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 36,
                    child: Text(
                      '${e.value}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _EntityChips extends StatelessWidget {
  const _EntityChips({
    required this.counts,
    required this.selected,
    required this.onSelect,
  });
  final Map<String, int> counts;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final entries =
        counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final e in entries)
          FilterChip(
            label: Text('${e.key} · ${e.value}'),
            selected: e.key == selected,
            onSelected: (_) => onSelect(e.key),
          ),
      ],
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.fact});
  final dynamic fact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final type = fact.type as String;
    final eid = fact.entityId as String?;
    final createdAt = fact.createdAt as DateTime;
    final color = _typeColor(type, scheme);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 4, right: 8),
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
                    if (eid != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        eid,
                        style: TextStyle(fontSize: 11, color: scheme.onSurface),
                      ),
                    ],
                    const Spacer(),
                    Text(
                      _formatTime(createdAt),
                      style: TextStyle(fontSize: 10, color: scheme.outline),
                    ),
                  ],
                ),
                Text(
                  _summary(fact),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _summary(dynamic fact) {
    final content = fact.content as Map?;
    if (content == null || content.isEmpty) return '';
    final parts = <String>[];
    for (final k in const [
      'source',
      'forkedRef',
      'kind',
      'model',
      'turnIndex',
      'value',
    ]) {
      if (content.containsKey(k)) {
        parts.add('$k=${content[k]}');
        if (parts.length >= 3) break;
      }
    }
    return parts.join(' · ');
  }
}

String _formatTime(DateTime t) {
  final h = t.hour.toString().padLeft(2, '0');
  final m = t.minute.toString().padLeft(2, '0');
  return '${t.month}/${t.day} $h:$m';
}

/// Light pastel-by-hash so distinct types stay visually distinct without a
/// hand-curated palette.
Color _typeColor(String type, ColorScheme scheme) {
  if (type.startsWith('agent.fork.assigned')) return scheme.primary;
  if (type.startsWith('agent.fork.evolved')) return scheme.tertiary;
  if (type.startsWith('agent.invoked')) return scheme.secondary;
  if (type.startsWith('agent.deleted')) return scheme.error;
  if (type.startsWith('kv:')) return scheme.outline;
  // Fallback: hash to HSL.
  final h = (type.hashCode & 0xFFFF) / 0xFFFF * 360;
  return HSLColor.fromAHSL(1, h, 0.45, 0.55).toColor();
}

// ============================================================================
// Force-directed graph — entity nodes + evidenceRefs edges (Phase 2)
// ============================================================================

class _ForceNode {
  _ForceNode({
    required this.id,
    required this.factCount,
    required Offset initial,
  }) : pos = initial,
       velocity = Offset.zero;

  final String id;
  final int factCount;
  Offset pos;
  Offset velocity;
  bool dragging = false;
}

class _ForceGraphCanvas extends StatefulWidget {
  const _ForceGraphCanvas({
    required this.facts,
    this.highlightEntity,
    this.highlightType,
  });
  final List<dynamic> facts;
  final String? highlightEntity;
  final String? highlightType;

  @override
  State<_ForceGraphCanvas> createState() => _ForceGraphCanvasState();
}

class _ForceGraphCanvasState extends State<_ForceGraphCanvas>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final List<_ForceNode> _nodes = [];
  final Set<({String from, String to})> _edges = {};
  Size _canvasSize = const Size(400, 320);
  _ForceNode? _drag;
  Offset _dragOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _rebuild();
  }

  @override
  void didUpdateWidget(covariant _ForceGraphCanvas old) {
    super.didUpdateWidget(old);
    if (old.facts.length != widget.facts.length) _rebuild();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _rebuild() {
    final entityCounts = <String, int>{};
    for (final f in widget.facts) {
      final eid = f.entityId as String?;
      if (eid != null && eid.isNotEmpty) {
        entityCounts[eid] = (entityCounts[eid] ?? 0) + 1;
      }
    }
    _edges.clear();
    final edgeRefs = <String, String>{
      for (final f in widget.facts)
        if (f.entityId is String) (f.id as String): f.entityId as String,
    };
    for (final f in widget.facts) {
      final from = f.entityId as String?;
      if (from == null) continue;
      final refs = (f.evidenceRefs as List?) ?? const [];
      for (final r in refs) {
        final to = edgeRefs[r as String];
        if (to != null && to != from) {
          _edges.add((from: from, to: to));
        }
      }
    }
    _nodes
      ..clear()
      ..addAll(_layoutInitial(entityCounts));
  }

  List<_ForceNode> _layoutInitial(Map<String, int> counts) {
    final entries =
        counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final cx = _canvasSize.width / 2;
    final cy = _canvasSize.height / 2;
    final radius = math.min(_canvasSize.width, _canvasSize.height) * 0.35;
    return [
      for (var i = 0; i < entries.length; i++)
        _ForceNode(
          id: entries[i].key,
          factCount: entries[i].value,
          initial: Offset(
            cx + radius * math.cos(2 * math.pi * i / entries.length),
            cy + radius * math.sin(2 * math.pi * i / entries.length),
          ),
        ),
    ];
  }

  void _onTick(Duration _) {
    if (_nodes.isEmpty) return;
    const repulsion = 6500.0;
    const springK = 0.04;
    const idealLen = 100.0;
    const damping = 0.85;
    final cx = _canvasSize.width / 2;
    final cy = _canvasSize.height / 2;

    for (var i = 0; i < _nodes.length; i++) {
      final a = _nodes[i];
      if (a.dragging) continue;
      var fx = 0.0;
      var fy = 0.0;
      // Repulsion between every other node.
      for (var j = 0; j < _nodes.length; j++) {
        if (i == j) continue;
        final b = _nodes[j];
        var dx = a.pos.dx - b.pos.dx;
        var dy = a.pos.dy - b.pos.dy;
        final d2 = (dx * dx + dy * dy).clamp(50.0, double.infinity);
        final f = repulsion / d2;
        final d = math.sqrt(d2);
        fx += f * dx / d;
        fy += f * dy / d;
      }
      // Spring along edges.
      for (final e in _edges) {
        if (e.from != a.id && e.to != a.id) continue;
        final otherId = e.from == a.id ? e.to : e.from;
        final other = _nodes.firstWhere(
          (n) => n.id == otherId,
          orElse: () => a,
        );
        if (identical(other, a)) continue;
        final dx = other.pos.dx - a.pos.dx;
        final dy = other.pos.dy - a.pos.dy;
        final d = math.sqrt(dx * dx + dy * dy).clamp(1.0, double.infinity);
        final f = springK * (d - idealLen);
        fx += f * dx / d;
        fy += f * dy / d;
      }
      // Mild centering pull.
      fx += (cx - a.pos.dx) * 0.002;
      fy += (cy - a.pos.dy) * 0.002;

      a.velocity = Offset(
        (a.velocity.dx + fx * 0.016) * damping,
        (a.velocity.dy + fy * 0.016) * damping,
      );
      a.pos = a.pos + a.velocity;
      // Keep inside canvas with a little padding.
      a.pos = Offset(
        a.pos.dx.clamp(20.0, _canvasSize.width - 20.0),
        a.pos.dy.clamp(20.0, _canvasSize.height - 20.0),
      );
    }
    if (mounted) setState(() {});
  }

  void _onPanStart(DragStartDetails d) {
    for (final n in _nodes) {
      if ((n.pos - d.localPosition).distance <= _radius(n) + 4) {
        _drag = n;
        n.dragging = true;
        _dragOffset = n.pos - d.localPosition;
        return;
      }
    }
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final n = _drag;
    if (n == null) return;
    n.pos = d.localPosition + _dragOffset;
  }

  void _onPanEnd(_) {
    final n = _drag;
    if (n != null) n.dragging = false;
    _drag = null;
  }

  double _radius(_ForceNode n) =>
      6.0 + math.min(14.0, math.sqrt(n.factCount.toDouble()) * 2.5);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _canvasSize = constraints.biggest;
        final scheme = Theme.of(context).colorScheme;
        return GestureDetector(
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          child: CustomPaint(
            size: _canvasSize,
            painter: _ForceGraphPainter(
              nodes: _nodes,
              edges: _edges,
              highlightEntity: widget.highlightEntity,
              scheme: scheme,
            ),
          ),
        );
      },
    );
  }
}

class _ForceGraphPainter extends CustomPainter {
  _ForceGraphPainter({
    required this.nodes,
    required this.edges,
    required this.scheme,
    this.highlightEntity,
  });
  final List<_ForceNode> nodes;
  final Set<({String from, String to})> edges;
  final ColorScheme scheme;
  final String? highlightEntity;

  @override
  void paint(Canvas canvas, Size size) {
    final bg =
        Paint()
          ..color = scheme.surfaceContainerLowest
          ..style = PaintingStyle.fill;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      bg,
    );
    final border =
        Paint()
          ..color = scheme.outlineVariant
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      border,
    );

    // Edges.
    final edgePaint =
        Paint()
          ..color = scheme.outlineVariant
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1;
    for (final e in edges) {
      final a = nodes.firstWhere(
        (n) => n.id == e.from,
        orElse: () => nodes.first,
      );
      final b = nodes.firstWhere(
        (n) => n.id == e.to,
        orElse: () => nodes.first,
      );
      canvas.drawLine(a.pos, b.pos, edgePaint);
    }

    // Nodes + labels.
    for (final n in nodes) {
      final double r =
          6.0 + math.min(14.0, math.sqrt(n.factCount.toDouble()) * 2.5);
      final highlighted = highlightEntity == null || n.id == highlightEntity;
      final fill =
          Paint()
            ..color =
                highlighted
                    ? scheme.primary.withValues(alpha: 0.85)
                    : scheme.primary.withValues(alpha: 0.25)
            ..style = PaintingStyle.fill;
      final stroke =
          Paint()
            ..color = scheme.onSurface
            ..style = PaintingStyle.stroke
            ..strokeWidth = highlighted ? 1.5 : 0.6;
      canvas.drawCircle(n.pos, r, fill);
      canvas.drawCircle(n.pos, r, stroke);

      final tp = TextPainter(
        text: TextSpan(
          text: n.id,
          style: TextStyle(
            fontSize: 10,
            fontFamily: 'monospace',
            color: highlighted ? scheme.onSurface : scheme.outline,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, n.pos + Offset(r + 4, -tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _ForceGraphPainter old) => true;
}
