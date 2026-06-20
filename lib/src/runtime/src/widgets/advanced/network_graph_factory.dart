import 'package:flutter/material.dart';
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Network Graph widgets (v1.1)
/// Renders a network graph visualization with nodes and edges
class NetworkGraphWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final nodes = context.resolve<List<dynamic>>(properties['nodes'] ?? [])
            as List<dynamic>? ??
        [];
    final edges = context.resolve<List<dynamic>>(properties['edges'] ?? [])
            as List<dynamic>? ??
        [];
    final width = context.resolve<double?>(properties['width']);
    final height = context.resolve<double?>(properties['height']) ?? 400.0;
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

    final onNodeTap = properties['onNodeTap'] as Map<String, dynamic>?;
    final onEdgeTap = properties['onEdgeTap'] as Map<String, dynamic>?;

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
        source: e['source']?.toString() ?? '',
        target: e['target']?.toString() ?? '',
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

  void _layoutNodes() {
    // Simple circular layout for nodes without explicit positions
    final nodesWithoutPos = _nodes.where((n) => n.x == null || n.y == null).toList();
    if (nodesWithoutPos.isEmpty) return;

    final count = nodesWithoutPos.length;
    for (int i = 0; i < count; i++) {
      final angle = (2 * 3.14159 * i) / count;
      const radius = 120.0;
      nodesWithoutPos[i].x = 200 + radius * (angle).cos() as double?;
      nodesWithoutPos[i].y = 200 + radius * (angle).sin() as double?;
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

extension on double {
  double cos() => _cos(this);
  double sin() => _sin(this);
}

double _cos(double x) {
  // Taylor series approximation
  x = x % (2 * 3.14159265);
  double result = 1.0;
  double term = 1.0;
  for (int i = 1; i <= 10; i++) {
    term *= -x * x / ((2 * i - 1) * (2 * i));
    result += term;
  }
  return result;
}

double _sin(double x) {
  x = x % (2 * 3.14159265);
  double result = x;
  double term = x;
  for (int i = 1; i <= 10; i++) {
    term *= -x * x / ((2 * i) * (2 * i + 1));
    result += term;
  }
  return result;
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

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = backgroundColor,
    );

    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);

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
