// ============================================================================
// vibe — design tokens (shim → vbu_studio_ui.VbuTokens)
// ============================================================================
//
// Single source of truth is `vibe_studio_ui` package's [VbuTokens]. This
// file re-exposes the same values under the legacy `VibeTokens` name so
// the studio chrome (AppTheme + native widgets) and the bundle runtime
// (ThemeManager.studioRuntimeTheme) all read from one palette.
//
// Adding a new token? Add it to `vibe_studio_ui/lib/src/tokens.dart`
// and surface it here through an alias if chrome call sites need the
// legacy name. Never define a chrome-only token here — it will drift
// from the bundle runtime's palette.

import 'package:flutter/material.dart';
import 'package:appplayer_studio/ui.dart' as vbu;

/// Legacy name for [vbu.VbuTokens]. All members forward to the single
/// `VbuTokens` instance so chrome + bundle runtime share one palette.
abstract final class VibeTokens {
  // ───────── Colors ─────────
  static const color = vbu.VbuTokens.color;
  static const lightColor = vbu.VbuTokens.lightColor;

  static vbu.VbuPalette colorOf(BuildContext context) =>
      vbu.VbuTokens.colorOf(context);

  static const layer = vbu.VbuTokens.layer;
  static const track = vbu.VbuTokens.track;
  static const status = vbu.VbuTokens.status;

  // ───────── Typography ─────────
  static const fontMono = vbu.VbuTokens.fontMono;
  static const fontSans = vbu.VbuTokens.fontSans;
  static const fontSerif = vbu.VbuTokens.fontSerif;

  // ───────── Spacing ─────────
  static const space0 = vbu.VbuTokens.space0;
  static const space1 = vbu.VbuTokens.space1;
  static const space2 = vbu.VbuTokens.space2;
  static const space3 = vbu.VbuTokens.space3;
  static const space4 = vbu.VbuTokens.space4;
  static const space5 = vbu.VbuTokens.space5;
  static const space6 = vbu.VbuTokens.space6;
  static const space8 = vbu.VbuTokens.space8;
  static const space10 = vbu.VbuTokens.space10;
  static const space12 = vbu.VbuTokens.space12;
  static const space16 = vbu.VbuTokens.space16;

  // ───────── Radius ─────────
  static const radiusNone = vbu.VbuTokens.radiusNone;
  static const radiusSm = vbu.VbuTokens.radiusSm;
  static const radiusMd = vbu.VbuTokens.radiusMd;
  static const radiusLg = vbu.VbuTokens.radiusLg;
  static const radiusXl = vbu.VbuTokens.radiusXl;
  static const radiusFull = vbu.VbuTokens.radiusFull;

  // ───────── Border ─────────
  static const borderThin = vbu.VbuTokens.borderThin;
  static const borderThick = vbu.VbuTokens.borderThick;

  // ───────── Motion ─────────
  static const durInstant = vbu.VbuTokens.durInstant;
  static const durFast = vbu.VbuTokens.durFast;
  static const durBase = vbu.VbuTokens.durBase;
  static const durSlow = vbu.VbuTokens.durSlow;

  static const easeStandard = vbu.VbuTokens.easeStandard;
  static const easeDecelerate = vbu.VbuTokens.easeDecelerate;
  static const easeAccelerate = vbu.VbuTokens.easeAccelerate;

  // ───────── Layout ─────────
  static const titlebarHeight = vbu.VbuTokens.titlebarHeight;
  static const statusbarHeight = vbu.VbuTokens.statusbarHeight;
  static const chatPanelWidth = vbu.VbuTokens.chatPanelWidth;
  static const propsPanelWidth = vbu.VbuTokens.propsPanelWidth;
  static const stripHeight = vbu.VbuTokens.stripHeight;
  static const stripCardWidth = vbu.VbuTokens.stripCardWidth;
  static const stripCardGap = vbu.VbuTokens.stripCardGap;
  static const panelPadding = vbu.VbuTokens.panelPadding;
}
