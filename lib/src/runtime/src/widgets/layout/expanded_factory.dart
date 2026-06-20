import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Expanded widgets
class ExpandedWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract child - check both 'child' and 'children' at properties and definition level
    Widget? child;

    // First check for single child
    final childDef = properties['child'] as Map<String, dynamic>? ??
        definition['child'] as Map<String, dynamic>?;
    if (childDef != null) {
      child = context.buildWidget(childDef);
    } else {
      // If no single child, check for children array
      final childrenDef = properties['children'] as List<dynamic>? ??
          definition['children'] as List<dynamic>?;
      if (childrenDef != null && childrenDef.isNotEmpty) {
        child = context.buildWidget(childrenDef.first as Map<String, dynamic>);
      }
    }

    // Extract flex value
    final flex = properties['flex'] as int? ?? 1;

    if (child == null) {
      return Container(); // Return empty container if no child
    }

    // Build expanded
    Widget expanded = Expanded(
      flex: flex,
      child: child,
    );

    return applyCommonWrappers(expanded, properties, context);
  }
}
