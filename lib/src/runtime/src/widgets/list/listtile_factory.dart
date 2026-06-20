import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for ListTile widgets
class ListTileWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final titleProp = properties['title'];
    final subtitleProp = properties['subtitle'];
    final isThreeLine = properties['isThreeLine'] as bool? ?? false;
    final dense = properties['dense'] as bool? ?? false;
    final enabled = properties['enabled'] as bool? ?? true;
    final selected = properties['selected'] as bool? ?? false;
    final iconColor = parseColor(context.resolve(properties['iconColor']), context);
    final textColor = parseColor(context.resolve(properties['textColor']), context);
    final contentPadding = parseEdgeInsets(properties['contentPadding']);
    final tileColor = parseColor(context.resolve(properties['tileColor']), context);
    final selectedTileColor =
        parseColor(context.resolve(properties['selectedTileColor']), context);
    final focusColor = parseColor(context.resolve(properties['focusColor']), context);
    final hoverColor = parseColor(context.resolve(properties['hoverColor']), context);
    final shape = _parseShapeBorder(properties['shape']);

    // Extract leading widget
    Widget? leading = _buildWidget(properties['leading'], context);

    // Extract trailing widget
    Widget? trailing = _buildWidget(properties['trailing'], context);

    // Extract action handlers
    // on + PascalCase optimal, legacy short names as fallback
    final onTap = (properties['onTap'] ?? properties['click'] ??
        properties['onTap']) as Map<String, dynamic>?;
    final onLongPress = (properties['onLongPress'] ?? properties['long-press'] ??
        properties['longPress']) as Map<String, dynamic>?;

    // Build title widget
    Widget? titleWidget;
    if (titleProp != null) {
      if (titleProp is String) {
        titleWidget = Text(context.resolve(titleProp) ?? titleProp);
      } else if (titleProp is Map<String, dynamic>) {
        titleWidget = context.renderer.renderWidget(titleProp, context);
      }
    }

    // Build subtitle widget
    Widget? subtitleWidget;
    if (subtitleProp != null) {
      if (subtitleProp is String) {
        subtitleWidget = Text(context.resolve(subtitleProp) ?? subtitleProp);
      } else if (subtitleProp is Map<String, dynamic>) {
        subtitleWidget = context.renderer.renderWidget(subtitleProp, context);
      }
    }

    Widget listTile = ListTile(
      leading: leading,
      title: titleWidget,
      subtitle: subtitleWidget,
      trailing: trailing,
      isThreeLine: isThreeLine,
      dense: dense,
      visualDensity: VisualDensity.standard,
      shape: shape,
      contentPadding: contentPadding,
      enabled: enabled,
      onTap: onTap != null
          ? () {
              context.actionHandler.execute(onTap, context);
            }
          : null,
      onLongPress: onLongPress != null
          ? () {
              context.actionHandler.execute(onLongPress, context);
            }
          : null,
      selected: selected,
      selectedColor: textColor,
      iconColor: iconColor,
      textColor: textColor,
      tileColor: tileColor,
      selectedTileColor: selectedTileColor,
      focusColor: focusColor,
      hoverColor: hoverColor,
    );

    return applyCommonWrappers(listTile, properties, context);
  }

  Widget? _buildWidget(dynamic widgetDef, RenderContext context) {
    if (widgetDef == null) return null;

    if (widgetDef is Map<String, dynamic>) {
      // Full widget definition
      return context.renderer.renderWidget(widgetDef, context);
    } else if (widgetDef is String) {
      // Simple icon name
      return Icon(_parseIconData(widgetDef));
    }

    return null;
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
      case 'stadium':
        return const StadiumBorder();
      default:
        return null;
    }
  }

  IconData _parseIconData(String iconName) {
    // Basic icon mapping - can be expanded
    switch (iconName) {
      case 'arrow_forward':
        return Icons.arrow_forward_ios;
      case 'arrow_back':
        return Icons.arrow_back_ios;
      case 'check':
        return Icons.check;
      case 'close':
        return Icons.close;
      default:
        return Icons.arrow_forward_ios;
    }
  }
}
