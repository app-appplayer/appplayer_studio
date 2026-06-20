/// Animated checkmark — draws the two-stroke `✓` path with a
/// progress-based draw-on effect.
library;

import 'package:flutter/material.dart';

import 'shared.dart';

class CheckMarkPainter extends CustomPainter {
  CheckMarkPainter({
    required this.center,
    required this.progress,
    required this.props,
  });
  final Offset center;
  final double progress; // 0..1
  final Map<String, dynamic> props;

  @override
  void paint(Canvas canvas, Size size) {
    final color = colorFromProps(props, 'color', kAccentGreen);
    final dim = doubleProp(props, 'size', 48);
    final stroke = doubleProp(props, 'stroke', dim * 0.12);
    // Check path centred on `center`, sized to `dim`.
    final l = center.dx - dim / 2;
    final t = center.dy - dim / 2;
    final p =
        Path()
          ..moveTo(l + dim * 0.18, t + dim * 0.55)
          ..lineTo(l + dim * 0.42, t + dim * 0.78)
          ..lineTo(l + dim * 0.82, t + dim * 0.28);
    final drawn = slicePath(p, progress);
    final paint =
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(drawn, paint);
  }

  @override
  bool shouldRepaint(covariant CheckMarkPainter old) =>
      old.progress != progress || old.center != center;
}
