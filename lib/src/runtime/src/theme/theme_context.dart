import 'package:flutter/material.dart';
import 'theme_manager.dart';

/// Theme context provider for MCP UI
class ThemeContext extends InheritedWidget {
  final ThemeManager themeManager;
  final Map<String, dynamic> themeOverrides;

  const ThemeContext({
    super.key,
    required this.themeManager,
    this.themeOverrides = const {},
    required super.child,
  });

  static ThemeContext? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ThemeContext>();
  }

  /// Get theme value with overrides
  dynamic getThemeValue(String path) {
    // Check overrides first
    final parts = path.split('.');
    dynamic current = themeOverrides;

    for (final part in parts) {
      if (current is Map<String, dynamic> && current.containsKey(part)) {
        current = current[part];
      } else {
        // Fallback to theme manager
        return themeManager.getThemeValue(path);
      }
    }

    return current;
  }

  @override
  bool updateShouldNotify(ThemeContext oldWidget) {
    return themeManager != oldWidget.themeManager ||
        themeOverrides != oldWidget.themeOverrides;
  }
}
