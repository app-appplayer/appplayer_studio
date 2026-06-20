import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Gauge widgets
class GaugeWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final value = context.resolve<num>(properties['value'] ?? 0).toDouble();
    final minValue = properties['min']?.toDouble() ?? 0.0;
    final maxValue = properties['max']?.toDouble() ?? 100.0;
    final size = properties['size']?.toDouble() ?? 200.0;
    final strokeWidth = properties['strokeWidth']?.toDouble() ?? 10.0;
    // The gauge's background arc ("track") falls back to the theme's
    // divider slot so it stays subtle in both light and dark modes
    // (previously a hardcoded `Colors.grey[300]` that blended with
    // dark surfaces).
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context) ??
            context.themeManager.getColorValue('outlineVariant') ??
            Colors.grey[300]!;
    final valueColor =
        parseColor(context.resolve(properties['valueColor']), context) ??
            context.themeManager.getColorValue('primary') ??
            Colors.blue;
    final showLabel = properties['showLabel'] as bool? ?? true;
    final labelFormat = properties['labelFormat'] as String? ?? '{value}%';
    final startAngle = properties['startAngle']?.toDouble() ?? -220.0;
    final sweepAngle = properties['sweepAngle']?.toDouble() ?? 260.0;

    // Parse segments: List of {from, to, color}
    final segmentsData = properties['segments'] as List<dynamic>?;
    final List<GaugeSegment> segments = [];
    if (segmentsData != null) {
      for (final seg in segmentsData) {
        if (seg is Map<String, dynamic>) {
          final from = (seg['from'] as num?)?.toDouble() ?? 0.0;
          final to = (seg['to'] as num?)?.toDouble() ?? 0.0;
          final segColor =
              parseColor(context.resolve(seg['color']), context) ?? Colors.blue;
          segments.add(GaugeSegment(from: from, to: to, color: segColor));
        }
      }
    }

    // Calculate normalized value
    final normalizedValue =
        ((value - minValue) / (maxValue - minValue)).clamp(0.0, 1.0);

    Widget gauge = SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _GaugePainter(
          value: normalizedValue,
          backgroundColor: backgroundColor,
          valueColor: valueColor,
          strokeWidth: strokeWidth,
          startAngle: startAngle,
          sweepAngle: sweepAngle,
          segments: segments,
          minValue: minValue,
          maxValue: maxValue,
        ),
        child: showLabel
            ? Center(
                child: Text(
                  labelFormat.replaceAll('{value}', value.toStringAsFixed(0)),
                  style: TextStyle(
                    fontSize: size * 0.15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              )
            : null,
      ),
    );

    return applyCommonWrappers(gauge, properties, context);
  }
}

/// Data class for a colored gauge segment
class GaugeSegment {
  final double from;
  final double to;
  final Color color;

  GaugeSegment({required this.from, required this.to, required this.color});
}

class _GaugePainter extends CustomPainter {
  final double value;
  final Color backgroundColor;
  final Color valueColor;
  final double strokeWidth;
  final double startAngle;
  final double sweepAngle;
  final List<GaugeSegment> segments;
  final double minValue;
  final double maxValue;

  _GaugePainter({
    required this.value,
    required this.backgroundColor,
    required this.valueColor,
    required this.strokeWidth,
    required this.startAngle,
    required this.sweepAngle,
    required this.segments,
    required this.minValue,
    required this.maxValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - strokeWidth / 2;

    // Draw background arc
    final backgroundPaint = Paint()
      ..color = backgroundColor
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      _degreesToRadians(startAngle),
      _degreesToRadians(sweepAngle),
      false,
      backgroundPaint,
    );

    if (segments.isNotEmpty) {
      // Draw colored segments
      final range = maxValue - minValue;
      for (final segment in segments) {
        final segStart =
            ((segment.from - minValue) / range).clamp(0.0, 1.0);
        final segEnd =
            ((segment.to - minValue) / range).clamp(0.0, 1.0);
        final segPaint = Paint()
          ..color = segment.color
          ..strokeWidth = strokeWidth
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.butt;

        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          _degreesToRadians(startAngle + sweepAngle * segStart),
          _degreesToRadians(sweepAngle * (segEnd - segStart)),
          false,
          segPaint,
        );
      }

      // Draw value indicator line on top of segments
      final valuePaint = Paint()
        ..color = valueColor
        ..strokeWidth = strokeWidth + 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      // Draw a small arc at the value position as indicator
      final indicatorSweep = sweepAngle * 0.02;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        _degreesToRadians(
            startAngle + sweepAngle * value - indicatorSweep / 2),
        _degreesToRadians(indicatorSweep),
        false,
        valuePaint,
      );
    } else {
      // Draw value arc (original behavior)
      final valuePaint = Paint()
        ..color = valueColor
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        _degreesToRadians(startAngle),
        _degreesToRadians(sweepAngle * value),
        false,
        valuePaint,
      );
    }
  }

  double _degreesToRadians(double degrees) {
    return degrees * (math.pi / 180);
  }

  @override
  bool shouldRepaint(_GaugePainter oldDelegate) {
    return oldDelegate.value != value ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.valueColor != valueColor ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.segments.length != segments.length;
  }
}
