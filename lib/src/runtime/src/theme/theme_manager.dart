import 'package:flutter/material.dart';
import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart';

import '../state/state_manager.dart';
import 'theme_builder.dart';

/// Theme manager for MCP UI DSL 1.3 — `specs/mcp_ui_dsl/05_Theme.md`.
///
/// Holds a strongly-typed [ThemeDefinition] (M3 14-domain — color, typography,
/// spacing, shape, elevation, motion, density, breakpoints, border, opacity,
/// focusRing, zIndex, component) plus its serialized JSON form for path-based
/// resolution of `{{theme.*}}` bindings.
///
/// Mode resolution: `light` / `dark` / `system`. In `system` mode the active
/// scheme follows host brightness (an embedder may inject an override via
/// [setHostBrightness] — useful when an outer launcher wants its own light/
/// dark choice to win over a server app declaring `mode: 'system'`).
class ThemeManager with ChangeNotifier {
  static final ThemeManager _instance = ThemeManager._internal();
  factory ThemeManager() => _instance;
  static ThemeManager get instance => _instance;

  ThemeManager._internal();

  /// Active strongly-typed theme definition.
  ThemeDefinition _definition = ThemeDefinition.defaultLight();

  /// Cached JSON projection of [_definition] for `{{theme.*}}` path traversal.
  Map<String, dynamic> _themeData = ThemeDefinition.defaultLight().toJson();

  /// Theme mode (`light` / `dark` / `system`). Default: `system`.
  String _themeMode = 'system';

  /// Optional state manager — `theme.mode` state override wins over the
  /// declared definition value.
  StateManager? _stateManager;

  /// Host-injected brightness override used to resolve `mode: 'system'`.
  Brightness? _hostBrightnessOverride;

  /// `true` once a bundle has supplied a theme via [setTheme] or
  /// [setThemeDefinition]. Distinguishes "bundle declared common-level
  /// colors but no mode-specific variant" (use `_definition` for the
  /// missing mode) from "bundle declared no theme at all" (use the M3
  /// default for that mode so the system toggle still produces a
  /// proper dark scheme).
  bool _isCustomized = false;

  /// Cached derived [ColorScheme] for each brightness, populated lazily
  /// in [_ensureColorScheme]. Used by [getColorValue] to fall back to a
  /// fromSeed-derived M3 28-role palette when a slot is absent from the
  /// bundle's raw `theme.color` map (spec §5.3 — bundles may declare
  /// only `seed` and a few overrides; the missing roles must derive).
  /// Invalidated on every [setThemeDefinition] / [resetTheme] / [reset]
  /// / [applyOverride] restore so the cache never out-runs the active
  /// definition.
  ColorScheme? _lightSchemeCache;
  ColorScheme? _darkSchemeCache;

  /// Currently active strongly-typed theme.
  ThemeDefinition get definition => _definition;

  /// JSON projection of the active theme (for binding resolution).
  Map<String, dynamic> get theme => _themeData;

  /// Declared theme mode (`light` / `dark` / `system`).
  String get themeMode => _themeMode;

  /// Spec alias.
  String get currentMode => _themeMode;

  /// Effective mode after resolving `system` against host brightness.
  String get effectiveMode => _resolveEffectiveMode();

  /// Flutter [ThemeMode] equivalent for routing into `MaterialApp`.
  /// Honours a `theme.mode` state override (spec §5.2).
  ///
  /// `mode: 'system'` resolves against the embedder's brightness override
  /// (`setHostBrightness`) when present — AppPlayer-class hosts are
  /// themselves "the system" for embedded bundles, so launcher light/dark
  /// toggles propagate. Without an override, falls back to OS platform
  /// brightness via [ThemeMode.system].
  ThemeMode get flutterThemeMode {
    // Host brightness override wins unconditionally — kept in lockstep
    // with [_resolveEffectiveMode]. Without this the two paths
    // dissonate: `getColorValue` / `fingerprint` would honour the host
    // pin (e.g. light) while `MaterialApp.themeMode` would still pick
    // the bundle's declared dark — so `theme.color.onSurface` resolved
    // to one brightness but the ambient ColorScheme came from the other,
    // producing the "ambient onSurface flips between frames" race
    // visible to the user as tab-cycle text-colour drift in dark mode.
    if (_hostBrightnessOverride != null) {
      return _hostBrightnessOverride == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light;
    }
    final resolved = (getThemeValue('mode') as String?) ?? _themeMode;
    switch (resolved) {
      case 'dark':
        return ThemeMode.dark;
      case 'light':
        return ThemeMode.light;
      case 'system':
        return ThemeMode.system;
      default:
        return ThemeMode.system;
    }
  }

  /// Convert active definition into Flutter [ThemeData] for the active mode.
  ThemeData get currentTheme => toFlutterTheme();

  /// Short fingerprint of the active ThemeManager state. Includes the
  /// identity of `_themeData` (changes when a mutator swaps the active
  /// definition), the declared `_themeMode`, the host brightness
  /// override, and the resolved effective mode at call time.
  ///
  /// Used by the Renderer's cache key (`_extractCacheableContext`) so a
  /// cached `text` / `box` / etc. widget — built with a `Color` baked in
  /// at first render — is invalidated when the active brightness or any
  /// token (typography / shape / color slots) changes. Without this, a
  /// widget cached in light mode survives a mode swap and renders the
  /// old colour on re-mount.
  ///
  /// Cheap: identity hash + a few scalar fields concatenated, no JSON
  /// encoding. Mutators that swap `_themeData` produce a fresh map ref,
  /// so the identity hash changes automatically.
  String get fingerprint {
    final brightness = _resolveEffectiveMode();
    return '${identityHashCode(_themeData)}'
        '|$_themeMode'
        '|${_hostBrightnessOverride?.index ?? -1}'
        '|$brightness';
  }

  // ---------------------------------------------------------------------------
  // Mutators
  // ---------------------------------------------------------------------------

  /// Set the theme from a JSON map (1.3 — 14 domains).
  void setTheme(Map<String, dynamic> theme) {
    final def = ThemeDefinition.fromJson(theme);
    setThemeDefinition(def);
  }

  /// Set the theme from a strongly-typed [ThemeDefinition].
  void setThemeDefinition(ThemeDefinition definition) {
    _definition = definition;
    _themeData = definition.toJson();
    if (definition.mode != _themeMode) {
      _themeMode = _validateMode(definition.mode);
    }
    _isCustomized = true;
    _invalidateSchemeCache();
    notifyListeners();
  }

  /// Set the theme mode (`light` / `dark` / `system`).
  void setThemeMode(String mode) {
    final validated = _validateMode(mode);
    if (_themeMode == validated) return;
    _themeMode = validated;
    notifyListeners();
  }

  /// Spec alias.
  void setMode(String mode) => setThemeMode(mode);

  /// Inject host brightness override. Wins unconditionally — see
  /// [_resolveEffectiveMode]. Pass `null` to clear and fall back to
  /// either the declared `_themeMode` or the platform brightness when
  /// `_themeMode == 'system'`.
  void setHostBrightness(Brightness? brightness) {
    if (_hostBrightnessOverride == brightness) return;
    _hostBrightnessOverride = brightness;
    // Always notify — the override now affects the resolved mode
    // unconditionally (not just when `_themeMode == 'system'`).
    notifyListeners();
  }

  /// Hook invoked when the OS platform brightness toggles. Only meaningful
  /// when no host override is active and `mode: 'system'` is declared.
  void notifyBrightnessChanged() {
    if (_themeMode != 'system' || _hostBrightnessOverride != null) return;
    notifyListeners();
  }

  /// Wire the state manager so `theme.mode` state overrides the declared mode.
  void setStateManager(StateManager stateManager) {
    _stateManager = stateManager;
  }

  /// Reset to defaults.
  void resetTheme() {
    _definition = ThemeDefinition.defaultLight();
    _themeData = _definition.toJson();
    _themeMode = 'system';
    _isCustomized = false;
    _invalidateSchemeCache();
    notifyListeners();
  }

  /// Test-only reset.
  void reset() {
    _definition = ThemeDefinition.defaultLight();
    _themeData = _definition.toJson();
    _themeMode = 'system';
    _hostBrightnessOverride = null;
    _stateManager = null;
    _isCustomized = false;
    _invalidateSchemeCache();
  }

  /// Apply a page-level override (spec §5.7 — deep merge) and return a
  /// restore callback.
  VoidCallback applyOverride(Map<String, dynamic> override) {
    final previousDef = _definition;
    final previousData = Map<String, dynamic>.from(_themeData);
    final previousMode = _themeMode;

    final merged = _deepMerge(_themeData, override);
    final mergedDef = ThemeDefinition.fromJson(merged);
    setThemeDefinition(mergedDef);

    return () {
      _definition = previousDef;
      _themeData = previousData;
      _themeMode = previousMode;
      _invalidateSchemeCache();
      notifyListeners();
    };
  }

  // ---------------------------------------------------------------------------
  // Bindings (spec §5.6)
  // ---------------------------------------------------------------------------

  /// Resolve a value via dotted path — e.g. `color.primary`,
  /// `typography.bodyLarge.fontSize`, `spacing.md`, `shape.medium.uniform`,
  /// `elevation.level3.shadow`, `motion.duration.medium2`.
  ///
  /// Spec §5.6 — bindings resolve against the active mode's effective
  /// definition. `theme.mode` is special: state-manager overrides win.
  dynamic getThemeValue(String path) {
    if (path == 'mode') {
      if (_stateManager != null) {
        final stateMode = _stateManager!.get<String>('theme.mode');
        if (stateMode != null &&
            const ['light', 'dark', 'system'].contains(stateMode)) {
          return stateMode;
        }
      }
      return _themeMode;
    }

    if (_stateManager != null) {
      final stateValue = _stateManager!.get<dynamic>('theme.$path');
      if (stateValue != null) return stateValue;
    }

    // Spec §5.7 — mode-specific override (`theme.light` / `theme.dark`)
    // wins over the base section for the active mode. Resolve the path
    // against the override first; on miss, fall back to the base.
    final mode = _resolveEffectiveMode();
    final override = _themeData[mode];
    if (override is Map<String, dynamic>) {
      final hit = _resolvePath(override, path);
      if (hit != null) return hit;
    }
    return _resolvePath(_themeData, path);
  }

  /// Spec alias.
  dynamic resolveThemeValue(String path) => getThemeValue(path);

  // ---------------------------------------------------------------------------
  // Convenience accessors (typed)
  // ---------------------------------------------------------------------------

  /// Returns the hex string for an M3 28-role color slot
  /// (e.g. `primary` / `surfaceContainer`).
  String? getColor(String slot) => getThemeValue('color.$slot') as String?;

  /// Resolved [Color] for a color slot.
  ///
  /// Resolution order (spec §5.3):
  ///   1. Bundle-declared raw value at `theme.color.<slot>` (mode override
  ///      first, then base) — preserves explicit author intent.
  ///   2. fromSeed-derived M3 28-role palette for the active brightness —
  ///      fills the roles a bundle did not enumerate. M3 lets a bundle
  ///      declare only `seed` and a handful of overrides; the missing
  ///      roles must derive, not return null.
  ///
  /// Semantic slots (`success` / `warning` / `info` and their `on*`
  /// counterparts) are not part of Flutter's [ColorScheme], so the
  /// fallback path returns null for those — callers must declare them
  /// in the bundle if needed.
  Color? getColorValue(String slot) {
    final raw = _parseColor(getColor(slot));
    if (raw != null) return raw;
    final scheme = _ensureColorScheme(_resolveEffectiveMode() == 'dark');
    return _colorFromScheme(scheme, slot);
  }

  /// Raw text-style map for an M3 typography role
  /// (e.g. `bodyLarge` / `titleMedium`).
  Map<String, dynamic>? getTextStyle(String role) =>
      getThemeValue('typography.$role') as Map<String, dynamic>?;

  /// Resolved [TextStyle] for an M3 typography role.
  TextStyle? getTextStyleValue(String role) =>
      _buildTextStyle(getTextStyle(role));

  /// Spacing token (`xxs`/`xs`/`sm`/`md`/`lg`/`xl`/`2xl`/`3xl`/`4xl`).
  num? getSpacing(String key) => getThemeValue('spacing.$key') as num?;
  double? getSpacingValue(String key) => getSpacing(key)?.toDouble();

  /// Shape token uniform corner radius
  /// (`none`/`extraSmall`/`small`/`medium`/`large`/`extraLarge`/`full`).
  num? getShape(String key) {
    final v = getThemeValue('shape.$key');
    if (v is num) return v;
    if (v is Map && v['uniform'] is num) return v['uniform'] as num;
    return null;
  }

  double? getShapeValue(String key) => getShape(key)?.toDouble();

  /// Elevation level shadow value (`level0`..`level5`).
  num? getElevation(String key) {
    final v = getThemeValue('elevation.$key');
    if (v is num) return v;
    if (v is Map && v['shadow'] is num) return v['shadow'] as num;
    return null;
  }

  double? getElevationValue(String key) => getElevation(key)?.toDouble();

  // ---------------------------------------------------------------------------
  // Flutter ThemeData
  // ---------------------------------------------------------------------------

  ThemeData toFlutterTheme({bool? isDark}) {
    final dark = isDark ?? (_resolveEffectiveMode() == 'dark');
    // Resolution order:
    //   1. mode-specific variant (`_definition.dark` / `_definition.light`)
    //   2. customised common definition (bundle declared common-level
    //      colors but no variant) — preserve the bundle's intent
    //   3. M3 default for that mode (bundle declared no theme at all) so
    //      `darkTheme` is a proper dark scheme rather than the light
    //      definition re-tagged.
    final modeDef = _modeSpecific(dark) ??
        (_isCustomized
            ? _definition
            : (dark
                ? ThemeDefinition.defaultDark()
                : ThemeDefinition.defaultLight()));
    return McpUiThemeBuilder.build(modeDef, isDark: dark);
  }

  /// Spec alias.
  ThemeData toFlutterThemeData({bool? isDark}) =>
      toFlutterTheme(isDark: isDark);

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  ThemeDefinition? _modeSpecific(bool dark) {
    if (dark) {
      return _definition.dark != null
          ? _definition.merge(_definition.dark!)
          : null;
    }
    return _definition.light != null
        ? _definition.merge(_definition.light!)
        : null;
  }

  /// Lazily build (and cache) the derived M3 [ColorScheme] for the
  /// requested brightness. Cache invalidation is the responsibility of
  /// any mutator that changes `_definition` / `_themeData`.
  ColorScheme _ensureColorScheme(bool dark) {
    final cached = dark ? _darkSchemeCache : _lightSchemeCache;
    if (cached != null) return cached;
    final modeDef = _modeSpecific(dark) ??
        (_isCustomized
            ? _definition
            : (dark
                ? ThemeDefinition.defaultDark()
                : ThemeDefinition.defaultLight()));
    final scheme = McpUiThemeBuilder.build(modeDef, isDark: dark).colorScheme;
    if (dark) {
      _darkSchemeCache = scheme;
    } else {
      _lightSchemeCache = scheme;
    }
    return scheme;
  }

  void _invalidateSchemeCache() {
    _lightSchemeCache = null;
    _darkSchemeCache = null;
  }

  /// Map an M3 28-role slot name to the corresponding [ColorScheme]
  /// field. Returns null for slots Flutter does not represent
  /// (`success` / `warning` / `info` and their `on*` variants).
  static Color? _colorFromScheme(ColorScheme s, String slot) {
    switch (slot) {
      case 'primary':
        return s.primary;
      case 'onPrimary':
        return s.onPrimary;
      case 'primaryContainer':
        return s.primaryContainer;
      case 'onPrimaryContainer':
        return s.onPrimaryContainer;
      case 'secondary':
        return s.secondary;
      case 'onSecondary':
        return s.onSecondary;
      case 'secondaryContainer':
        return s.secondaryContainer;
      case 'onSecondaryContainer':
        return s.onSecondaryContainer;
      case 'tertiary':
        return s.tertiary;
      case 'onTertiary':
        return s.onTertiary;
      case 'tertiaryContainer':
        return s.tertiaryContainer;
      case 'onTertiaryContainer':
        return s.onTertiaryContainer;
      case 'error':
        return s.error;
      case 'onError':
        return s.onError;
      case 'errorContainer':
        return s.errorContainer;
      case 'onErrorContainer':
        return s.onErrorContainer;
      case 'surface':
        return s.surface;
      case 'onSurface':
        return s.onSurface;
      case 'onSurfaceVariant':
        return s.onSurfaceVariant;
      case 'surfaceTint':
        return s.surfaceTint;
      case 'surfaceBright':
        return s.surfaceBright;
      case 'surfaceDim':
        return s.surfaceDim;
      case 'surfaceContainerLowest':
        return s.surfaceContainerLowest;
      case 'surfaceContainerLow':
        return s.surfaceContainerLow;
      case 'surfaceContainer':
        return s.surfaceContainer;
      case 'surfaceContainerHigh':
        return s.surfaceContainerHigh;
      case 'surfaceContainerHighest':
        return s.surfaceContainerHighest;
      case 'outline':
        return s.outline;
      case 'outlineVariant':
        return s.outlineVariant;
      case 'inverseSurface':
        return s.inverseSurface;
      case 'onInverseSurface':
        return s.onInverseSurface;
      case 'inversePrimary':
        return s.inversePrimary;
      case 'scrim':
        return s.scrim;
      case 'shadow':
        return s.shadow;
    }
    return null;
  }

  String _resolveEffectiveMode() {
    // Host brightness override wins unconditionally when set. AppPlayer-
    // class hosts are themselves "the system" for embedded bundles —
    // when the host chrome explicitly pins a brightness (settings
    // toggle, preview pane mode pin) the bundle MUST follow even if it
    // declared an explicit `theme.mode`. Earlier this gate only fired
    // for `_themeMode == 'system'`, which meant a bundle that hard-set
    // `mode: 'dark'` ignored the host's light/dark toggle entirely and
    // — worse — the toggle's effect depended on race-timing between
    // `setTheme(appDef.theme)` and `setHostBrightness` (intermittent
    // mid-frame rebuild capturing whichever state landed first).
    if (_hostBrightnessOverride != null) {
      return _hostBrightnessOverride == Brightness.dark ? 'dark' : 'light';
    }
    if (_themeMode == 'system') {
      return WidgetsBinding.instance.platformDispatcher.platformBrightness ==
              Brightness.dark
          ? 'dark'
          : 'light';
    }
    return _themeMode;
  }

  String _validateMode(String mode) {
    if (!const ['light', 'dark', 'system'].contains(mode)) {
      throw ArgumentError(
          'Invalid theme mode: $mode. Use "light", "dark", or "system".');
    }
    return mode;
  }

  static dynamic _resolvePath(Map<String, dynamic> root, String path) {
    final parts = path.split('.');
    dynamic current = root;
    for (final part in parts) {
      if (current is Map && current.containsKey(part)) {
        current = current[part];
      } else {
        return null;
      }
    }
    return current;
  }

  TextStyle? _buildTextStyle(dynamic data) {
    if (data is! Map<String, dynamic>) return null;
    final size = (data['fontSize'] as num?)?.toDouble();
    final lineH = (data['lineHeight'] as num?)?.toDouble();
    return TextStyle(
      fontSize: size,
      fontWeight: _parseFontWeight(data['fontWeight']),
      letterSpacing: (data['letterSpacing'] as num?)?.toDouble(),
      height: (size != null && lineH != null && size > 0)
          ? lineH / size
          : null,
    );
  }

  Color? _parseColor(dynamic value) {
    if (value is! String) return null;
    final v = value.trim();
    if (v.startsWith('#')) {
      final hex = v.substring(1);
      if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
      if (hex.length == 8) return Color(int.parse(hex, radix: 16));
      return null;
    }
    if (v.startsWith('rgb(') || v.startsWith('rgba(')) {
      final inside =
          v.substring(v.indexOf('(') + 1, v.indexOf(')')).split(',');
      if (inside.length < 3) return null;
      final r = int.tryParse(inside[0].trim());
      final g = int.tryParse(inside[1].trim());
      final b = int.tryParse(inside[2].trim());
      if (r == null || g == null || b == null) return null;
      final a = inside.length == 4
          ? ((double.tryParse(inside[3].trim()) ?? 1.0) * 255).round()
          : 255;
      return Color.fromARGB(a, r, g, b);
    }
    return null;
  }

  FontWeight? _parseFontWeight(dynamic value) {
    if (value is num) {
      final w = value.toInt();
      return FontWeight.values.firstWhere(
        (fw) => fw.value == ((w ~/ 100) * 100).clamp(100, 900),
        orElse: () => FontWeight.w400,
      );
    }
    if (value is! String) return null;
    switch (value) {
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

  static Map<String, dynamic> _deepMerge(
    Map<String, dynamic> base,
    Map<String, dynamic> override,
  ) {
    final result = Map<String, dynamic>.from(base);
    override.forEach((key, value) {
      if (value is Map<String, dynamic> && result[key] is Map) {
        result[key] = _deepMerge(
          Map<String, dynamic>.from(result[key] as Map),
          value,
        );
      } else {
        result[key] = value;
      }
    });
    return result;
  }
}
