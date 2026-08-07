import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for vertical divider widget
class VerticalDividerWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    return VerticalDivider(
      width: numberOf(properties['width'], context),
      thickness: numberOf(properties['thickness'], context),
      indent: numberOf(properties['indent'], context),
      endIndent: numberOf(properties['endIndent'], context),
      color: resolveColor(properties['color'], context),
    );
  }
}
