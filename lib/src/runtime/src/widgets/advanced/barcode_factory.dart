import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';
import 'barcode_encoder.dart';

/// Factory for `barcode` (spec §10.24).
class BarcodeFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final value = context.resolve<String?>(properties['value']) ?? '';
    final format = _formatFrom(context.resolve<String?>(properties['format']));
    final height =
        context.resolve<num?>(properties['height'])?.toDouble() ?? 80.0;
    final width = context.resolve<num?>(properties['width'])?.toDouble();
    final displayValue =
        context.resolve<bool?>(properties['displayValue']) ?? true;
    final fg = parseColor(context.resolve(properties['foregroundColor']), context) ??
        const Color(0xFF000000);
    final bg = parseColor(context.resolve(properties['backgroundColor']), context) ??
        const Color(0xFFFFFFFF);

    if (value.isEmpty) return SizedBox(height: height);

    BarcodePattern pattern;
    try {
      pattern = encodeBarcode(value, format);
    } on BarcodeFormatException catch (e) {
      // Reported, never rendered wrong: a barcode that scans as the wrong
      // number is worse than one that does not render.
      return SizedBox(
        height: height,
        child: Center(
          child: Text(e.reason, style: const TextStyle(fontSize: 11)),
        ),
      );
    }

    // Omitting `width` means intrinsic — the natural width for the module
    // count, which is what stays scannable at any density.
    final intrinsic = pattern.moduleCount.toDouble();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: width ?? intrinsic,
          height: height,
          child: CustomPaint(
            painter: _BarcodePainter(
              pattern: pattern,
              foreground: fg,
              background: bg,
            ),
          ),
        ),
        if (displayValue)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              pattern.text,
              style: const TextStyle(fontSize: 12, letterSpacing: 2),
            ),
          ),
      ],
    );
  }

  static BarcodeFormat _formatFrom(String? value) {
    switch (value) {
      case 'code39':
        return BarcodeFormat.code39;
      case 'ean13':
        return BarcodeFormat.ean13;
      case 'ean8':
        return BarcodeFormat.ean8;
      case 'upcA':
        return BarcodeFormat.upcA;
      case 'upcE':
        return BarcodeFormat.upcE;
      case 'itf':
        return BarcodeFormat.itf;
      case 'codabar':
        return BarcodeFormat.codabar;
      case 'code128':
      default:
        return BarcodeFormat.code128;
    }
  }
}

class _BarcodePainter extends CustomPainter {
  const _BarcodePainter({
    required this.pattern,
    required this.foreground,
    required this.background,
  });

  final BarcodePattern pattern;
  final Color foreground;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = background,
    );
    final module = size.width / pattern.moduleCount;
    final paint = Paint()..color = foreground;
    for (var i = 0; i < pattern.bars.length; i++) {
      if (!pattern.bars[i]) continue;
      canvas.drawRect(
        // Half-pixel overlap so rounding cannot open a light seam between
        // adjacent dark modules.
        Rect.fromLTWH(i * module, 0, module + 0.5, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarcodePainter old) =>
      old.pattern != pattern ||
      old.foreground != foreground ||
      old.background != background;
}
