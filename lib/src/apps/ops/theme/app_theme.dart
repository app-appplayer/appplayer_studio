// makemind Ops — Flutter ThemeData builder
// Material 3, dark-first. Mirrors ops_design.html.

import 'package:flutter/material.dart';

import 'tokens.dart';

ThemeData buildOpsTheme({Brightness brightness = Brightness.dark}) {
  final isDark = brightness == Brightness.dark;

  // Palette swap
  final bg = isDark ? OpsColors.bg : OpsColorsLight.bg;
  final surface = isDark ? OpsColors.surface : OpsColorsLight.surface;
  final surface2 = isDark ? OpsColors.surface2 : OpsColorsLight.surface2;
  final border = isDark ? OpsColors.border : OpsColorsLight.border;
  final borderStrong =
      isDark ? OpsColors.borderStrong : OpsColorsLight.borderStrong;
  final text = isDark ? OpsColors.text : OpsColorsLight.text;
  final text2 = isDark ? OpsColors.text2 : OpsColorsLight.text2;
  final text3 = isDark ? OpsColors.text3 : OpsColorsLight.text3;
  final accent = isDark ? OpsColors.accent : OpsColorsLight.accent;

  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: accent,
    onPrimary: Colors.white,
    secondary: OpsColors.knowledge,
    onSecondary: Colors.white,
    error: OpsColors.danger,
    onError: Colors.white,
    surface: surface,
    // Tone hierarchy is matched to the home page's row tones:
    // titles inherit `onSurface` (text2 muted) and meta lines inherit
    // `onSurfaceVariant` (text3 darker mono). Custom widgets keep using
    // explicit OpsColors tokens so they're unaffected.
    onSurface: text2,
    onSurfaceVariant: text3,
    // Map all M3 surface containers to the canonical dark `surface` so
    // Material widgets (Card, Drawer, etc.) that default to a higher
    // container slot render at the same tone as our custom OpsCard.
    // surface2 stays for hover/selected states only via direct token use.
    surfaceContainerLowest: bg,
    surfaceContainerLow: surface,
    surfaceContainer: surface,
    surfaceContainerHigh: surface,
    surfaceContainerHighest: surface,
    outline: borderStrong,
    outlineVariant: border,
  );

  TextStyle t(
    double size,
    FontWeight w, {
    Color? color,
    double letter = 0,
    String family = OpsType.sans,
    double height = 1.45,
  }) => TextStyle(
    fontFamily: family,
    fontSize: size,
    fontWeight: w,
    color: color ?? text,
    letterSpacing: letter,
    height: height,
  );

  final textTheme = TextTheme(
    // Display / hero
    displayLarge: t(
      OpsType.display,
      OpsType.bold,
      letter: OpsType.tight,
      height: 1.2,
    ),
    displayMedium: t(
      OpsType.xxxl,
      OpsType.bold,
      letter: OpsType.snug,
      height: 1.2,
    ),
    displaySmall: t(
      OpsType.xxl,
      OpsType.bold,
      letter: OpsType.snug,
      height: 1.25,
    ),

    // Section titles
    titleLarge: t(OpsType.xl, OpsType.semibold, letter: OpsType.snug),
    titleMedium: t(OpsType.lg, OpsType.semibold),
    titleSmall: t(OpsType.md, OpsType.semibold),

    // Body
    bodyLarge: t(OpsType.lg, OpsType.regular, height: 1.5),
    bodyMedium: t(OpsType.md, OpsType.regular, color: text2, height: 1.5),
    bodySmall: t(OpsType.sm, OpsType.regular, color: text3, height: 1.5),

    // Labels & monospace tags
    labelLarge: t(OpsType.md, OpsType.medium),
    labelMedium: t(OpsType.sm, OpsType.medium, color: text2),
    labelSmall: t(
      OpsType.xs,
      OpsType.semibold,
      color: text3,
      letter: OpsType.mono06,
      family: OpsType.mono,
    ),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: bg,
    canvasColor: bg,
    dividerColor: border,
    fontFamily: OpsType.sans,
    textTheme: textTheme,

    cardTheme: CardThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: OpsRadius.all_md,
        side: BorderSide(color: border),
      ),
      margin: EdgeInsets.zero,
    ),

    appBarTheme: AppBarTheme(
      backgroundColor: surface,
      foregroundColor: text,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(bottom: BorderSide(color: border)),
      titleTextStyle: t(OpsType.lg, OpsType.semibold),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        textStyle: const TextStyle(
          fontFamily: OpsType.sans,
          fontSize: OpsType.md,
          fontWeight: OpsType.medium,
          height: 1.0,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: const RoundedRectangleBorder(borderRadius: OpsRadius.all_sm),
        minimumSize: const Size(0, 32),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: text,
        side: BorderSide(color: borderStrong),
        textStyle: const TextStyle(
          fontFamily: OpsType.sans,
          fontSize: OpsType.md,
          fontWeight: OpsType.medium,
          height: 1.0,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: const RoundedRectangleBorder(borderRadius: OpsRadius.all_sm),
        minimumSize: const Size(0, 32),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: text2,
        textStyle: const TextStyle(
          fontFamily: OpsType.sans,
          fontSize: OpsType.md,
          fontWeight: OpsType.medium,
          height: 1.0,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        shape: const RoundedRectangleBorder(borderRadius: OpsRadius.all_sm),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      hintStyle: TextStyle(color: text3, fontSize: OpsType.md),
      border: OutlineInputBorder(
        borderRadius: OpsRadius.all_sm,
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: OpsRadius.all_sm,
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: OpsRadius.all_sm,
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
    ),

    dividerTheme: DividerThemeData(color: border, space: 1, thickness: 1),
    iconTheme: IconThemeData(color: text2, size: 16),

    // Explicit colors required: Flutter's ListTile merges its defaults
    // (bodyLarge / bodyMedium with their own color) into our styles, so
    // a null color slot here lets the default white text leak through.
    // Set both colors directly + leave [textColor] unset so title and
    // subtitle stay in different tones.
    listTileTheme: ListTileThemeData(
      iconColor: text2,
      titleTextStyle: TextStyle(
        fontFamily: OpsType.sans,
        fontSize: OpsType.lg,
        fontWeight: OpsType.semibold,
        height: 1.45,
        color: text2,
      ),
      subtitleTextStyle: TextStyle(
        fontFamily: OpsType.mono,
        fontSize: OpsType.sm,
        height: 1.5,
        color: text3,
      ),
    ),

    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black.withValues(alpha: 0.4),
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: OpsRadius.all_md,
        side: BorderSide(color: border),
      ),
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      textStyle: TextStyle(
        fontFamily: OpsType.sans,
        fontSize: OpsType.md,
        color: text,
        height: 1.2,
      ),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        return TextStyle(
          fontFamily: OpsType.sans,
          fontSize: OpsType.md,
          color: states.contains(WidgetState.disabled) ? text3 : text,
          height: 1.2,
        );
      }),
    ),

    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: OpsRadius.all_md,
            side: BorderSide(color: border),
          ),
        ),
        elevation: const WidgetStatePropertyAll(6),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 4),
        ),
      ),
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: surface2,
        borderRadius: OpsRadius.all_sm,
        border: Border.all(color: border),
      ),
      textStyle: TextStyle(
        color: text,
        fontSize: OpsType.sm,
        fontFamily: OpsType.mono,
      ),
    ),

    visualDensity: VisualDensity.compact,
  );
}

/// Status pill styling — used by NodeRow / ProcessListItem / activity feed.
class OpsStatus {
  final Color bg;
  final Color fg;
  const OpsStatus(this.bg, this.fg);

  static final ok = OpsStatus(Color(0x2E4FBE91), OpsColors.success);
  static final running = OpsStatus(Color(0x385E8FFA), OpsColors.protocol);
  static final gate = OpsStatus(Color(0x42E5B04A), OpsColors.warn);
  static final queued = OpsStatus(OpsColors.surface2, OpsColors.text2);
  static final error = OpsStatus(Color(0x42E26A6A), OpsColors.danger);
}
