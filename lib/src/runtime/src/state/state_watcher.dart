import 'package:flutter/foundation.dart';
import '../utils/mcp_logger.dart';

/// Represents a function that is called when a watched state value changes
typedef StateChangeCallback = Future<void> Function(
    dynamic newValue, dynamic oldValue);

/// Watches for changes to a specific state path
class StateWatcher {
  StateWatcher({
    required this.path,
    required this.onChange,
    this.condition,
    this.debounceMs = 0,
    this.enableDebugMode = kDebugMode,
  }) : _logger = MCPLogger('StateWatcher', enableLogging: enableDebugMode);

  /// The state path to watch
  final String path;

  /// Callback function to execute when the state changes
  final StateChangeCallback onChange;

  /// Optional condition to check before triggering the callback
  final bool Function(dynamic newValue, dynamic oldValue)? condition;

  /// Debounce delay in milliseconds
  final int debounceMs;

  /// Whether debug mode is enabled
  final bool enableDebugMode;

  final MCPLogger _logger;

  DateTime? _lastTriggerTime;
  dynamic _lastValue;
  bool _isInitialized = false;

  /// Gets the last known value for this watcher
  dynamic get lastValue => _lastValue;

  /// Gets whether this watcher has been initialized with a value
  bool get isInitialized => _isInitialized;

  /// Triggers the watcher with new and old values
  Future<void> trigger(dynamic newValue, dynamic oldValue) async {
    // Initialize on first trigger
    if (!_isInitialized) {
      _lastValue = newValue;
      _isInitialized = true;
      return;
    }

    // Check if value actually changed
    if (_areValuesEqual(newValue, _lastValue)) {
      return;
    }

    // Check condition if provided
    if (condition != null && !condition!(newValue, oldValue)) {
      return;
    }

    // Handle debouncing
    if (debounceMs > 0) {
      final now = DateTime.now();
      _lastTriggerTime = now;
      final capturedLastValue = _lastValue;

      // Schedule a delayed trigger
      Future.delayed(Duration(milliseconds: debounceMs), () async {
        // Only execute if this is still the latest trigger
        if (_lastTriggerTime == now) {
          await _executeTrigger(newValue, capturedLastValue);
          _lastValue = newValue;
        }
      });
      return;
    }

    _lastValue = newValue;
    await _executeTrigger(newValue, oldValue);
  }

  /// Executes the onChange callback
  Future<void> _executeTrigger(dynamic newValue, dynamic oldValue) async {
    try {
      if (enableDebugMode) {
        _logger.debug(
            'Triggering for path "$path": $oldValue -> $newValue');
      }

      await onChange(newValue, oldValue);
    } catch (error, stackTrace) {
      if (enableDebugMode) {
        _logger.error(
            'Error in onChange callback for path "$path"', error, stackTrace);
      }
      rethrow;
    }
  }

  /// Checks if two values are equal, handling different types appropriately
  bool _areValuesEqual(dynamic a, dynamic b) {
    // Use standard equality which includes reference equality for collections
    return a == b;
  }

  /// Creates a watcher from configuration
  static StateWatcher fromConfig(Map<String, dynamic> config) {
    final path = config['path'] as String;
    final debounceMs = config['debounceMs'] as int? ?? 0;

    return StateWatcher(
      path: path,
      onChange: (newValue, oldValue) async {
        // This would typically be configured with actual action handlers
        // For now, it's a placeholder
      },
      debounceMs: debounceMs,
    );
  }

  @override
  String toString() {
    return 'StateWatcher(path: $path, debounceMs: $debounceMs, initialized: $_isInitialized)';
  }
}

/// A group of watchers that can be managed together
class StateWatcherGroup {
  StateWatcherGroup({
    this.name,
    this.enableDebugMode = kDebugMode,
  }) : _logger = MCPLogger('StateWatcherGroup', enableLogging: enableDebugMode);

  final String? name;
  final bool enableDebugMode;
  final MCPLogger _logger;
  final List<StateWatcher> _watchers = [];

  /// Gets all watchers in this group
  List<StateWatcher> get watchers => List.unmodifiable(_watchers);

  /// Adds a watcher to this group
  void add(StateWatcher watcher) {
    _watchers.add(watcher);

    if (enableDebugMode) {
      _logger.debug(
          'Added watcher for path "${watcher.path}" to group "${name ?? 'unnamed'}"');
    }
  }

  /// Removes a watcher from this group
  void remove(StateWatcher watcher) {
    _watchers.remove(watcher);

    if (enableDebugMode) {
      _logger.debug(
          'Removed watcher for path "${watcher.path}" from group "${name ?? 'unnamed'}"');
    }
  }

  /// Triggers all watchers in this group with the same values
  Future<void> triggerAll(dynamic newValue, dynamic oldValue) async {
    for (final watcher in _watchers) {
      try {
        await watcher.trigger(newValue, oldValue);
      } catch (error) {
        if (enableDebugMode) {
          _logger.error(
              'Error triggering watcher for path "${watcher.path}": $error');
        }
      }
    }
  }

  /// Clears all watchers from this group
  void clear() {
    _watchers.clear();

    if (enableDebugMode) {
      _logger.debug(
          'Cleared all watchers from group "${name ?? 'unnamed'}"');
    }
  }

  /// Gets the count of watchers in this group
  int get count => _watchers.length;

  @override
  String toString() {
    return 'StateWatcherGroup(name: $name, count: ${_watchers.length})';
  }
}
