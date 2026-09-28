import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for flow layout widget
class FlowWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final children = definition['children'] as List<dynamic>? ?? [];

    // Extract flow configuration properties
    final spacing = context.resolve(properties['spacing'])?.toDouble() ?? 8.0;
    final direction = readEnum(properties['direction'], context) ?? 'horizontal';
    final alignment = readEnum(properties['alignment'], context) ?? 'start';

    return Flow(
      delegate: _ConfigurableFlowDelegate(
        spacing: spacing,
        direction: direction,
        alignment: alignment,
      ),
      children: children
          .map((child) => context.buildWidget(child as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Configurable flow delegate that arranges children based on properties
class _ConfigurableFlowDelegate extends FlowDelegate {
  final double spacing;
  final String direction;
  final String alignment;

  _ConfigurableFlowDelegate({
    required this.spacing,
    required this.direction,
    required this.alignment,
  });

  /// Children size themselves; the flow only places them.
  ///
  /// Without this they inherit the Flow's own constraints — TIGHT whenever
  /// the flow sits in a sized box, which is the ordinary case. Every child
  /// was then forced to the full size of the flow, so the first one filled it
  /// and every other one was placed off the bottom edge: a tag list that
  /// showed one enormous tag and nothing else, with no error to say why.
  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      constraints.loosen();

  @override
  void paintChildren(FlowPaintingContext context) {
    double x = 0;
    double y = 0;

    for (int i = 0; i < context.childCount; i++) {
      final childSize = context.getChildSize(i) ?? Size.zero;

      if (direction == 'vertical') {
        // Vertical flow layout
        if (y + childSize.height > context.size.height) {
          y = 0;
          x += childSize.width + spacing;
        }
        context.paintChild(i, transform: Matrix4.translationValues(x, y, 0));
        y += childSize.height + spacing;
      } else {
        // Horizontal flow layout (default)
        if (x + childSize.width > context.size.width) {
          x = 0;
          y += childSize.height + spacing;
        }
        context.paintChild(i, transform: Matrix4.translationValues(x, y, 0));
        x += childSize.width + spacing;
      }
    }
  }

  @override
  bool shouldRepaint(covariant FlowDelegate oldDelegate) {
    if (oldDelegate is! _ConfigurableFlowDelegate) return true;
    return oldDelegate.spacing != spacing ||
        oldDelegate.direction != direction ||
        oldDelegate.alignment != alignment;
  }
}
