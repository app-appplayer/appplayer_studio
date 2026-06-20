import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for GestureDetector widgets
class GestureDetectorWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract child widget (support both 'child' and 'children')
    final childDef = definition['child'] as Map<String, dynamic>?;
    final childrenDef = properties['children'] as List<dynamic>? ??
        definition['children'] as List<dynamic>?;
    Widget? child;
    if (childDef != null) {
      child = context.buildWidget(childDef);
    } else if (childrenDef != null && childrenDef.isNotEmpty) {
      child = context.buildWidget(childrenDef.first as Map<String, dynamic>);
    }

    // Extract action handlers
    final onTap = (properties['onTap'] ?? properties['click'] ?? properties['onTap']) as Map<String, dynamic>?;
    final onDoubleTap = (properties['onDoubleTap'] ?? properties['double-click'] ?? properties['onDoubleTap']) as Map<String, dynamic>?;
    final onLongPress = (properties['onLongPress'] ?? properties['long-press'] ?? properties['longPress']) as Map<String, dynamic>?;
    final onPanUpdate = properties['onPanUpdate'] as Map<String, dynamic>?;
    final panStartAction = (properties['panStart'] ?? properties['onPanStart']) as Map<String, dynamic>?;
    final panEndAction = (properties['panEnd'] ?? properties['onPanEnd']) as Map<String, dynamic>?;
    final onScaleUpdate = properties['onScaleUpdate'] as Map<String, dynamic>?;

    Widget gestureDetector = GestureDetector(
      onTap: onTap != null
          ? () {
              context.actionHandler.execute(onTap, context);
            }
          : null,
      onDoubleTap: onDoubleTap != null
          ? () {
              context.actionHandler.execute(onDoubleTap, context);
            }
          : null,
      onLongPress: onLongPress != null
          ? () {
              context.actionHandler.execute(onLongPress, context);
            }
          : null,
      onPanStart: panStartAction != null
          ? (details) {
              context.actionHandler.execute(panStartAction, context);
            }
          : null,
      onPanEnd: panEndAction != null
          ? (details) {
              context.actionHandler.execute(panEndAction, context);
            }
          : null,
      onPanUpdate: onPanUpdate != null
          ? (details) {
              final eventData = Map<String, dynamic>.from(onPanUpdate);
              if (eventData['delta'] == '{{event.delta}}') {
                eventData['delta'] = {
                  'dx': details.delta.dx,
                  'dy': details.delta.dy,
                };
              }
              context.actionHandler.execute(eventData, context);
            }
          : null,
      onScaleUpdate: onScaleUpdate != null
          ? (details) {
              final eventData = Map<String, dynamic>.from(onScaleUpdate);
              if (eventData['scale'] == '{{event.scale}}') {
                eventData['scale'] = details.scale;
              }
              context.actionHandler.execute(eventData, context);
            }
          : null,
      child: child,
    );

    return applyCommonWrappers(gestureDetector, properties, context);
  }
}
