import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for vertical divider widget
class VerticalDividerWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    return VerticalDivider(
      width: properties['width']?.toDouble(),
      thickness: properties['thickness']?.toDouble(),
      indent: properties['indent']?.toDouble(),
      endIndent: properties['endIndent']?.toDouble(),
      color: resolveColor(properties['color'], context),
    );
  }
}
