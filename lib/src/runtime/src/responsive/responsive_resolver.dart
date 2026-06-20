import 'package:flutter/material.dart';

import 'breakpoint_system.dart';

/// Resolves responsive properties in widget definitions.
///
/// Walks through a widget definition map and resolves any responsive values
/// (maps keyed by breakpoint names) to their appropriate values based on
/// the current screen width.
class ResponsiveResolver {
  /// The breakpoint system used for resolution
  final BreakpointSystem breakpointSystem;

  /// Creates a resolver with the given breakpoint system
  ResponsiveResolver({BreakpointSystem? breakpointSystem})
      : breakpointSystem = breakpointSystem ?? BreakpointSystem();

  /// Resolve all responsive properties in a widget definition.
  ///
  /// Recursively walks the definition map and resolves any property whose
  /// value is a map with breakpoint keys to the appropriate value for the
  /// current screen width.
  Map<String, dynamic> resolveDefinition(
    Map<String, dynamic> definition,
    double width,
  ) {
    final resolved = <String, dynamic>{};

    for (final entry in definition.entries) {
      resolved[entry.key] = _resolveValue(entry.value, width);
    }

    return resolved;
  }

  /// Resolve all responsive properties using a BuildContext.
  /// Convenience method that extracts width from MediaQuery.
  Map<String, dynamic> resolveFromContext(
    Map<String, dynamic> definition,
    BuildContext context,
  ) {
    final width = MediaQuery.of(context).size.width;
    return resolveDefinition(definition, width);
  }

  /// Recursively resolve a value, handling maps, lists, and responsive values
  dynamic _resolveValue(dynamic value, double width) {
    if (value == null) return null;

    if (value is Map<String, dynamic>) {
      // Check if this map has breakpoint keys indicating a responsive value
      if (_isResponsiveValue(value)) {
        return breakpointSystem.resolveResponsiveValue(value, width);
      }

      // Otherwise, recursively resolve nested values
      final resolved = <String, dynamic>{};
      for (final entry in value.entries) {
        resolved[entry.key] = _resolveValue(entry.value, width);
      }
      return resolved;
    }

    if (value is List) {
      return value.map((item) => _resolveValue(item, width)).toList();
    }

    return value;
  }

  /// Check if a map represents a responsive value (keyed by breakpoint names).
  ///
  /// A map is considered responsive if it contains at least one key that
  /// matches a known breakpoint name and does NOT contain a 'type' key
  /// (which would indicate a widget definition). Recognises the Material
  /// 3 window-size class names used by [BreakpointSystem] defaults.
  bool _isResponsiveValue(Map<String, dynamic> value) {
    if (value.containsKey('type')) return false;

    const breakpointKeys = {
      'compact',
      'medium',
      'expanded',
      'large',
      'extraLarge',
    };
    return value.keys.any((key) => breakpointKeys.contains(key));
  }
}
