/// Pulsing dot — small filled circle that breathes at a target point.
library;

import 'package:flutter/material.dart';

import 'shared.dart';

class PulseDotPainter extends CustomPainter {
  PulseDotPainter({
    required this.center,
    required this.progress,
    required this.props,
  });
  final Offset center;
  final double progress; // 0..1, continuous breathing
  final Map<String, dynamic> props;

  @override
  void paint(Canvas canvas, Size size) {
    final color = colorFromProps(props, 'color', kAccentMint);
    final baseR = doubleProp(props, 'radius', 6);
    // Two concentric circles: inner solid pulses scale 1.0↔1.4 ; outer ring
    // expands and fades as visual emphasis.
    final t = (progress * 2 - 1).abs(); // 0 at midpoint, 1 at ends
    final scale = 1.0 + 0.4 * (1.0 - t);
    final inner = Paint()..color = color;
    canvas.drawCircle(center, baseR * scale, inner);
    final ringR = baseR * (1.6 + 1.2 * progress);
    final ringOpacity = (1.0 - progress).clamp(0.0, 1.0);
    final ring =
        Paint()
          ..color = color.withOpacity(ringOpacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2;
    canvas.drawCircle(center, ringR, ring);
  }

  @override
  bool shouldRepaint(covariant PulseDotPainter old) =>
      old.progress != progress || old.center != center;
}
