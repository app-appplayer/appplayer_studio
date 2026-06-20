/// Speech bubble + connector line painters.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'shared.dart';

class SpeechBubbleOverlay extends StatelessWidget {
  const SpeechBubbleOverlay({
    super.key,
    required this.target,
    required this.props,
  });
  final Rect target;
  final Map<String, dynamic> props;

  @override
  Widget build(BuildContext context) {
    final text = stringProp(props, 'text', '');
    final tailSide = stringProp(props, 'tailSide', 'bottom');
    final color = colorFromProps(props, 'color', kBgScrim);
    final textColor = colorFromProps(props, 'textColor', kTextOnDark);
    final approxW = (text.length * 8.0).clamp(80.0, 280.0);
    const approxH = 56.0;
    double left, top;
    switch (tailSide) {
      case 'top':
        left = target.center.dx - approxW / 2;
        top = target.bottom + 18;
        break;
      case 'left':
        left = target.right + 18;
        top = target.center.dy - approxH / 2;
        break;
      case 'right':
        left = target.left - approxW - 18;
        top = target.center.dy - approxH / 2;
        break;
      case 'bottom':
      default:
        left = target.center.dx - approxW / 2;
        top = target.top - approxH - 18;
    }
    return Positioned(
      left: left,
      top: top,
      child: CustomPaint(
        painter: _BubbleTailPainter(
          tailSide: tailSide,
          color: color,
          bubbleSize: Size(approxW, approxH),
        ),
        child: Container(
          width: approxW,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            text,
            style: TextStyle(
              color: textColor,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
        ),
      ),
    );
  }
}

class _BubbleTailPainter extends CustomPainter {
  _BubbleTailPainter({
    required this.tailSide,
    required this.color,
    required this.bubbleSize,
  });
  final String tailSide;
  final Color color;
  final Size bubbleSize;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final w = bubbleSize.width;
    final h = bubbleSize.height;
    final p = Path();
    switch (tailSide) {
      case 'top':
        p.moveTo(w / 2 - 8, 0);
        p.lineTo(w / 2, -8);
        p.lineTo(w / 2 + 8, 0);
        break;
      case 'left':
        p.moveTo(0, h / 2 - 8);
        p.lineTo(-8, h / 2);
        p.lineTo(0, h / 2 + 8);
        break;
      case 'right':
        p.moveTo(w, h / 2 - 8);
        p.lineTo(w + 8, h / 2);
        p.lineTo(w, h / 2 + 8);
        break;
      case 'bottom':
      default:
        p.moveTo(w / 2 - 8, h);
        p.lineTo(w / 2, h + 8);
        p.lineTo(w / 2 + 8, h);
    }
    p.close();
    canvas.drawPath(p, paint);
  }

  @override
  bool shouldRepaint(covariant _BubbleTailPainter old) =>
      old.tailSide != tailSide || old.color != color;
}

/// `connector_line` painter — line or arrow between two resolved
/// points. draw-on along the path with arrow head appearing near end.
class ConnectorLinePainter extends CustomPainter {
  ConnectorLinePainter({
    required this.from,
    required this.to,
    required this.progress,
    required this.props,
  });
  final Offset from;
  final Offset to;
  final double progress;
  final Map<String, dynamic> props;

  @override
  void paint(Canvas canvas, Size size) {
    final color = colorFromProps(props, 'color', kAccentMint);
    final stroke = doubleProp(props, 'stroke', 2.5);
    final style = stringProp(props, 'style', 'arrow');
    final p =
        Path()
          ..moveTo(from.dx, from.dy)
          ..lineTo(to.dx, to.dy);
    final paint =
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round;
    canvas.drawPath(slicePath(p, progress), paint);
    if (style == 'arrow' && progress > 0.85) {
      final dir = math.atan2(to.dy - from.dy, to.dx - from.dx);
      const headLen = 10.0;
      const headAngle = 0.4;
      final h1 =
          to -
          Offset(
            math.cos(dir - headAngle) * headLen,
            math.sin(dir - headAngle) * headLen,
          );
      final h2 =
          to -
          Offset(
            math.cos(dir + headAngle) * headLen,
            math.sin(dir + headAngle) * headLen,
          );
      final headPath =
          Path()
            ..moveTo(to.dx, to.dy)
            ..lineTo(h1.dx, h1.dy)
            ..lineTo(h2.dx, h2.dy)
            ..close();
      canvas.drawPath(headPath, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant ConnectorLinePainter old) =>
      old.progress != progress || old.from != from || old.to != to;
}
