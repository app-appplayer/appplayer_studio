import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Network Graph widgets (v1.1)
/// Renders a network graph visualization with nodes and edges
class NetworkGraphWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final nodes = context.resolve<List<dynamic>?>(properties['nodes'] ?? []) ??
        [];
    final edges = context.resolve<List<dynamic>?>(properties['edges'] ?? []) ??
        [];
    final width = parseDimension(context.resolve((properties['width'])));
    final height = parseDimension(context.resolve((properties['height']))) ?? 400.0;
    final interactive =
        context.resolve<bool>(properties['interactive'] ?? true);
    final layout = context.resolve<String>(properties['layout'] ?? 'force');
    // Theme-adaptive defaults — authors that don't set explicit colors
    // still get a graph that's readable in dark mode.
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context) ??
            context.themeManager.getColorValue('surface') ??
            Colors.white;
    final nodeColor =
        parseColor(context.resolve(properties['nodeColor']), context) ??
            context.themeManager.getColorValue('primary') ??
            Colors.blue;
    final edgeColor =
        parseColor(context.resolve(properties['edgeColor']), context) ??
            context.themeManager.getColorValue('outlineVariant') ??
            Colors.grey.shade400;
    final labelColor =
        parseColor(context.resolve(properties['labelColor']), context) ??
            context.themeManager.getColorValue('onSurface') ??
            Colors.black87;

    final onNodeTap = actionOf(properties['onNodeTap'], context);
    final onEdgeTap = actionOf(properties['onEdgeTap'], context);

    final parsedNodes = _parseNodes(nodes);
    final parsedEdges = _parseEdges(edges);

    Widget graph = _NetworkGraphWidget(
      nodes: parsedNodes,
      edges: parsedEdges,
      interactive: interactive,
      layout: layout,
      backgroundColor: backgroundColor,
      nodeColor: nodeColor,
      edgeColor: edgeColor,
      labelColor: labelColor,
      onNodeTap: onNodeTap,
      onEdgeTap: onEdgeTap,
      context: context,
    );

    graph = SizedBox(
      width: width,
      height: height,
      child: graph,
    );

    return applyCommonWrappers(graph, properties, context);
  }

  List<_GraphNode> _parseNodes(List<dynamic> nodes) {
    return nodes.whereType<Map>().map((n) {
      return _GraphNode(
        id: n['id']?.toString() ?? '',
        label: n['label']?.toString() ?? '',
        x: (n['x'] as num?)?.toDouble(),
        y: (n['y'] as num?)?.toDouble(),
        size: (n['size'] as num?)?.toDouble() ?? 24.0,
        color: n['color']?.toString(),
        icon: n['icon']?.toString(),
      );
    }).toList();
  }

  List<_GraphEdge> _parseEdges(List<dynamic> edges) {
    return edges.whereType<Map>().map((e) {
      return _GraphEdge(
        // Spec §10.13 spells an edge `{from, to}`. This read `source`/`target`
        // and nothing else, so a graph written the documented way drew its
        // nodes and not one edge between them — with no error to say so.
        // The older spelling is still accepted.
        source: (e['from'] ?? e['source'])?.toString() ?? '',
        target: (e['to'] ?? e['target'])?.toString() ?? '',
        label: e['label']?.toString(),
        weight: (e['weight'] as num?)?.toDouble() ?? 1.0,
        color: e['color']?.toString(),
        directed: e['directed'] as bool? ?? false,
      );
    }).toList();
  }
}

class _GraphNode {
  final String id;
  final String label;
  double? x;
  double? y;
  final double size;
  final String? color;
  final String? icon;

  _GraphNode({
    required this.id,
    required this.label,
    this.x,
    this.y,
    required this.size,
    this.color,
    this.icon,
  });
}

class _GraphEdge {
  final String source;
  final String target;
  final String? label;
  final double weight;
  final String? color;
  final bool directed;

  _GraphEdge({
    required this.source,
    required this.target,
    this.label,
    required this.weight,
    this.color,
    required this.directed,
  });
}

class _NetworkGraphWidget extends StatefulWidget {
  final List<_GraphNode> nodes;
  final List<_GraphEdge> edges;
  final bool interactive;
  final String layout;
  final Color backgroundColor;
  final Color nodeColor;
  final Color edgeColor;
  final Color labelColor;
  final Map<String, dynamic>? onNodeTap;
  final Map<String, dynamic>? onEdgeTap;
  final RenderContext context;

  const _NetworkGraphWidget({
    required this.nodes,
    required this.edges,
    required this.interactive,
    required this.layout,
    required this.backgroundColor,
    required this.nodeColor,
    required this.edgeColor,
    required this.labelColor,
    this.onNodeTap,
    this.onEdgeTap,
    required this.context,
  });

  @override
  State<_NetworkGraphWidget> createState() => _NetworkGraphWidgetState();
}

class _NetworkGraphWidgetState extends State<_NetworkGraphWidget> {
  late List<_GraphNode> _nodes;
  Offset _panOffset = Offset.zero;
  double _scale = 1.0;
  Offset? _lastFocalPoint;

  @override
  void initState() {
    super.initState();
    _nodes = List.from(widget.nodes);
    _layoutNodes();
  }

  /// Places the nodes the document did not place itself.
  ///
  /// `layout` names four algorithms and this method used to be one circle for
  /// all of them: a document asking for `grid` or `tree` got the same picture
  /// as `circular`, and nothing said the word had been ignored.
  void _layoutNodes() {
    final free = _nodes.where((n) => n.x == null || n.y == null).toList();
    if (free.isEmpty) return;

    const centreX = 200.0;
    const centreY = 200.0;
    const radius = 120.0;

    void circular() {
      for (var i = 0; i < free.length; i++) {
        final angle = (2 * math.pi * i) / free.length;
        free[i].x = centreX + radius * math.cos(angle);
        free[i].y = centreY + radius * math.sin(angle);
      }
    }

    switch (widget.layout) {
      case 'grid':
        final columns = math.max(1, math.sqrt(free.length).ceil());
        const step = 90.0;
        final rows = (free.length / columns).ceil();
        for (var i = 0; i < free.length; i++) {
          final col = i % columns;
          final row = i ~/ columns;
          free[i].x = centreX + (col - (columns - 1) / 2) * step;
          free[i].y = centreY + (row - (rows - 1) / 2) * step;
        }
      case 'tree':
      case 'hierarchical':
        // Layers by distance from a root — a node nothing points at. With no
        // such node (a cycle) the first node is the root, which is still a
        // hierarchy and not a circle.
        final incoming = <String, int>{for (final n in free) n.id: 0};
        for (final e in widget.edges) {
          if (incoming.containsKey(e.target)) {
            incoming[e.target] = incoming[e.target]! + 1;
          }
        }
        final depth = <String, int>{};
        final roots = free.where((n) => (incoming[n.id] ?? 0) == 0).toList();
        final queue = <_GraphNode>[...(roots.isEmpty ? [free.first] : roots)];
        for (final r in queue) {
          depth[r.id] = 0;
        }
        var head = 0;
        while (head < queue.length) {
          final node = queue[head++];
          for (final e in widget.edges.where((e) => e.source == node.id)) {
            if (depth.containsKey(e.target)) continue;
            final child = free.where((n) => n.id == e.target);
            if (child.isEmpty) continue;
            depth[e.target] = depth[node.id]! + 1;
            queue.add(child.first);
          }
        }
        final byDepth = <int, List<_GraphNode>>{};
        for (final n in free) {
          byDepth.putIfAbsent(depth[n.id] ?? 0, () => []).add(n);
        }
        final levels = byDepth.keys.toList()..sort();
        for (final level in levels) {
          final row = byDepth[level]!;
          for (var i = 0; i < row.length; i++) {
            row[i].x = centreX + (i - (row.length - 1) / 2) * 100;
            row[i].y = 80.0 + level * 100;
          }
        }
      case 'force':
        // Circular start, then a few rounds of spring + repulsion. Connected
        // nodes end up near each other, which is the whole point of asking
        // for a force layout instead of a circle.
        circular();
        const iterations = 60;
        for (var step = 0; step < iterations; step++) {
          for (final a in free) {
            var dx = 0.0;
            var dy = 0.0;
            for (final b in free) {
              if (identical(a, b)) continue;
              final vx = a.x! - b.x!;
              final vy = a.y! - b.y!;
              final d2 = math.max(400.0, vx * vx + vy * vy);
              dx += vx / d2 * 4000;
              dy += vy / d2 * 4000;
            }
            for (final e in widget.edges) {
              String? otherId;
              if (e.source == a.id) otherId = e.target;
              if (e.target == a.id) otherId = e.source;
              if (otherId == null) continue;
              final others = free.where((n) => n.id == otherId);
              if (others.isEmpty) continue;
              final b = others.first;
              dx += (b.x! - a.x!) * 0.02;
              dy += (b.y! - a.y!) * 0.02;
            }
            a.x = a.x! + dx.clamp(-8.0, 8.0);
            a.y = a.y! + dy.clamp(-8.0, 8.0);
          }
        }
      default:
        circular();
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget content = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CustomPaint(
        painter: _NetworkGraphPainter(
          nodes: _nodes,
          edges: widget.edges,
          nodeColor: widget.nodeColor,
          edgeColor: widget.edgeColor,
          backgroundColor: widget.backgroundColor,
          labelColor: widget.labelColor,
          offset: _panOffset,
          scale: _scale,
        ),
        child: Container(),
      ),
    );

    if (widget.interactive) {
      content = GestureDetector(
        onScaleStart: (details) {
          _lastFocalPoint = details.focalPoint;
        },
        onScaleUpdate: (details) {
          setState(() {
            if (_lastFocalPoint != null) {
              _panOffset += details.focalPoint - _lastFocalPoint!;
              _lastFocalPoint = details.focalPoint;
            }
            if (details.scale != 1.0) {
              _scale = (_scale * details.scale).clamp(0.3, 3.0);
            }
          });
        },
        onScaleEnd: (_) {
          _lastFocalPoint = null;
        },
        onTapUp: _onTapUp,
        child: content,
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: content,
    );
  }

  void _onTapUp(TapUpDetails details) {
    if (widget.onNodeTap == null) return;

    final tapPos = (details.localPosition - _panOffset) / _scale;
    for (final node in _nodes) {
      if (node.x == null || node.y == null) continue;
      final dist = (Offset(node.x!, node.y!) - tapPos).distance;
      if (dist < node.size) {
        final eventContext = widget.context.createChildContext(
          variables: {
            'event': {'nodeId': node.id, 'label': node.label},
          },
        );
        widget.context.actionHandler.execute(widget.onNodeTap!, eventContext);
        return;
      }
    }
  }
}

class _NetworkGraphPainter extends CustomPainter {
  final List<_GraphNode> nodes;
  final List<_GraphEdge> edges;
  final Color nodeColor;
  final Color edgeColor;
  final Color backgroundColor;
  final Color labelColor;
  final Offset offset;
  final double scale;

  _NetworkGraphPainter({
    required this.nodes,
    required this.edges,
    required this.nodeColor,
    required this.edgeColor,
    required this.backgroundColor,
    required this.labelColor,
    required this.offset,
    required this.scale,
  });

  /// Scales and centres the node coordinates so the whole graph is inside
  /// [size], with room for the node circles and their labels.
  void _applyFit(Canvas canvas, Size size) {
    final placed = nodes.where((n) => n.x != null && n.y != null).toList();
    if (placed.isEmpty || size.width <= 0 || size.height <= 0) return;

    var minX = double.infinity, maxX = double.negativeInfinity;
    var minY = double.infinity, maxY = double.negativeInfinity;
    var margin = 24.0;
    for (final n in placed) {
      minX = math.min(minX, n.x!);
      maxX = math.max(maxX, n.x!);
      minY = math.min(minY, n.y!);
      maxY = math.max(maxY, n.y!);
      margin = math.max(margin, n.size / 2 + 18);
    }

    final availableW = math.max(1.0, size.width - margin * 2);
    final availableH = math.max(1.0, size.height - margin * 2);
    final spanX = maxX - minX;
    final spanY = maxY - minY;
    final fit = math.min(
      spanX > 0 ? availableW / spanX : double.infinity,
      spanY > 0 ? availableH / spanY : double.infinity,
    );
    final factor = fit.isFinite ? math.min(1.0, fit) : 1.0;

    // Centre what is drawn on what we can draw on.
    final drawnW = spanX * factor;
    final drawnH = spanY * factor;
    canvas.translate(
      (size.width - drawnW) / 2 - minX * factor,
      (size.height - drawnH) / 2 - minY * factor,
    );
    canvas.scale(factor);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = backgroundColor,
    );

    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);
    // Fit whatever coordinates the nodes carry into the box we were given.
    // The placements were written around a fixed centre of (200, 200) with a
    // radius of 120, so any widget smaller than 400×400 drew part of its graph
    // outside itself — and a document supplying its own coordinates in any
    // other range drew nothing at all.
    _applyFit(canvas, size);

    // Build node position map
    final nodeMap = <String, _GraphNode>{};
    for (final node in nodes) {
      nodeMap[node.id] = node;
    }

    // Draw edges
    final edgePaint = Paint()
      ..color = edgeColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    for (final edge in edges) {
      final source = nodeMap[edge.source];
      final target = nodeMap[edge.target];
      if (source?.x != null && source?.y != null &&
          target?.x != null && target?.y != null) {
        canvas.drawLine(
          Offset(source!.x!, source.y!),
          Offset(target!.x!, target.y!),
          edgePaint,
        );

        if (edge.directed) {
          // Draw arrowhead
          final dx = target.x! - source.x!;
          final dy = target.y! - source.y!;
          final len = (dx * dx + dy * dy);
          if (len > 0) {
            final ndx = dx / len * 10;
            final ndy = dy / len * 10;
            final arrowPaint = Paint()
              ..color = edgeColor
              ..style = PaintingStyle.fill;
            final path = Path()
              ..moveTo(target.x!, target.y!)
              ..lineTo(target.x! - ndx - ndy * 0.5, target.y! - ndy + ndx * 0.5)
              ..lineTo(target.x! - ndx + ndy * 0.5, target.y! - ndy - ndx * 0.5)
              ..close();
            canvas.drawPath(path, arrowPaint);
          }
        }
      }
    }

    // Draw nodes
    for (final node in nodes) {
      if (node.x == null || node.y == null) continue;
      final pos = Offset(node.x!, node.y!);

      // Node circle
      canvas.drawCircle(
        pos,
        node.size / 2,
        Paint()..color = nodeColor,
      );
      canvas.drawCircle(
        pos,
        node.size / 2,
        Paint()
          ..color = nodeColor.withValues(alpha: 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );

      // Node label
      if (node.label.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(
            text: node.label,
            style: TextStyle(fontSize: 10, color: labelColor),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy + node.size / 2 + 4));
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_NetworkGraphPainter oldDelegate) => true;
}
