import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Placeholder widgets
class PlaceholderWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final color = parseColor(context.resolve(properties['color']), context) ??
        context.themeManager.getColorValue('onSurface') ??
        const Color(0xFF455A64); // Theme-aware grey stroke
    final strokeWidth = parseDimension(properties['strokeWidth']) ?? 2.0;
    final fallbackWidth = parseDimension(properties['fallbackWidth']) ?? 400.0;
    final fallbackHeight = parseDimension(properties['fallbackHeight']) ?? 400.0;

    // Spec §2.5.12 canonical `child`. Accept legacy `children[0]`.
    final childDef = (properties['child'] ?? definition['child'])
        as Map<String, dynamic>?;
    Widget? child;
    if (childDef != null) {
      child = context.buildWidget(childDef);
    } else {
      final childrenDef = properties['children'] as List<dynamic>? ??
          definition['children'] as List<dynamic>?;
      if (childrenDef != null && childrenDef.isNotEmpty) {
        child = context.buildWidget(childrenDef.first as Map<String, dynamic>);
      }
    }

    Widget placeholder = Placeholder(
      color: color,
      strokeWidth: strokeWidth,
      fallbackWidth: fallbackWidth,
      fallbackHeight: fallbackHeight,
      child: child,
    );

    return applyCommonWrappers(placeholder, properties, context);
  }
}
