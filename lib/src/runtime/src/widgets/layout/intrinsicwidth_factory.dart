import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for IntrinsicWidth widgets
class IntrinsicWidthWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final stepWidth = properties['stepWidth']?.toDouble();
    final stepHeight = properties['stepHeight']?.toDouble();

    // Extract child widget (support both 'child' and 'children' per MCP UI DSL spec)
    final childDef = (properties['child'] ?? definition['child'])
        as Map<String, dynamic>?;
    final childrenDef = properties['children'] as List<dynamic>? ??
        definition['children'] as List<dynamic>?;
    Widget? child;
    if (childDef != null) {
      child = context.buildWidget(childDef);
    } else if (childrenDef != null && childrenDef.isNotEmpty) {
      child = context.buildWidget(childrenDef.first as Map<String, dynamic>);
    }

    Widget intrinsicWidth = IntrinsicWidth(
      stepWidth: stepWidth,
      stepHeight: stepHeight,
      child: child,
    );

    return applyCommonWrappers(intrinsicWidth, properties, context);
  }
}
