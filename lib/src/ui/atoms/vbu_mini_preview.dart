import 'package:flutter/material.dart';

import '../tokens.dart';

/// 8-layer mini sketch — each layer card in the Overview Strip shows a
/// per-layer visual signature (App tree · Theme swatches · Components
/// pair · Dashboard grid · Navigation rail · Page bars · Assets folder ·
/// Whole grid). Drawn via CustomPaint so we stay in the vbu_studio_ui
/// scope (no Material widget dependencies for the sketch itself).
///
/// `layer` accepts the focused-state enum strings:
///   appStructure · theme · components · dashboard · navigation · pages
///   · assets · whole.
/// Unknown values render an empty box (no crash).
class VbuMiniPreview extends StatelessWidget {
  const VbuMiniPreview({
    super.key,
    required this.layer,
    this.size = const Size(140, 48),
    this.color,
  });

  final String layer;
  final Size size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final palette = VbuTokens.colorOf(context);
    final accent = color ?? _layerColor(context, layer);
    return CustomPaint(
      size: size,
      painter: _MiniPainter(layer: layer, accent: accent, palette: palette),
    );
  }

  static Color _layerColor(BuildContext context, String layer) {
    final c = VbuTokens.colorOf(context);
    switch (layer) {
      case 'appStructure':
        return c.layerApp;
      case 'theme':
        return c.layerTheme;
      case 'components':
        return c.layerComponent;
      case 'dashboard':
        return c.layerDashboard;
      case 'navigation':
        return c.layerNavigation;
      case 'pages':
        return c.layerPage;
      case 'assets':
        return c.layerAssets;
      case 'whole':
        return c.layerWhole;
      default:
        return c.textTertiary;
    }
  }
}

class _MiniPainter extends CustomPainter {
  _MiniPainter({
    required this.layer,
    required this.accent,
    required this.palette,
  });

  final String layer;
  final Color accent;
  final dynamic palette;

  @override
  void paint(Canvas canvas, Size size) {
    final c = palette;
    final stroke =
        Paint()
          ..color = c.borderStrong
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0;
    final fill = Paint()..color = accent;
    final faint = Paint()..color = c.textTertiary.withValues(alpha: 0.45);

    switch (layer) {
      case 'appStructure':
        _paintApp(canvas, size, fill, stroke);
        break;
      case 'theme':
        _paintTheme(canvas, size, accent);
        break;
      case 'components':
        _paintComponents(canvas, size, fill, stroke);
        break;
      case 'dashboard':
        _paintDashboard(canvas, size, fill, faint);
        break;
      case 'navigation':
        _paintNavigation(canvas, size, fill, faint);
        break;
      case 'pages':
        _paintPages(canvas, size, fill, faint);
        break;
      case 'assets':
        _paintAssets(canvas, size, fill, faint);
        break;
      case 'whole':
        _paintWhole(canvas, size, fill, faint);
        break;
      default:
        canvas.drawRect(Offset.zero & size, stroke);
    }
  }

  // App — rounded square icon + 4 dots horizontally
  void _paintApp(Canvas canvas, Size size, Paint fill, Paint stroke) {
    final cy = size.height / 2;
    final iconRect = Rect.fromLTWH(8, cy - 9, 18, 18);
    canvas.drawRRect(
      RRect.fromRectAndRadius(iconRect, const Radius.circular(4)),
      fill,
    );
    for (var i = 0; i < 4; i++) {
      canvas.drawCircle(Offset(38 + i * 12.0, cy), 2.0, fill);
    }
  }

  // Theme — 5 color swatches
  void _paintTheme(Canvas canvas, Size size, Color accent) {
    final c = palette;
    final swatches = <Color>[
      c.layerApp,
      c.layerTheme,
      c.layerComponent,
      c.layerDashboard,
      c.layerNavigation,
    ];
    final cy = size.height / 2;
    for (var i = 0; i < swatches.length; i++) {
      final p = Paint()..color = swatches[i];
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(8 + i * 14.0, cy - 6, 12, 12),
          const Radius.circular(3),
        ),
        p,
      );
    }
  }

  // Components — 2 button shapes side by side
  void _paintComponents(Canvas canvas, Size size, Paint fill, Paint stroke) {
    final cy = size.height / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(8, cy - 8, 32, 16),
        const Radius.circular(4),
      ),
      fill,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(48, cy - 8, 32, 16),
        const Radius.circular(4),
      ),
      stroke,
    );
  }

  // Dashboard — 3×2 grid skeleton
  void _paintDashboard(Canvas canvas, Size size, Paint fill, Paint faint) {
    const cols = 3;
    const rows = 2;
    final cellW = (size.width - 16 - 8) / cols;
    final cellH = (size.height - 12) / rows;
    for (var r = 0; r < rows; r++) {
      for (var col = 0; col < cols; col++) {
        final isAccent = (r == 0 && col == 0);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              8 + col * (cellW + 4),
              6 + r * (cellH + 4),
              cellW,
              cellH,
            ),
            const Radius.circular(3),
          ),
          isAccent ? fill : faint,
        );
      }
    }
  }

  // Navigation — left rail + 3 text rows
  void _paintNavigation(Canvas canvas, Size size, Paint fill, Paint faint) {
    canvas.drawRect(Rect.fromLTWH(8, 6, 6, size.height - 12), fill);
    for (var i = 0; i < 3; i++) {
      canvas.drawRect(Rect.fromLTWH(22, 8 + i * 10, size.width - 30, 4), faint);
    }
  }

  // Pages — top bar + 2 rows
  void _paintPages(Canvas canvas, Size size, Paint fill, Paint faint) {
    canvas.drawRect(Rect.fromLTWH(8, 6, size.width - 16, 8), fill);
    canvas.drawRect(Rect.fromLTWH(8, 20, size.width - 24, 4), faint);
    canvas.drawRect(Rect.fromLTWH(8, 28, size.width - 36, 4), faint);
    canvas.drawRect(Rect.fromLTWH(8, 36, size.width - 28, 4), faint);
  }

  // Assets — folder tab + 3 file rows
  void _paintAssets(Canvas canvas, Size size, Paint fill, Paint faint) {
    // Folder tab
    canvas.drawRect(Rect.fromLTWH(8, 6, 18, 4), fill);
    canvas.drawRect(
      Rect.fromLTWH(8, 10, size.width - 16, size.height - 16),
      faint,
    );
    for (var i = 0; i < 3; i++) {
      canvas.drawRect(
        Rect.fromLTWH(12, 16 + i * 8, size.width - 24, 3),
        fill..color = fill.color.withValues(alpha: 0.7),
      );
    }
  }

  // Whole — 2×3 page thumbnail grid
  void _paintWhole(Canvas canvas, Size size, Paint fill, Paint faint) {
    const cols = 3;
    const rows = 2;
    final cellW = (size.width - 16 - 8) / cols;
    final cellH = (size.height - 12) / rows;
    for (var r = 0; r < rows; r++) {
      for (var col = 0; col < cols; col++) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              8 + col * (cellW + 4),
              6 + r * (cellH + 4),
              cellW,
              cellH,
            ),
            const Radius.circular(3),
          ),
          (r + col).isEven ? fill : faint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MiniPainter old) =>
      old.layer != layer || old.accent != accent;
}
