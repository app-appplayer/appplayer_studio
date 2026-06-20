import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Badge widgets
class BadgeWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties - support both design doc keys and implementation keys
    final label = context.resolve<String?>(properties['label']);
    // Design: color → Implementation: backgroundColor
    final backgroundColor =
        parseColor(context.resolve(properties['color'] ?? properties['backgroundColor']), context);
    final textColor = parseColor(context.resolve(properties['textColor']), context);
    final smallSize = properties['smallSize'] as bool? ?? false;
    final isLabelVisible = properties['isLabelVisible'] as bool? ?? true;
    final offset = _parseOffset(properties['offset']);
    final alignment = parseAlignment(properties['alignment']);

    // Build child widget
    Widget? child;
    final childDef = properties['child'] as Map<String, dynamic>?;
    if (childDef != null) {
      child = context.renderer.renderWidget(childDef, context);
    }

    // Build label widget
    Widget? labelWidget;
    if (label != null && label.isNotEmpty) {
      labelWidget = Text(
        label,
        style: TextStyle(
          color: textColor,
          fontSize: smallSize ? 10.0 : null,
        ),
      );
    }

    Widget badge = Badge(
      label: labelWidget,
      backgroundColor: backgroundColor,
      textColor: textColor,
      smallSize: smallSize ? 6.0 : null,
      isLabelVisible: isLabelVisible,
      offset: offset,
      alignment: alignment,
      child: child,
    );

    return applyCommonWrappers(badge, properties, context);
  }

  Offset _parseOffset(dynamic offset) {
    if (offset == null) return Offset.zero;

    if (offset is Map<String, dynamic>) {
      final dx = offset['dx']?.toDouble() ?? 0.0;
      final dy = offset['dy']?.toDouble() ?? 0.0;
      return Offset(dx, dy);
    }

    return Offset.zero;
  }
}
