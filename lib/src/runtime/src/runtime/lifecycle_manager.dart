import 'package:flutter/foundation.dart';
import '../utils/mcp_logger.dart';

/// Enumeration of lifecycle events supported by the runtime
enum LifecycleEvent {
  /// App-level initialization (called once on application start)
  initialize,

  /// Page-level initialization (called on each page enter/mount)
  pageInit,

  ready,
  pause,
  resume,
  destroy,
  mount,
  unmount,
  enter,
  leave,
  pagePause,
  pageResume,
}

/// Manages component and runtime lifecycle events
class LifecycleManager {
  LifecycleManager({
    this.enableDebugMode = kDebugMode,
  }) : _logger = MCPLogger('LifecycleManager', enableLogging: enableDebugMode);

  final bool enableDebugMode;
  final MCPLogger _logger;
  final Map<LifecycleEvent, List<Function>> _eventListeners = {};

  // Action handler for executing lifecycle hooks
  dynamic _actionHandler;
  dynamic _renderContext;

  /// Sets the action handler for executing lifecycle hooks
  void setActionHandler(dynamic actionHandler, dynamic renderContext) {
    _actionHandler = actionHandler;
    _renderContext = renderContext;
  }

  /// Registers a listener for a specific lifecycle event
  void addListener(LifecycleEvent event, Function listener) {
    _eventListeners.putIfAbsent(event, () => []).add(listener);

    if (enableDebugMode) {
      _logger.debug(' Added listener for ${event.name}');
    }
  }

  /// Removes a listener for a specific lifecycle event
  void removeListener(LifecycleEvent event, Function listener) {
    _eventListeners[event]?.remove(listener);

    if (enableDebugMode) {
      _logger.debug(' Removed listener for ${event.name}');
    }
  }

  /// Executes lifecycle hooks defined in the runtime configuration
  Future<void> executeLifecycleHooks(
    LifecycleEvent event,
    List<dynamic> hooks,
  ) async {
    if (enableDebugMode) {
      _logger.debug(' Executing ${hooks.length} hooks for ${event.name}');
    }

    // Execute registered listeners first
    final listeners = _eventListeners[event];
    if (listeners != null) {
      for (final listener in listeners) {
        try {
          if (listener is Future<void> Function()) {
            await listener();
          } else if (listener is void Function()) {
            listener();
          }
        } catch (error) {
          if (enableDebugMode) {
            _logger.debug(' Error in listener for ${event.name}: $error');
          }
        }
      }
    }

    // Execute hooks from configuration
    for (final hook in hooks) {
      try {
        await _executeHook(event, hook);
      } catch (error) {
        if (enableDebugMode) {
          _logger.debug(' Error executing hook for ${event.name}: $error');
        }
        // Continue with other hooks even if one fails
      }
    }

    if (enableDebugMode) {
      _logger.debug(' Completed hooks for ${event.name}');
    }
  }

  /// Triggers a lifecycle event and executes associated hooks
  Future<void> triggerEvent(LifecycleEvent event, [dynamic data]) async {
    if (enableDebugMode) {
      _logger.debug(' Triggering ${event.name}');
    }

    // Execute registered listeners
    final listeners = _eventListeners[event];
    if (listeners != null) {
      for (final listener in listeners) {
        try {
          if (listener is Future<void> Function(dynamic)) {
            await listener(data);
          } else if (listener is void Function(dynamic)) {
            listener(data);
          } else if (listener is Future<void> Function()) {
            await listener();
          } else if (listener is void Function()) {
            listener();
          }
        } catch (error) {
          if (enableDebugMode) {
            _logger.debug(' Error in listener for ${event.name}: $error');
          }
        }
      }
    }
  }

  /// Executes a single lifecycle hook
  Future<void> _executeHook(LifecycleEvent event, dynamic hook) async {
    if (hook is! Map<String, dynamic>) {
      if (enableDebugMode) {
        _logger.debug(' Invalid hook format for ${event.name}');
      }
      return;
    }

    final hookMap = hook;
    final actionType = hookMap['type'] as String?;

    if (actionType == null) {
      if (enableDebugMode) {
        _logger.debug(' Hook missing type for ${event.name}');
      }
      return;
    }

    // Use ActionHandler to execute the hook
    // Note: This would need to be injected or accessed differently
    // For now, we'll create a placeholder implementation
    switch (actionType) {
      case 'state':
        await _executeStateHook(hookMap);
        break;
      case 'tool':
        await _executeToolHook(hookMap);
        break;
      case 'service':
        await _executeServiceHook(hookMap);
        break;
      case 'notification':
        await _executeNotificationHook(hookMap);
        break;
      case 'resource':
        await _executeResourceHook(hookMap);
        break;
      default:
        // Delegate unknown hook types to ActionHandler so any action type
        // can be used as a lifecycle hook.
        await _dispatchToActionHandler(hookMap, actionType);
        break;
    }
  }

  /// Dispatch a lifecycle hook to the action handler, logging an explicit
  /// error when the handler or render context is missing.
  ///
  /// A null `_renderContext` means [setActionHandler] was never invoked, or
  /// was invoked after lifecycle hooks already started firing — typically
  /// because `onInitialize` ran before `RuntimeEngine._initializeV1Format`
  /// completed wiring. Silently swallowing that condition (the previous
  /// behavior) made the failure invisible. Surfacing it via the logger gives
  /// hosts a chance to spot the ordering bug.
  Future<void> _dispatchToActionHandler(
      Map<String, dynamic> hook, String label) async {
    if (_actionHandler == null || _renderContext == null) {
      _logger.error(
          'Lifecycle hook "$label" dropped: ActionHandler / RenderContext '
          'not yet wired. Hook ran before LifecycleManager.setActionHandler '
          'was invoked — check initialization order.');
      return;
    }
    try {
      await _actionHandler.execute(hook, _renderContext);
    } catch (e, stack) {
      _logger.error('Error executing lifecycle hook "$label"', e, stack);
    }
  }

  /// Executes a resource-related lifecycle hook via ActionHandler
  Future<void> _executeResourceHook(Map<String, dynamic> hook) async {
    if (enableDebugMode) {
      _logger.debug(' Executing resource hook: ${hook['resource']}');
    }
    await _dispatchToActionHandler(hook, 'resource');
  }

  /// Executes a state-related lifecycle hook via ActionHandler
  Future<void> _executeStateHook(Map<String, dynamic> hook) async {
    if (enableDebugMode) {
      _logger.debug(' Executing state hook: ${hook['action']}');
    }
    await _dispatchToActionHandler(hook, 'state');
  }

  /// Executes a tool-related lifecycle hook
  Future<void> _executeToolHook(Map<String, dynamic> hook) async {
    if (enableDebugMode) {
      _logger.debug(' Executing tool hook: ${hook['tool']}');
    }
    await _dispatchToActionHandler(hook, 'tool');
  }

  /// Executes a service-related lifecycle hook via ActionHandler
  Future<void> _executeServiceHook(Map<String, dynamic> hook) async {
    if (enableDebugMode) {
      _logger.debug(' Executing service hook: ${hook['service']}');
    }
    await _dispatchToActionHandler(hook, 'service');
  }

  /// Executes a notification-related lifecycle hook via ActionHandler
  Future<void> _executeNotificationHook(Map<String, dynamic> hook) async {
    if (enableDebugMode) {
      _logger.debug(' Executing notification hook: ${hook['action']}');
    }
    await _dispatchToActionHandler(hook, 'notification');
  }

  /// Convenience method: execute onInitialize lifecycle hooks (app-level)
  Future<void> executeOnInitialize(List<dynamic> hooks) async {
    await executeLifecycleHooks(LifecycleEvent.initialize, hooks);
  }

  /// Convenience method: execute onInit lifecycle hooks (page-level)
  Future<void> executeOnInit(List<dynamic> hooks) async {
    await executeLifecycleHooks(LifecycleEvent.pageInit, hooks);
  }

  /// Convenience method: execute onReady lifecycle hooks
  Future<void> executeOnReady(List<dynamic> hooks) async {
    await executeLifecycleHooks(LifecycleEvent.ready, hooks);
  }

  /// Convenience method: execute onPause lifecycle hooks
  Future<void> executeOnPause(List<dynamic> hooks) async {
    await executeLifecycleHooks(LifecycleEvent.pause, hooks);
  }

  /// Convenience method: execute onResume lifecycle hooks
  Future<void> executeOnResume(List<dynamic> hooks) async {
    await executeLifecycleHooks(LifecycleEvent.resume, hooks);
  }

  /// Convenience method: execute onDispose lifecycle hooks
  Future<void> executeOnDispose(List<dynamic> hooks) async {
    await executeLifecycleHooks(LifecycleEvent.destroy, hooks);
  }

  /// Convenience method: execute onMount lifecycle hooks
  Future<void> executeOnMount(List<dynamic> hooks) async {
    await executeLifecycleHooks(LifecycleEvent.mount, hooks);
  }

  /// Convenience method: execute onUnmount lifecycle hooks
  Future<void> executeOnUnmount(List<dynamic> hooks) async {
    await executeLifecycleHooks(LifecycleEvent.unmount, hooks);
  }

  /// Convenience method: execute onEnter lifecycle hooks (page navigation enter)
  Future<void> executeOnEnter(List<dynamic> hooks) async {
    await executeLifecycleHooks(LifecycleEvent.enter, hooks);
  }

  /// Convenience method: execute onLeave lifecycle hooks (page navigation leave)
  Future<void> executeOnLeave(List<dynamic> hooks) async {
    await executeLifecycleHooks(LifecycleEvent.leave, hooks);
  }

  /// Convenience method: execute page-level onPause lifecycle hooks
  Future<void> executeOnPagePause(List<dynamic> hooks) async {
    await executeLifecycleHooks(LifecycleEvent.pagePause, hooks);
  }

  /// Convenience method: execute page-level onResume lifecycle hooks
  Future<void> executeOnPageResume(List<dynamic> hooks) async {
    await executeLifecycleHooks(LifecycleEvent.pageResume, hooks);
  }

  /// Creates a component lifecycle handler
  ComponentLifecycleHandler createComponentHandler(String componentId) {
    return ComponentLifecycleHandler(
      componentId: componentId,
      lifecycleManager: this,
      enableDebugMode: enableDebugMode,
    );
  }

  /// Disposes of the lifecycle manager and cleans up resources
  void dispose() {
    _eventListeners.clear();

    if (enableDebugMode) {
      _logger.debug(' Disposed');
    }
  }
}

/// Handles lifecycle events for individual components
class ComponentLifecycleHandler {
  ComponentLifecycleHandler({
    required this.componentId,
    required this.lifecycleManager,
    this.enableDebugMode = kDebugMode,
  });

  final String componentId;
  final LifecycleManager lifecycleManager;
  final bool enableDebugMode;
  late final MCPLogger _logger = MCPLogger(
    'ComponentLifecycle:$componentId',
    enableLogging: enableDebugMode,
  );

  bool _isMounted = false;
  Map<String, dynamic>? _lifecycleConfig;

  /// Gets whether the component is currently mounted
  bool get isMounted => _isMounted;

  /// Sets the lifecycle configuration for this component
  void setLifecycleConfig(Map<String, dynamic>? config) {
    _lifecycleConfig = config;
  }

  /// Handles component mount event
  Future<void> mount() async {
    if (_isMounted) return;

    _isMounted = true;

    if (enableDebugMode) {
      _logger.debug('Mounted');
    }

    // Execute onMount hooks if defined
    final onMountHooks = _lifecycleConfig?['onMount'] as List<dynamic>?;
    if (onMountHooks != null) {
      await lifecycleManager.executeLifecycleHooks(
        LifecycleEvent.mount,
        onMountHooks,
      );
    }

    // Trigger global mount event
    await lifecycleManager.triggerEvent(LifecycleEvent.mount, componentId);
  }

  /// Handles component unmount event
  Future<void> unmount() async {
    if (!_isMounted) return;

    if (enableDebugMode) {
      _logger.debug('Unmounting');
    }

    // Execute onUnmount hooks if defined
    final onUnmountHooks = _lifecycleConfig?['onUnmount'] as List<dynamic>?;
    if (onUnmountHooks != null) {
      await lifecycleManager.executeLifecycleHooks(
        LifecycleEvent.unmount,
        onUnmountHooks,
      );
    }

    // Trigger global unmount event
    await lifecycleManager.triggerEvent(LifecycleEvent.unmount, componentId);

    _isMounted = false;

    if (enableDebugMode) {
      _logger.debug('Unmounted');
    }
  }
}
