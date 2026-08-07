import 'package:flutter/material.dart';

import '../../assets/asset_ref.dart';
import '../../renderer/render_context.dart';
import '../widget_factory.dart';
import 'qr_encoder.dart';

/// Factory for `qrCode` (spec §10.23).
class QrCodeFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final value = context.resolve<String?>(properties['value']) ?? '';
    final size = context.resolve<num?>(properties['size'])?.toDouble() ?? 200.0;
    final margin = context.resolve<bool?>(properties['margin']) ?? true;
    final ec = _ecFrom(context.resolve<String?>(properties['errorCorrection']));
    final fg = parseColor(context.resolve(properties['foregroundColor']), context) ??
        const Color(0xFF000000);
    final bg = parseColor(context.resolve(properties['backgroundColor']), context) ??
        const Color(0xFFFFFFFF);

    if (value.isEmpty) return SizedBox(width: size, height: size);

    QrSymbol symbol;
    try {
      symbol = encodeQr(value.codeUnits, ec);
    } on QrTooLongException {
      // Reported rather than truncated: a code that encodes part of a payload
      // scans cleanly and carries the wrong thing, which is worse than none.
      return _unrenderable(size, 'Payload too long for a QR code');
    }

    // Contrast below this cannot be read reliably by a scanner, so the widget
    // refuses rather than emitting an unreadable code (spec §10.23).
    if (_contrast(fg, bg) < 3.0) {
      return _unrenderable(size, 'QR contrast too low to scan');
    }

    final logoRef = AssetRef.parse(context.resolve(properties['logo']));
    final logoProvider =
        logoRef == null ? null : context.assetResolver.imageProviderFor(logoRef);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(size, size),
            painter: _QrPainter(
              symbol: symbol,
              foreground: fg,
              background: bg,
              quietZone: margin ? 4 : 0,
            ),
          ),
          if (logoProvider != null)
            SizedBox(
              // A quarter of the edge is the largest overlay high error
              // correction reliably survives.
              width: size * 0.22,
              height: size * 0.22,
              child: Image(image: logoProvider, fit: BoxFit.contain),
            ),
        ],
      ),
    );
  }

  static Widget _unrenderable(double size, String reason) => SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Text(
            reason,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11),
          ),
        ),
      );

  static QrErrorCorrection _ecFrom(String? value) {
    switch (value) {
      // Canonical (§17.1.3 lower case).
      case 'low':
        return QrErrorCorrection.l;
      case 'quartile':
        return QrErrorCorrection.q;
      case 'high':
        return QrErrorCorrection.h;
      case 'medium':
        return QrErrorCorrection.m;
      // The QR standard's own single letters — kept as legacy aliases, not
      // part of the canonical surface (§17.3).
      case 'L':
        return QrErrorCorrection.l;
      case 'Q':
        return QrErrorCorrection.q;
      case 'H':
        return QrErrorCorrection.h;
      default:
        return QrErrorCorrection.m;
    }
  }

  static double _contrast(Color a, Color b) {
    double luminance(Color c) => c.computeLuminance();
    final la = luminance(a), lb = luminance(b);
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }
}

class _QrPainter extends CustomPainter {
  const _QrPainter({
    required this.symbol,
    required this.foreground,
    required this.background,
    required this.quietZone,
  });

  final QrSymbol symbol;
  final Color foreground;
  final Color background;
  final int quietZone;

  @override
  void paint(Canvas canvas, Size size) {
    final total = symbol.size + quietZone * 2;
    final module = size.width / total;

    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = background,
    );

    final paint = Paint()..color = foreground;
    for (var y = 0; y < symbol.size; y++) {
      for (var x = 0; x < symbol.size; x++) {
        if (!symbol.isDark(x, y)) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            (x + quietZone) * module,
            (y + quietZone) * module,
            // Half a device pixel of overlap: adjacent modules must not show
            // a seam after rounding, which a scanner reads as a light module.
            module + 0.5,
            module + 0.5,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) =>
      old.symbol != symbol ||
      old.foreground != foreground ||
      old.background != background ||
      old.quietZone != quietZone;
}
