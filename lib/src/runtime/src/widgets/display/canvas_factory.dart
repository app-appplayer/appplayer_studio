import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart' show PropertyKeys;

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Canvas widgets (v1.3)
///
/// Renders ordered drawing commands (rect, circle, arc, line, path, text, image)
/// onto a CustomPaint canvas surface. All command properties support data binding.
class CanvasWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final width = parseDimension(context.resolve(properties[PropertyKeys.width])) ?? 300;
    final height = parseDimension(context.resolve(properties[PropertyKeys.height])) ?? 200;
    final bgColor = parseColor(context.resolve(properties[PropertyKeys.backgroundColor]), context);

    final rawCommands = properties[PropertyKeys.commands];
    final List<Map<String, dynamic>> commands = [];
    if (rawCommands is List) {
      for (final cmd in rawCommands) {
        if (cmd is Map<String, dynamic>) {
          // Resolve all binding expressions, then normalize any color
          // values (`fill`, `stroke`, `color`) through the theme-aware
          // parseColor so slot names like `primary` / `surface` /
          // `textOnBackground` are substituted with the active mode's
          // hex. The painter's own color parser only understands hex,
          // so without this pass a slot-named fill would return null
          // and the shape would silently disappear in dark mode.
          final resolved = <String, dynamic>{};
          for (final entry in cmd.entries) {
            final value = context.resolve(entry.value);
            if (_isColorKey(entry.key) && value is String) {
              final resolvedColor = parseColor(value, context);
              resolved[entry.key] =
                  resolvedColor != null ? _toHex(resolvedColor) : value;
            } else {
              resolved[entry.key] = value;
            }
          }
          commands.add(resolved);
        }
      }
    }

    Widget canvas = CustomPaint(
      size: Size(width, height),
      painter: _CanvasCommandPainter(
        commands: commands,
        backgroundColor: bgColor,
      ),
    );

    canvas = SizedBox(
      width: width,
      height: height,
      child: canvas,
    );

    return applyCommonWrappers(canvas, properties, context);
  }

  static bool _isColorKey(String key) =>
      key == 'fill' || key == 'stroke' || key == 'color';

  static String _toHex(Color c) {
    // Flutter's new `Color` exposes a/r/g/b as 0.0–1.0 doubles, so
    // round to the 0–255 channel byte before converting to hex.
    String two(double v) =>
        (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0')
            .toUpperCase();
    return '#${two(c.a)}${two(c.r)}${two(c.g)}${two(c.b)}';
  }
}

/// Painter that executes ordered drawing commands on a canvas
class _CanvasCommandPainter extends CustomPainter {
  final List<Map<String, dynamic>> commands;
  final Color? backgroundColor;

  _CanvasCommandPainter({
    required this.commands,
    this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (backgroundColor != null) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = backgroundColor!,
      );
    }

    for (final cmd in commands) {
      final op = cmd[PropertyKeys.op] as String?;
      if (op == null) continue;

      switch (op) {
        case 'rect':
          _drawRect(canvas, cmd);
        case 'circle':
          _drawCircle(canvas, cmd);
        case 'arc':
          _drawArc(canvas, cmd);
        case 'line':
          _drawLine(canvas, cmd);
        case 'path':
          _drawPath(canvas, cmd);
        case 'text':
          _drawText(canvas, cmd);
        case 'image':
          _drawImage(canvas, cmd);
        // Unknown ops are skipped gracefully per spec
      }
    }
  }

  void _drawRect(Canvas canvas, Map<String, dynamic> cmd) {
    final x = _toDouble(cmd[PropertyKeys.x]);
    final y = _toDouble(cmd[PropertyKeys.y]);
    final w = _toDouble(cmd[PropertyKeys.width]);
    final h = _toDouble(cmd[PropertyKeys.height]);
    final cr = _toDouble(cmd[PropertyKeys.cornerRadius]);

    final rect = Rect.fromLTWH(x, y, w, h);
    final rrect = cr > 0
        ? RRect.fromRectAndRadius(rect, Radius.circular(cr))
        : null;

    final fill = _parseColor(cmd[PropertyKeys.fill]);
    if (fill != null) {
      final paint = Paint()..color = fill;
      if (rrect != null) {
        canvas.drawRRect(rrect, paint);
      } else {
        canvas.drawRect(rect, paint);
      }
    }

    final stroke = _parseColor(cmd[PropertyKeys.stroke]);
    if (stroke != null) {
      final paint = Paint()
        ..color = stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = _toDouble(cmd[PropertyKeys.strokeWidth], 1);
      if (rrect != null) {
        canvas.drawRRect(rrect, paint);
      } else {
        canvas.drawRect(rect, paint);
      }
    }
  }

  void _drawCircle(Canvas canvas, Map<String, dynamic> cmd) {
    final cxVal = _toDouble(cmd[PropertyKeys.cx]);
    final cyVal = _toDouble(cmd[PropertyKeys.cy]);
    final radius = _toDouble(cmd[PropertyKeys.radius]);

    final fill = _parseColor(cmd[PropertyKeys.fill]);
    if (fill != null) {
      canvas.drawCircle(Offset(cxVal, cyVal), radius, Paint()..color = fill);
    }

    final stroke = _parseColor(cmd[PropertyKeys.stroke]);
    if (stroke != null) {
      canvas.drawCircle(
        Offset(cxVal, cyVal),
        radius,
        Paint()
          ..color = stroke
          ..style = PaintingStyle.stroke
          ..strokeWidth = _toDouble(cmd[PropertyKeys.strokeWidth], 1),
      );
    }
  }

  void _drawArc(Canvas canvas, Map<String, dynamic> cmd) {
    final cxVal = _toDouble(cmd[PropertyKeys.cx]);
    final cyVal = _toDouble(cmd[PropertyKeys.cy]);
    final radius = _toDouble(cmd[PropertyKeys.radius]);
    final sa = _toDouble(cmd[PropertyKeys.startAngle]);
    final ea = _toDouble(cmd[PropertyKeys.endAngle]);

    final rect = Rect.fromCircle(center: Offset(cxVal, cyVal), radius: radius);
    final sweepAngle = ea - sa;

    final stroke = _parseColor(cmd[PropertyKeys.stroke]);
    if (stroke != null) {
      final paint = Paint()
        ..color = stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = _toDouble(cmd[PropertyKeys.strokeWidth], 1)
        ..strokeCap = _parseStrokeCap(cmd[PropertyKeys.strokeCap]);
      canvas.drawArc(rect, sa, sweepAngle, false, paint);
    }
  }

  void _drawLine(Canvas canvas, Map<String, dynamic> cmd) {
    final x1 = _toDouble(cmd[PropertyKeys.x1]);
    final y1 = _toDouble(cmd[PropertyKeys.y1]);
    final x2 = _toDouble(cmd[PropertyKeys.x2]);
    final y2 = _toDouble(cmd[PropertyKeys.y2]);

    final stroke = _parseColor(cmd[PropertyKeys.stroke]) ?? Colors.black;
    final paint = Paint()
      ..color = stroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = _toDouble(cmd[PropertyKeys.strokeWidth], 1)
      ..strokeCap = _parseStrokeCap(cmd[PropertyKeys.strokeCap]);

    canvas.drawLine(Offset(x1, y1), Offset(x2, y2), paint);
  }

  void _drawPath(Canvas canvas, Map<String, dynamic> cmd) {
    final pathData = cmd[PropertyKeys.d] as String?;
    if (pathData == null || pathData.isEmpty) return;

    final path = _parseSvgPath(pathData);

    final fill = _parseColor(cmd[PropertyKeys.fill]);
    if (fill != null) {
      canvas.drawPath(path, Paint()..color = fill);
    }

    final stroke = _parseColor(cmd[PropertyKeys.stroke]);
    if (stroke != null) {
      canvas.drawPath(
        path,
        Paint()
          ..color = stroke
          ..style = PaintingStyle.stroke
          ..strokeWidth = _toDouble(cmd[PropertyKeys.strokeWidth], 1),
      );
    }
  }

  void _drawText(Canvas canvas, Map<String, dynamic> cmd) {
    final textContent = cmd[PropertyKeys.content] as String? ?? '';
    final x = _toDouble(cmd[PropertyKeys.x]);
    final y = _toDouble(cmd[PropertyKeys.y]);
    final fontSize = _toDouble(cmd[PropertyKeys.fontSize], 14);
    final color = _parseColor(cmd[PropertyKeys.color]) ?? Colors.black;

    final fontWeight = cmd[PropertyKeys.fontWeight] == 'bold'
        ? FontWeight.bold
        : FontWeight.normal;

    final textAlign = switch (cmd[PropertyKeys.textAlign]) {
      'center' => TextAlign.center,
      'right' || 'end' => TextAlign.right,
      _ => TextAlign.left,
    };

    final textPainter = TextPainter(
      text: TextSpan(
        text: textContent,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: fontWeight,
          color: color,
        ),
      ),
      textAlign: textAlign,
      textDirection: ui.TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(x, y));
  }

  /// Draw image placeholder rect (async image loading not supported in CustomPainter)
  void _drawImage(Canvas canvas, Map<String, dynamic> cmd) {
    final x = _toDouble(cmd[PropertyKeys.x]);
    final y = _toDouble(cmd[PropertyKeys.y]);
    final w = _toDouble(cmd[PropertyKeys.width], 50);
    final h = _toDouble(cmd[PropertyKeys.height], 50);
    final opacityVal = _toDouble(cmd[PropertyKeys.opacity], 1.0);

    final paint = Paint()
      ..color = Colors.grey.withValues(alpha: opacityVal)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(Rect.fromLTWH(x, y, w, h), paint);
  }

  /// Simple SVG path parser supporting M, L, C, Z commands
  Path _parseSvgPath(String d) {
    final path = Path();
    final commands = RegExp(r'[MLCQAZmlcqaz][^MLCQAZmlcqaz]*')
        .allMatches(d)
        .toList();

    for (final match in commands) {
      final segment = match.group(0)!.trim();
      if (segment.isEmpty) continue;

      final cmd = segment[0];
      final nums = RegExp(r'-?[\d.]+')
          .allMatches(segment.substring(1))
          .map((m) => double.tryParse(m.group(0)!) ?? 0)
          .toList();

      switch (cmd) {
        case 'M' when nums.length >= 2:
          path.moveTo(nums[0], nums[1]);
        case 'L' when nums.length >= 2:
          path.lineTo(nums[0], nums[1]);
        case 'C' when nums.length >= 6:
          path.cubicTo(nums[0], nums[1], nums[2], nums[3], nums[4], nums[5]);
        case 'Q' when nums.length >= 4:
          path.quadraticBezierTo(nums[0], nums[1], nums[2], nums[3]);
        case 'Z' || 'z':
          path.close();
      }
    }

    return path;
  }

  StrokeCap _parseStrokeCap(dynamic value) {
    return switch (value) {
      'round' => StrokeCap.round,
      'square' => StrokeCap.square,
      _ => StrokeCap.butt,
    };
  }

  Color? _parseColor(dynamic value) {
    if (value == null) return null;
    if (value is String && value.startsWith('#')) {
      final hex = value.replaceFirst('#', '');
      if (hex.length == 6) {
        return Color(int.parse('FF$hex', radix: 16));
      } else if (hex.length == 8) {
        return Color(int.parse(hex, radix: 16));
      }
    }
    return null;
  }

  double _toDouble(dynamic value, [double defaultValue = 0]) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? defaultValue;
    return defaultValue;
  }

  @override
  bool shouldRepaint(covariant _CanvasCommandPainter oldDelegate) {
    return oldDelegate.commands != commands ||
        oldDelegate.backgroundColor != backgroundColor;
  }
}
