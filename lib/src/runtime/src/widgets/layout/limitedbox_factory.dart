import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for LimitedBox widgets
class LimitedBoxWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final maxWidth = parseDimension(properties['maxWidth']) ?? double.infinity;
    final maxHeight = parseDimension(properties['maxHeight']) ?? double.infinity;

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

    Widget limitedBox = LimitedBox(
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      child: child ?? const SizedBox.shrink(),
    );

    return applyCommonWrappers(limitedBox, properties, context);
  }
}
