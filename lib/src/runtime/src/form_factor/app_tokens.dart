import 'package:flutter/material.dart';

import 'form_factor.dart';

/// Design-token sets resolved against the active [FormFactor].
///
/// Static members on each namespace class are the compact / mobile
/// baseline — identical to what a phone-sized window renders. The
/// `.of(context)` accessor returns a [FormFactor]-scaled value object so
/// the same call site can produce refined values on desktop
/// (`expanded` / `large`) or enlarged values on embedded chrome.
///
/// Derivative players may override a token set at the widget tree level
/// (e.g. industrial chrome bumping icon sizes for gloved touch) by
/// wrapping a [FormFactorScope] with the pinned class above their
/// chrome — token accessors then resolve to the pinned class's scaling
/// curve.

// -----------------------------------------------------------------------------
// Spacing
// -----------------------------------------------------------------------------

/// FormFactor-resolved spacing values. Returned from [AppSpacing.of].
class AppSpacingScale {
  const AppSpacingScale({
    required this.xxs,
    required this.xs,
    required this.sm,
    required this.md,
    required this.base,
    required this.lg,
    required this.xl,
    required this.xxl,
  });

  final double xxs;
  final double xs;
  final double sm;
  final double md;
  final double base;
  final double lg;
  final double xl;
  final double xxl;
}

/// Spacing / padding / gap scale (8-point grid). Logical pixels.
class AppSpacing {
  const AppSpacing._();

  // Compact / mobile baseline — also the static default when no
  // FormFactor-aware accessor is needed.
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double base = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;

  static const EdgeInsets screenPadding = EdgeInsets.all(base);
  static const EdgeInsets cardPadding = EdgeInsets.all(md);

  static Widget vGap(double size) => SizedBox(height: size);
  static Widget hGap(double size) => SizedBox(width: size);

  /// Resolve spacing for the active [FormFactor]. Expanded / large keep
  /// the same numeric scale as compact (content breathes via layout
  /// rather than inflating gaps); embedded bumps ×1.25 to tolerate
  /// gloved / imprecise touch.
  static AppSpacingScale of(BuildContext context) {
    switch (FormFactor.of(context)) {
      case FormFactor.compact:
      case FormFactor.medium:
      case FormFactor.expanded:
      case FormFactor.large:
      case FormFactor.extraLarge:
        return _baseline;
      case FormFactor.embedded:
        return _embedded;
    }
  }

  static const AppSpacingScale _baseline = AppSpacingScale(
    xxs: 2, xs: 4, sm: 8, md: 12, base: 16, lg: 24, xl: 32, xxl: 48,
  );

  static const AppSpacingScale _embedded = AppSpacingScale(
    xxs: 3, xs: 6, sm: 10, md: 16, base: 20, lg: 32, xl: 40, xxl: 64,
  );
}

// -----------------------------------------------------------------------------
// Icon sizes
// -----------------------------------------------------------------------------

/// FormFactor-resolved icon sizes. Returned from [AppIconSizes.of].
class AppIconSizesScale {
  const AppIconSizesScale({
    required this.sm,
    required this.md,
    required this.lg,
    required this.xl,
  });

  final double sm;
  final double md;
  final double lg;
  final double xl;
}

/// Icon-size scale. Logical pixels.
class AppIconSizes {
  const AppIconSizes._();

  // Compact / mobile baseline — also static defaults.
  static const double sm = 16;
  static const double md = 24;
  static const double lg = 32;
  static const double xl = 48;

  /// Resolve icon sizes for the active [FormFactor]. Expanded / large
  /// tighten for a refined desktop chrome; embedded bumps ×1.3 for
  /// gloved / industrial touch targets.
  static AppIconSizesScale of(BuildContext context) {
    switch (FormFactor.of(context)) {
      case FormFactor.compact:
        return _compact;
      case FormFactor.medium:
        return _medium;
      case FormFactor.expanded:
      case FormFactor.large:
      case FormFactor.extraLarge:
        return _desktop;
      case FormFactor.embedded:
        return _embedded;
    }
  }

  static const AppIconSizesScale _compact = AppIconSizesScale(
    sm: 16, md: 24, lg: 32, xl: 48,
  );

  static const AppIconSizesScale _medium = AppIconSizesScale(
    sm: 15, md: 22, lg: 30, xl: 44,
  );

  static const AppIconSizesScale _desktop = AppIconSizesScale(
    sm: 14, md: 20, lg: 28, xl: 40,
  );

  static const AppIconSizesScale _embedded = AppIconSizesScale(
    sm: 20, md: 32, lg: 42, xl: 64,
  );
}

// -----------------------------------------------------------------------------
// Typography
// -----------------------------------------------------------------------------

/// [TextTheme] resolved against the active [FormFactor].
///
/// Compact / medium = the host [Theme]'s raw [TextTheme]. Expanded /
/// large tighten by a factor so desktop chrome reads as refined rather
/// than inflated. Embedded enlarges for farther viewing distance.
class AppTypographyScale {
  const AppTypographyScale({
    required this.textTheme,
    required this.scale,
  });

  final TextTheme textTheme;
  final double scale;
}

class AppTypography {
  const AppTypography._();

  /// Resolve typography for the active [FormFactor]. Pulls the host
  /// theme's [TextTheme] then applies a [FormFactor]-specific scale.
  static AppTypographyScale of(BuildContext context) {
    final baseline = Theme.of(context).textTheme;
    final scale = _scaleFor(FormFactor.of(context));
    if (scale == 1.0) return AppTypographyScale(textTheme: baseline, scale: scale);
    return AppTypographyScale(textTheme: _scale(baseline, scale), scale: scale);
  }

  static double _scaleFor(FormFactor ff) {
    switch (ff) {
      case FormFactor.compact:
        return 1.0;
      case FormFactor.medium:
        return 0.95;
      case FormFactor.expanded:
      case FormFactor.large:
      case FormFactor.extraLarge:
        return 0.85;
      case FormFactor.embedded:
        return 1.2;
    }
  }

  static TextTheme _scale(TextTheme base, double factor) {
    TextStyle? s(TextStyle? style) {
      if (style?.fontSize == null) return style;
      return style!.copyWith(fontSize: style.fontSize! * factor);
    }

    return base.copyWith(
      displayLarge: s(base.displayLarge),
      displayMedium: s(base.displayMedium),
      displaySmall: s(base.displaySmall),
      headlineLarge: s(base.headlineLarge),
      headlineMedium: s(base.headlineMedium),
      headlineSmall: s(base.headlineSmall),
      titleLarge: s(base.titleLarge),
      titleMedium: s(base.titleMedium),
      titleSmall: s(base.titleSmall),
      bodyLarge: s(base.bodyLarge),
      bodyMedium: s(base.bodyMedium),
      bodySmall: s(base.bodySmall),
      labelLarge: s(base.labelLarge),
      labelMedium: s(base.labelMedium),
      labelSmall: s(base.labelSmall),
    );
  }
}

// -----------------------------------------------------------------------------
// Density
// -----------------------------------------------------------------------------

/// [VisualDensity] and scrollbar hover policy for the active
/// [FormFactor].
///
/// Compact / medium keep Material's standard density so touch targets
/// stay comfortable on phone / tablet. Expanded / large apply
/// `VisualDensity.compact` so desktop chrome packs tighter without
/// dropping below Material's minimum hit target. Embedded returns to
/// `standard` (with slightly more breathing room) since industrial
/// chrome prioritises hit accuracy over density.
class AppDensity {
  const AppDensity._({
    required this.visualDensity,
    required this.scrollbarAlwaysVisible,
  });

  final VisualDensity visualDensity;

  /// Whether chrome-level scrollbars should be always visible
  /// (hover-less pointing) or auto-fade on touch.
  final bool scrollbarAlwaysVisible;

  static AppDensity of(BuildContext context) {
    switch (FormFactor.of(context)) {
      case FormFactor.compact:
      case FormFactor.medium:
        return _touch;
      case FormFactor.expanded:
      case FormFactor.large:
      case FormFactor.extraLarge:
        return _desktop;
      case FormFactor.embedded:
        return _touch;
    }
  }

  static const AppDensity _touch = AppDensity._(
    visualDensity: VisualDensity.standard,
    scrollbarAlwaysVisible: false,
  );

  static const AppDensity _desktop = AppDensity._(
    visualDensity: VisualDensity(horizontal: -1, vertical: -1),
    scrollbarAlwaysVisible: true,
  );
}
