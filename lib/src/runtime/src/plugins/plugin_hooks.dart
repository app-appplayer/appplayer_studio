/// Plugin hook system for MCP UI DSL v1.0
///
/// Provides typed hook registration, firing, and error handling
/// for plugin lifecycle events.
library plugin_hooks;

import '../utils/mcp_logger.dart';

/// Hook types supported by the plugin system
enum PluginHookType {
  /// Fired when a new widget type is registered in the widget registry
  onWidgetRegister,

  /// Fired when a new action executor is registered in the action handler
  onActionRegister,

  /// Fired on plugin lifecycle transitions (init, enable, disable, dispose)
  onLifecycle,

  /// Fired when application state changes
  onStateChange,

  /// Fired before/after a widget is rendered
  onRender,

  /// Fired when an error occurs during plugin or runtime operations
  onError,
}

/// Lifecycle event types passed to onLifecycle hooks
enum PluginLifecycleEvent {
  /// Plugin initialization started
  initializing,

  /// Plugin initialization completed
  initialized,

  /// Plugin was enabled
  enabled,

  /// Plugin was disabled
  disabled,

  /// Plugin disposal started
  disposing,

  /// Plugin disposal completed
  disposed,
}

/// Context passed to hook callbacks with event information
class PluginHookContext {
  /// The hook type being fired
  final PluginHookType hookType;

  /// Name of the plugin that registered this hook (if applicable)
  final String? pluginName;

  /// Event-specific data payload
  final Map<String, dynamic> data;

  /// Timestamp of when the hook was fired
  final DateTime timestamp;

  const PluginHookContext({
    required this.hookType,
    this.pluginName,
    this.data = const {},
    required this.timestamp,
  });

  /// Create a hook context for the current moment
  factory PluginHookContext.now({
    required PluginHookType hookType,
    String? pluginName,
    Map<String, dynamic> data = const {},
  }) {
    return PluginHookContext(
      hookType: hookType,
      pluginName: pluginName,
      data: data,
      timestamp: DateTime.now(),
    );
  }
}

/// Callback signature for plugin hooks
typedef PluginHookCallback = Future<void> Function(PluginHookContext context);

/// Registration entry for a single hook
class _HookRegistration {
  final String pluginName;
  final PluginHookCallback callback;
  final int priority;

  _HookRegistration({
    required this.pluginName,
    required this.callback,
    this.priority = 0,
  });
}

/// Manages plugin hook registration and firing
///
/// Hooks are registered by plugins and fired by the runtime at appropriate
/// times. Errors in individual hooks are caught and logged without
/// affecting other hooks or the runtime.
class PluginHookManager {
  static PluginHookManager? _instance;
  static PluginHookManager get instance => _instance ??= PluginHookManager._();

  PluginHookManager._();

  /// Allow resetting for tests
  static void resetInstance() {
    _instance = null;
  }

  final Map<PluginHookType, List<_HookRegistration>> _hooks = {};
  final MCPLogger _logger = MCPLogger('PluginHookManager');

  /// Register a hook callback for a specific hook type
  ///
  /// [pluginName] identifies which plugin registered the hook.
  /// [hookType] determines when the callback is invoked.
  /// [callback] is the async function to call when the hook fires.
  /// [priority] controls execution order (higher runs first).
  void registerHook({
    required String pluginName,
    required PluginHookType hookType,
    required PluginHookCallback callback,
    int priority = 0,
  }) {
    _hooks.putIfAbsent(hookType, () => []);
    _hooks[hookType]!.add(_HookRegistration(
      pluginName: pluginName,
      callback: callback,
      priority: priority,
    ));

    // Sort by priority descending so higher priority runs first
    _hooks[hookType]!.sort((a, b) => b.priority.compareTo(a.priority));

    _logger.debug(
      'Registered ${hookType.name} hook from plugin "$pluginName" '
      '(priority: $priority)',
    );
  }

  /// Unregister all hooks for a specific plugin
  void unregisterPlugin(String pluginName) {
    for (final hookType in _hooks.keys) {
      _hooks[hookType]!.removeWhere((reg) => reg.pluginName == pluginName);
    }
    _logger.debug('Unregistered all hooks for plugin "$pluginName"');
  }

  /// Unregister a specific hook type for a plugin
  void unregisterHook({
    required String pluginName,
    required PluginHookType hookType,
  }) {
    _hooks[hookType]?.removeWhere((reg) => reg.pluginName == pluginName);
    _logger.debug(
      'Unregistered ${hookType.name} hook for plugin "$pluginName"',
    );
  }

  /// Fire all registered hooks for a given hook type
  ///
  /// Errors in individual hook callbacks are caught and logged.
  /// All registered hooks will be called even if earlier hooks fail.
  Future<void> fireHook(
    PluginHookType hookType, {
    Map<String, dynamic> data = const {},
  }) async {
    final registrations = _hooks[hookType];
    if (registrations == null || registrations.isEmpty) return;

    final context = PluginHookContext.now(
      hookType: hookType,
      data: data,
    );

    for (final registration in registrations) {
      try {
        await registration.callback(context);
      } catch (e, stackTrace) {
        _logger.error(
          'Error in ${hookType.name} hook from plugin '
          '"${registration.pluginName}"',
          e,
          stackTrace,
        );
        // Continue firing remaining hooks despite the error
      }
    }
  }

  /// Fire hooks synchronously where possible, catching all errors
  ///
  /// This is a convenience for hooks that need to fire in hot paths
  /// (e.g., onRender) where awaiting is not desirable.
  void fireHookSync(
    PluginHookType hookType, {
    Map<String, dynamic> data = const {},
  }) {
    final registrations = _hooks[hookType];
    if (registrations == null || registrations.isEmpty) return;

    final context = PluginHookContext.now(
      hookType: hookType,
      data: data,
    );

    for (final registration in registrations) {
      try {
        // Fire and forget - errors are logged but not propagated
        registration.callback(context).catchError((Object e, StackTrace s) {
          _logger.error(
            'Async error in ${hookType.name} hook from plugin '
            '"${registration.pluginName}"',
            e,
            s,
          );
        });
      } catch (e, stackTrace) {
        _logger.error(
          'Sync error in ${hookType.name} hook from plugin '
          '"${registration.pluginName}"',
          e,
          stackTrace,
        );
      }
    }
  }

  /// Check if any hooks are registered for a given type
  bool hasHooks(PluginHookType hookType) {
    final registrations = _hooks[hookType];
    return registrations != null && registrations.isNotEmpty;
  }

  /// Get the count of registered hooks for a given type
  int hookCount(PluginHookType hookType) {
    return _hooks[hookType]?.length ?? 0;
  }

  /// Get all hook types that have registered callbacks
  List<PluginHookType> get activeHookTypes {
    return _hooks.entries
        .where((e) => e.value.isNotEmpty)
        .map((e) => e.key)
        .toList();
  }

  /// Clear all registered hooks
  void clear() {
    _hooks.clear();
    _logger.debug('Cleared all plugin hooks');
  }

  /// Dispose of the hook manager
  void dispose() {
    clear();
  }
}
