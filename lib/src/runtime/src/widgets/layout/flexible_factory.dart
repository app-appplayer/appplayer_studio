import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Flexible widgets
class FlexibleWidgetFactory extends WidgetFactory {
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

    // Extract properties
    final flex = properties['flex'] as int? ?? 1;
    final fit = _parseFlexFit(properties['fit']);

    if (child == null) {
      return Container(); // Return empty container if no child
    }

    // Build flexible
    Widget flexible = Flexible(
      flex: flex,
      fit: fit,
      child: child,
    );

    return applyCommonWrappers(flexible, properties, context);
  }

  FlexFit _parseFlexFit(String? value) {
    switch (value) {
      case 'tight':
        return FlexFit.tight;
      case 'loose':
        return FlexFit.loose;
      default:
        return FlexFit.loose;
    }
  }
}
