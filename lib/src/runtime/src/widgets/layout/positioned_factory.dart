import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Positioned widgets
class PositionedWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final left = dimensionOf(properties['left'], context);
    final top = dimensionOf(properties['top'], context);
    final right = dimensionOf(properties['right'], context);
    final bottom = dimensionOf(properties['bottom'], context);
    final width = dimensionOf(properties['width'], context);
    final height = dimensionOf(properties['height'], context);

    // Extract child
    final childData = definition['child'];
    Widget child = Container();
    if (childData != null) {
      child = context.renderer.renderWidget(childData, context);
    }

    return Positioned(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      width: width,
      height: height,
      child: child,
    );
  }
}
