import 'package:flutter/material.dart';
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for FractionallySizedBox widgets
/// Sizes its child as a fraction of the parent's available space
class FractionallySizedWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final widthFactor =
        context.resolve<double?>(properties['widthFactor']);
    final heightFactor =
        context.resolve<double?>(properties['heightFactor']);
    final alignment = parseAlignment(properties['alignment']) ?? Alignment.center;

    // Build child widget
    Widget? child;
    final childDef = properties['child'] as Map<String, dynamic>?;
    if (childDef != null) {
      child = context.renderer.renderWidget(childDef, context);
    }

    // Also support children array with single child
    if (child == null) {
      final children = properties['children'] as List<dynamic>?;
      if (children != null && children.isNotEmpty) {
        final firstChild = children.first;
        if (firstChild is Map<String, dynamic>) {
          child = context.renderer.renderWidget(firstChild, context);
        }
      }
    }

    Widget widget = FractionallySizedBox(
      widthFactor: widthFactor,
      heightFactor: heightFactor,
      alignment: alignment,
      child: child,
    );

    return applyCommonWrappers(widget, properties, context);
  }
}
