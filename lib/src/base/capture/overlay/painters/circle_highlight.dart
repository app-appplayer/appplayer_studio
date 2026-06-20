/// Pulsing ring around a target rect.
library;

import 'package:flutter/material.dart';

import '../overlay_models.dart';
import 'shared.dart';

class CircleHighlightPainter extends CustomPainter {
  CircleHighlightPainter({
    required this.target,
    required this.progress,
    required this.props,
  });
  final Rect target;
  final double progress; // 0..1 per pulse
  final Map<String, dynamic> props;

  @override
  void paint(Canvas canvas, Size size) {
    final color = colorFromProps(props, 'color', kAccentMint);
    final stroke = doubleProp(props, 'stroke', 3);
    // Expand outward as the pulse advances; fade out near end.
    final base = (target.shortestSide / 2) + 8;
    final expand = base + 12 * progress;
    final opacity = (1.0 - progress).clamp(0.0, 1.0);
    final paint =
        Paint()
          ..color = color.withOpacity(opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke;
    canvas.drawCircle(target.center, expand, paint);
  }

  @override
  bool shouldRepaint(covariant CircleHighlightPainter old) =>
      old.progress != progress || old.target != target;
}

OverlaySpec circleHighlightSample() =>
    OverlaySpec(id: 'sample', kind: OverlayKind.circleHighlight);
