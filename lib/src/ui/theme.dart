// ============================================================================
// vibe_studio_ui — ThemeData (Material 3, dark + light)
// Extracted from vibe's AppTheme.dark. Every makemind builder shares
// the same tone.
// ============================================================================

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

abstract final class VbuTheme {
  /// Default dark theme — vibe-derived. Default for every makemind builder.
  static ThemeData get dark => _build(_darkScheme());

  /// mcp_ui_runtime ThemeManager JSON shape derived from
  /// [VbuTokens.color]. Consumers (DslWorkspaceView, preview panes,
  /// embedded runtimes) inject this into `mountDef.theme` or
  /// `themeManager.setTheme` so the inner MaterialApp follows the
  /// studio M3 tone without each call site hardcoding hex values.
  ///
  /// `isDark` selects the surface palette; accent / typography
  /// colors stay token-driven either way. Future palette swaps live
  /// in [VbuTokens.color] and propagate to every consumer.
  static Map<String, Object?> studioRuntimeTheme({bool isDark = true}) {
    String hex(Color v) {
      final n = v.toARGB32() & 0x00FFFFFF;
      return '#${n.toRadixString(16).padLeft(6, '0').toUpperCase()}';
    }

    // Brand accents — shared across light and dark.
    const dark = VbuTokens.color;
    const light = VbuTokens.lightColor;

    Map<String, Object?> paletteFor(VbuPalette p) => <String, Object?>{
      'primary': hex(p.mint),
      'onPrimary': hex(p.bg),
      'surface': hex(p.surface),
      'onSurface': hex(p.textPrimary),
      'background': hex(p.bg),
      'onBackground': hex(p.textPrimary),
    };

    Map<String, Object?> typographyFor(VbuPalette p) => <String, Object?>{
      'fontFamily': 'Roboto',
      for (final entry
          in const <String, double>{
            'displayLarge': 57,
            'displayMedium': 45,
            'displaySmall': 36,
            'headlineLarge': 32,
            'headlineMedium': 28,
            'headlineSmall': 24,
            'titleLarge': 22,
            'titleMedium': 16,
            'titleSmall': 14,
            'bodyLarge': 16,
            'bodyMedium': 14,
            'bodySmall': 12,
            'labelLarge': 14,
            'labelMedium': 12,
            'labelSmall': 11,
          }.entries)
        entry.key: <String, Object?>{
          'fontFamily': 'Roboto',
          'fontSize': entry.value,
          'color': hex(p.textPrimary),
        },
    };

    // Single ThemeDefinition with both `dark` and `light` mode-specific
    // variants. ThemeManager resolves the active mode (driven by
    // `mode` + `setHostBrightness`) and picks the matching variant —
    // without this both branches saw the common (dark) palette and
    // the light toggle did nothing.
    //
    // `mode: 'system'` is the canonical declaration here so the
    // runtime's `flutterThemeMode` honours `setHostBrightness` (which
    // ThemeManager only consults when `_themeMode == 'system'`).
    // Hosts that need a hard dark/light pin can override after
    // `initialize` via `themeManager.setMode(...)`.
    return <String, Object?>{
      'mode': 'system',
      'typography': typographyFor(dark),
      'color': paletteFor(dark),
      'dark': <String, Object?>{
        'typography': typographyFor(dark),
        'color': paletteFor(dark),
      },
      'light': <String, Object?>{
        'typography': typographyFor(light),
        'color': paletteFor(light),
      },
    };
  }

  /// Light variant — surface/text inverted only. Accent / status colors
  /// unchanged.
  static ThemeData get light => _build(_lightScheme());

  static ColorScheme _darkScheme() {
    final c = VbuTokens.color;
    return ColorScheme.dark(
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
  }

  static ColorScheme _lightScheme() {
    final c = VbuTokens.color;
    // Inverts surfaces / text. Accents stay so badges keep their meaning.
    return ColorScheme.light(
      brightness: Brightness.light,
      primary: c.mint,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFD8F2EC),
      onPrimaryContainer: const Color(0xFF14342D),
      secondary: c.violet,
      onSecondary: Colors.white,
      tertiary: c.amber,
      onTertiary: const Color(0xFF3B2A0F),
      error: c.coral,
      onError: Colors.white,
      surface: const Color(0xFFFAFBFC),
      onSurface: const Color(0xFF14181F),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFF6F7F9),
      surfaceContainer: const Color(0xFFEFF1F4),
      surfaceContainerHigh: const Color(0xFFE6E9EE),
      surfaceContainerHighest: const Color(0xFFDADFE6),
      onSurfaceVariant: const Color(0xFF505868),
      outline: const Color(0xFFC4CAD3),
      outlineVariant: const Color(0xFFE0E4EA),
      shadow: Colors.transparent,
      scrim: Colors.black54,
    );
  }

  static ThemeData _build(ColorScheme scheme) {
    final isDark = scheme.brightness == Brightness.dark;
    final c = VbuTokens.color;
    final textPrimary = isDark ? c.textPrimary : scheme.onSurface;
    final textSecondary = isDark ? c.textSecondary : scheme.onSurfaceVariant;
    final textTertiary = isDark ? c.textTertiary : const Color(0xFF7A8290);
    final borderDefault = scheme.outline;
    final borderStrong = isDark ? c.borderStrong : const Color(0xFFA9B0BB);
    final surface2 = isDark ? c.surface2 : scheme.surfaceContainer;
    final surface3 = isDark ? c.surface3 : scheme.surfaceContainerHigh;
    final elevated = isDark ? c.elevated : scheme.surfaceContainerHigh;

    final base = ThemeData(
      useMaterial3: true,
      brightness: scheme.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: isDark ? c.bg : scheme.surface,
      canvasColor: isDark ? c.bg : scheme.surface,
      textTheme: GoogleFonts.interTextTheme(),
      visualDensity: VisualDensity.compact,
      splashFactory: NoSplash.splashFactory,
    );

    return base.copyWith(
      textTheme: _textTheme(textPrimary, textSecondary, textTertiary),
      iconTheme: IconThemeData(color: textSecondary, size: 16),
      dividerTheme: DividerThemeData(
        color: borderDefault,
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
            borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          side: BorderSide(color: borderStrong),
          textStyle: GoogleFonts.inter(
            fontWeight: FontWeight.w500,
            fontSize: 13,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: textSecondary,
          textStyle: GoogleFonts.inter(
            fontWeight: FontWeight.w500,
            fontSize: 13,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface2,
        hoverColor: surface3,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        hintStyle: TextStyle(color: textTertiary, fontSize: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
          borderSide: BorderSide(color: borderDefault),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
          borderSide: BorderSide(color: borderDefault),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
          borderSide: BorderSide(color: c.mint, width: 1.5),
        ),
      ),
      cardTheme: CardThemeData(
        color: surface2,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VbuTokens.radiusLg),
          side: BorderSide(color: borderDefault),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: elevated,
          borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
          border: Border.all(color: borderStrong),
        ),
        textStyle: GoogleFonts.inter(fontSize: 11, color: textPrimary),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(borderStrong),
        thickness: WidgetStateProperty.all(6),
        radius: const Radius.circular(3),
      ),
    );
  }

  static TextTheme _textTheme(Color primary, Color secondary, Color tertiary) {
    TextStyle sans({
      double size = 13,
      FontWeight weight = FontWeight.w400,
      Color? color,
      double? height,
      double? letterSpacing,
    }) => GoogleFonts.inter(
      fontSize: size,
      fontWeight: weight,
      color: color ?? primary,
      height: height,
      letterSpacing: letterSpacing,
    );

    return TextTheme(
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
      headlineLarge: sans(size: 18, weight: FontWeight.w600),
      headlineMedium: sans(size: 16, weight: FontWeight.w600),
      headlineSmall: sans(size: 14, weight: FontWeight.w600),
      titleLarge: sans(size: 14, weight: FontWeight.w600),
      titleMedium: sans(size: 13, weight: FontWeight.w500),
      titleSmall: sans(size: 12, weight: FontWeight.w500, color: secondary),
      bodyLarge: sans(size: 14, weight: FontWeight.w400, height: 1.5),
      bodyMedium: sans(size: 13, weight: FontWeight.w400, height: 1.5),
      bodySmall: sans(
        size: 12,
        weight: FontWeight.w400,
        height: 1.5,
        color: secondary,
      ),
      labelLarge: sans(size: 13, weight: FontWeight.w500),
      labelMedium: sans(size: 12, weight: FontWeight.w500, color: secondary),
      labelSmall: sans(
        size: 11,
        weight: FontWeight.w500,
        letterSpacing: 0.04 * 11,
        color: tertiary,
      ),
    );
  }
}

/// Mono text style — for code, IDs, paths. 1:1 with vibe's `vibeMono`.
TextStyle vbuMono({
  double size = 12,
  FontWeight weight = FontWeight.w400,
  Color? color,
}) => GoogleFonts.jetBrainsMono(
  fontSize: size,
  fontWeight: weight,
  color: color,
  height: 1.5,
);
