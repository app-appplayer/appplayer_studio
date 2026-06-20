import 'package:flutter/material.dart';
import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart';

/// Convert MCP UI DSL 1.3 [ThemeDefinition] into Flutter [ThemeData].
///
/// Implements `specs/mcp_ui_dsl/05_Theme.md` Material 3 mapping:
/// - 28-role color → Flutter [ColorScheme]
/// - 15-role typography → Flutter [TextTheme]
/// - DensityDefinition → [VisualDensity]
/// - ShapeDefinition → component shape themes
/// - ElevationDefinition → tonal surface tint
class McpUiThemeBuilder {
  McpUiThemeBuilder._();

  /// Build [ThemeData] from a [ThemeDefinition] for the specified brightness.
  static ThemeData build(ThemeDefinition def, {required bool isDark}) {
    final brightness = isDark ? Brightness.dark : Brightness.light;
    final color = def.color;
    final typography = def.typography;

    final colorScheme = _buildColorScheme(color, brightness);
    final textTheme = _buildTextTheme(typography);
    final density = _buildDensity(def.density);
    final shape = _buildShape(def.shape);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      textTheme: textTheme,
      visualDensity: density,
      cardTheme: CardThemeData(
        shape: shape != null ? RoundedRectangleBorder(borderRadius: shape) : null,
      ),
      dialogTheme: DialogThemeData(
        shape: shape != null ? RoundedRectangleBorder(borderRadius: shape) : null,
      ),
      // M3 default — SnackBar uses `inverseSurface` (dark in light mode,
      // light in dark mode) for high contrast against the scaffold. Pinned
      // to floating so the layout doesn't push the body up; explicit
      // background prevents Flutter's default fixed container from
      // overriding the M3 colours.
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colorScheme.inverseSurface,
        contentTextStyle: TextStyle(color: colorScheme.onInverseSurface),
        actionTextColor: colorScheme.inversePrimary,
        closeIconColor: colorScheme.onInverseSurface,
      ),
    );
  }

  static ColorScheme _buildColorScheme(
    ColorSchemeDefinition? def,
    Brightness brightness,
  ) {
    if (def == null) {
      return ColorScheme.fromSeed(
        seedColor: const Color(0xFF3F51B5),
        brightness: brightness,
      );
    }

    Color? parse(String? hex) => _parseHexColor(hex);

    Color pick(String? slot, Color fallback) => parse(slot) ?? fallback;

    final seedColor = parse(def.seed);
    final base = seedColor != null
        ? ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness)
        : (brightness == Brightness.dark
            ? const ColorScheme.dark()
            : const ColorScheme.light());

    return base.copyWith(
      primary: pick(def.primary, base.primary),
      onPrimary: pick(def.onPrimary, base.onPrimary),
      primaryContainer: pick(def.primaryContainer, base.primaryContainer),
      onPrimaryContainer: pick(def.onPrimaryContainer, base.onPrimaryContainer),
      secondary: pick(def.secondary, base.secondary),
      onSecondary: pick(def.onSecondary, base.onSecondary),
      secondaryContainer: pick(def.secondaryContainer, base.secondaryContainer),
      onSecondaryContainer:
          pick(def.onSecondaryContainer, base.onSecondaryContainer),
      tertiary: pick(def.tertiary, base.tertiary),
      onTertiary: pick(def.onTertiary, base.onTertiary),
      tertiaryContainer: pick(def.tertiaryContainer, base.tertiaryContainer),
      onTertiaryContainer:
          pick(def.onTertiaryContainer, base.onTertiaryContainer),
      error: pick(def.error, base.error),
      onError: pick(def.onError, base.onError),
      errorContainer: pick(def.errorContainer, base.errorContainer),
      onErrorContainer: pick(def.onErrorContainer, base.onErrorContainer),
      surface: pick(def.surface, base.surface),
      onSurface: pick(def.onSurface, base.onSurface),
      onSurfaceVariant: pick(def.onSurfaceVariant, base.onSurfaceVariant),
      surfaceTint: pick(def.surfaceTint, base.surfaceTint),
      surfaceBright: pick(def.surfaceBright, base.surfaceBright),
      surfaceDim: pick(def.surfaceDim, base.surfaceDim),
      surfaceContainerLowest:
          pick(def.surfaceContainerLowest, base.surfaceContainerLowest),
      surfaceContainerLow:
          pick(def.surfaceContainerLow, base.surfaceContainerLow),
      surfaceContainer: pick(def.surfaceContainer, base.surfaceContainer),
      surfaceContainerHigh:
          pick(def.surfaceContainerHigh, base.surfaceContainerHigh),
      surfaceContainerHighest:
          pick(def.surfaceContainerHighest, base.surfaceContainerHighest),
      outline: pick(def.outline, base.outline),
      outlineVariant: pick(def.outlineVariant, base.outlineVariant),
      inverseSurface: pick(def.inverseSurface, base.inverseSurface),
      onInverseSurface: pick(def.onInverseSurface, base.onInverseSurface),
      inversePrimary: pick(def.inversePrimary, base.inversePrimary),
      scrim: pick(def.scrim, base.scrim),
      shadow: pick(def.shadow, base.shadow),
    );
  }

  static TextTheme _buildTextTheme(TypographyDefinition? def) {
    if (def == null) return const TextTheme();
    return TextTheme(
      displayLarge: _ts(def.displayLarge),
      displayMedium: _ts(def.displayMedium),
      displaySmall: _ts(def.displaySmall),
      headlineLarge: _ts(def.headlineLarge),
      headlineMedium: _ts(def.headlineMedium),
      headlineSmall: _ts(def.headlineSmall),
      titleLarge: _ts(def.titleLarge),
      titleMedium: _ts(def.titleMedium),
      titleSmall: _ts(def.titleSmall),
      bodyLarge: _ts(def.bodyLarge),
      bodyMedium: _ts(def.bodyMedium),
      bodySmall: _ts(def.bodySmall),
      labelLarge: _ts(def.labelLarge),
      labelMedium: _ts(def.labelMedium),
      labelSmall: _ts(def.labelSmall),
    );
  }

  static TextStyle? _ts(TextStyleDefinition? s) {
    if (s == null) return null;
    final size = s.fontSize?.toDouble();
    final lineH = s.lineHeight?.toDouble();
    final family = s.fontFamily;
    final fontFamily = family is String ? family : null;
    final fontFamilyFallback = family is List
        ? family.map((e) => e.toString()).toList()
        : null;
    return TextStyle(
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSize: size,
      fontWeight: _weight(s.fontWeight),
      letterSpacing: s.letterSpacing?.toDouble(),
      height: (size != null && lineH != null && size > 0)
          ? lineH / size
          : null,
    );
  }

  static FontWeight? _weight(Object? w) {
    if (w == null) return null;
    if (w is num) {
      final v = w.toInt();
      const buckets = [100, 200, 300, 400, 500, 600, 700, 800, 900];
      final closest = buckets.reduce(
          (a, b) => (a - v).abs() < (b - v).abs() ? a : b);
      switch (closest) {
        case 100:
          return FontWeight.w100;
        case 200:
          return FontWeight.w200;
        case 300:
          return FontWeight.w300;
        case 400:
          return FontWeight.w400;
        case 500:
          return FontWeight.w500;
        case 600:
          return FontWeight.w600;
        case 700:
          return FontWeight.w700;
        case 800:
          return FontWeight.w800;
        case 900:
          return FontWeight.w900;
      }
      return FontWeight.w400;
    }
    if (w is! String) return null;
    switch (w) {
      case 'thin':
      case '100':
        return FontWeight.w100;
      case 'extraLight':
      case '200':
        return FontWeight.w200;
      case 'light':
      case '300':
        return FontWeight.w300;
      case 'regular':
      case 'normal':
      case '400':
        return FontWeight.w400;
      case 'medium':
      case '500':
        return FontWeight.w500;
      case 'semiBold':
      case '600':
        return FontWeight.w600;
      case 'bold':
      case '700':
        return FontWeight.w700;
      case 'extraBold':
      case '800':
        return FontWeight.w800;
      case 'black':
      case '900':
        return FontWeight.w900;
      default:
        return null;
    }
  }

  static VisualDensity _buildDensity(DensityDefinition? def) {
    if (def == null) return VisualDensity.standard;
    final active = def.active ?? 'standard';
    final level = def.level(active) ?? def.standard;
    if (level == null) return VisualDensity.standard;
    return VisualDensity(
      horizontal: level.horizontal.toDouble(),
      vertical: level.vertical.toDouble(),
    );
  }

  static BorderRadius? _buildShape(ShapeDefinition? def) {
    if (def == null) return null;
    final corner = def.medium ?? def.small;
    if (corner == null) return null;
    return _cornerToBorderRadius(corner);
  }

  static BorderRadius _cornerToBorderRadius(ShapeCorner corner) {
    if (corner.uniform != null) {
      return BorderRadius.circular(corner.uniform!.toDouble());
    }
    return BorderRadius.only(
      topLeft: Radius.circular((corner.topStart ?? 0).toDouble()),
      topRight: Radius.circular((corner.topEnd ?? 0).toDouble()),
      bottomLeft: Radius.circular((corner.bottomStart ?? 0).toDouble()),
      bottomRight: Radius.circular((corner.bottomEnd ?? 0).toDouble()),
    );
  }

  static Color? _parseHexColor(String? value) {
    if (value == null) return null;
    final v = value.trim();
    if (v.isEmpty || !v.startsWith('#')) return null;
    final hex = v.substring(1);
    if (hex.length == 6) {
      return Color(int.parse('FF$hex', radix: 16));
    }
    if (hex.length == 8) {
      return Color(int.parse(hex, radix: 16));
    }
    return null;
  }
}
