import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for SnackBar widgets
class SnackBarWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final content =
        context.resolve<String>(properties['content']) as String? ?? '';
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context);
    final elevation = parseDimension(properties['elevation']);
    final margin = parseEdgeInsets(properties['margin']);
    final padding = parseEdgeInsets(properties['padding']);
    final width = parseDimension(properties['width']);
    final shape = _parseShapeBorder(properties['shape']);
    final behavior = _parseSnackBarBehavior(properties['behavior']);
    final duration = Duration(milliseconds: properties['duration'] ?? 4000);
    final showCloseIcon = properties['showCloseIcon'] as bool? ?? false;
    final closeIconColor =
        parseColor(context.resolve(properties['closeIconColor']), context);
    final dismissDirection =
        _parseDismissDirection(properties['dismissDirection']);

    // Extract action
    final actionData = properties['action'] as Map<String, dynamic>?;
    SnackBarAction? action;
    if (actionData != null) {
      action = SnackBarAction(
        label: actionData['label'] ?? 'ACTION',
        textColor: parseColor(context.resolve(actionData['textColor']), context),
        backgroundColor:
            parseColor(context.resolve(actionData['backgroundColor']), context),
        onPressed: () {
          final clickAction = actionData['onTap'] ?? actionData['onPressed'];
          if (clickAction != null) {
            context.actionHandler.execute(clickAction, context);
          }
        },
      );
    }

    // Build content widget
    Widget contentWidget = Text(
      content,
      style: TextStyle(
        color: parseColor(context.resolve(properties['textColor']), context),
      ),
    );

    final snackBar = SnackBar(
      content: contentWidget,
      backgroundColor: backgroundColor,
      elevation: elevation,
      margin: margin,
      padding: padding,
      width: width,
      shape: shape,
      behavior: behavior,
      action: action,
      duration: duration,
      showCloseIcon: showCloseIcon,
      closeIconColor: closeIconColor,
      dismissDirection: dismissDirection,
      onVisible: properties['onVisible'] != null
          ? () {
              context.actionHandler.execute(properties['onVisible'], context);
            }
          : null,
    );

    // SnackBar needs to be wrapped in a widget that can display it
    return Builder(
      builder: (BuildContext context) {
        // Schedule showing the snackbar after the current frame
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ScaffoldMessenger.of(context).showSnackBar(snackBar);
        });
        // Return an empty container as placeholder
        return Container();
      },
    );
  }

  SnackBarBehavior _parseSnackBarBehavior(String? behavior) {
    switch (behavior) {
      case 'fixed':
        return SnackBarBehavior.fixed;
      case 'floating':
        return SnackBarBehavior.floating;
      default:
        return SnackBarBehavior.fixed;
    }
  }

  DismissDirection _parseDismissDirection(String? direction) {
    switch (direction) {
      case 'vertical':
        return DismissDirection.vertical;
      case 'horizontal':
        return DismissDirection.horizontal;
      case 'endToStart':
        return DismissDirection.endToStart;
      case 'startToEnd':
        return DismissDirection.startToEnd;
      case 'up':
        return DismissDirection.up;
      case 'down':
        return DismissDirection.down;
      case 'none':
        return DismissDirection.none;
      default:
        return DismissDirection.down;
    }
  }

  ShapeBorder? _parseShapeBorder(Map<String, dynamic>? shape) {
    if (shape == null) return null;

    final type = shape['type'] as String?;
    switch (type) {
      case 'rounded':
        final radius = shape['radius']?.toDouble() ?? 4.0;
        return RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        );
      case 'stadium':
        return const StadiumBorder();
      default:
        return null;
    }
  }
}
