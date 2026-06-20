import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Divider widgets
class DividerWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final height = parseDimension(properties['height']);
    final thickness = parseDimension(properties['thickness']) ?? 1.0;
    final indent = parseDimension(properties['indent']) ?? 0.0;
    final endIndent = parseDimension(properties['endIndent']) ?? 0.0;
    final color = parseColor(context.resolve(properties['color']), context);
    final isVertical = properties['vertical'] as bool? ?? false;

    Widget divider;

    if (isVertical) {
      divider = VerticalDivider(
        width: height,
        thickness: thickness,
        indent: indent,
        endIndent: endIndent,
        color: color,
      );
    } else {
      divider = Divider(
        height: height,
        thickness: thickness,
        indent: indent,
        endIndent: endIndent,
        color: color,
      );
    }

    return applyCommonWrappers(divider, properties, context);
  }
}
