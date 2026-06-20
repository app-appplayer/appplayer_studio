import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Positioned widgets
class PositionedWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final left = parseDimension(properties['left']);
    final top = parseDimension(properties['top']);
    final right = parseDimension(properties['right']);
    final bottom = parseDimension(properties['bottom']);
    final width = parseDimension(properties['width']);
    final height = parseDimension(properties['height']);

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
