import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for AlertDialog widgets
class AlertDialogWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final titleData = properties['title'];
    final contentData = properties['content'];
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context);
    final elevation = properties['elevation']?.toDouble();
    final shadowColor = parseColor(context.resolve(properties['shadowColor']), context);
    final surfaceTintColor =
        parseColor(context.resolve(properties['surfaceTintColor']), context);
    final shape = _parseShapeBorder(properties['shape']);
    final alignment = parseAlignment(properties['alignment']);
    final insetPadding = parseEdgeInsets(properties['insetPadding']) ??
        const EdgeInsets.symmetric(horizontal: 40.0, vertical: 24.0);
    final clipBehavior = _parseClip(properties['clipBehavior']);
    final scrollable = properties['scrollable'] as bool? ?? false;

    // Extract actions
    final actionsData = properties['actions'] as List<dynamic>?;
    List<Widget>? actions;
    if (actionsData != null) {
      actions = actionsData.map((action) {
        if (action is Map<String, dynamic>) {
          final label = action['label'] as String? ?? 'OK';
          final isDefaultAction = action['isDefault'] as bool? ?? false;
          final isDestructiveAction = action['isDestructive'] as bool? ?? false;

          return TextButton(
            onPressed: () {
              final clickAction = action['onTap'] ?? action['onTap'];
              if (clickAction != null) {
                context.actionHandler.execute(clickAction, context);
              }
            },
            child: Text(
              label,
              style: TextStyle(
                color: isDestructiveAction
                    ? (context.themeManager.getColorValue('error') ??
                        Colors.red)
                    : null,
                fontWeight: isDefaultAction ? FontWeight.bold : null,
              ),
            ),
          );
        }
        return Container();
      }).toList();
    }

    // Build title widget
    Widget? titleWidget;
    if (titleData != null) {
      if (titleData is String) {
        titleWidget = Text(context.resolve<String>(titleData));
      } else if (titleData is Map<String, dynamic>) {
        titleWidget = context.renderer.renderWidget(titleData, context);
      }
    } else if (properties['titleWidget'] != null &&
        properties['titleWidget'] is Map<String, dynamic>) {
      titleWidget =
          context.renderer.renderWidget(properties['titleWidget'], context);
    }

    // Build content widget
    Widget? contentWidget;
    if (contentData != null) {
      if (contentData is String) {
        contentWidget = Text(context.resolve<String>(contentData));
      } else if (contentData is Map<String, dynamic>) {
        contentWidget = context.renderer.renderWidget(contentData, context);
      }
    } else if (properties['contentWidget'] != null &&
        properties['contentWidget'] is Map<String, dynamic>) {
      contentWidget =
          context.renderer.renderWidget(properties['contentWidget'], context);
    } else {
      final childrenData = definition['children'] as List<dynamic>?;
      if (childrenData != null && childrenData.isNotEmpty) {
        contentWidget =
            context.renderer.renderWidget(childrenData.first, context);
      }
    }

    return AlertDialog(
      title: titleWidget,
      content: contentWidget,
      actions: actions,
      backgroundColor: backgroundColor,
      elevation: elevation,
      shadowColor: shadowColor,
      surfaceTintColor: surfaceTintColor,
      shape: shape,
      alignment: alignment,
      insetPadding: insetPadding,
      clipBehavior: clipBehavior,
      scrollable: scrollable,
    );
  }

  Clip _parseClip(String? value) {
    switch (value) {
      case 'none':
        return Clip.none;
      case 'hardEdge':
        return Clip.hardEdge;
      case 'antiAlias':
        return Clip.antiAlias;
      case 'antiAliasWithSaveLayer':
        return Clip.antiAliasWithSaveLayer;
      default:
        return Clip.none;
    }
  }

  ShapeBorder? _parseShapeBorder(Map<String, dynamic>? shape) {
    if (shape == null) return null;

    final type = shape['type'] as String?;
    switch (type) {
      case 'rounded':
        final radius = shape['radius']?.toDouble() ?? 8.0;
        return RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        );
      case 'circle':
        return const CircleBorder();
      default:
        return null;
    }
  }
}
