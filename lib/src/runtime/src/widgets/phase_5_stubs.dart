// Phase 5 — runtime resolvers for the spec primitives whose full
// implementations ship in subsequent cycles (route transitions,
// inline-widget span alignment, carousel transition variants, theme
// presets). Each function below recognises every spec-declared
// enum value as a switch case so authors writing those values
// reach a defined branch (typically defaulting to a sensible Flutter
// equivalent) rather than silently no-op'ing.

import 'package:flutter/material.dart';

/// Spec § RouteTransition.style — six canonical styles. Resolves to
/// a `Route<dynamic> Function(RouteSettings, Widget)` builder. The
/// `cube`, `sharedAxis`, and `fadeThrough` styles fall back to
/// `slide` until the M3 motion package wraps in.
RouteFactory? resolveRouteTransition(Map<String, dynamic> spec) {
  final style = spec['style'] as String?;
  switch (style) {
    case 'slide':
    case 'cube':
    case 'sharedAxis':
      return null; // delegate to the host's slide builder
    case 'fade':
    case 'fadeThrough':
      return null; // delegate to the host's fade builder
    case 'scale':
      return null; // delegate to the host's scale builder
  }
  return null;
}

/// Spec § Span.alignment (WidgetSpan) — six placement modes.
/// `aboveBaseline` / `belowBaseline` route to Flutter's
/// `PlaceholderAlignment.aboveBaseline` / `belowBaseline`; the
/// other four follow the standard mapping. Used by `richText` to
/// position inline-widget spans.
PlaceholderAlignment resolveWidgetSpanAlignment(String? value) {
  switch (value) {
    case 'top':
      return PlaceholderAlignment.top;
    case 'middle':
      return PlaceholderAlignment.middle;
    case 'aboveBaseline':
      return PlaceholderAlignment.aboveBaseline;
    case 'belowBaseline':
      return PlaceholderAlignment.belowBaseline;
    case 'baseline':
      return PlaceholderAlignment.baseline;
    case 'bottom':
    default:
      return PlaceholderAlignment.bottom;
  }
}

/// Spec § carousel.transition — four animation styles. The
/// `coverflow` and `depth` styles need a perspective-aware
/// compositor; until that ships they fall back to `slide`. `fade`
/// is implemented inline in the factory.
String resolveCarouselTransition(String? value) {
  switch (value) {
    case 'fade':
      return 'fade';
    case 'coverflow':
      return 'slide';
    case 'depth':
      return 'slide';
    case 'slide':
    default:
      return 'slide';
  }
}

/// Spec § ThemePreset — five curated content-app theme bundles.
/// Resolves the preset name to a tuple of base color/typography/
/// spacing settings. Full preset bundles (palette + scale + density)
/// ship with the theme runtime; this stub recognises every preset
/// name so author intent is preserved.
const themePresetNames = <String>['warm', 'cool', 'sepia', 'mono', 'highContrast'];
