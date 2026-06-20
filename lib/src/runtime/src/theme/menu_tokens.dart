import 'package:flutter/material.dart';

import 'theme_manager.dart';

/// Shared compact-menu visual tokens for `Dropdown` and `PopupMenuButton`.
///
/// Resolution order, applied per-token:
/// 1. Widget-level DSL property (caller passes via constructor args).
/// 2. `theme.component.menu.<key>` from the active `ThemeDefinition` —
///    publishers tune all menu instances at once.
/// 3. `theme.shape.*` for radius (Material 3 shape family).
/// 4. Compact defaults baked here — Material's bare defaults
///    (16dp padding, 0 radius) are visually broken; this layer makes
///    the runtime look right out of the box without any DSL config.
class MenuTokens {
  MenuTokens._({
    required this.radius,
    required this.itemHeight,
    required this.itemHorizontalPadding,
    required this.itemVerticalPadding,
    required this.menuVerticalPadding,
    required this.elevation,
    required this.noAnimation,
  });

  /// Resolved corner radius for the menu surface (in logical pixels).
  final double radius;

  /// Per-item minimum height (in logical pixels). `null` means
  /// "no minimum" — the item's natural height (text + padding) wins,
  /// so larger fonts grow the item proportionally.
  final double? itemHeight;

  /// Per-item horizontal padding.
  final double itemHorizontalPadding;

  /// Per-item vertical padding (kept tight by default).
  final double itemVerticalPadding;

  /// Vertical padding around the menu list (PopupMenuButton's default
  /// is 8dp top/bottom — compact = 0 so items sit flush against the
  /// menu border).
  final double menuVerticalPadding;

  /// Elevation passed to the popup menu.
  final double elevation;

  /// When `true`, suppress the default popup open/close animation.
  final bool noAnimation;

  /// Compact defaults — applied when neither widget props nor theme
  /// supply a value. `itemHeight` default is `null` so item height
  /// auto-scales with font size (text natural height + vertical
  /// padding wins). With the 4dp vertical padding default this gives
  /// ≈ 25px for 13px text, ≈ 32px for 20px text — proportional
  /// breathing room across font sizes.
  static const double _defaultRadius = 6;
  static const double? _defaultItemHeight = null;
  static const double _defaultItemHorizontalPadding = 12;
  static const double _defaultItemVerticalPadding = 4;
  static const double _defaultMenuVerticalPadding = 4;
  static const double _defaultElevation = 4;
  static const bool _defaultNoAnimation = true;

  /// Resolve the active token bundle.
  ///
  /// Each named arg is the widget-level override (`null` = "no DSL
  /// override; defer to theme / defaults"). The returned bundle has
  /// every field non-null; factories pass it directly to Flutter
  /// widgets.
  static MenuTokens resolve(
    ThemeManager theme, {
    double? radius,
    double? itemHeight,
    double? itemHorizontalPadding,
    double? itemVerticalPadding,
    double? menuVerticalPadding,
    double? elevation,
    bool? noAnimation,
  }) {
    final menu = theme.getThemeValue('component.menu') as Map<String, dynamic>?;
    double? read(String key) {
      final v = menu?[key];
      if (v is num) return v.toDouble();
      return null;
    }

    bool? readBool(String key) {
      final v = menu?[key];
      if (v is bool) return v;
      return null;
    }

    final shapeRadius = (theme.getThemeValue('shape.small.uniform') as num?)
            ?.toDouble() ??
        (theme.getThemeValue('shape.extraSmall.uniform') as num?)?.toDouble();

    return MenuTokens._(
      radius: radius ?? read('radius') ?? shapeRadius ?? _defaultRadius,
      itemHeight:
          itemHeight ?? read('itemHeight') ?? _defaultItemHeight,
      itemHorizontalPadding: itemHorizontalPadding ??
          read('itemHorizontalPadding') ??
          _defaultItemHorizontalPadding,
      itemVerticalPadding: itemVerticalPadding ??
          read('itemVerticalPadding') ??
          _defaultItemVerticalPadding,
      menuVerticalPadding: menuVerticalPadding ??
          read('menuVerticalPadding') ??
          _defaultMenuVerticalPadding,
      elevation: elevation ?? read('elevation') ?? _defaultElevation,
      noAnimation:
          noAnimation ?? readBool('noAnimation') ?? _defaultNoAnimation,
    );
  }

  /// Convenience — `RoundedRectangleBorder` with the resolved radius.
  RoundedRectangleBorder get shape => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      );

  /// Convenience — `EdgeInsets.symmetric` with the resolved item padding.
  EdgeInsets get itemPadding => EdgeInsets.symmetric(
        horizontal: itemHorizontalPadding,
        vertical: itemVerticalPadding,
      );

  /// Convenience — `EdgeInsets.symmetric` for the menu surface itself.
  EdgeInsets get menuPadding => EdgeInsets.symmetric(
        vertical: menuVerticalPadding,
      );

  /// Convenience — `AnimationStyle.noAnimation` when [noAnimation] is
  /// `true`, otherwise `null` (use Flutter's default).
  AnimationStyle? get popupAnimationStyle =>
      noAnimation ? AnimationStyle.noAnimation : null;
}
