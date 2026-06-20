// ============================================================================
// vibe — Flutter ThemeData (Material 3, dark)
// Drop-in: copy to lib/theme/app_theme.dart
// Wire in main.dart:  MaterialApp(theme: AppTheme.dark, ...)
// ============================================================================

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'tokens.dart';

abstract final class AppTheme {
  /// Light variant of the chrome theme — mirror of [dark] with the
  /// brand mint accent on top of a Material-3 light surface ramp. Used
  /// when the user picks "Light" in Settings (or "System" + OS light).
  /// The shape, spacing, and component themes stay identical; only the
  /// ColorScheme + a couple of surface bridges flip.
  static ThemeData get light {
    final c = VibeTokens.lightColor;
    final colorScheme = ColorScheme.light(
      brightness: Brightness.light,
      primary: c.mint,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFC7EFE5),
      onPrimaryContainer: const Color(0xFF0F3D34),
      secondary: c.violet,
      onSecondary: Colors.white,
      tertiary: c.amber,
      onTertiary: Colors.black,
      error: c.coral,
      onError: Colors.white,
      surface: Colors.white,
      onSurface: const Color(0xFF0B0E13),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFF7F8FA),
      surfaceContainer: const Color(0xFFEFF1F5),
      surfaceContainerHigh: const Color(0xFFE6E9EE),
      surfaceContainerHighest: const Color(0xFFDDE1E7),
      onSurfaceVariant: const Color(0xFF424B5C),
      outline: const Color(0xFFC9CED6),
      outlineVariant: const Color(0xFFE4E7EC),
      shadow: Colors.transparent,
      scrim: Colors.black54,
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: Colors.white,
      canvasColor: Colors.white,
      textTheme: GoogleFonts.interTextTheme(),
      visualDensity: VisualDensity.compact,
      splashFactory: NoSplash.splashFactory,
    );
    // Mirror dark theme's textTheme + component themes — the only
    // axis that flips is the ColorScheme. Without this the light
    // chrome inherits Flutter's default 16px body text and the chat
    // composer (uses textTheme.bodyMedium) suddenly balloons.
    return base.copyWith(
      textTheme: _textTheme(c),
      iconTheme: IconThemeData(color: colorScheme.onSurfaceVariant, size: 16),
      dividerTheme: DividerThemeData(
        color: colorScheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          textStyle: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.onSurface,
          side: BorderSide(color: colorScheme.outline),
          textStyle: GoogleFonts.inter(
            fontWeight: FontWeight.w500,
            fontSize: 13,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.onSurfaceVariant,
          textStyle: GoogleFonts.inter(
            fontWeight: FontWeight.w500,
            fontSize: 13,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerLow,
        hoverColor: colorScheme.surfaceContainer,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        hintStyle: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
          borderSide: BorderSide(color: colorScheme.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
          borderSide: BorderSide(color: colorScheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
        ),
      ),
      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VibeTokens.radiusLg),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
          border: Border.all(color: colorScheme.outline),
        ),
        textStyle: GoogleFonts.inter(
          fontSize: 11,
          color: colorScheme.onSurface,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(colorScheme.outline),
        thickness: WidgetStateProperty.all(6),
        radius: const Radius.circular(3),
      ),
    );
  }

  static ThemeData get dark {
    final c = VibeTokens.color;

    final colorScheme = ColorScheme.dark(
      brightness: Brightness.dark,
      primary: c.mint,
      onPrimary: c.bg,
      primaryContainer: const Color(0xFF1A2A26),
      onPrimaryContainer: c.mint,
      secondary: c.violet,
      onSecondary: c.bg,
      tertiary: c.amber,
      onTertiary: c.bg,
      error: c.coral,
      onError: c.bg,
      surface: c.surface,
      onSurface: c.textPrimary,
      surfaceContainerLowest: c.bg,
      surfaceContainerLow: c.surface,
      surfaceContainer: c.surface2,
      surfaceContainerHigh: c.surface3,
      surfaceContainerHighest: c.elevated,
      onSurfaceVariant: c.textSecondary,
      outline: c.borderDefault,
      outlineVariant: c.borderSubtle,
      shadow: Colors.transparent,
      scrim: Colors.black54,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: c.bg,
      canvasColor: c.bg,
      // Pulls Inter from Google Fonts at runtime so the design's typography
      // intent survives without bundling .ttf assets.
      textTheme: GoogleFonts.interTextTheme(),
      visualDensity: VisualDensity.compact,
      splashFactory: NoSplash.splashFactory,
    );

    return base.copyWith(
      textTheme: _textTheme(c),
      iconTheme: IconThemeData(color: c.textSecondary, size: 16),

      dividerTheme: DividerThemeData(
        color: c.borderDefault,
        thickness: 1,
        space: 1,
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.mint,
          foregroundColor: c.bg,
          textStyle: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.textPrimary,
          side: BorderSide(color: c.borderStrong),
          textStyle: GoogleFonts.inter(
            fontWeight: FontWeight.w500,
            fontSize: 13,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.textSecondary,
          textStyle: GoogleFonts.inter(
            fontWeight: FontWeight.w500,
            fontSize: 13,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surface2,
        hoverColor: c.surface3,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        hintStyle: TextStyle(color: c.textTertiary, fontSize: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
          borderSide: BorderSide(color: c.borderDefault),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
          borderSide: BorderSide(color: c.borderDefault),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
          borderSide: BorderSide(color: c.mint, width: 1.5),
        ),
      ),

      cardTheme: CardThemeData(
        color: c.surface2,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VibeTokens.radiusLg),
          side: BorderSide(color: c.borderDefault),
        ),
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: c.elevated,
          borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
          border: Border.all(color: c.borderStrong),
        ),
        textStyle: GoogleFonts.inter(fontSize: 11, color: c.textPrimary),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),

      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(c.borderStrong),
        thickness: WidgetStateProperty.all(6),
        radius: const Radius.circular(3),
      ),
    );
  }

  static TextTheme _textTheme(dynamic c) {
    TextStyle sans({
      double size = 13,
      FontWeight weight = FontWeight.w400,
      Color? color,
      double? height,
      double? letterSpacing,
    }) => GoogleFonts.inter(
      fontSize: size,
      fontWeight: weight,
      color: color ?? c.textPrimary,
      height: height,
      letterSpacing: letterSpacing,
    );

    return TextTheme(
      // Display — large numbers, hero text
      displayLarge: sans(
        size: 32,
        weight: FontWeight.w600,
        height: 1.2,
        letterSpacing: -0.5,
      ),
      displayMedium: sans(
        size: 24,
        weight: FontWeight.w600,
        height: 1.3,
        letterSpacing: -0.3,
      ),
      displaySmall: sans(size: 20, weight: FontWeight.w600, height: 1.3),

      // Headline — section headers
      headlineLarge: sans(size: 18, weight: FontWeight.w600),
      headlineMedium: sans(size: 16, weight: FontWeight.w600),
      headlineSmall: sans(size: 14, weight: FontWeight.w600),

      // Title — panel titles, card titles
      titleLarge: sans(size: 14, weight: FontWeight.w600),
      titleMedium: sans(size: 13, weight: FontWeight.w500),
      titleSmall: sans(
        size: 12,
        weight: FontWeight.w500,
        color: c.textSecondary,
      ),

      // Body — paragraph, content
      bodyLarge: sans(size: 14, weight: FontWeight.w400, height: 1.5),
      bodyMedium: sans(size: 13, weight: FontWeight.w400, height: 1.5),
      bodySmall: sans(
        size: 12,
        weight: FontWeight.w400,
        height: 1.5,
        color: c.textSecondary,
      ),

      // Label — buttons, chips, badges
      labelLarge: sans(size: 13, weight: FontWeight.w500),
      labelMedium: sans(
        size: 12,
        weight: FontWeight.w500,
        color: c.textSecondary,
      ),
      labelSmall: sans(
        size: 11,
        weight: FontWeight.w500,
        letterSpacing: 0.04 * 11,
        color: c.textTertiary,
      ),
    );
  }
}

/// Mono text style — for code, IDs, paths.
TextStyle vibeMono({
  double size = 12,
  FontWeight weight = FontWeight.w400,
  Color? color,
}) => GoogleFonts.jetBrainsMono(
  fontSize: size,
  fontWeight: weight,
  color: color,
  height: 1.5,
);
