import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// `flow` — children placed along the main axis with a fixed `spacing`, a new
/// run when the next child would not fit, and each run placed by `alignment`
/// (`start` · `center` · `end`).
///
/// Laid out by [Wrap], which sizes to its runs. A Flutter `Flow` takes the
/// whole space it is given, so in a column inside a scroll view — no height
/// limit — it was given an infinite size and the page failed to draw
/// (`RangeError` in release). The spec's flow is a content-sized chain, which
/// is what [Wrap] lays out.
class FlowWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final children = definition['children'] as List<dynamic>? ?? [];

    final spacing = readNumber(properties['spacing'], context) ?? 8.0;
    final vertical =
        (readEnum(properties['direction'], context) ?? 'horizontal') ==
            'vertical';
    final alignment = switch (readEnum(properties['alignment'], context)) {
      'center' => WrapAlignment.center,
      'end' => WrapAlignment.end,
      _ => WrapAlignment.start,
    };

    return Wrap(
      direction: vertical ? Axis.vertical : Axis.horizontal,
      spacing: spacing,
      runSpacing: spacing,
      alignment: alignment,
      children: children
          .map((child) => context.buildWidget(child as Map<String, dynamic>))
          .toList(),
    );
  }
}
