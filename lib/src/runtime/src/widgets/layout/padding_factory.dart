import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Padding widgets
class PaddingWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract padding
    final padding = parseEdgeInsets(properties['padding']) ?? EdgeInsets.zero;

    // Padding is a single-child widget, so child should be in properties
    Widget? child;
    final childDef = properties['child'] as Map<String, dynamic>?;
    if (childDef != null) {
      child = context.renderer.renderWidget(childDef, context);
    }

    Widget paddingWidget = Padding(
      padding: padding,
      child: child,
    );

    return applyCommonWrappers(paddingWidget, properties, context);
  }
}
