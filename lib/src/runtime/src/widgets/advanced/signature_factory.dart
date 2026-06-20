/// Signature widget factory for MCP UI DSL v1.1
///
/// Provides a signature pad for capturing handwritten signatures.
library signature_factory;

import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Signature widgets
class SignatureWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final width = (properties['width'] as num?)?.toDouble();
    final height = (properties['height'] as num?)?.toDouble() ?? 200;

    // Style properties — theme-adaptive defaults. Pen defaults to the
    // on-surface text color so a dark-mode signature reads against the
    // dark surface; background falls back to the `surface` slot.
    final penColor = parseColor(properties['penColor'], context) ??
        context.themeManager.getColorValue('onSurface') ??
        Colors.black;
    final penWidth = (properties['penWidth'] as num?)?.toDouble() ?? 2.0;
    final backgroundColor =
        parseColor(properties['backgroundColor'], context) ??
            context.themeManager.getColorValue('surface') ??
            Colors.white;
    final borderColor = parseColor(properties['borderColor'], context) ??
        context.themeManager.getColorValue('outlineVariant') ??
        Colors.grey.shade300;
    final borderWidth = (properties['borderWidth'] as num?)?.toDouble() ?? 1.0;

    // Options
    final showClearButton = properties['showClearButton'] as bool? ?? true;
    final showGuide = properties['showGuide'] as bool? ?? true;

    // Action handlers
    final onSignatureStart =
        properties['onSignatureStart'] as Map<String, dynamic>?;
    final onSignatureEnd =
        properties['onSignatureEnd'] as Map<String, dynamic>?;
    final onClear = properties['onClear'] as Map<String, dynamic>?;

    // State binding
    final stateBinding = properties['binding'] as String?;

    Widget signature = _SignaturePad(
      penColor: penColor,
      penWidth: penWidth,
      backgroundColor: backgroundColor,
      borderColor: borderColor,
      borderWidth: borderWidth,
      showClearButton: showClearButton,
      showGuide: showGuide,
      onSignatureStart: onSignatureStart,
      onSignatureEnd: onSignatureEnd,
      onClear: onClear,
      stateBinding: stateBinding,
      context: context,
    );

    signature = SizedBox(
      width: width,
      height: height,
      child: signature,
    );

    return applyCommonWrappers(signature, properties, context);
  }
}

class _SignaturePad extends StatefulWidget {
  final Color penColor;
  final double penWidth;
  final Color backgroundColor;
  final Color borderColor;
  final double borderWidth;
  final bool showClearButton;
  final bool showGuide;
  final Map<String, dynamic>? onSignatureStart;
  final Map<String, dynamic>? onSignatureEnd;
  final Map<String, dynamic>? onClear;
  final String? stateBinding;
  final RenderContext context;

  const _SignaturePad({
    required this.penColor,
    required this.penWidth,
    required this.backgroundColor,
    required this.borderColor,
    required this.borderWidth,
    required this.showClearButton,
    required this.showGuide,
    this.onSignatureStart,
    this.onSignatureEnd,
    this.onClear,
    this.stateBinding,
    required this.context,
  });

  @override
  State<_SignaturePad> createState() => _SignaturePadState();
}

class _SignaturePadState extends State<_SignaturePad> {
  final List<List<Offset>> _strokes = [];
  List<Offset> _currentStroke = [];
  bool _hasSignature = false;

  void _onPanStart(DragStartDetails details) {
    setState(() {
      _currentStroke = [details.localPosition];
    });

    if (widget.onSignatureStart != null) {
      widget.context.actionHandler.execute(
        widget.onSignatureStart!,
        widget.context,
      );
    }
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() {
      _currentStroke.add(details.localPosition);
    });
  }

  void _onPanEnd(DragEndDetails details) {
    setState(() {
      if (_currentStroke.isNotEmpty) {
        _strokes.add(List.from(_currentStroke));
        _currentStroke = [];
        _hasSignature = true;
      }
    });

    _updateBinding();

    if (widget.onSignatureEnd != null) {
      final eventContext = widget.context.createChildContext(
        variables: {
          'event': {
            'strokeCount': _strokes.length,
            'hasSignature': _hasSignature,
          }
        },
      );
      widget.context.actionHandler.execute(
        widget.onSignatureEnd!,
        eventContext,
      );
    }
  }

  void _clear() {
    setState(() {
      _strokes.clear();
      _currentStroke = [];
      _hasSignature = false;
    });

    _updateBinding();

    if (widget.onClear != null) {
      widget.context.actionHandler.execute(widget.onClear!, widget.context);
    }
  }

  void _updateBinding() {
    if (widget.stateBinding != null) {
      // Update state with signature data
      widget.context.setValue(
        widget.stateBinding!,
        _hasSignature ? _serializeStrokes() : null,
      );
    }
  }

  Map<String, dynamic> _serializeStrokes() {
    return {
      'strokes': _strokes
          .map((stroke) => stroke.map((p) => {'x': p.dx, 'y': p.dy}).toList())
          .toList(),
      'strokeCount': _strokes.length,
      'timestamp': DateTime.now().toIso8601String(),
    };
  }

  Future<Uint8List?> toImage() async {
    if (!_hasSignature) return null;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = context.size ?? const Size(300, 200);

    // Draw background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = widget.backgroundColor,
    );

    // Draw strokes
    final paint = Paint()
      ..color = widget.penColor
      ..strokeWidth = widget.penWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (final stroke in _strokes) {
      if (stroke.length < 2) continue;
      final path = Path();
      path.moveTo(stroke[0].dx, stroke[0].dy);
      for (int i = 1; i < stroke.length; i++) {
        path.lineTo(stroke[i].dx, stroke[i].dy);
      }
      canvas.drawPath(path, paint);
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(size.width.toInt(), size.height.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    // Resolve theme-aware colors for built-in chrome (clear button +
    // guide + placeholder). Falls back to Flutter's ColorScheme when the
    // mcp_ui ThemeManager doesn't expose the slot, so the widget keeps
    // working under bare-MaterialApp hosts.
    final tm = widget.context.themeManager;
    final scheme = Theme.of(context).colorScheme;
    final clearBg =
        tm.getColorValue('secondaryContainer') ?? scheme.secondaryContainer;
    final clearFg = tm.getColorValue('onSecondaryContainer') ??
        scheme.onSecondaryContainer;
    final guideColor =
        tm.getColorValue('outlineVariant') ?? scheme.outlineVariant;
    final placeholderColor =
        tm.getColorValue('onSurfaceVariant') ?? scheme.onSurfaceVariant;

    return Container(
      decoration: BoxDecoration(
        color: widget.backgroundColor,
        border: Border.all(
          color: widget.borderColor,
          width: widget.borderWidth,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        children: [
          // Guide line
          if (widget.showGuide)
            Positioned(
              left: 16,
              right: 16,
              bottom: 40,
              child: Container(
                height: 1,
                color: guideColor,
              ),
            ),

          // Signature area
          Positioned.fill(
            child: GestureDetector(
              onPanStart: _onPanStart,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              child: CustomPaint(
                painter: _SignaturePainter(
                  strokes: _strokes,
                  currentStroke: _currentStroke,
                  penColor: widget.penColor,
                  penWidth: widget.penWidth,
                ),
              ),
            ),
          ),

          // Clear button
          if (widget.showClearButton && _hasSignature)
            Positioned(
              top: 8,
              right: 8,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _clear,
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: clearBg,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.clear, size: 14, color: clearFg),
                        const SizedBox(width: 4),
                        Text(
                          'Clear',
                          style: TextStyle(fontSize: 12, color: clearFg),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // Placeholder text when empty
          if (!_hasSignature && _currentStroke.isEmpty)
            Center(
              child: Text(
                'Sign here',
                style: TextStyle(
                  color: placeholderColor,
                  fontSize: 16,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SignaturePainter extends CustomPainter {
  final List<List<Offset>> strokes;
  final List<Offset> currentStroke;
  final Color penColor;
  final double penWidth;

  _SignaturePainter({
    required this.strokes,
    required this.currentStroke,
    required this.penColor,
    required this.penWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = penColor
      ..strokeWidth = penWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    // Draw completed strokes
    for (final stroke in strokes) {
      _drawStroke(canvas, stroke, paint);
    }

    // Draw current stroke
    if (currentStroke.isNotEmpty) {
      _drawStroke(canvas, currentStroke, paint);
    }
  }

  void _drawStroke(Canvas canvas, List<Offset> points, Paint paint) {
    if (points.length < 2) {
      // Draw a dot for single point
      if (points.length == 1) {
        canvas.drawCircle(points[0], penWidth / 2, paint..style = PaintingStyle.fill);
        paint.style = PaintingStyle.stroke;
      }
      return;
    }

    final path = Path();
    path.moveTo(points[0].dx, points[0].dy);

    // Use quadratic bezier for smoother lines
    for (int i = 1; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final midX = (p0.dx + p1.dx) / 2;
      final midY = (p0.dy + p1.dy) / 2;
      path.quadraticBezierTo(p0.dx, p0.dy, midX, midY);
    }

    // Connect to the last point
    if (points.length > 1) {
      final last = points.last;
      path.lineTo(last.dx, last.dy);
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SignaturePainter oldDelegate) {
    return strokes != oldDelegate.strokes ||
        currentStroke != oldDelegate.currentStroke ||
        penColor != oldDelegate.penColor ||
        penWidth != oldDelegate.penWidth;
  }
}
