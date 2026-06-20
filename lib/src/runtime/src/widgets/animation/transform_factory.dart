import 'package:flutter/material.dart';
import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart' show PropertyKeys;

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Transform widgets (v1.3)
///
/// Applies geometric transformations (rotate, scale, translate) to a child widget.
/// Supports implicit animation when `animated: true`.
class TransformWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final rotate = _toDouble(context.resolve(properties[PropertyKeys.rotate]));
    final translate = _resolveTranslate(context, properties[PropertyKeys.translate]);
    final scale = _resolveScale(context, properties[PropertyKeys.scale]);
    final origin = _resolveOrigin(context, properties[PropertyKeys.origin]);

    final animated = context.resolve<bool>(properties[PropertyKeys.animated] ?? false);
    final duration = (context.resolve(properties[PropertyKeys.duration]) as num?)?.toInt() ?? 300;
    final curveStr = context.resolve<String?>(properties[PropertyKeys.curve]) ?? 'easeInOut';
    final curve = _parseCurve(curveStr);

    // Render child
    final childDef = properties[PropertyKeys.child] as Map<String, dynamic>?;
    final child = childDef != null
        ? context.buildWidget(childDef)
        : const SizedBox.shrink();

    // Build transform matrix: translate, rotate, scale (per DDD spec)
    // ignore: deprecated_member_use
    final matrix = Matrix4.identity()
      // ignore: deprecated_member_use
      ..translate(translate.dx, translate.dy)
      ..rotateZ(rotate)
      // ignore: deprecated_member_use
      ..scale(scale.dx, scale.dy);

    Widget result;
    if (animated) {
      result = AnimatedContainer(
        duration: Duration(milliseconds: duration),
        curve: curve,
        transform: matrix,
        transformAlignment: Alignment(
          origin.dx * 2 - 1, // Convert 0-1 fraction to -1 to 1
          origin.dy * 2 - 1,
        ),
        child: child,
      );
    } else {
      result = Transform(
        transform: matrix,
        origin: origin != const Offset(0.5, 0.5)
            ? null // Will use alignment instead
            : null,
        alignment: Alignment(
          origin.dx * 2 - 1,
          origin.dy * 2 - 1,
        ),
        child: child,
      );
    }

    return applyCommonWrappers(result, properties, context);
  }

  Offset _resolveTranslate(RenderContext context, dynamic value) {
    if (value == null) return Offset.zero;
    if (value is Map) {
      final x = _toDouble(context.resolve(value['x']));
      final y = _toDouble(context.resolve(value['y']));
      return Offset(x, y);
    }
    return Offset.zero;
  }

  Offset _resolveScale(RenderContext context, dynamic value) {
    if (value == null) return const Offset(1.0, 1.0);
    final resolved = context.resolve(value);
    if (resolved is num) {
      final s = resolved.toDouble();
      return Offset(s, s);
    }
    if (resolved is Map) {
      final x = _toDouble(resolved['x'] ?? 1.0);
      final y = _toDouble(resolved['y'] ?? 1.0);
      return Offset(x, y);
    }
    if (resolved is String) {
      final s = double.tryParse(resolved) ?? 1.0;
      return Offset(s, s);
    }
    return const Offset(1.0, 1.0);
  }

  Offset _resolveOrigin(RenderContext context, dynamic value) {
    if (value == null) return const Offset(0.5, 0.5); // Default: center
    if (value is Map) {
      final x = _toDouble(context.resolve(value['x'] ?? 0.5));
      final y = _toDouble(context.resolve(value['y'] ?? 0.5));
      return Offset(x, y);
    }
    return const Offset(0.5, 0.5);
  }

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  Curve _parseCurve(String name) {
    return switch (name) {
      'linear' => Curves.linear,
      'easeIn' => Curves.easeIn,
      'easeOut' => Curves.easeOut,
      'easeInOut' => Curves.easeInOut,
      'bounceIn' => Curves.bounceIn,
      'bounceOut' => Curves.bounceOut,
      'elasticIn' => Curves.elasticIn,
      'elasticOut' => Curves.elasticOut,
      _ => Curves.easeInOut,
    };
  }
}
