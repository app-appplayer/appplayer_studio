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
    final enableFeedback = boolOf(properties['enableFeedback'], context) ?? true;
    final excludeFromSemantics =
        boolOf(properties['excludeFromSemantics'], context) ?? false;
    final canRequestFocus = boolOf(properties['canRequestFocus'], context) ?? true;
    final autofocus = boolOf(properties['autofocus'], context) ?? false;

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
    final onTap = actionOf(properties['onTap'] ?? properties['click'] ?? properties['onTap'], context);
    final onDoubleTap = actionOf(properties['onDoubleTap'] ?? properties['double-click'] ?? properties['onDoubleTap'], context);
    final onLongPress = actionOf(properties['onLongPress'] ?? properties['long-press'] ?? properties['longPress'], context);
    final onTapDown = actionOf(properties['onTapDown'], context);
    final onTapUp = actionOf(properties['onTapUp'], context);
    final onTapCancel = actionOf(properties['onTapCancel'], context);
    final onHighlightChanged =
        actionOf(properties['onHighlightChanged'], context);
    final onHover = actionOf(properties['onHover'] ?? properties['hover'], context);

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

    // Ink is painted by the nearest `Material`, which is normally the app's —
    // *below* everything the document paints on the way down. A page that
    // gives itself a background therefore covered the splash, the focus and
    // the hover overlay completely: the properties validated, rendered no
    // error, and drew nothing. Measured three ways (opaque child, transparent
    // child, no page background) the deciding factor was not the child but
    // any painting ancestor at all, so the ink layer has to live here.
    //
    // `MaterialType.transparency` adds no paint of its own and no layout, so
    // this is the ink layer moving, not a surface appearing.
    inkWell = Material(type: MaterialType.transparency, child: inkWell);

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
