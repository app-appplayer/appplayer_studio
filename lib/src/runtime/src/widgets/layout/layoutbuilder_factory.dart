import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for creating LayoutBuilder widgets.
///
/// Renders different child widgets based on parent constraints,
/// enabling responsive layouts within the widget tree.
///
/// Properties:
/// - `breakpoints`: Map of breakpoint names to min-width values
/// - `layouts`: Map of breakpoint names to widget definitions
/// - `default`: Widget definition when no breakpoint matches
class LayoutBuilderFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final breakpoints = properties['breakpoints'] as Map<String, dynamic>?;
    final layouts = properties['layouts'] as Map<String, dynamic>?;
    final defaultChild = properties['default'] as Map<String, dynamic>? ??
        properties['child'] as Map<String, dynamic>?;

    Widget widget = LayoutBuilder(
      builder: (buildContext, constraints) {
        if (breakpoints != null && layouts != null) {
          // Sort breakpoints by value descending to find largest match
          final sorted = breakpoints.entries.toList()
            ..sort((a, b) =>
                (b.value as num).compareTo(a.value as num));

          for (final bp in sorted) {
            final minWidth = (bp.value as num).toDouble();
            if (constraints.maxWidth >= minWidth) {
              final layout = layouts[bp.key];
              if (layout is Map<String, dynamic>) {
                return context.renderer.renderWidget(layout, context);
              }
            }
          }
        }

        // Fall back to default child
        if (defaultChild != null) {
          return context.renderer.renderWidget(defaultChild, context);
        }

        return const SizedBox.shrink();
      },
    );

    return applyCommonWrappers(widget, properties, context);
  }
}
