import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Graph widgets (simple line/bar chart)
class GraphWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final data =
        context.resolve<List<dynamic>>(properties['data']) as List<dynamic>? ??
            [];
    // Spec §10.12 canonical `chartType`; `type` kept as legacy alias but
    // collides with the widget-type discriminator, so `chartType` is the
    // preferred form.
    final type =
        (properties['chartType'] ?? properties['type']) as String? ?? 'line';
    final width = properties['width']?.toDouble() ?? 300.0;
    final height = properties['height']?.toDouble() ?? 200.0;
    final showGrid = properties['showGrid'] as bool? ?? true;
    final showLabels = properties['showLabels'] as bool? ?? true;
    final themePrimary =
        context.themeManager.getColorValue('primary') ?? Colors.blue;
    final lineColor =
        parseColor(context.resolve(properties['lineColor']), context) ??
            themePrimary;
    final fillColor = parseColor(context.resolve(properties['fillColor']), context) ??
        themePrimary.withValues(alpha: 0.3);
    final gridColor = parseColor(context.resolve(properties['gridColor']), context) ??
        context.themeManager.getColorValue('outlineVariant') ??
        Colors.grey[300]!;
    // Axis label colour — onSurface at reduced alpha so numbers remain
    // legible on both light and dark chart backgrounds without drowning
    // out the series itself.
    final labelColor = parseColor(
            context.resolve(properties['labelColor']), context) ??
        context.themeManager.getColorValue('onSurface') ??
        Colors.grey[600]!;
    final strokeWidth = properties['strokeWidth']?.toDouble() ?? 2.0;

    // Parse data points
    List<double> values = [];
    List<String> labels = [];

    for (var item in data) {
      if (item is num) {
        values.add(item.toDouble());
        labels.add('');
      } else if (item is Map) {
        values.add((item['value'] as num?)?.toDouble() ?? 0.0);
        labels.add(item['label']?.toString() ?? '');
      }
    }

    if (values.isEmpty) {
      return const SizedBox();
    }

    Widget graph = SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _GraphPainter(
          values: values,
          labels: labels,
          type: type,
          showGrid: showGrid,
          showLabels: showLabels,
          lineColor: lineColor,
          fillColor: fillColor,
          gridColor: gridColor,
          labelColor: labelColor,
          strokeWidth: strokeWidth,
        ),
      ),
    );

    return applyCommonWrappers(graph, properties, context);
  }
}

class _GraphPainter extends CustomPainter {
  final List<double> values;
  final List<String> labels;
  final String type;
  final bool showGrid;
  final bool showLabels;
  final Color lineColor;
  final Color fillColor;
  final Color gridColor;
  final Color labelColor;
  final double strokeWidth;

  _GraphPainter({
    required this.values,
    required this.labels,
    required this.type,
    required this.showGrid,
    required this.showLabels,
    required this.lineColor,
    required this.fillColor,
    required this.gridColor,
    required this.labelColor,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;

    final padding = showLabels ? 40.0 : 20.0;
    final graphWidth = size.width - padding * 2;
    final graphHeight = size.height - padding * 2;

    // Find min and max values
    final minValue = values.reduce(math.min);
    final maxValue = values.reduce(math.max);
    final valueRange = maxValue - minValue;

    // Draw grid
    if (showGrid) {
      final gridPaint = Paint()
        ..color = gridColor
        ..strokeWidth = 1;

      // Horizontal grid lines
      for (int i = 0; i <= 5; i++) {
        final y = padding + (graphHeight * i / 5);
        canvas.drawLine(
          Offset(padding, y),
          Offset(padding + graphWidth, y),
          gridPaint,
        );
      }

      // Vertical grid lines
      final gridSpacing = graphWidth / (values.length - 1);
      for (int i = 0; i < values.length; i++) {
        final x = padding + (i * gridSpacing);
        canvas.drawLine(
          Offset(x, padding),
          Offset(x, padding + graphHeight),
          gridPaint,
        );
      }
    }

    // Calculate points
    final points = <Offset>[];
    final spacing = graphWidth / (values.length - 1);

    for (int i = 0; i < values.length; i++) {
      final normalizedValue =
          valueRange > 0 ? (values[i] - minValue) / valueRange : 0.5;
      final x = padding + (i * spacing);
      final y = padding + graphHeight - (normalizedValue * graphHeight);
      points.add(Offset(x, y));
    }

    if (type == 'line') {
      // Draw filled area
      final fillPath = Path();
      fillPath.moveTo(points.first.dx, padding + graphHeight);
      for (final point in points) {
        fillPath.lineTo(point.dx, point.dy);
      }
      fillPath.lineTo(points.last.dx, padding + graphHeight);
      fillPath.close();

      final fillPaint = Paint()
        ..color = fillColor
        ..style = PaintingStyle.fill;
      canvas.drawPath(fillPath, fillPaint);

      // Draw line
      final linePaint = Paint()
        ..color = lineColor
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      final linePath = Path();
      linePath.moveTo(points.first.dx, points.first.dy);
      for (int i = 1; i < points.length; i++) {
        linePath.lineTo(points[i].dx, points[i].dy);
      }
      canvas.drawPath(linePath, linePaint);

      // Draw points
      final pointPaint = Paint()
        ..color = lineColor
        ..style = PaintingStyle.fill;

      for (final point in points) {
        canvas.drawCircle(point, 4, pointPaint);
      }
    } else if (type == 'bar') {
      // Draw bars
      final barWidth = (spacing * 0.6).clamp(10.0, 40.0);
      final barPaint = Paint()
        ..color = lineColor
        ..style = PaintingStyle.fill;

      for (int i = 0; i < points.length; i++) {
        final rect = Rect.fromLTWH(
          points[i].dx - barWidth / 2,
          points[i].dy,
          barWidth,
          padding + graphHeight - points[i].dy,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(2)),
          barPaint,
        );
      }
    }

    // Draw labels
    if (showLabels) {
      final textPainter = TextPainter(
        textDirection: TextDirection.ltr,
      );

      // Value labels on Y axis
      for (int i = 0; i <= 5; i++) {
        final value = minValue + (valueRange * (5 - i) / 5);
        textPainter.text = TextSpan(
          text: value.toStringAsFixed(0),
          style: TextStyle(
              color: labelColor.withValues(alpha: 0.7), fontSize: 10),
        );
        textPainter.layout();
        final y = padding + (graphHeight * i / 5) - textPainter.height / 2;
        textPainter.paint(canvas, Offset(padding - textPainter.width - 5, y));
      }

      // X axis labels
      for (int i = 0; i < labels.length && i < values.length; i++) {
        if (labels[i].isNotEmpty) {
          textPainter.text = TextSpan(
            text: labels[i],
            style: TextStyle(
              color: labelColor.withValues(alpha: 0.7), fontSize: 10),
          );
          textPainter.layout();
          final x = points[i].dx - textPainter.width / 2;
          final y = padding + graphHeight + 5;
          textPainter.paint(canvas, Offset(x, y));
        }
      }
    }
  }

  @override
  bool shouldRepaint(_GraphPainter oldDelegate) {
    return true;
  }
}
