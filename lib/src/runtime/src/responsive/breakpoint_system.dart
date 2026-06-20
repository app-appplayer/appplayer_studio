import 'package:flutter/material.dart';

/// Breakpoint definition for responsive layout
/// Each breakpoint defines a named range of screen widths.
class Breakpoint {
  /// Name identifier for this breakpoint. Default set uses Material 3
  /// window-size class names: `compact`, `medium`, `expanded`, `large`,
  /// `extraLarge`.
  final String name;

  /// Minimum width (inclusive) for this breakpoint
  final double minWidth;

  /// Maximum width (inclusive) for this breakpoint
  final double maxWidth;

  /// Creates a breakpoint with the given name and width range
  const Breakpoint({
    required this.name,
    required this.minWidth,
    required this.maxWidth,
  });
}

/// Breakpoint system for MCP UI DSL.
///
/// Default breakpoints align with the FormFactor axis (see
/// `form_factor/form_factor.dart`) so the tier C `responsive:` cascade
/// and the tier A / B chrome adaptation classify window widths
/// identically: `compact < 600`, `medium 600-839`, `expanded 840-1199`,
/// `large 1200-1599`, `extraLarge ≥ 1600`.
///
/// Provides methods to determine the current breakpoint based on screen
/// width, resolve responsive property values, and customize breakpoint
/// definitions.
class BreakpointSystem {
  /// Default breakpoint definitions — Material 3 window-size class.
  static const defaultBreakpoints = {
    'compact': Breakpoint(name: 'compact', minWidth: 0, maxWidth: 599),
    'medium': Breakpoint(name: 'medium', minWidth: 600, maxWidth: 839),
    'expanded':
        Breakpoint(name: 'expanded', minWidth: 840, maxWidth: 1199),
    'large': Breakpoint(name: 'large', minWidth: 1200, maxWidth: 1599),
    'extraLarge': Breakpoint(
        name: 'extraLarge', minWidth: 1600, maxWidth: double.infinity),
  };

  /// Ordered list of breakpoint names from smallest to largest
  static const _breakpointOrder = [
    'compact',
    'medium',
    'expanded',
    'large',
    'extraLarge',
  ];

  /// Current active breakpoints (can be customized)
  Map<String, Breakpoint> _breakpoints = Map.from(defaultBreakpoints);

  /// Returns the current breakpoint name for the given screen width
  String getCurrentBreakpoint(double width) {
    for (final name in _breakpointOrder) {
      final bp = _breakpoints[name];
      if (bp != null && width >= bp.minWidth && width <= bp.maxWidth) {
        return bp.name;
      }
    }
    // Custom breakpoints: fall back to the largest defined
    if (_breakpoints.isNotEmpty) {
      final ordered = _breakpoints.values.toList()
        ..sort((a, b) => a.minWidth.compareTo(b.minWidth));
      return ordered.last.name;
    }
    return 'extraLarge';
  }

  /// Checks whether the given width falls within the specified breakpoint
  bool isBreakpoint(double width, String breakpoint) {
    final bp = _breakpoints[breakpoint];
    if (bp == null) return false;
    return width >= bp.minWidth && width <= bp.maxWidth;
  }

  /// Replaces the current breakpoint definitions with custom ones
  void setCustomBreakpoints(Map<String, Breakpoint> breakpoints) {
    _breakpoints = Map.from(breakpoints);
  }

  /// Resets breakpoints to the default definitions
  void resetBreakpoints() {
    _breakpoints = Map.from(defaultBreakpoints);
  }

  /// Returns the current breakpoint definitions
  Map<String, Breakpoint> get breakpoints => Map.unmodifiable(_breakpoints);

  /// Resolve a responsive property value based on current width.
  ///
  /// If [value] is a Map with breakpoint keys (e.g., `{compact: 12, expanded: 6}`),
  /// resolves to the value matching the current breakpoint. Falls back to
  /// smaller breakpoints if no exact match is found.
  ///
  /// If [value] is not a Map, returns it unchanged.
  dynamic resolveResponsiveValue(dynamic value, double width) {
    if (value is Map<String, dynamic>) {
      final bp = getCurrentBreakpoint(width);
      final bpIndex = _breakpointOrder.indexOf(bp);

      // Try exact match first
      if (value.containsKey(bp)) {
        return value[bp];
      }

      // Fall back to the next smaller breakpoint that has a value
      for (int i = bpIndex - 1; i >= 0; i--) {
        final fallbackKey = _breakpointOrder[i];
        if (value.containsKey(fallbackKey)) {
          return value[fallbackKey];
        }
      }

      // If no smaller breakpoint found, try larger breakpoints
      for (int i = bpIndex + 1; i < _breakpointOrder.length; i++) {
        final fallbackKey = _breakpointOrder[i];
        if (value.containsKey(fallbackKey)) {
          return value[fallbackKey];
        }
      }

      // Return the first available value as last resort
      if (value.isNotEmpty) {
        return value.values.first;
      }
    }

    return value;
  }

  /// Resolve a responsive property value using a BuildContext.
  /// Convenience method that extracts width from MediaQuery.
  dynamic resolveFromContext(dynamic value, BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return resolveResponsiveValue(value, width);
  }
}
