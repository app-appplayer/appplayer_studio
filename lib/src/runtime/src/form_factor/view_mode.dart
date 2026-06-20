import 'form_factor.dart';

/// User-selected view-mode pin.
///
/// Domain of the per-app pin (`AppConfig.viewMode`), global pin
/// (`AppSettings.defaultViewMode`), and the server-side DSL `responsive`
/// hint. `auto` means "do not pin at this level — defer to the next
/// source in the priority chain".
enum ViewMode {
  auto,
  compact,
  medium,
  expanded,
  large,
  extraLarge;

  /// Map a concrete (non-`auto`) pin to a [FormFactor]. Returns `null`
  /// for [ViewMode.auto] so the priority chain can skip it.
  FormFactor? toFormFactor() {
    switch (this) {
      case ViewMode.auto:
        return null;
      case ViewMode.compact:
        return FormFactor.compact;
      case ViewMode.medium:
        return FormFactor.medium;
      case ViewMode.expanded:
        return FormFactor.expanded;
      case ViewMode.large:
        return FormFactor.large;
      case ViewMode.extraLarge:
        return FormFactor.extraLarge;
    }
  }

  /// Parse a persisted string pin. Unknown / missing values collapse to
  /// [ViewMode.auto].
  static ViewMode parse(Object? raw) {
    if (raw is! String) return ViewMode.auto;
    switch (raw) {
      case 'compact':
        return ViewMode.compact;
      case 'medium':
        return ViewMode.medium;
      case 'expanded':
        return ViewMode.expanded;
      case 'large':
        return ViewMode.large;
      case 'extraLarge':
      case 'extra-large':
        return ViewMode.extraLarge;
      case 'auto':
      default:
        return ViewMode.auto;
    }
  }

  /// Canonical string form (stored in AppConfig / AppSettings / DSL).
  String get value {
    switch (this) {
      case ViewMode.auto:
        return 'auto';
      case ViewMode.compact:
        return 'compact';
      case ViewMode.medium:
        return 'medium';
      case ViewMode.expanded:
        return 'expanded';
      case ViewMode.large:
        return 'large';
      case ViewMode.extraLarge:
        return 'extraLarge';
    }
  }
}

/// Resolves the effective [FormFactor] by walking the priority chain
/// defined in the responsive-rendering plan §4:
///
/// 1. Per-app pin (`AppConfig.viewMode`)
/// 2. Global pin (`AppSettings.defaultViewMode`)
/// 3. DSL `responsive` hint (server-stamped)
/// 4. `MediaQuery` auto
///
/// `auto` at any step skips that step.
class ViewModeResolver {
  const ViewModeResolver._();

  static FormFactor resolve({
    ViewMode? perApp,
    ViewMode? global,
    ViewMode? dslHint,
    required double windowWidth,
  }) {
    for (final source in [perApp, global, dslHint]) {
      final ff = source?.toFormFactor();
      if (ff != null) return ff;
    }
    return FormFactor.fromWidth(windowWidth);
  }
}
