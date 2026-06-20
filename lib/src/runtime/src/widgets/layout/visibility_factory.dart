import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for visibility widget
class VisibilityWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Support both 'child' (single widget, design doc spec) and 'children' (legacy array)
    final childDef = properties['child'] as Map<String, dynamic>?;
    final children = definition['children'] as List<dynamic>? ?? [];

    Widget child;
    if (childDef != null) {
      child = context.buildWidget(childDef);
    } else if (children.isNotEmpty) {
      child = context.buildWidget(children.first as Map<String, dynamic>);
    } else {
      child = Container();
    }

    // Resolve visible through binding expressions
    final visible = context.resolve<bool>(properties['visible'] ?? true);

    return Visibility(
      visible: visible,
      maintainSize: properties['maintainSize'] == true,
      maintainAnimation: properties['maintainAnimation'] == true,
      maintainState: properties['maintainState'] == true,
      maintainInteractivity: properties['maintainInteractivity'] == true,
      replacement: _buildReplacement(properties['replacement'], context),
      child: child,
    );
  }

  Widget _buildReplacement(dynamic replacement, RenderContext context) {
    if (replacement is Map<String, dynamic>) {
      return context.buildWidget(replacement);
    }
    return const SizedBox.shrink();
  }
}
