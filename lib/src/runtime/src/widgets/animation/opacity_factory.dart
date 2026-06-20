import 'package:flutter/material.dart';
import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart' show PropertyKeys;

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Opacity widgets (v1.3)
///
/// Controls the visual opacity of a child widget.
/// Supports implicit animation when `animated: true`.
class OpacityWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Resolve and clamp opacity to [0.0, 1.0]
    final rawOpacity = context.resolve(properties[PropertyKeys.opacity]);
    final double opacity;
    if (rawOpacity is num) {
      opacity = rawOpacity.toDouble().clamp(0.0, 1.0);
    } else if (rawOpacity is String) {
      opacity = (double.tryParse(rawOpacity) ?? 1.0).clamp(0.0, 1.0);
    } else {
      opacity = 1.0;
    }

    final animated = context.resolve<bool>(properties[PropertyKeys.animated] ?? false);
    final duration = (context.resolve(properties[PropertyKeys.duration]) as num?)?.toInt() ?? 300;
    final curveStr = context.resolve<String?>(properties[PropertyKeys.curve]) ?? 'easeInOut';
    final curve = _parseCurve(curveStr);

    // Render child
    final childDef = properties[PropertyKeys.child] as Map<String, dynamic>?;
    final child = childDef != null
        ? context.buildWidget(childDef)
        : const SizedBox.shrink();

    Widget result;
    if (animated) {
      result = AnimatedOpacity(
        opacity: opacity,
        duration: Duration(milliseconds: duration),
        curve: curve,
        child: child,
      );
    } else {
      result = Opacity(
        opacity: opacity,
        child: child,
      );
    }

    return applyCommonWrappers(result, properties, context);
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
