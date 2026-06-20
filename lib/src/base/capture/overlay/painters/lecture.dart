/// Lecture-style markup painters bundled into one `LecturePainter`
/// dispatching on [OverlayKind]. Shares the draw-on path-extraction
/// scheme so authors get a consistent "drawn live" feel across
/// underline / strikethrough / highlighter / box_outline / bracket
/// / numbered_label.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../overlay_models.dart';
import 'shared.dart';

class LecturePainter extends CustomPainter {
  LecturePainter({
    required this.kind,
    required this.target,
    required this.targets,
    required this.progress,
    required this.props,
  });
  final OverlayKind kind;
  final Rect? target;
  final List<Rect>? targets;
  final double progress;
  final Map<String, dynamic> props;

  @override
  void paint(Canvas canvas, Size size) {
    switch (kind) {
      case OverlayKind.underline:
        _drawUnderline(canvas);
        break;
      case OverlayKind.strikethrough:
        _drawStrikethrough(canvas);
        break;
      case OverlayKind.highlighter:
        _drawHighlighter(canvas);
        break;
      case OverlayKind.boxOutline:
        _drawBoxOutline(canvas);
        break;
      case OverlayKind.bracket:
        _drawBracket(canvas);
        break;
      case OverlayKind.numberedLabel:
        _drawNumbered(canvas);
        break;
      default:
        break;
    }
  }

  void _drawUnderline(Canvas canvas) {
    final r = target;
    if (r == null) return;
    final style = stringProp(props, 'style', 'straight');
    final color = colorFromProps(props, 'color', kAccentMint);
    final thickness = doubleProp(props, 'thickness', 3);
    final pad = doubleProp(props, 'padding', 2);
    final y = r.bottom + pad;
    final p = Path();
    if (style == 'wavy') {
      final amp = doubleProp(props, 'amplitude', 3);
      final freq = doubleProp(props, 'frequency', 0.18);
      var x = r.left;
      p.moveTo(x, y);
      while (x < r.right) {
        x += 2;
        p.lineTo(x, y + amp * math.sin(x * freq));
      }
    } else if (style == 'double') {
      p.moveTo(r.left, y - thickness * 0.8);
      p.lineTo(r.right, y - thickness * 0.8);
      p.moveTo(r.left, y + thickness * 0.8);
      p.lineTo(r.right, y + thickness * 0.8);
    } else if (style == 'dashed') {
      const dash = 6.0;
      const gap = 4.0;
      var x = r.left;
      while (x < r.right) {
        p.moveTo(x, y);
        p.lineTo(math.min(x + dash, r.right), y);
        x += dash + gap;
      }
    } else {
      p.moveTo(r.left, y);
      p.lineTo(r.right, y);
    }
    final drawn = slicePath(p, progress);
    final paint =
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = thickness
          ..strokeCap = StrokeCap.round;
    canvas.drawPath(drawn, paint);
  }

  void _drawStrikethrough(Canvas canvas) {
    final r = target;
    if (r == null) return;
    final color = colorFromProps(props, 'color', kAccentRed);
    final thickness = doubleProp(props, 'thickness', 2.5);
    final y = r.center.dy;
    final p =
        Path()
          ..moveTo(r.left, y)
          ..lineTo(r.right, y);
    canvas.drawPath(
      slicePath(p, progress),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness
        ..strokeCap = StrokeCap.round,
    );
  }

  void _drawHighlighter(Canvas canvas) {
    final r = target;
    if (r == null) return;
    final color = colorFromProps(props, 'color', kAccentYellow);
    final opacity = doubleProp(props, 'opacity', 0.35);
    final pad = doubleProp(props, 'padding', 2);
    final widthFrac = progress.clamp(0.0, 1.0);
    final rect = Rect.fromLTWH(
      r.left - pad,
      r.top - pad,
      (r.width + pad * 2) * widthFrac,
      r.height + pad * 2,
    );
    canvas.drawRect(rect, Paint()..color = color.withOpacity(opacity));
  }

  void _drawBoxOutline(Canvas canvas) {
    final r = target;
    if (r == null) return;
    final color = colorFromProps(props, 'color', kAccentMint);
    final stroke = doubleProp(props, 'stroke', 2.5);
    final corners = stringProp(props, 'corners', 'rounded');
    final radius = corners == 'square' ? 0.0 : doubleProp(props, 'radius', 6);
    final pad = doubleProp(props, 'padding', 4);
    final padded = r.inflate(pad);
    final p =
        Path()
          ..addRRect(RRect.fromRectAndRadius(padded, Radius.circular(radius)));
    canvas.drawPath(
      slicePath(p, progress),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void _drawBracket(Canvas canvas) {
    final ts = targets;
    if (ts == null || ts.isEmpty) return;
    final top = ts.reduce((a, b) => a.top < b.top ? a : b);
    final bot = ts.reduce((a, b) => a.bottom > b.bottom ? a : b);
    final color = colorFromProps(props, 'color', kAccentMint);
    final stroke = doubleProp(props, 'stroke', 2.5);
    final side = stringProp(props, 'side', 'right');
    final tipLen = doubleProp(props, 'tip', 12);
    final gap = doubleProp(props, 'gap', 12);
    final xSpine =
        side == 'left'
            ? ts.map((r) => r.left).reduce(math.min) - gap
            : ts.map((r) => r.right).reduce(math.max) + gap;
    final tipDx = side == 'left' ? -tipLen : tipLen;
    final p =
        Path()
          ..moveTo(xSpine - tipDx, top.top)
          ..lineTo(xSpine, top.top)
          ..lineTo(xSpine, bot.bottom)
          ..lineTo(xSpine - tipDx, bot.bottom);
    canvas.drawPath(
      slicePath(p, progress),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void _drawNumbered(Canvas canvas) {
    final r = target;
    if (r == null) return;
    final index = intProp(props, 'index', 1);
    final style = stringProp(props, 'style', 'circle');
    final color = colorFromProps(props, 'color', kAccentMint);
    final size = doubleProp(props, 'size', 28);
    final side = stringProp(props, 'side', 'left');
    final dx = side == 'right' ? r.right + 8 + size / 2 : r.left - 8 - size / 2;
    final dy = r.center.dy;
    // Scale-in (elastic-like) on progress
    final scale = (progress * 1.4).clamp(0.0, 1.4);
    final eff = scale > 1.0 ? 1.0 + (1.0 - scale) * 0.3 : scale;
    final shape = Paint()..color = color;
    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(eff);
    if (style == 'square') {
      final rect = Rect.fromCenter(
        center: Offset.zero,
        width: size,
        height: size,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        shape,
      );
    } else {
      canvas.drawCircle(Offset.zero, size / 2, shape);
    }
    final tp = TextPainter(
      text: TextSpan(
        text: '$index',
        style: TextStyle(
          color: const Color(0xff0a0a0a),
          fontSize: size * 0.55,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant LecturePainter old) =>
      old.progress != progress || old.target != target;
}
