import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Center widgets
class CenterWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final widthFactor = properties['widthFactor']?.toDouble();
    final heightFactor = properties['heightFactor']?.toDouble();

    // Center is a single-child widget, so child should be in properties
    Widget? child;
    final childDef = properties['child'] as Map<String, dynamic>?;
    if (childDef != null) {
      child = context.renderer.renderWidget(childDef, context);
    }

    Widget center = Center(
      widthFactor: widthFactor,
      heightFactor: heightFactor,
      child: child,
    );

    return applyCommonWrappers(center, properties, context);
  }
}
