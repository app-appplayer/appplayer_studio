import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for icon button widget
class IconButtonWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    // Resolve icon
    final icon = properties['icon'];
    IconData? iconData;
    if (icon is String) {
      iconData = _resolveIconData(icon);
    } else if (icon is int) {
      iconData =
          IconData(icon, fontFamily: properties['fontFamily'] as String?);
    }

    iconData ??= Icons.error;

    // Callback property: onTap as primary, event name 'click' as fallback
    final clickAction = (properties['onTap'] ?? properties['click']) as Map<String, dynamic>?;
    final onPressed = clickAction != null
        ? () => context.handleAction(clickAction)
        : null;

    // Spec §2.6.2: `size` (canonical) and `enabled`. `iconSize` kept as legacy.
    final size = properties['size']?.toDouble() ??
        properties['iconSize']?.toDouble() ??
        24.0;
    final enabled = properties['enabled'] as bool? ?? true;

    return IconButton(
      icon: Icon(iconData),
      onPressed: enabled ? onPressed : null,
      iconSize: size,
      color: resolveColor(properties['color'], context),
      disabledColor: resolveColor(properties['disabledColor'], context),
      splashColor: resolveColor(properties['splashColor'], context),
      highlightColor: resolveColor(properties['highlightColor'], context),
      tooltip: context.resolve(properties['tooltip']),
      padding:
          resolveEdgeInsets(properties['padding']) ?? const EdgeInsets.all(8.0),
      alignment: resolveAlignment(properties['alignment']) ?? Alignment.center,
      splashRadius: properties['splashRadius']?.toDouble(),
      enableFeedback: properties['enableFeedback'] ?? true,
    );
  }

  IconData _resolveIconData(String iconName) {
    // Use the same icon resolution logic as in Renderer
    switch (iconName.toLowerCase()) {
      case 'add':
        return Icons.add;
      case 'remove':
        return Icons.remove;
      case 'edit':
        return Icons.edit;
      case 'delete':
        return Icons.delete;
      case 'save':
        return Icons.save;
      case 'close':
        return Icons.close;
      case 'menu':
        return Icons.menu;
      case 'search':
        return Icons.search;
      case 'home':
        return Icons.home;
      case 'settings':
        return Icons.settings;
      case 'person':
        return Icons.person;
      case 'favorite':
        return Icons.favorite;
      case 'share':
        return Icons.share;
      case 'info':
        return Icons.info;
      case 'warning':
        return Icons.warning;
      case 'error':
        return Icons.error;
      case 'check':
        return Icons.check;
      case 'arrow_back':
        return Icons.arrow_back;
      case 'arrow_forward':
        return Icons.arrow_forward;
      case 'arrow_upward':
        return Icons.arrow_upward;
      case 'arrow_downward':
        return Icons.arrow_downward;
      case 'refresh':
        return Icons.refresh;
      case 'more_vert':
        return Icons.more_vert;
      case 'more_horiz':
        return Icons.more_horiz;
      default:
        return Icons.help_outline;
    }
  }
}
