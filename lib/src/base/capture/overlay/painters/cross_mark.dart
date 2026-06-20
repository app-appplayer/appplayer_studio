/// Animated `✗` cross — two strokes drawn sequentially.
library;

import 'package:flutter/material.dart';

import 'shared.dart';

class CrossMarkPainter extends CustomPainter {
  CrossMarkPainter({
    required this.center,
    required this.progress,
    required this.props,
  });
  final Offset center;
  final double progress;
  final Map<String, dynamic> props;

  @override
  void paint(Canvas canvas, Size size) {
    final color = colorFromProps(props, 'color', kAccentRed);
    final dim = doubleProp(props, 'size', 48);
    final stroke = doubleProp(props, 'stroke', dim * 0.12);
    final r = dim / 2;
    final l = center.dx - r;
    final t = center.dy - r;
    // First stroke (top-left → bottom-right) drawn during 0..0.5;
    // second stroke (top-right → bottom-left) during 0.5..1.0.
    final s1 = (progress / 0.5).clamp(0.0, 1.0);
    final s2 = ((progress - 0.5) / 0.5).clamp(0.0, 1.0);
    final p1 =
        Path()
          ..moveTo(l + dim * 0.2, t + dim * 0.2)
          ..lineTo(l + dim * 0.8, t + dim * 0.8);
    final p2 =
        Path()
          ..moveTo(l + dim * 0.8, t + dim * 0.2)
          ..lineTo(l + dim * 0.2, t + dim * 0.8);
    final paint =
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round;
    canvas.drawPath(slicePath(p1, s1), paint);
    if (s2 > 0) canvas.drawPath(slicePath(p2, s2), paint);
  }

  @override
  bool shouldRepaint(covariant CrossMarkPainter old) =>
      old.progress != progress || old.center != center;
}
