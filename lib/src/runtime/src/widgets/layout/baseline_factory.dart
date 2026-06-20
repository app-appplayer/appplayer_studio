import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Baseline widgets
class BaselineWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final baseline = properties['baseline']?.toDouble() ?? 0.0;
    final baselineType = _parseTextBaseline(properties['baselineType']) ??
        TextBaseline.alphabetic;

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

    Widget baselineWidget = Baseline(
      baseline: baseline,
      baselineType: baselineType,
      child: child ?? const SizedBox.shrink(),
    );

    return applyCommonWrappers(baselineWidget, properties, context);
  }

  TextBaseline? _parseTextBaseline(String? value) {
    switch (value) {
      case 'alphabetic':
        return TextBaseline.alphabetic;
      case 'ideographic':
        return TextBaseline.ideographic;
      default:
        return null;
    }
  }
}
