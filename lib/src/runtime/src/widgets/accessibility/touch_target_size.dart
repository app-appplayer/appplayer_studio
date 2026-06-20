import 'package:flutter/material.dart';

/// Minimum touch target size constants for accessibility compliance.
///
/// Interactive widgets should enforce the 48x48dp minimum touch target
/// size per WCAG 2.1 and Material Design guidelines.
class TouchTargetSize {
  TouchTargetSize._();

  /// Minimum touch target dimension in logical pixels (48x48 dp)
  static const double minimum = 48.0;

  /// Ensure a widget meets the minimum touch target size.
  ///
  /// If the child is smaller than [minimum] x [minimum], it is centered
  /// within a constrained box of that minimum size.
  static Widget ensureMinimumSize(Widget child) {
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: minimum,
        minHeight: minimum,
      ),
      child: Center(
        widthFactor: 1.0,
        heightFactor: 1.0,
        child: child,
      ),
    );
  }
}
