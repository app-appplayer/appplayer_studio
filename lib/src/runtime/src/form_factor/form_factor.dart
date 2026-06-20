import 'package:flutter/widgets.dart';

/// Device form factor class per Material 3 window-size taxonomy.
///
/// Derived from the logical window width; hosts may override it with a
/// [FormFactorScope] to honour per-app / global view-mode pins or to
/// flag off-axis embedded chrome (industrial HMI, vehicle IVI).
enum FormFactor {
  /// `< 600` logical px. Phones, split panes, small popouts.
  compact,

  /// `600 – 839` logical px. Tablet portrait, foldables.
  medium,

  /// `840 – 1199` logical px. Desktop, tablet landscape.
  expanded,

  /// `1200 – 1599` logical px. Large monitors.
  large,

  /// `≥ 1600` logical px. Extra-large monitors, TVs, dashboard walls.
  extraLarge,

  /// Off-axis embedded chrome (industrial HMI, vehicle IVI). Not picked
  /// up from window width — hosts inject this via [FormFactorScope].
  embedded;

  /// Upper bound (exclusive) for each class in logical pixels.
  static const double compactMax = 600;
  static const double mediumMax = 840;
  static const double expandedMax = 1200;
  static const double largeMax = 1600;

  /// Classify a logical-pixel window width into one of the five
  /// width-based classes. [FormFactor.embedded] is never returned —
  /// hosts tag that explicitly.
  static FormFactor fromWidth(double width) {
    if (width < compactMax) return FormFactor.compact;
    if (width < mediumMax) return FormFactor.medium;
    if (width < expandedMax) return FormFactor.expanded;
    if (width < largeMax) return FormFactor.large;
    return FormFactor.extraLarge;
  }

  /// Resolve the effective form factor for [context]. Honours any
  /// [FormFactorScope] above the widget; otherwise falls back to
  /// `MediaQuery.sizeOf(context).width`.
  static FormFactor of(BuildContext context) {
    final scope = FormFactorScope.maybeOf(context);
    if (scope != null) return scope.formFactor;
    final width = MediaQuery.sizeOf(context).width;
    return fromWidth(width);
  }

  /// True when the form factor is one of the compact / medium classes —
  /// the standard threshold at which single-column layouts apply.
  bool get isCompactOrMedium =>
      this == FormFactor.compact || this == FormFactor.medium;

  /// True when the form factor is one of the expanded / large / extra-
  /// large classes — the threshold at which multi-column / rail-based
  /// layouts apply.
  bool get isExpandedOrLarger =>
      this == FormFactor.expanded ||
      this == FormFactor.large ||
      this == FormFactor.extraLarge;
}

/// InheritedWidget that pins a [FormFactor] for a subtree.
///
/// Hosts wrap the widget tree in a [FormFactorScope] when the user has
/// set a per-app or global view-mode pin, which forces the pinned class
/// regardless of the physical window width. Derivative players may also
/// inject a scope to flag [FormFactor.embedded].
class FormFactorScope extends InheritedWidget {
  const FormFactorScope({
    super.key,
    required this.formFactor,
    required super.child,
  });

  final FormFactor formFactor;

  static FormFactorScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FormFactorScope>();

  @override
  bool updateShouldNotify(FormFactorScope old) =>
      formFactor != old.formFactor;
}
