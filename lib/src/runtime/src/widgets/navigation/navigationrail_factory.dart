import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../../utils/icon_resolver.dart';
import '../widget_factory.dart';

/// Factory for NavigationRail widgets
class NavigationRailWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties. `selectedIndex` may be a binding expression; the
    // factory resolves through the render context before clamping.
    final selectedIndexRaw = context.resolve(properties['selectedIndex']);
    final selectedIndex = selectedIndexRaw is int
        ? selectedIndexRaw
        : (selectedIndexRaw is num ? selectedIndexRaw.toInt() : 0);
    final extended = boolOf(properties['extended'], context) ?? false;
    final minWidth = numberOf(properties['minWidth'], context);
    final minExtendedWidth = numberOf(properties['minExtendedWidth'], context);
    final groupAlignment = numberOf(properties['groupAlignment'], context) ?? -1.0;
    final labelType = _parseLabelType(properties['labelType']);
    final unselectedLabelTextStyle =
        _parseTextStyle(properties['unselectedLabelTextStyle'], context);
    final selectedLabelTextStyle =
        _parseTextStyle(properties['selectedLabelTextStyle'], context);
    final unselectedIconTheme =
        _parseIconThemeData(properties['unselectedIconTheme'], context);
    final selectedIconTheme =
        _parseIconThemeData(properties['selectedIconTheme'], context);
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context);
    final elevation = numberOf(properties['elevation'], context);

    // Extract destinations
    final destinationsData = (properties['items'] ?? properties['destinations']) as List<dynamic>? ?? [];
    final destinations = destinationsData
        .map((dest) => _buildDestination(dest, context))
        .toList();

    // Extract leading and trailing widgets
    final leading = properties['leading'] != null
        ? context.buildWidget(properties['leading'] as Map<String, dynamic>)
        : null;
    final trailing = properties['trailing'] != null
        ? context.buildWidget(properties['trailing'] as Map<String, dynamic>)
        : null;

    // Extract action handler
    final onDestinationSelected =
        actionOf(properties['onChange'] ?? properties['onSelect'] ?? properties['change'] ?? properties['select'] ?? properties['onDestinationSelected'], context);

    Widget navigationRail = NavigationRail(
      selectedIndex: selectedIndex.clamp(0, destinations.length - 1),
      destinations: destinations,
      extended: extended,
      minWidth: minWidth,
      minExtendedWidth: minExtendedWidth,
      groupAlignment: groupAlignment,
      labelType: labelType,
      unselectedLabelTextStyle: unselectedLabelTextStyle,
      selectedLabelTextStyle: selectedLabelTextStyle,
      unselectedIconTheme: unselectedIconTheme,
      selectedIconTheme: selectedIconTheme,
      backgroundColor: backgroundColor,
      elevation: elevation,
      leading: leading,
      trailing: trailing,
      onDestinationSelected: onDestinationSelected != null
          ? (index) {
              // `{{event.index}}` resolves wherever the action puts it. The
              // previous form substituted into an `index` KEY of the action
              // map, which no action reads — so a rail wired to
              // `state.set { value: "{{event.index}}" }` wrote null.
              final eventContext = context.createChildContext(
                variables: {
                  'event': {'index': index, 'type': 'change'},
                },
              );
              context.actionHandler.execute(onDestinationSelected, eventContext);
            }
          : null,
    );

    return applyCommonWrappers(navigationRail, properties, context);
  }

  NavigationRailDestination _buildDestination(
      dynamic destData, RenderContext context) {
    if (destData is Map<String, dynamic>) {
      final icon = _parseIcon(destData['icon'], context) ?? const Icon(Icons.home);
      // Undeclared means "same as the icon", which is what Material does with
      // a null `selectedIcon`. Substituting a house here replaced whatever the
      // document declared on exactly the one destination the user is on.
      final selectedIcon = _parseIcon(destData['selectedIcon'], context);
      Widget label;
      if (destData['label'] != null) {
        final labelData = destData['label'];
        if (labelData is String) {
          label = Text(labelData);
        } else if (labelData is Map<String, dynamic>) {
          label = context.buildWidget(labelData);
        } else {
          label = const Text('');
        }
      } else if (destData['labelText'] != null) {
        label = Text(
            context.resolve<String?>(destData['labelText']) ?? '');
      } else {
        label = const Text('');
      }
      final padding = parseEdgeInsets(destData['padding']);

      return NavigationRailDestination(
        icon: icon,
        selectedIcon: selectedIcon,
        label: label,
        padding: padding,
      );
    }

    return const NavigationRailDestination(
      icon: Icon(Icons.home),
      label: Text('Item'),
    );
  }

  Widget? _parseIcon(dynamic iconData, RenderContext context) {
    if (iconData is Map<String, dynamic>) {
      return context.buildWidget(iconData);
    }

    if (iconData is String) {
      return Icon(_parseIconData(iconData));
    }

    return null;
  }

  IconData _parseIconData(String iconName) => resolveIconData(iconName);

  NavigationRailLabelType? _parseLabelType(String? value) {
    switch (value) {
      case 'none':
        return NavigationRailLabelType.none;
      case 'selected':
        return NavigationRailLabelType.selected;
      case 'all':
        return NavigationRailLabelType.all;
      default:
        return null;
    }
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

  IconThemeData? _parseIconThemeData(dynamic theme, RenderContext context) {
    if (theme == null) return null;

    if (theme is Map<String, dynamic>) {
      return IconThemeData(
        color: parseColor(context.resolve(theme['color']), context),
        size: theme['size']?.toDouble(),
        opacity: theme['opacity']?.toDouble(),
      );
    }

    return null;
  }
}
