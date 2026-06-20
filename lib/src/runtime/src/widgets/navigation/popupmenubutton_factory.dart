import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../../theme/menu_tokens.dart';
import '../widget_factory.dart';

/// Factory for PopupMenuButton widgets.
///
/// DSL props win where present; otherwise the runtime applies its
/// shared compact menu tokens (radius / item height / item padding /
/// menu padding / animation), resolved from
/// `theme.component.menu` → `theme.shape` → hardcoded compact defaults.
/// Material's bare PopupMenuButton ships visually loud defaults
/// (8dp menu padding, 0 radius); the runtime overrides them so menus
/// look right out of the box without per-instance config.
class PopupMenuButtonWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final tooltip = context.resolve<String?>(properties['tooltip']);
    final padding =
        parseEdgeInsets(properties['padding']) ?? const EdgeInsets.all(8.0);
    final splashRadius = parseDimension(properties['splashRadius']);
    final iconSize = parseDimension(properties['iconSize']);
    final offset = _parseOffset(properties['offset']);
    final enabled = properties['enabled'] as bool? ?? true;
    final color = parseColor(context.resolve(properties['color']), context);
    final shadowColor = parseColor(context.resolve(properties['shadowColor']), context);
    final surfaceTintColor =
        parseColor(context.resolve(properties['surfaceTintColor']), context);

    // Resolve compact menu tokens. Spec-bound popupMenuButton props are
    // `{type, icon, items, onSelect}`; visual fine-tuning happens
    // through `theme.component.menu.*` (free-form component tokens,
    // spec §5.12) and the runtime's compact defaults. The DSL `shape`
    // / `elevation` reads below are pre-existing factory inputs (kept
    // for back-compat with bundles that already use them) — no new
    // non-spec widget props are introduced.
    final dslShape = _parseShapeBorder(properties['shape']);
    final dslShapeRadius = _radiusOf(dslShape);
    final dslElevation = parseDimension(properties['elevation']);
    final tokens = MenuTokens.resolve(
      context.themeManager,
      radius: dslShapeRadius,
      elevation: dslElevation,
    );
    // Use DSL `shape` map verbatim (supports per-corner) when present;
    // otherwise build a uniform shape from the resolved radius.
    final effectiveShape = dslShape ?? tokens.shape;

    // Extract items
    final itemsData = properties['items'] as List<dynamic>? ?? [];
    final items =
        itemsData.map((item) => _buildPopupMenuItem(item, context, tokens)).toList();

    // Extract child widget or icon
    final childrenDef = properties['children'] as List<dynamic>? ??
        definition['children'] as List<dynamic>?;
    Widget? child;
    if (childrenDef != null && childrenDef.isNotEmpty) {
      child = context.renderer
          .renderWidget(childrenDef.first as Map<String, dynamic>, context);
    } else {
      final icon = properties['icon'] as String?;
      if (icon != null) {
        child = Icon(_parseIconData(icon));
      } else {
        // If no child or icon is specified, use default icon
        child = const Icon(Icons.more_vert);
      }
    }

    // Extract action handlers
    final onSelected = (properties['onSelected'] ?? properties['onChange'] ?? properties['onSelect'] ?? properties['select'] ?? properties['change']) as Map<String, dynamic>?;
    final onOpened = properties['onOpened'] as Map<String, dynamic>?;
    final onCanceled = properties['onCanceled'] as Map<String, dynamic>?;

    Widget popupMenuButton = PopupMenuButton<String>(
      itemBuilder: (BuildContext ctx) => items,
      onSelected: onSelected != null
          ? (value) {
              final eventData = Map<String, dynamic>.from(onSelected);
              if (eventData['value'] == '{{event.value}}') {
                eventData['value'] = value;
              }
              context.actionHandler.execute(eventData, context);
            }
          : null,
      onOpened: onOpened != null
          ? () {
              context.actionHandler.execute(onOpened, context);
            }
          : null,
      onCanceled: onCanceled != null
          ? () {
              context.actionHandler.execute(onCanceled, context);
            }
          : null,
      tooltip: tooltip,
      elevation: tokens.elevation,
      padding: padding,
      menuPadding: tokens.menuPadding,
      splashRadius: splashRadius,
      iconSize: iconSize,
      offset: offset,
      enabled: enabled,
      shape: effectiveShape,
      color: color,
      shadowColor: shadowColor,
      surfaceTintColor: surfaceTintColor,
      popUpAnimationStyle: tokens.popupAnimationStyle,
      child: child,
    );

    return applyCommonWrappers(popupMenuButton, properties, context);
  }

  PopupMenuItem<String> _buildPopupMenuItem(
      dynamic itemData, RenderContext context, MenuTokens tokens) {
    // `null` itemHeight = no minimum. PopupMenuItem uses the value as
    // a `minHeight` constraint (max is infinite), so passing 0 makes
    // the item track text natural height + padding — items auto-grow
    // with `textStyle.fontSize`.
    final minHeight = tokens.itemHeight ?? 0;

    if (itemData is Map<String, dynamic>) {
      final value = context.resolve<String>(itemData['value']) as String? ?? '';
      final enabled = itemData['enabled'] as bool? ?? true;
      final height = itemData['height']?.toDouble() ?? minHeight;
      final padding =
          parseEdgeInsets(itemData['padding']) ?? tokens.itemPadding;
      final dslTextStyle = _parseTextStyle(itemData['textStyle'], context);
      final label =
          itemData['text']?.toString() ?? itemData['label']?.toString() ?? value;

      final Widget child = itemData['child'] != null
          ? context.renderer
              .renderWidget(itemData['child'] as Map<String, dynamic>, context)
          : Text(label);

      // Default item label = fontSize 13 (compact); DSL `textStyle`
      // wins when given (already a spec-allowed item field).
      return PopupMenuItem<String>(
        value: value,
        enabled: enabled,
        height: height,
        padding: padding,
        textStyle: dslTextStyle ?? const TextStyle(fontSize: 13),
        child: child,
      );
    }

    return PopupMenuItem<String>(
      value: itemData.toString(),
      height: minHeight,
      padding: tokens.itemPadding,
      textStyle: const TextStyle(fontSize: 13),
      child: Text(itemData.toString()),
    );
  }

  /// Extract the uniform corner radius from a [RoundedRectangleBorder]
  /// so the menu-token resolver can apply it as the active radius.
  /// Returns `null` for any other [ShapeBorder] shape.
  double? _radiusOf(ShapeBorder? shape) {
    if (shape is RoundedRectangleBorder) {
      final br = shape.borderRadius;
      if (br is BorderRadius) {
        final r = br.topLeft.x;
        if (r == br.topRight.x &&
            r == br.bottomLeft.x &&
            r == br.bottomRight.x) {
          return r;
        }
      }
    }
    return null;
  }

  IconData _parseIconData(String iconName) {
    switch (iconName) {
      case 'more_vert':
        return Icons.more_vert;
      case 'more_horiz':
        return Icons.more_horiz;
      case 'menu':
        return Icons.menu;
      case 'settings':
        return Icons.settings;
      default:
        return Icons.more_vert;
    }
  }

  Offset _parseOffset(dynamic offset) {
    if (offset == null) return Offset.zero;

    if (offset is Map<String, dynamic>) {
      final dx = offset['dx'];
      final dy = offset['dy'];
      return Offset(
        dx != null ? dx.toDouble() : 0,
        dy != null ? dy.toDouble() : 0,
      );
    }

    return Offset.zero;
  }

  ShapeBorder? _parseShapeBorder(dynamic shape) {
    if (shape == null) return null;

    if (shape is Map<String, dynamic>) {
      final type = shape['type'] as String?;
      switch (type) {
        case 'rounded':
          final radiusValue = shape['radius'];
          final radius = radiusValue != null ? radiusValue.toDouble() : 8.0;
          return RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          );
        default:
          return null;
      }
    }

    return null;
  }

  TextStyle? _parseTextStyle(dynamic style, RenderContext context) {
    if (style == null) return null;

    if (style is Map<String, dynamic>) {
      return TextStyle(
        color: parseColor(context.resolve(style['color']), context),
        fontSize: style['fontSize']?.toDouble(),
        fontWeight: style['fontWeight'] == 'bold' ? FontWeight.bold : null,
      );
    }

    return null;
  }
}
