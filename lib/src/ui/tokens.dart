// ============================================================================
// vibe_studio_ui — design tokens
// Extracted from vibe's VibeTokens (domain tokens excluded).
// ============================================================================

import 'package:flutter/material.dart';

/// All makemind design tokens. Use via [VbuTokens.color], [VbuTokens.space], etc.
abstract final class VbuTokens {
  // ───────── Colors ─────────
  /// Dark palette — the default. Preserved for call sites that don't
  /// have a [BuildContext] handy (theme builders, top-level constants).
  /// Brightness-aware sites should use [colorOf] instead.
  static const color = _DarkColors();

  /// Light variant palette — explicit accessor for non-context call
  /// sites (e.g. JSON theme builders). [colorOf] picks this vs [color]
  /// based on the active Theme brightness.
  static const lightColor = _LightColors();

  /// Brightness-aware palette accessor. Resolves to [lightColor] when
  /// `Theme.of(context).brightness == Brightness.light`, otherwise
  /// [color]. vbu_* atoms call this so the studio chrome and the
  /// preview canvases both follow the active Theme brightness.
  static VbuPalette colorOf(BuildContext context) {
    return Theme.of(context).brightness == Brightness.light
        ? lightColor
        : color;
  }

  static const status = _StatusColors();

  /// 8-layer palette (App / Theme / Component / Dashboard / Navigation /
  /// Page / Assets / Whole) — identical across light/dark. Available
  /// both as static accessors and through [VbuPalette.layerXxx].
  static const layer = _LayerColors();

  /// Track palette — separates host-driven MCP signals (blue) from
  /// self-emitted runtime signals (amber). Used by debug overlays /
  /// status pills that surface where a state change came from.
  static const track = _TrackColors();

  // ───────── Typography ─────────
  static const fontMono = 'JetBrainsMono';
  static const fontSans = 'Inter';
  static const fontSerif = 'Fraunces';

  // ───────── Spacing (4px base) ─────────
  static const space0 = 0.0;
  static const space1 = 4.0;
  static const space2 = 8.0;
  static const space3 = 12.0;
  static const space4 = 16.0;
  static const space5 = 20.0;
  static const space6 = 24.0;
  static const space8 = 32.0;
  static const space10 = 40.0;
  static const space12 = 48.0;
  static const space16 = 64.0;

  // ───────── Radius ─────────
  static const radiusNone = 0.0;
  static const radiusSm = 4.0;
  static const radiusMd = 6.0;
  static const radiusLg = 10.0;
  static const radiusXl = 14.0;
  static const radiusFull = 999.0;

  // ───────── Border ─────────
  static const borderThin = 1.0;
  static const borderThick = 2.0;

  // ───────── Motion ─────────
  static const durInstant = Duration(milliseconds: 80);
  static const durFast = Duration(milliseconds: 160);
  static const durBase = Duration(milliseconds: 240);
  static const durSlow = Duration(milliseconds: 400);

  static const easeStandard = Cubic(0.2, 0, 0, 1);
  static const easeDecelerate = Cubic(0, 0, 0, 1);
  static const easeAccelerate = Cubic(0.3, 0, 1, 1);

  // ───────── Layout (builder convention) ─────────
  static const titlebarHeight = 28.0;
  static const statusbarHeight = 24.0;
  static const sideColumnWidth = 320.0;

  /// Legacy aliases for [sideColumnWidth] preserved for the chrome
  /// (chat panel) and the properties pane (props panel) — both
  /// historically 320 and pinned to the same value.
  static const chatPanelWidth = sideColumnWidth;
  static const propsPanelWidth = sideColumnWidth;
  static const stripHeight = 96.0;
  static const stripCardWidth = 168.0;
  static const stripCardGap = 12.0;
  static const panelPadding = 16.0;
}

/// Surface · text · accent palette contract. Two concrete implementations
/// ([_DarkColors] / [_LightColors]) supply the actual hex values per
/// brightness. vbu_* atoms read through [VbuTokens.colorOf] so the
/// active Theme drives which palette they see.
abstract class VbuPalette {
  const VbuPalette();

  // Surfaces (darkest → lightest)
  Color get bg;
  Color get surface;
  Color get surface2;
  Color get surface3;
  Color get elevated;

  // Borders
  Color get borderSubtle;
  Color get borderDefault;
  Color get borderStrong;

  // Text
  Color get textPrimary;
  Color get textSecondary;
  Color get textTertiary;
  Color get textMuted;

  // Accents — brand colors, identical across light/dark.
  Color get mint => const Color(0xFF7DD3C0);
  Color get mintDim => const Color(0xFF4A8478);
  Color get amber => const Color(0xFFE9B873);
  Color get violet => const Color(0xFF9B87F5);
  Color get blue => const Color(0xFF5FA8FF);
  Color get pink => const Color(0xFFE58FB7);
  Color get coral => const Color(0xFFE78A7A);

  // Layer colors — 8-layer model (App Builder catalog Part D).
  // Identical across brightness.
  Color get layerApp => const Color(0xFF5FA8FF);
  Color get layerTheme => const Color(0xFFE58FB7);
  Color get layerComponent => const Color(0xFF7DD3C0);
  Color get layerDashboard => const Color(0xFFE9B873);
  Color get layerNavigation => const Color(0xFF6BC8D8);
  Color get layerPage => const Color(0xFF9B87F5);
  Color get layerAssets => const Color(0xFF7AB87E);
  Color get layerWhole => const Color(0xFFC8B9A0);
}

/// Dark palette — 1:1 with vibe's `VbuPalette`. Default for studio chrome.
class _DarkColors extends VbuPalette {
  const _DarkColors();

  @override
  Color get bg => const Color(0xFF0B0E13);
  @override
  Color get surface => const Color(0xFF11151C);
  @override
  Color get surface2 => const Color(0xFF161B24);
  @override
  Color get surface3 => const Color(0xFF1C2230);
  @override
  Color get elevated => const Color(0xFF1F2633);

  @override
  Color get borderSubtle => const Color(0xFF1A1F2A);
  @override
  Color get borderDefault => const Color(0xFF232A38);
  @override
  Color get borderStrong => const Color(0xFF2E3647);

  @override
  Color get textPrimary => const Color(0xFFE6EAF2);
  @override
  Color get textSecondary => const Color(0xFF9AA3B2);
  @override
  Color get textTertiary => const Color(0xFF5F6877);
  @override
  Color get textMuted => const Color(0xFF424B5C);
}

/// Light palette — inverted surface ramp with the same accent palette.
/// Used by [VbuTokens.colorOf] when the active Theme is light.
class _LightColors extends VbuPalette {
  const _LightColors();

  @override
  Color get bg => const Color(0xFFFFFFFF);
  @override
  Color get surface => const Color(0xFFF5F6F8);
  @override
  Color get surface2 => const Color(0xFFEEF0F4);
  @override
  Color get surface3 => const Color(0xFFE4E7EC);
  @override
  Color get elevated => const Color(0xFFFFFFFF);

  @override
  Color get borderSubtle => const Color(0xFFE4E7EC);
  @override
  Color get borderDefault => const Color(0xFFC9CED6);
  @override
  Color get borderStrong => const Color(0xFFA7AEB8);

  @override
  Color get textPrimary => const Color(0xFF0B0E13);
  @override
  Color get textSecondary => const Color(0xFF424B5C);
  @override
  Color get textTertiary => const Color(0xFF5F6877);
  @override
  Color get textMuted => const Color(0xFF9AA3B2);
}

/// 8-layer palette accessors — same hex values exposed through
/// [VbuPalette.layerXxx] methods. Surfaces both shapes so call sites
/// reading `VbuTokens.layer.app` and ones reading
/// `palette.layerApp` resolve to the identical color.
class _LayerColors {
  const _LayerColors();
  Color get app => const Color(0xFF5FA8FF);
  Color get theme => const Color(0xFFE58FB7);
  Color get component => const Color(0xFF7DD3C0);
  Color get dashboard => const Color(0xFFE9B873);
  Color get navigation => const Color(0xFF6BC8D8);
  Color get page => const Color(0xFF9B87F5);
  Color get assets => const Color(0xFF7AB87E);
  // Bundle-mode layers — each gets a distinct accent so the 4-card strip
  // reads as 4 peers (parity with the UI-mode strip), not fallback pairs.
  Color get knowledge => const Color(0xFFD9C77E); // gold
  Color get manifest => const Color(0xFF8AA0C8); // slate
  Color get tools => const Color(0xFFE9B873); // warm amber — verb / action
  Color get agents => const Color(0xFFE78A7A); // coral — agent / persona
  Color get whole => const Color(0xFFC8B9A0);
}

/// Track palette — MCP-driven (blue) vs self-emitted (amber) runtime
/// signals. Debug overlays / status pills use this to disambiguate
/// signal origin.
class _TrackColors {
  const _TrackColors();
  Color get mcp => const Color(0xFF5FA8FF);
  Color get self => const Color(0xFFE9B873);
}

/// Severity tint — mapped from accents so badges / status pills stay
/// visually consistent across builders.
class _StatusColors {
  const _StatusColors();
  Color get ok => const Color(0xFF7DD3C0);
  Color get warn => const Color(0xFFE9B873);
  Color get error => const Color(0xFFE78A7A);
  Color get info => const Color(0xFF5FA8FF);
  Color get neutral => const Color(0xFF9AA3B2);
}
