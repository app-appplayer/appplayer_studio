import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Chip widgets
class ChipWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final label = context.resolve<String>(properties['label']) as String? ?? '';
    final avatar = properties['avatar'] as Map<String, dynamic>?;
    final selected = context.resolve<bool>(properties['selected'] ?? false);
    final variant = context.resolve<String?>(properties['variant']);
    final deleteIcon = properties['deleteIcon'] as String?;
    // Per DDD spec §5.9, canonical name is 'onDelete'
    final onDelete = properties['onDelete'] as Map<String, dynamic>?;
    final onDeleteLegacy = properties['onDeleted'] as Map<String, dynamic>?;
    final deleteAlias = properties['delete'] as Map<String, dynamic>?;
    final effectiveDeleteAction = onDelete ?? onDeleteLegacy ?? deleteAlias;
    final onPressed = (properties['onTap'] ?? properties['click'] ?? properties['onPressed']) as Map<String, dynamic>?;
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context);
    final labelStyle = _parseTextStyle(properties['labelStyle'], context);
    final padding = parseEdgeInsets(properties['padding']);
    final elevation = properties['elevation']?.toDouble();
    final shadowColor = parseColor(context.resolve(properties['shadowColor']), context);
    final side = _parseBorderSide(properties['side'], context);
    final shape = _parseOutlinedBorder(properties['shape']);

    // Build avatar widget
    Widget? avatarWidget;
    if (avatar != null) {
      final avatarText = avatar['text'] as String?;
      final avatarIcon = avatar['icon'] as String?;
      final avatarImage = avatar['image'] as String?;

      if (avatarText != null) {
        avatarWidget = CircleAvatar(
          radius: 14,
          child: Text(avatarText.substring(0, 1).toUpperCase()),
        );
      } else if (avatarIcon != null) {
        avatarWidget = CircleAvatar(
          radius: 14,
          child: Icon(_parseIconData(avatarIcon), size: 18),
        );
      } else if (avatarImage != null) {
        avatarWidget = CircleAvatar(
          backgroundImage: NetworkImage(avatarImage),
          radius: 14,
        );
      }
    }

    // Build delete icon
    Widget? deleteIconWidget;
    if (deleteIcon != null) {
      deleteIconWidget = Icon(_parseIconData(deleteIcon), size: 18);
    }

    // Build the appropriate chip variant
    Widget chip;
    if (variant == 'outlined') {
      // Outlined variant: ensure border side is visible
      final outlinedSide = side ?? const BorderSide();
      chip = RawChip(
        label: Text(label),
        avatar: avatarWidget,
        deleteIcon: deleteIconWidget,
        selected: selected,
        showCheckmark: false,
        onDeleted: effectiveDeleteAction != null
            ? () {
                context.actionHandler
                    .execute(effectiveDeleteAction, context);
              }
            : null,
        onPressed: onPressed != null
            ? () {
                context.actionHandler.execute(onPressed, context);
              }
            : null,
        backgroundColor: Colors.transparent,
        selectedColor: backgroundColor?.withValues(alpha: 0.12),
        labelStyle: labelStyle,
        padding: padding,
        elevation: 0,
        shadowColor: shadowColor,
        side: outlinedSide,
        shape: shape,
      );
    } else {
      // Default / 'filled' variant
      chip = RawChip(
        label: Text(label),
        avatar: avatarWidget,
        deleteIcon: deleteIconWidget,
        selected: selected,
        showCheckmark: false,
        onDeleted: effectiveDeleteAction != null
            ? () {
                context.actionHandler
                    .execute(effectiveDeleteAction, context);
              }
            : null,
        onPressed: onPressed != null
            ? () {
                context.actionHandler.execute(onPressed, context);
              }
            : null,
        backgroundColor: backgroundColor,
        // Selected state reuses the chip's own bg if set; otherwise a
        // soft primary tint from the active theme (keeps contrast in
        // both light and dark modes).
        selectedColor: backgroundColor?.withValues(alpha: 0.87) ??
            (context.themeManager.getColorValue('primary')?.withValues(alpha: 0.2)) ??
            Colors.blue.shade100,
        labelStyle: labelStyle,
        padding: padding,
        elevation: elevation,
        shadowColor: shadowColor,
        side: side,
        shape: shape,
      );
    }

    return applyCommonWrappers(chip, properties, context);
  }

  TextStyle? _parseTextStyle(
      Map<String, dynamic>? style, RenderContext context) {
    if (style == null) return null;

    return TextStyle(
      color: parseColor(context.resolve(style['color']), context),
      fontSize: style['fontSize']?.toDouble(),
      fontWeight: _parseFontWeight(style['fontWeight']),
    );
  }

  FontWeight? _parseFontWeight(String? value) {
    switch (value) {
      case 'bold':
        return FontWeight.bold;
      case 'normal':
        return FontWeight.normal;
      default:
        return null;
    }
  }

  BorderSide? _parseBorderSide(
      Map<String, dynamic>? side, RenderContext context) {
    if (side == null) return null;

    return BorderSide(
      color: parseColor(context.resolve(side['color']), context) ??
          context.themeManager.getColorValue('outlineVariant') ??
          Colors.black,
      width: side['width']?.toDouble() ?? 1.0,
    );
  }

  OutlinedBorder? _parseOutlinedBorder(Map<String, dynamic>? shape) {
    if (shape == null) return null;

    final type = shape['type'] as String?;
    switch (type) {
      case 'stadium':
        return const StadiumBorder();
      case 'rounded':
        final radius = shape['radius']?.toDouble() ?? 8.0;
        return RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        );
      default:
        return null;
    }
  }

  IconData _parseIconData(String iconName) {
    switch (iconName) {
      case 'close':
        return Icons.close;
      case 'cancel':
        return Icons.cancel;
      case 'clear':
        return Icons.clear;
      default:
        return Icons.close;
    }
  }
}
