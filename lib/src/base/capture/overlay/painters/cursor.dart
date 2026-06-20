/// Synthetic mouse cursor — the recorder captures the shell
/// `RepaintBoundary`, which does NOT include the OS pointer, so demo
/// videos need a drawn cursor. Renders a classic arrow pointer at
/// [position] (with a soft shadow) plus an optional click ripple. Motion
/// (A→B travel) and click timing are computed by the overlay layer and
/// fed in as [position] / [clickProgress]; this painter is pure draw.
library;

import 'package:flutter/material.dart';

import 'shared.dart';

class CursorPainter extends CustomPainter {
  CursorPainter({
    required this.position,
    required this.clickProgress,
    required this.props,
  });

  /// Where the pointer tip sits.
  final Offset position;

  /// Click ripple progress 0..1, or < 0 for "no click".
  final double clickProgress;
  final Map<String, dynamic> props;

  @override
  void paint(Canvas canvas, Size size) {
    // Click ripple first (under the pointer).
    if (clickProgress >= 0) {
      final rippleColor = colorFromProps(props, 'clickColor', kAccentMint);
      final maxR = doubleProp(props, 'clickRadius', 28);
      final t = clickProgress.clamp(0.0, 1.0);
      final r = maxR * Curves.easeOut.transform(t);
      final ring =
          Paint()
            ..color = rippleColor.withValues(alpha: (1.0 - t) * 0.8)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3;
      canvas.drawCircle(position, r, ring);
      final fill =
          Paint()..color = rippleColor.withValues(alpha: (1.0 - t) * 0.25);
      canvas.drawCircle(position, r * 0.6, fill);
    }

    final scale = doubleProp(props, 'scale', 1.4);
    final fillColor = colorFromProps(props, 'color', Colors.white);
    final outline = colorFromProps(props, 'outline', const Color(0xff111111));

    // Classic arrow pointer outline, tip at (0,0), in a ~16x22 box.
    final path =
        Path()
          ..moveTo(0, 0)
          ..lineTo(0, 16.4)
          ..lineTo(3.9, 12.6)
          ..lineTo(6.6, 18.8)
          ..lineTo(8.9, 17.8)
          ..lineTo(6.3, 11.7)
          ..lineTo(11.6, 11.7)
          ..close();

    canvas.save();
    canvas.translate(position.dx, position.dy);
    canvas.scale(scale);

    // Soft drop shadow.
    canvas.save();
    canvas.translate(0.8, 1.2);
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0x55000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
    );
    canvas.restore();

    canvas.drawPath(path, Paint()..color = fillColor);
    canvas.drawPath(
      path,
      Paint()
        ..color = outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CursorPainter old) =>
      old.position != position ||
      old.clickProgress != clickProgress ||
      old.props != props;
}
