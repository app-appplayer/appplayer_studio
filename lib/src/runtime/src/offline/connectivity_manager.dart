import 'dart:async';

/// Network status for MCP UI DSL v1.1
enum NetworkStatus {
  /// Device is connected to the network
  online,

  /// Device has no network connectivity
  offline,

  /// Network connectivity is available but slow
  slow,

  /// Network status has not been determined yet
  unknown,
}

/// Network connection type for MCP UI DSL v1.1
enum NetworkType {
  /// Connected via Wi-Fi
  wifi,

  /// Connected via cellular data
  cellular,

  /// Connected via wired ethernet
  ethernet,

  /// No active network connection
  none,

  /// Connection type could not be determined
  unknown,
}

/// Manages network connectivity state for MCP UI DSL v1.1
///
/// Tracks the current network status and type, emitting status changes
/// through a stream that other components can listen to.
///
/// This is a platform-agnostic connectivity tracker. Platform-specific
/// connectivity detection should update this manager via [updateStatus].
///
/// Example usage:
/// ```dart
/// final connectivity = ConnectivityManager();
///
/// // Listen for status changes
/// connectivity.statusStream.listen((status) {
///   if (status == NetworkStatus.offline) {
///     // Switch to offline mode
///   }
/// });
///
/// // Update from platform-specific code
/// connectivity.updateStatus(NetworkStatus.online, type: NetworkType.wifi);
/// ```
class ConnectivityManager {
  final StreamController<NetworkStatus> _statusController =
      StreamController<NetworkStatus>.broadcast();

  NetworkStatus _status = NetworkStatus.unknown;
  NetworkType _type = NetworkType.unknown;
  DateTime? _lastStatusChange;
  final List<void Function(NetworkStatus, NetworkStatus)> _changeCallbacks = [];

  /// Current network status
  NetworkStatus get status => _status;

  /// Current network connection type
  NetworkType get type => _type;

  /// Stream of network status changes
  Stream<NetworkStatus> get statusStream => _statusController.stream;

  /// Timestamp of the last status change
  DateTime? get lastStatusChange => _lastStatusChange;

  /// Update connectivity status
  ///
  /// Emits a status change event if the new status differs from the current one.
  /// Optionally updates the connection [type] as well.
  void updateStatus(NetworkStatus status, {NetworkType? type}) {
    final previousStatus = _status;
    final changed = _status != status;

    _status = status;
    if (type != null) {
      _type = type;
    }

    // Update type to 'none' when going offline
    if (status == NetworkStatus.offline) {
      _type = NetworkType.none;
    }

    if (changed) {
      _lastStatusChange = DateTime.now();

      if (!_statusController.isClosed) {
        _statusController.add(status);
      }

      // Notify registered callbacks
      for (final callback in _changeCallbacks) {
        callback(previousStatus, status);
      }
    }
  }

  /// Check if the device is currently online
  bool get isOnline => _status == NetworkStatus.online;

  /// Check if the device is currently offline
  bool get isOffline => _status == NetworkStatus.offline;

  /// Register a callback for status transitions
  ///
  /// The callback receives the previous and new status values.
  /// Returns a function that can be called to unregister the callback.
  void Function() onStatusChange(
      void Function(NetworkStatus previous, NetworkStatus current) callback) {
    _changeCallbacks.add(callback);
    return () {
      _changeCallbacks.remove(callback);
    };
  }

  /// Get a human-readable description of the current connectivity
  String get statusDescription {
    switch (_status) {
      case NetworkStatus.online:
        return 'Online (${_type.name})';
      case NetworkStatus.offline:
        return 'Offline';
      case NetworkStatus.slow:
        return 'Slow (${_type.name})';
      case NetworkStatus.unknown:
        return 'Unknown';
    }
  }

  /// Dispose the connectivity manager and release resources
  void dispose() {
    _changeCallbacks.clear();
    if (!_statusController.isClosed) {
      _statusController.close();
    }
  }
}
