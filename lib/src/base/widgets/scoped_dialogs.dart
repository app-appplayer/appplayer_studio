import 'dart:async';

import 'package:flutter/material.dart';

/// Dialogs that die with the page that opened them.
///
/// `showDialog` pushes a separate navigator route, so a dialog outlives
/// the page it was opened from — when a built-in's project closes (or a
/// deep link rebinds the tab) the page unmounts but its dialog keeps
/// floating over state that no longer exists (live-caught 2026-07-04:
/// an issue-detail dialog over a CLOSED Form Builder project, action
/// buttons still armed). Pages whose dialogs reference project state
/// open them through [showScopedDialog] instead: the mixin tracks the
/// routes and removes any still-active ones when the page disposes.
mixin ScopedDialogs<T extends StatefulWidget> on State<T> {
  final List<Route<dynamic>> _scopedRoutes = <Route<dynamic>>[];
  NavigatorState? _scopedNavigator;

  /// Drop-in replacement for `showDialog` — same semantics, plus the
  /// route is torn down (no pop animation) if this page disposes first.
  Future<R?> showScopedDialog<R>({
    required WidgetBuilder builder,
    bool barrierDismissible = true,
  }) {
    final nav = Navigator.of(context, rootNavigator: true);
    _scopedNavigator = nav;
    final route = DialogRoute<R>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
    );
    _scopedRoutes.add(route);
    return nav.push(route).whenComplete(() => _scopedRoutes.remove(route));
  }

  @override
  void dispose() {
    final nav = _scopedNavigator;
    final stale = List<Route<dynamic>>.of(_scopedRoutes);
    _scopedRoutes.clear();
    if (nav != null && stale.isNotEmpty) {
      // Route removal re-entrance is illegal mid-teardown — defer one
      // microtask so the navigator mutates outside this dispose pass.
      scheduleMicrotask(() {
        for (final r in stale) {
          if (r.isActive) nav.removeRoute(r);
        }
      });
    }
    super.dispose();
  }
}
