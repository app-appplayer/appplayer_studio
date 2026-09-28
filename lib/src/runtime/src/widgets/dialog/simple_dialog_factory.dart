import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../../utils/icon_resolver.dart';
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
    final elevation = numberOf(properties['elevation'], context);
    final shape = _parseShapeBorder(properties['shape']);
    final contentPadding = edgeInsetsOf(properties['contentPadding'], context) ??
        const EdgeInsets.fromLTRB(0.0, 12.0, 0.0, 16.0);
    final titlePadding = edgeInsetsOf(properties['titlePadding'], context) ??
        const EdgeInsets.fromLTRB(24.0, 24.0, 24.0, 0.0);

    // Extract options list
    final optionsData = properties['options'] as List<dynamic>?;
    final onSelect = actionOf(properties['onSelect'] ?? properties['select'], context);

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
            // Through the shared resolver: the local switch below knew 25
            // names and answered null for the rest, so an option declaring any
            // other icon lost it silently — the perform-or-report rule applied to a slot.
            leading = Icon(resolveIconRef(iconData));
          }

          return SimpleDialogOption(
            onPressed: () {
              if (onSelect != null) {
                // The chosen value is published as `event`, the way every
                // other selectable widget publishes it. It used to be written
                // into the action map as `selectedValue` only, so the ordinary
                // spelling — `value: "{{event.value}}"` — resolved to nothing
                // and the document was told which dialog fired but not what
                // the user picked. `selectedValue` is kept for documents
                // already written against it.
                final actionConfig = Map<String, dynamic>.from(onSelect);
                actionConfig['selectedValue'] = value;
                context.actionHandler.execute(
                  actionConfig,
                  context.createChildContext(
                    variables: {
                      'event': {
                        'value': value,
                        'label': label,
                        'type': 'select',
                      },
                    },
                  ),
                );
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
