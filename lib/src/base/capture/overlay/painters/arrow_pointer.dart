/// Arrow + text label pointing at a target rect. The label sits on
/// the `anchor` side; the arrow shaft connects label-mid to target-edge.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'shared.dart';

class ArrowPointerPainter extends CustomPainter {
  ArrowPointerPainter({
    required this.target,
    required this.progress,
    required this.text,
    required this.props,
    required this.textPainter,
  });
  final Rect target;
  final double progress;
  final String text;
  final Map<String, dynamic> props;
  final TextPainter textPainter;

  @override
  void paint(Canvas canvas, Size size) {
    final color = colorFromProps(props, 'color', kAccentMint);
    final stroke = doubleProp(props, 'stroke', 2.5);
    final anchor = stringProp(props, 'anchor', 'above');
    final gap = doubleProp(props, 'gap', 36);
    final paint =
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round;
    Offset labelCenter;
    Offset targetEdge;
    switch (anchor) {
      case 'below':
        targetEdge = Offset(target.center.dx, target.bottom);
        labelCenter = Offset(target.center.dx, target.bottom + gap);
        break;
      case 'left':
        targetEdge = Offset(target.left, target.center.dy);
        labelCenter = Offset(target.left - gap, target.center.dy);
        break;
      case 'right':
        targetEdge = Offset(target.right, target.center.dy);
        labelCenter = Offset(target.right + gap, target.center.dy);
        break;
      case 'above':
      default:
        targetEdge = Offset(target.center.dx, target.top);
        labelCenter = Offset(target.center.dx, target.top - gap);
    }
    final shaft =
        Path()
          ..moveTo(labelCenter.dx, labelCenter.dy)
          ..lineTo(targetEdge.dx, targetEdge.dy);
    canvas.drawPath(slicePath(shaft, progress), paint);
    // Arrow head — only once the shaft has drawn past 80% so the
    // tip lands on the target.
    if (progress > 0.8) {
      final tipDir = (targetEdge - labelCenter).direction; // radians
      const headLen = 10.0;
      const headAngle = 0.4; // radians from shaft axis
      final h1 =
          targetEdge -
          Offset(math.cos(tipDir - headAngle), math.sin(tipDir - headAngle)) *
              headLen;
      final h2 =
          targetEdge -
          Offset(math.cos(tipDir + headAngle), math.sin(tipDir + headAngle)) *
              headLen;
      final headPaint =
          Paint()
            ..color = color
            ..style = PaintingStyle.fill;
      final headPath =
          Path()
            ..moveTo(targetEdge.dx, targetEdge.dy)
            ..lineTo(h1.dx, h1.dy)
            ..lineTo(h2.dx, h2.dy)
            ..close();
      canvas.drawPath(headPath, headPaint);
    }
    // Label box + text — only once progress > 0.1 so the label
    // pops in just after the shaft starts.
    if (progress > 0.05 && text.isNotEmpty) {
      textPainter.layout();
      final tw = textPainter.width;
      final th = textPainter.height;
      const padX = 10.0;
      const padY = 6.0;
      final box = Rect.fromCenter(
        center: labelCenter,
        width: tw + padX * 2,
        height: th + padY * 2,
      );
      final boxPaint = Paint()..color = kBgScrim;
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, const Radius.circular(6)),
        boxPaint,
      );
      textPainter.paint(canvas, Offset(box.left + padX, box.top + padY));
    }
  }

  @override
  bool shouldRepaint(covariant ArrowPointerPainter old) =>
      old.progress != progress || old.target != target || old.text != text;
}
