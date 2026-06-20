import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Dialog widgets
class DialogWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context);
    final elevation = properties['elevation']?.toDouble();
    final shadowColor = parseColor(context.resolve(properties['shadowColor']), context);
    final surfaceTintColor =
        parseColor(context.resolve(properties['surfaceTintColor']), context);
    final insetPadding = parseEdgeInsets(properties['insetPadding']) ??
        const EdgeInsets.symmetric(horizontal: 40.0, vertical: 24.0);
    final clipBehavior = _parseClip(properties['clipBehavior']);
    final shape = _parseShapeBorder(properties['shape']);
    final alignment = parseAlignment(properties['alignment']);

    // Extract dialog type
    final type = properties['type'] as String? ?? 'custom';

    Widget dialog;

    switch (type) {
      case 'alert':
        dialog = _buildAlertDialog(properties, definition, context);
        break;
      case 'simple':
        dialog = _buildSimpleDialog(properties, definition, context);
        break;
      default:
        // Custom dialog
        final childrenData = definition['children'] as List<dynamic>?;
        Widget? child;
        if (childrenData != null && childrenData.isNotEmpty) {
          child = context.renderer.renderWidget(childrenData.first, context);
        }

        dialog = Dialog(
          backgroundColor: backgroundColor,
          elevation: elevation,
          shadowColor: shadowColor,
          surfaceTintColor: surfaceTintColor,
          insetPadding: insetPadding,
          clipBehavior: clipBehavior,
          shape: shape,
          alignment: alignment,
          child: child,
        );
    }

    return dialog;
  }

  Widget _buildAlertDialog(
    Map<String, dynamic> properties,
    Map<String, dynamic> definition,
    RenderContext context,
  ) {
    final title = context.resolve<String?>(properties['title']);
    final content = context.resolve<String?>(properties['content']);
    final actionsData = properties['actions'] as List<dynamic>?;

    List<Widget>? actions;
    if (actionsData != null) {
      actions = actionsData.map((action) {
        if (action is Map<String, dynamic>) {
          return TextButton(
            onPressed: () {
              final clickAction = action['onTap'] ?? action['onTap'];
              if (clickAction != null) {
                context.actionHandler.execute(clickAction, context);
              }
            },
            child: Text(action['label'] ?? 'OK'),
          );
        }
        return Container();
      }).toList();
    }

    return AlertDialog(
      title: title != null ? Text(title) : null,
      content: content != null ? Text(content) : null,
      actions: actions,
      backgroundColor:
          parseColor(context.resolve(properties['backgroundColor']), context),
      elevation: properties['elevation']?.toDouble(),
      shape: _parseShapeBorder(properties['shape']),
    );
  }

  Widget _buildSimpleDialog(
    Map<String, dynamic> properties,
    Map<String, dynamic> definition,
    RenderContext context,
  ) {
    final title = context.resolve<String?>(properties['title']);
    final childrenData = definition['children'] as List<dynamic>?;

    List<Widget>? children;
    if (childrenData != null) {
      children = childrenData
          .map((child) => context.renderer.renderWidget(child, context))
          .toList();
    }

    return SimpleDialog(
      title: title != null ? Text(title) : null,
      backgroundColor:
          parseColor(context.resolve(properties['backgroundColor']), context),
      elevation: properties['elevation']?.toDouble(),
      shape: _parseShapeBorder(properties['shape']),
      children: children,
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
