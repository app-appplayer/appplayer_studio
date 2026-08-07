import 'package:flutter/material.dart';

import 'mcp_logger.dart';

/// One reading of MCP UI DSL §5.3.4 `Color`, for every surface that takes one.
///
/// Four parsers used to answer this question and no two agreed: widget
/// properties took hex, the ten basic names and the scheme slots; the page
/// renderer took `pink` and `transparent` but no slot at all and mis-read
/// `#fff`; the theme took `rgb()` and nothing else; a dialog dropped alpha and
/// painted transparent. A document was therefore legal or not depending on
/// which slot it landed in, which is not a spec.
///
/// Accepted, per §5.3.4:
///
/// * **Scheme slot** — a role name from §5.3.1, resolved through
///   [slotResolver]. Preferred: it is the only spelling that follows light /
///   dark mode.
/// * **Hex** — `#RGB`, `#RRGGBB`, `#AARRGGBB` (alpha first).
/// * **CSS basic name** — the ten §5.3.4 names, case-insensitive.
/// * **Functional** — `rgb(r, g, b)` / `rgba(r, g, b, a)`; SHOULD, below hex.
///
/// Anything else resolves to null *and says so*. Silence is the failure this
/// exists to stop: an unresolvable name paints nothing, and a screen that
/// paints nothing looks like a design decision.
class DslColor {
  const DslColor._();

  /// Canonical M3 scheme slots (§5.3.1) — 28 roles, the three semantic pairs
  /// this spec adds, and the four legacy spellings §5.3.1 keeps.
  static const Set<String> schemeSlots = <String>{
    'primary', 'onPrimary', 'primaryContainer', 'onPrimaryContainer',
    'secondary', 'onSecondary', 'secondaryContainer', 'onSecondaryContainer',
    'tertiary', 'onTertiary', 'tertiaryContainer', 'onTertiaryContainer',
    'error', 'onError', 'errorContainer', 'onErrorContainer',
    'surface', 'onSurface', 'onSurfaceVariant',
    // The theme resolves these three and the schema declares them; leaving
    // them out here meant a document that named one validated, loaded, and
    // painted nothing.
    'surfaceTint', 'surfaceBright', 'surfaceDim',
    'surfaceContainerLowest', 'surfaceContainerLow', 'surfaceContainer',
    'surfaceContainerHigh', 'surfaceContainerHighest',
    'outline', 'outlineVariant',
    'inverseSurface', 'onInverseSurface', 'inverseOnSurface',
    'background', 'onBackground', 'surfaceVariant',
    'inversePrimary', 'scrim', 'shadow',
    'success', 'onSuccess', 'warning', 'onWarning', 'info', 'onInfo',
  };

  /// Pre-M3 slot names that documents in the field still carry.
  ///
  /// They were the vocabulary before §5.3.1's roles, and a document written
  /// then names them in `penColor`, a border, a divider. Refusing them stops
  /// the whole document at load (validation runs before the first frame) and
  /// resolving them to nothing paints an invisible line — so they map onto the
  /// role each one meant. Not advertised: §5.3.1 lists the canonical roles,
  /// and these resolve without appearing in a completion list.
  static const Map<String, String> legacyAliases = <String, String>{
    'divider': 'outlineVariant',
    'foreground': 'onSurface',
    'textOnPrimary': 'onPrimary',
    'textOnSecondary': 'onSecondary',
    'textOnBackground': 'onBackground',
    'textOnSurface': 'onSurface',
    'textOnError': 'onError',
  };

  static const Map<String, Color> _basicNames = <String, Color>{
    'red': Colors.red,
    'blue': Colors.blue,
    'green': Colors.green,
    'yellow': Colors.yellow,
    'orange': Colors.orange,
    'purple': Colors.purple,
    'black': Colors.black,
    'white': Colors.white,
    'grey': Colors.grey,
    'gray': Colors.grey,
  };

  static final RegExp _functional = RegExp(
    r'^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(?:,\s*([0-9]*\.?[0-9]+)\s*)?\)$',
    caseSensitive: false,
  );

  /// Parses [value] as a DSL color.
  ///
  /// [slotResolver] resolves a scheme slot against the active theme. Pass it
  /// wherever a theme exists — without it a slot cannot be read, and this
  /// reports nothing rather than calling a valid name invalid.
  ///
  /// [where] names the calling surface in the diagnostic, so a reader knows
  /// which property to look at.
  static Color? parse(
    dynamic value, {
    Color? Function(String slot)? slotResolver,
    String where = 'color',
  }) {
    if (value == null) return null;
    // §5.3.4 is a string vocabulary. An int or a map is not a color in this
    // DSL, and taking one here would let a document that no validator accepts
    // render anyway.
    if (value is! String) return null;

    final raw = value.trim();
    if (raw.isEmpty) return null;

    // An unresolved binding is not a color problem — the binding layer owns
    // it, and warning here would blame the wrong thing.
    if (raw.startsWith('{{') && raw.endsWith('}}')) return null;

    if (raw.startsWith('#')) {
      final hex = raw.substring(1);
      final parsed = _hex(hex);
      if (parsed == null) {
        _report(raw, where,
            'a hex color is #RGB, #RRGGBB or #AARRGGBB (alpha first)');
      }
      return parsed;
    }

    final basic = _basicNames[raw.toLowerCase()];
    if (basic != null) return basic;

    final functional = _functional.firstMatch(raw);
    if (functional != null) return _fromFunctional(functional, raw, where);

    final canonical = legacyAliases[raw];
    if (canonical != null) {
      if (slotResolver == null) return null;
      final resolved = slotResolver(canonical);
      if (resolved != null) return resolved;
      _report(raw, where, 'the active theme has no `$canonical` slot');
      return null;
    }

    if (schemeSlots.contains(raw)) {
      if (slotResolver == null) {
        // The name is valid; this surface simply has no theme to read it
        // from. Saying "not a color" here would be a lie.
        return null;
      }
      final resolved = slotResolver(raw);
      if (resolved == null) {
        _report(raw, where,
            'that scheme slot is not present in the active theme');
      }
      return resolved;
    }

    _report(
      raw,
      where,
      'use hex (#RGB / #RRGGBB / #AARRGGBB), one of the ten basic names '
      '(red, blue, green, yellow, orange, '
      'purple, black, white, grey/gray), rgb()/rgba(), or a Material 3 scheme '
      'slot such as `primary` — the only spelling that follows light / dark '
      'mode. CSS keyword colors beyond those ten are not accepted (§5.3.4)',
    );
    return null;
  }

  static Color? _hex(String hex) {
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) return null;
    switch (hex.length) {
      case 3:
        final expanded = hex.split('').map((c) => '$c$c').join();
        return Color(int.parse('FF$expanded', radix: 16));
      case 6:
        return Color(int.parse('FF$hex', radix: 16));
      case 8:
        return Color(int.parse(hex, radix: 16));
      default:
        return null;
    }
  }

  static Color? _fromFunctional(RegExpMatch m, String raw, String where) {
    final r = int.parse(m.group(1)!);
    final g = int.parse(m.group(2)!);
    final b = int.parse(m.group(3)!);
    if (r > 255 || g > 255 || b > 255) {
      _report(raw, where, 'rgb channels run 0-255');
      return null;
    }
    final alphaText = m.group(4);
    var alpha = 255;
    if (alphaText != null) {
      final a = double.tryParse(alphaText);
      if (a == null || a < 0 || a > 1) {
        _report(raw, where, 'rgba alpha runs 0-1');
        return null;
      }
      alpha = (a * 255).round();
    }
    return Color.fromARGB(alpha, r, g, b);
  }

  /// Once per distinct value: a color is read on every rebuild, and a
  /// per-frame log is a log nobody reads. Bounded, because values can arrive
  /// from state — an unbounded set would grow for the life of the process.
  static const int _warnCap = 128;
  static final Set<String> _warned = <String>{};
  static bool _capReported = false;

  static void _report(String value, String where, String advice) {
    if (_warned.length >= _warnCap) {
      if (_capReported) return;
      _capReported = true;
      MCPLogger('DslColor').warning(
        'stopped reporting unrecognised colors after $_warnCap distinct '
        'values — the document is producing them from state, and the '
        'remaining reports would be noise.',
      );
      return;
    }
    if (!_warned.add('$where|$value')) return;
    MCPLogger('DslColor')
        .warning('$where: "$value" is not a color the DSL accepts — $advice.');
  }

  /// Test seam: the warn-once set is process-wide, so a suite asserting on a
  /// warning has to be able to start from nothing.
  @visibleForTesting
  static void resetWarnings() {
    _warned.clear();
    _capReported = false;
  }
}
