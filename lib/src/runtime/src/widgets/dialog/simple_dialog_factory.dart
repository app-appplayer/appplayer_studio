import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for SimpleDialog widgets
///
/// A simple dialog shows a list of options for the user to select from.
class SimpleDialogWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final title = context.resolve<String?>(properties['title']);
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context);
    final elevation = properties['elevation']?.toDouble();
    final shape = _parseShapeBorder(properties['shape']);
    final contentPadding = parseEdgeInsets(properties['contentPadding']) ??
        const EdgeInsets.fromLTRB(0.0, 12.0, 0.0, 16.0);
    final titlePadding = parseEdgeInsets(properties['titlePadding']) ??
        const EdgeInsets.fromLTRB(24.0, 24.0, 24.0, 0.0);

    // Extract options list
    final optionsData = properties['options'] as List<dynamic>?;
    final onSelect = (properties['onSelect'] ?? properties['select']) as Map<String, dynamic>?;

    // Build option widgets
    List<Widget> children = [];
    if (optionsData != null) {
      children = optionsData.map((option) {
        if (option is Map<String, dynamic>) {
          final label = option['label'] as String? ?? '';
          final value = option['value'];
          final iconData = option['icon'] as String?;

          Widget? leading;
          if (iconData != null) {
            leading = Icon(_parseIconData(iconData));
          }

          return SimpleDialogOption(
            onPressed: () {
              if (onSelect != null) {
                // Execute onSelect action with the selected value
                final actionConfig = Map<String, dynamic>.from(onSelect);
                actionConfig['selectedValue'] = value;
                context.actionHandler.execute(actionConfig, context);
              }
            },
            child: leading != null
                ? Row(
                    children: [
                      leading,
                      const SizedBox(width: 16),
                      Expanded(child: Text(label)),
                    ],
                  )
                : Text(label),
          );
        }
        return const SizedBox.shrink();
      }).toList();
    } else {
      // Fall back to children from definition
      final childrenData = definition['children'] as List<dynamic>?;
      if (childrenData != null) {
        children = childrenData
            .map((child) => context.renderer.renderWidget(child, context))
            .toList();
      }
    }

    return SimpleDialog(
      title: title != null ? Text(title) : null,
      backgroundColor: backgroundColor,
      elevation: elevation,
      shape: shape,
      contentPadding: contentPadding,
      titlePadding: titlePadding,
      children: children,
    );
  }

  IconData? _parseIconData(String name) {
    // Map common icon names to Material Icons
    switch (name) {
      case 'check':
        return Icons.check;
      case 'close':
        return Icons.close;
      case 'add':
        return Icons.add;
      case 'delete':
        return Icons.delete;
      case 'edit':
        return Icons.edit;
      case 'search':
        return Icons.search;
      case 'settings':
        return Icons.settings;
      case 'home':
        return Icons.home;
      case 'star':
        return Icons.star;
      case 'favorite':
        return Icons.favorite;
      case 'info':
        return Icons.info;
      case 'warning':
        return Icons.warning;
      case 'error':
        return Icons.error;
      case 'person':
        return Icons.person;
      case 'email':
        return Icons.email;
      case 'phone':
        return Icons.phone;
      case 'location':
        return Icons.location_on;
      case 'calendar':
        return Icons.calendar_today;
      case 'camera':
        return Icons.camera_alt;
      case 'photo':
        return Icons.photo;
      case 'share':
        return Icons.share;
      case 'download':
        return Icons.download;
      case 'upload':
        return Icons.upload;
      case 'copy':
        return Icons.copy;
      case 'paste':
        return Icons.paste;
      default:
        return null;
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
