/// `VbuRouter` — value-based switching widget. DSL `conditional` only
/// supports truthy checks; this atom fills the gap by matching a
/// resolved string value against a cases map and rendering the
/// corresponding widget. Authors declare `routes` / `cases` and a
/// `value` binding (typically `{{runtime.navigation.currentRoute}}`)
/// so domain navigation can drive page swaps from a single state key.
library;

import 'package:flutter/material.dart';

class VbuRouter extends StatelessWidget {
  const VbuRouter({
    super.key,
    required this.value,
    required this.cases,
    this.fallback,
  });

  /// Resolved value (typically a route string like `'/tools'`) used as
  /// the case key. Already-resolved at construction by the factory.
  final String value;

  /// Map of value → child widget. The first key matching [value] wins.
  final Map<String, Widget> cases;

  /// Widget rendered when no case matches. Null → empty `SizedBox.shrink()`.
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    final picked = cases[value];
    if (picked != null) return picked;
    return fallback ?? const SizedBox.shrink();
  }
}
