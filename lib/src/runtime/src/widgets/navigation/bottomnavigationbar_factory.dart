import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for BottomNavigationBar widgets
class BottomNavigationBarWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Canonical `selectedIndex`; `currentIndex` kept as legacy
    // Flutter-style alias.
    // Tolerant read: a bound path whose state holds the wrong shape used to
    // throw a cast error out of `resolve<num?>`, and the renderer painted a red
    // box over the whole widget. A mistyped binding is an authoring mistake,
    // not a reason to take the screen down.
    final rawIndex = numberOf(
            properties['selectedIndex'] ?? properties['currentIndex'], context) ??
        0;
    final elevation = dimensionOf(properties['elevation'], context);
    final type = _parseBottomNavigationBarType(properties['type']);
    final fixedColor = parseColor(context.resolve(properties['fixedColor']), context);
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context);
    final iconSize = dimensionOf(properties['iconSize'], context) ?? 24.0;
    final selectedItemColor =
        parseColor(context.resolve(properties['selectedItemColor']), context);
    final unselectedItemColor =
        parseColor(context.resolve(properties['unselectedItemColor']), context);
    final selectedIconTheme =
        _parseIconThemeData(properties['selectedIconTheme'], context);
    final unselectedIconTheme =
        _parseIconThemeData(properties['unselectedIconTheme'], context);
    final selectedFontSize = dimensionOf(properties['selectedFontSize'], context) ?? 14.0;
    final unselectedFontSize =
        dimensionOf(properties['unselectedFontSize'], context) ?? 12.0;
    final selectedLabelStyle =
        _parseTextStyle(properties['selectedLabelStyle'], context);
    final unselectedLabelStyle =
        _parseTextStyle(properties['unselectedLabelStyle'], context);
    final showSelectedLabels = boolOf(properties['showSelectedLabels'], context);
    final showUnselectedLabels = boolOf(properties['showUnselectedLabels'], context);
    final enableFeedback = boolOf(properties['enableFeedback'], context);

    // Extract items
    // Tolerant read — see `tabBar`: a wrong-shaped binding drew an error box
    // over the navigation bar instead of an empty one.
    final itemsData = listOf(properties['items'], context) ?? const [];
    final items = itemsData.map<BottomNavigationBarItem>((item) {
      if (item is Map<String, dynamic>) {
        return BottomNavigationBarItem(
          icon: _buildIcon(item['icon'], context),
          activeIcon: item['activeIcon'] != null
              ? _buildIcon(item['activeIcon'], context)
              : null,
          // Canonical 'label', legacy alias 'title'.
          label: (item['label'] ?? item['title']) as String?,
          tooltip: item['tooltip'] as String?,
          backgroundColor: parseColor(context.resolve(item['backgroundColor']), context),
        );
      }
      return const BottomNavigationBarItem(
        icon: Icon(Icons.home),
        label: 'Item',
      );
    }).toList();

    // on + PascalCase optimal, legacy short names as fallback
    final onTap = actionOf(properties['onChange'] ?? properties['onTap'] ?? properties['change'] ?? properties['click'], context);

    // Flutter asserts a bottom bar has at least two items, so an empty list is
    // a crash rather than an empty bar. A document whose `items` binding has
    // not arrived yet (or holds the wrong shape) draws nothing here — which is
    // what "no data" looks like everywhere else — instead of taking the page
    // down or covering it with a cast error.
    if (items.length < 2) {
      return applyCommonWrappers(const SizedBox.shrink(), properties, context);
    }

    Widget bottomBar = BottomNavigationBar(
      items: items,
      // Flutter asserts on an out-of-range index. A bound index can exceed
      // the item count for a frame — clamping degrades that to the nearest
      // real tab instead of taking the whole page down.
      currentIndex: items.isEmpty
          ? 0
          : rawIndex.toInt().clamp(0, items.length - 1),
      elevation: elevation,
      type: type,
      fixedColor: fixedColor,
      backgroundColor: backgroundColor,
      iconSize: iconSize,
      selectedItemColor: selectedItemColor,
      unselectedItemColor: unselectedItemColor,
      selectedIconTheme: selectedIconTheme,
      unselectedIconTheme: unselectedIconTheme,
      selectedFontSize: selectedFontSize,
      unselectedFontSize: unselectedFontSize,
      selectedLabelStyle: selectedLabelStyle,
      unselectedLabelStyle: unselectedLabelStyle,
      showSelectedLabels: showSelectedLabels,
      showUnselectedLabels: showUnselectedLabels,
      enableFeedback: enableFeedback,
      onTap: onTap != null
          ? (index) {
              // Update state if bindTo is specified
              final path = stringOf(properties['bindTo'], context);
              if (path != null) {
                context.setValue(path, index);
              }

              // Execute action with index
              final eventData = Map<String, dynamic>.from(onTap);
              if (eventData['value'] == '{{event.index}}') {
                eventData['value'] = index;
              }
              context.actionHandler.execute(eventData, context);
            }
          : null,
    );

    return bottomBar;
  }

  Widget _buildIcon(dynamic iconDef, RenderContext context) {
    if (iconDef == null) return const Icon(Icons.home);

    if (iconDef is Map<String, dynamic>) {
      return context.renderer.renderWidget(iconDef, context);
    } else if (iconDef is String) {
      return Icon(_parseIconData(iconDef));
    }

    return const Icon(Icons.home);
  }

  BottomNavigationBarType _parseBottomNavigationBarType(String? type) {
    switch (type) {
      case 'fixed':
        return BottomNavigationBarType.fixed;
      case 'shifting':
        return BottomNavigationBarType.shifting;
      default:
        return BottomNavigationBarType.fixed;
    }
  }

  IconThemeData? _parseIconThemeData(
      Map<String, dynamic>? data, RenderContext context) {
    if (data == null) return null;

    return IconThemeData(
      color: parseColor(context.resolve(data['color']), context),
      size: data['size']?.toDouble(),
      opacity: data['opacity']?.toDouble(),
    );
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

  IconData _parseIconData(String iconName) {
    // Basic icon mapping
    switch (iconName) {
      case 'home':
        return Icons.home;
      case 'search':
        return Icons.search;
      case 'favorite':
        return Icons.favorite;
      case 'person':
        return Icons.person;
      case 'settings':
        return Icons.settings;
      default:
        return Icons.home;
    }
  }
}
