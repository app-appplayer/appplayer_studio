// makemind Ops — design tokens (Flutter)
// Auto-derived from tokens.json. Keep in sync.
//
// Usage:
//   import 'package:appplayer_studio/src/apps/ops/theme/tokens.dart';
//   Container(color: OpsColors.surface)
//
// Color naming mirrors the CSS tokens. Light overrides are provided as
// `OpsColorsLight` so the theme builder can swap the surface scale.

import 'package:flutter/material.dart';

import 'package:appplayer_studio/base.dart' show VibeTokens;

/// Ops shares the single Studio palette: surfaces / text / border /
/// semantic colors forward to [VibeTokens] (dark = `color`) so Ops's
/// chrome matches the rest of the studio instead of carrying a parallel
/// palette. Only the makemind architecture-layer accents (L1–L6) stay
/// Ops-specific — they color-code Ops's own concepts, which the Studio
/// theme has no equivalent for. (Getters, not `const`, because they read
/// the runtime palette.)
abstract class OpsColors {
  // Surfaces — Studio palette.
  static Color get bg => VibeTokens.color.bg;
  static Color get surface => VibeTokens.color.surface;
  static Color get surface1 => VibeTokens.color.surface;
  static Color get surface2 => VibeTokens.color.surface2;
  static Color get surface3 => VibeTokens.color.surface3;
  static Color get border => VibeTokens.color.borderDefault;
  static Color get borderStrong => VibeTokens.color.borderStrong;

  // Text — Studio palette.
  static Color get text => VibeTokens.color.textPrimary;
  static Color get text2 => VibeTokens.color.textSecondary;
  static Color get text3 => VibeTokens.color.textTertiary;
  static Color get textMute => VibeTokens.color.textMuted;

  // makemind layer accents — Ops's L1–L6 architecture color-coding.
  // No Studio equivalent, so these stay Ops-specific.
  static const foundation = Color(0xFF15161A);
  static const protocol = Color(0xFF5E8FFA); // L1 — MCP, RPC
  static const io = Color(0xFF2BB39A); // L2 — adapters
  static const domain = Color(0xFFD49142); // L3 — tasks/processes
  static const knowledge = Color(0xFF9B7BE8); // L4 — facts/patterns
  static const ui = Color(0xFFD17FB0); // L5 — surfaces
  static const app = Color(0xFFE07565); // L6 — top-level apps

  // Semantic — Studio palette.
  static Color get accent => VibeTokens.color.blue;
  static const accentSoft = Color(0x245E8FFA); // 14% protocol
  static Color get success => VibeTokens.color.mint;
  static Color get warn => VibeTokens.color.amber;
  static Color get danger => VibeTokens.color.coral;
}

/// Light-mode surface + text — forwards to the Studio light palette.
/// Layer accents stay the same (Ops-specific, see [OpsColors]).
abstract class OpsColorsLight {
  static Color get bg => VibeTokens.lightColor.bg;
  static Color get surface => VibeTokens.lightColor.surface;
  static Color get surface1 => VibeTokens.lightColor.surface;
  static Color get surface2 => VibeTokens.lightColor.surface2;
  static Color get surface3 => VibeTokens.lightColor.surface3;
  static Color get border => VibeTokens.lightColor.borderDefault;
  static Color get borderStrong => VibeTokens.lightColor.borderStrong;

  static Color get text => VibeTokens.lightColor.textPrimary;
  static Color get text2 => VibeTokens.lightColor.textSecondary;
  static Color get text3 => VibeTokens.lightColor.textTertiary;
  static Color get textMute => VibeTokens.lightColor.textMuted;

  static Color get accent => VibeTokens.lightColor.blue;
  static const accentSoft = Color(0x1A2D6CDF); // 10%
}

/// Type tokens. Pair with `app_theme.dart` for the canonical TextStyles.
abstract class OpsType {
  static const sans = 'Inter';
  static const mono = 'JetBrains Mono';

  // Sizes (logical px)
  static const xs = 10.0;
  static const sm = 11.0;
  static const md = 12.0;
  static const lg = 13.0;
  static const xl = 14.0;
  static const xxl = 18.0;
  static const xxxl = 22.0;
  static const display = 26.0;

  // Weights
  static const regular = FontWeight.w400;
  static const medium = FontWeight.w500;
  static const semibold = FontWeight.w600;
  static const bold = FontWeight.w700;

  // Letter spacing
  static const tight = -0.44; // ≈ -0.02em @ 22px
  static const snug = -0.13; // ≈ -0.01em @ 13px
  static const mono06 = 0.66; // ≈ 0.06em @ 11px (uppercase mono labels)
}

/// Corner radii.
abstract class OpsRadius {
  static const sm = Radius.circular(6);
  static const md = Radius.circular(10);
  static const lg = Radius.circular(14);
  static const xl = Radius.circular(20);

  static const all_sm = BorderRadius.all(sm);
  static const all_md = BorderRadius.all(md);
  static const all_lg = BorderRadius.all(lg);
  static const all_xl = BorderRadius.all(xl);
}

/// 4-pt grid spacing scale.
abstract class OpsSpace {
  static const s0 = 0.0;
  static const s1 = 4.0;
  static const s2 = 6.0;
  static const s3 = 8.0;
  static const s4 = 10.0;
  static const s5 = 12.0;
  static const s6 = 14.0;
  static const s7 = 16.0;
  static const s8 = 20.0;
  static const s9 = 24.0;
  static const s10 = 28.0;
}

/// Density variants — drives row heights and inner padding for tables/lists.
enum OpsDensity { compact, normal, comfy }

class OpsDensityValues {
  final double rowHeight;
  final double padding;
  const OpsDensityValues({required this.rowHeight, required this.padding});

  static const compact = OpsDensityValues(rowHeight: 32, padding: 12);
  static const normal = OpsDensityValues(rowHeight: 38, padding: 16);
  static const comfy = OpsDensityValues(rowHeight: 44, padding: 20);

  static OpsDensityValues of(OpsDensity d) => switch (d) {
    OpsDensity.compact => compact,
    OpsDensity.normal => normal,
    OpsDensity.comfy => comfy,
  };
}

/// Elevation as BoxShadow lists. Use for cards/menus/modals.
abstract class OpsElevation {
  static const e1 = <BoxShadow>[
    BoxShadow(color: Color(0x59000000), blurRadius: 2, offset: Offset(0, 1)),
  ];
  static const e2 = <BoxShadow>[
    BoxShadow(color: Color(0x73000000), blurRadius: 16, offset: Offset(0, 4)),
    BoxShadow(color: Color(0x59000000), blurRadius: 3, offset: Offset(0, 1)),
  ];
  static const e3 = <BoxShadow>[
    BoxShadow(color: Color(0x8C000000), blurRadius: 60, offset: Offset(0, 24)),
    BoxShadow(color: Color(0x66000000), blurRadius: 20, offset: Offset(0, 6)),
  ];
}

/// Convenience: linear gradient used on member/agent avatars.
class OpsAvatarGradients {
  static const knowledge = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [OpsColors.knowledge, OpsColors.protocol],
  );
  static const research = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [OpsColors.io, OpsColors.knowledge],
  );
  static const writer = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [OpsColors.domain, OpsColors.app],
  );
  static const human = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [OpsColors.ui, OpsColors.app],
  );
}
