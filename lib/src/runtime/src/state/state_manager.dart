import 'dart:async';

import 'package:flutter/foundation.dart';

import '../plugins/plugin_hooks.dart';
import '../utils/json_path.dart';
import '../utils/mcp_logger.dart';
import 'computed_property.dart';

/// State change event
///
/// Emitted by [StateManager] on every mutation. The [source] field carries
/// the canonical origin classification defined by spec §3.11:
///
/// | `source` | Meaning |
/// |----------|---------|
/// | `action` | User-triggered via a `state` action |
/// | `tool` | Tool response auto-merge (§3.10) |
/// | `subscription` | Resource notification (§4.5) |
/// | `system` | Internal runtime update |
///
/// Other values are accepted for backward compatibility but downstream
/// consumers should treat unknown values as `system`.
class StateChangeEvent {
  final String path;
  final dynamic oldValue;
  final dynamic newValue;
  final DateTime timestamp;

  /// Canonical source identifier per spec §3.11.
  /// One of `'action'`, `'tool'`, `'subscription'`, `'system'`. May be null
  /// when the caller did not specify a source (treated as `system`).
  final String? source;

  StateChangeEvent({
    required this.path,
    this.oldValue,
    this.newValue,
    this.source,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Manages application state with change notifications
/// Supports computed properties according to MCP UI DSL v1.0
class StateManager extends ChangeNotifier {
  final Map<String, dynamic> _state = {};
  final Map<String, StreamController> _streamControllers = {};
  final Map<String, ComputedProperty> _computedProperties = {};
  final Map<String, List<VoidCallback>> _keyListeners = {};
  final MCPLogger _logger = MCPLogger('StateManager');

  // Stream controller for state changes
  final StreamController<StateChangeEvent> _stateChangeController =
      StreamController<StateChangeEvent>.broadcast();

  /// Stream of state change events
  Stream<StateChangeEvent> get stream => _stateChangeController.stream;

  /// Get the current state
  Map<String, dynamic> get state => Map<String, dynamic>.from(_state);

  /// Initialize state with initial values
  void initialize(Map<String, dynamic> initialState) {
    _state.clear();
    _state.addAll(initialState);
    _logger.debug('initialize with: $initialState');
    _logger.debug('state after init: $_state');
    _logger.debug('hashCode: $hashCode');
    notifyListeners();
  }

  /// Get a value from state using a path
  /// Supports computed properties according to MCP UI DSL v1.0
  T? get<T>(String path) {
    // Check if this is a computed property
    if (_computedProperties.containsKey(path)) {
      final computed = _computedProperties[path]!;
      if (!computed.isInitialized) {
        computed.computeAndCache(_state);
      }
      final result = computed.cachedValue as T?;
      _logger.debug('get computed property: $path, result: $result');
      return result;
    }

    // Get regular state value
    final result = JsonPath.get(_state, path) as T?;
    _logger.debug('get path: $path, result: $result, state: $_state');
    return result;
  }

  /// Set a value in state using a path
  void set(String path, dynamic value, {String? source}) {
    final oldValue = JsonPath.get(_state, path);
    JsonPath.set(_state, path, value);
    _logger.debug('set path: $path, value: $value, new state: $_state');

    // Emit state change event
    _stateChangeController.add(StateChangeEvent(
      path: path,
      oldValue: oldValue,
      newValue: value,
      source: source,
    ));

    // Invalidate affected computed properties
    _invalidateComputedProperties({path: value.toString()});

    // Notify stream listeners for this specific path
    final controller = _streamControllers[path];
    if (controller != null && !controller.isClosed) {
      controller.add(value);
    }

    // Notify general listeners
    _logger.debug('calling notifyListeners() for path: $path');
    notifyListeners();

    // Notify key-specific listeners
    _keyListeners[path]?.forEach((listener) => listener());

    // Fire plugin onStateChange hook
    PluginHookManager.instance.fireHookSync(
      PluginHookType.onStateChange,
      data: {'path': path, 'oldValue': oldValue, 'newValue': value},
    );
  }

  /// Update a specific state path with a transform function.
  /// The updater receives the current value and returns the new value.
  void update(String path, dynamic Function(dynamic current) updater) {
    final current = get(path);
    final updated = updater(current);
    set(path, updated);
  }

  /// Update multiple values at once
  ///
  /// [source] carries the canonical [StateChangeEvent] source per spec §3.11.
  /// Defaults to `'system'` when the caller does not specify (was previously
  /// the non-canonical `'updateAll'`, which is no longer emitted).
  void updateAll(Map<String, dynamic> updates, {String? source}) {
    final eventSource = source ?? 'system';
    updates.forEach((path, value) {
      final oldValue = JsonPath.get(_state, path);
      JsonPath.set(_state, path, value);

      // Emit state change event
      _stateChangeController.add(StateChangeEvent(
        path: path,
        oldValue: oldValue,
        newValue: value,
        source: eventSource,
      ));

      // Notify stream listeners
      final controller = _streamControllers[path];
      if (controller != null && !controller.isClosed) {
        controller.add(value);
      }
    });

    // Invalidate affected computed properties
    _invalidateComputedProperties(
      updates.map((k, v) => MapEntry(k, v.toString())),
    );

    notifyListeners();
  }

  /// Watch a specific path for changes
  Stream<T> watch<T>(String path) {
    // Create or get existing stream controller
    _streamControllers.putIfAbsent(
      path,
      () => StreamController<T>.broadcast(),
    );

    final controller = _streamControllers[path] as StreamController<T>;

    // Emit current value immediately
    final currentValue = get<T>(path);
    if (currentValue != null) {
      controller.add(currentValue);
    }

    return controller.stream;
  }

  /// Increment a numeric value
  void increment(String path, [num amount = 1]) {
    final current = get<num>(path) ?? 0;
    set(path, current + amount);
  }

  /// Decrement a numeric value
  void decrement(String path, [num amount = 1]) {
    final current = get<num>(path) ?? 0;
    set(path, current - amount);
  }

  /// Toggle a boolean value
  void toggle(String path) {
    final current = get<bool>(path) ?? false;
    set(path, !current);
  }

  /// Push an item to the end of a list (alias for append)
  void push(String path, dynamic item) {
    append(path, item);
  }

  /// Pop and return the last item from a list
  dynamic pop(String path) {
    final current = get<List>(path) ?? [];
    if (current.isEmpty) return null;
    final lastItem = current.last;
    final newList = List.from(current)..removeLast();
    set(path, newList);
    return lastItem;
  }

  /// Append to a list
  void append(String path, dynamic item) {
    final current = get<List>(path) ?? [];
    final newList = List.from(current)..add(item);
    set(path, newList);
  }

  /// Remove from a list
  void remove(String path, dynamic item) {
    final current = get<List>(path) ?? [];
    final newList = List.from(current)..remove(item);
    set(path, newList);
  }

  /// Remove at index from a list
  void removeAt(String path, int index) {
    final current = get<List>(path) ?? [];
    if (index >= 0 && index < current.length) {
      final newList = List.from(current)..removeAt(index);
      set(path, newList);
    }
  }

  /// Clear a list or map
  void clear(String path) {
    final current = get(path);
    if (current is List) {
      set(path, []);
    } else if (current is Map) {
      set(path, {});
    }
  }

  /// Get a copy of the entire state
  Map<String, dynamic> getState() {
    return Map<String, dynamic>.from(_state);
  }

  /// Replace the entire state
  void setState(Map<String, dynamic> newState) {
    _state.clear();
    _state.addAll(newState);

    // Notify all stream listeners
    _streamControllers.forEach((path, controller) {
      if (!controller.isClosed) {
        final value = get(path);
        if (value != null) {
          controller.add(value);
        }
      }
    });

    notifyListeners();
  }

  /// Clear all state
  void clearState() {
    _state.clear();
    _computedProperties.clear();
    notifyListeners();
  }

  /// Register a computed property
  void registerComputedProperty(String path, ComputedProperty property) {
    _computedProperties[path] = property;
    _logger.debug('Registered computed property: $path');
  }

  /// Unregister a computed property
  void unregisterComputedProperty(String path) {
    _computedProperties.remove(path);
    _logger.debug('Unregistered computed property: $path');
  }

  /// Add a computed property from expression
  void addComputedProperty(String path, String expression,
      {List<String>? dependencies}) {
    final property = ComputedProperty.fromExpression(path, expression,
        dependencies: dependencies);
    registerComputedProperty(path, property);
  }

  /// Invalidate computed properties that depend on the changed paths
  void _invalidateComputedProperties(Map<String, String> changedPaths) {
    for (final property in _computedProperties.values) {
      if (property.shouldRecompute(changedPaths)) {
        property.invalidate();
        _logger.debug('Invalidated computed property: ${property.name}');
      }
    }
  }

  /// Get all computed property names
  List<String> get computedPropertyNames => _computedProperties.keys.toList();

  /// Merge state from a map (e.g., tool response auto-merge per spec §3.10).
  ///
  /// Each top-level key of [data] is set as a state variable using
  /// shallow overwrite semantics — nested objects replace existing values
  /// without deep merging. The default [source] is `'tool'` per spec §3.11,
  /// reflecting the primary call site (tool response auto-merge). Callers
  /// using `mergeState` from other contexts should pass an explicit source.
  void mergeState(Map<String, dynamic> data, {String source = 'tool'}) {
    for (final entry in data.entries) {
      set(entry.key, entry.value, source: source);
    }
  }

  /// Set application-level state (global, shared across pages)
  void setAppState(String key, dynamic value) {
    set('app.$key', value);
  }

  /// Get application-level state
  T? getAppState<T>(String key) {
    return get<T>('app.$key');
  }

  /// Set page-level state (isolated per page)
  void setPageState(String key, dynamic value) {
    set('page.$key', value);
  }

  /// Get page-level state
  T? getPageState<T>(String key) {
    return get<T>('page.$key');
  }

  /// Set route parameters
  void setRouteParams(Map<String, String> params) {
    set('route.params', params);
  }

  /// Get a route parameter
  String? getRouteParam(String key) {
    final params = get<Map<String, dynamic>>('route.params');
    return params?[key] as String?;
  }

  /// Get all active resource subscriptions
  Map<String, String> get activeSubscriptions {
    return Map<String, String>.from(
      get<Map<String, dynamic>>('_subscriptions') ?? {},
    );
  }

  /// Add a listener for a specific state key
  void addKeyListener(String key, VoidCallback listener) {
    _keyListeners[key] ??= <VoidCallback>[];
    _keyListeners[key]!.add(listener);
  }

  /// Remove a listener for a specific state key
  void removeKeyListener(String key, VoidCallback listener) {
    _keyListeners[key]?.remove(listener);
    if (_keyListeners[key]?.isEmpty ?? false) {
      _keyListeners.remove(key);
    }
  }

  @override
  void dispose() {
    // Close all stream controllers
    for (final controller in _streamControllers.values) {
      controller.close();
    }
    _streamControllers.clear();
    _computedProperties.clear();
    _stateChangeController.close();

    super.dispose();
  }
}
