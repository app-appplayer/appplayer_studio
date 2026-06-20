import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Spacer widgets
class SpacerWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final flex = properties['flex'] as int? ?? 1;

    Widget spacer = Spacer(flex: flex);

    return applyCommonWrappers(spacer, properties, context);
  }
}
