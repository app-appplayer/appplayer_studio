import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for InkWell widgets
class InkWellWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final splashColor = parseColor(context.resolve(properties['splashColor']), context);
    final highlightColor =
        parseColor(context.resolve(properties['highlightColor']), context);
    final hoverColor = parseColor(context.resolve(properties['hoverColor']), context);
    final focusColor = parseColor(context.resolve(properties['focusColor']), context);
    final overlayColor = properties['overlayColor'] != null
        ? WidgetStateProperty.all(
            parseColor(context.resolve(properties['overlayColor']), context))
        : null;
    // splashRadius is not available in current Flutter stable version
    // final splashRadius = context.resolve<num?>(properties['splashRadius'])?.toDouble();
    final borderRadius = _parseBorderRadius(properties['borderRadius']);
    final customBorder = _parseShapeBorder(properties['customBorder']);
    final enableFeedback = properties['enableFeedback'] as bool? ?? true;
    final excludeFromSemantics =
        properties['excludeFromSemantics'] as bool? ?? false;
    final canRequestFocus = properties['canRequestFocus'] as bool? ?? true;
    final autofocus = properties['autofocus'] as bool? ?? false;

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

    // Extract action handlers
    final onTap = (properties['onTap'] ?? properties['click'] ?? properties['onTap']) as Map<String, dynamic>?;
    final onDoubleTap = (properties['onDoubleTap'] ?? properties['double-click'] ?? properties['onDoubleTap']) as Map<String, dynamic>?;
    final onLongPress = (properties['onLongPress'] ?? properties['long-press'] ?? properties['longPress']) as Map<String, dynamic>?;
    final onTapDown = properties['onTapDown'] as Map<String, dynamic>?;
    final onTapUp = properties['onTapUp'] as Map<String, dynamic>?;
    final onTapCancel = properties['onTapCancel'] as Map<String, dynamic>?;
    final onHighlightChanged =
        properties['onHighlightChanged'] as Map<String, dynamic>?;
    final onHover = (properties['onHover'] ?? properties['hover']) as Map<String, dynamic>?;

    Widget inkWell = InkWell(
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
      onTapDown: onTapDown != null
          ? (details) {
              final eventData = Map<String, dynamic>.from(onTapDown);
              if (eventData['position'] == '{{event.position}}') {
                eventData['position'] = {
                  'dx': details.localPosition.dx,
                  'dy': details.localPosition.dy,
                };
              }
              context.actionHandler.execute(eventData, context);
            }
          : null,
      onTapUp: onTapUp != null
          ? (details) {
              final eventData = Map<String, dynamic>.from(onTapUp);
              if (eventData['position'] == '{{event.position}}') {
                eventData['position'] = {
                  'dx': details.localPosition.dx,
                  'dy': details.localPosition.dy,
                };
              }
              context.actionHandler.execute(eventData, context);
            }
          : null,
      onTapCancel: onTapCancel != null
          ? () {
              context.actionHandler.execute(onTapCancel, context);
            }
          : null,
      onHighlightChanged: onHighlightChanged != null
          ? (value) {
              final eventData = Map<String, dynamic>.from(onHighlightChanged);
              if (eventData['highlighted'] == '{{event.highlighted}}') {
                eventData['highlighted'] = value;
              }
              context.actionHandler.execute(eventData, context);
            }
          : null,
      onHover: onHover != null
          ? (value) {
              final eventData = Map<String, dynamic>.from(onHover);
              if (eventData['hovering'] == '{{event.hovering}}') {
                eventData['hovering'] = value;
              }
              context.actionHandler.execute(eventData, context);
            }
          : null,
      splashColor: splashColor,
      highlightColor: highlightColor,
      hoverColor: hoverColor,
      focusColor: focusColor,
      overlayColor: overlayColor,
      // Note: splashRadius is not available in current Flutter stable version
      // It will be available in future releases
      borderRadius: borderRadius,
      customBorder: customBorder,
      enableFeedback: enableFeedback,
      excludeFromSemantics: excludeFromSemantics,
      canRequestFocus: canRequestFocus,
      autofocus: autofocus,
      child: child,
    );

    return applyCommonWrappers(inkWell, properties, context);
  }

  BorderRadius? _parseBorderRadius(dynamic value) {
    if (value == null) return null;

    if (value is num) {
      return BorderRadius.circular(value.toDouble());
    }

    if (value is Map<String, dynamic>) {
      return BorderRadius.only(
        topLeft: Radius.circular(value['topLeft']?.toDouble() ?? 0),
        topRight: Radius.circular(value['topRight']?.toDouble() ?? 0),
        bottomLeft: Radius.circular(value['bottomLeft']?.toDouble() ?? 0),
        bottomRight: Radius.circular(value['bottomRight']?.toDouble() ?? 0),
      );
    }

    return null;
  }

  ShapeBorder? _parseShapeBorder(dynamic shape) {
    if (shape == null) return null;

    if (shape is Map<String, dynamic>) {
      final type = shape['type'] as String?;
      switch (type) {
        case 'circle':
          return const CircleBorder();
        case 'rounded':
          final radius = shape['radius']?.toDouble() ?? 8.0;
          return RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          );
        default:
          return null;
      }
    }

    return null;
  }
}
