import 'package:flutter/material.dart';

import 'connectivity_manager.dart';

/// Per-widget offline behavior mode
enum OfflineWidgetMode {
  /// Widget is hidden when offline
  hide,

  /// Widget is visible but non-interactive when offline
  disable,

  /// Show last cached version when offline
  cached,

  /// Show a fallback widget when offline
  fallback,
}

/// Wraps a widget with offline-aware behavior based on [OfflineWidgetMode].
///
/// Listens to [ConnectivityManager] status changes and adjusts the child
/// widget's rendering accordingly.
class OfflineWidgetWrapper extends StatelessWidget {
  /// The child widget to wrap
  final Widget child;

  /// The offline behavior mode
  final OfflineWidgetMode mode;

  /// Fallback widget shown when mode is [OfflineWidgetMode.fallback] and offline
  final Widget? fallbackWidget;

  /// Cached widget shown when mode is [OfflineWidgetMode.cached] and offline
  final Widget? cachedWidget;

  /// The connectivity manager to observe
  final ConnectivityManager connectivityManager;

  const OfflineWidgetWrapper({
    super.key,
    required this.child,
    required this.mode,
    required this.connectivityManager,
    this.fallbackWidget,
    this.cachedWidget,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<NetworkStatus>(
      stream: connectivityManager.statusStream,
      initialData: connectivityManager.status,
      builder: (context, snapshot) {
        final isOffline = snapshot.data == NetworkStatus.offline;

        if (!isOffline) {
          return child;
        }

        switch (mode) {
          case OfflineWidgetMode.hide:
            return const SizedBox.shrink();

          case OfflineWidgetMode.disable:
            return IgnorePointer(
              child: Opacity(
                opacity: 0.5,
                child: child,
              ),
            );

          case OfflineWidgetMode.cached:
            return cachedWidget ?? child;

          case OfflineWidgetMode.fallback:
            return fallbackWidget ?? const SizedBox.shrink();
        }
      },
    );
  }
}
