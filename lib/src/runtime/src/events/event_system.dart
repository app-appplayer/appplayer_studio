import 'dart:async';

import 'event_delegate.dart';

/// Event phases for MCP UI DSL v1.1
///
/// Follows the W3C event propagation model:
/// - [capture]: Event travels down from root to target
/// - [target]: Event is at the target element
/// - [bubble]: Event travels up from target to root
enum EventPhase {
  /// Capture phase - event propagates from root to target
  capture,

  /// Target phase - event is at the target element
  target,

  /// Bubble phase - event propagates from target to root
  bubble,
}

/// UI Event with propagation support for MCP UI DSL v1.1
///
/// Represents a custom event that can be emitted, listened to,
/// and propagated through the component tree.
class UIEvent {
  /// The event type identifier (e.g., 'click', 'submit', 'custom.update')
  final String type;

  /// Optional event payload data
  final dynamic data;

  /// Current propagation phase of this event
  final EventPhase phase;

  /// ID of the target component that originated this event
  final String? targetId;

  /// Timestamp when the event was created
  final DateTime timestamp;

  bool _stopped = false;
  bool _immediateStopped = false;
  bool _defaultPrevented = false;

  UIEvent({
    required this.type,
    this.data,
    this.phase = EventPhase.target,
    this.targetId,
  }) : timestamp = DateTime.now();

  /// Create a copy of this event with a different phase.
  ///
  /// Propagation state is intentionally NOT copied so that each phase
  /// starts clean; the shared [_stopped] / [_immediateStopped] flags on
  /// the *original* event are what [EventBus.dispatchEvent] checks between
  /// phases. [isDefaultPrevented] is preserved because it is a semantic
  /// flag independent of propagation.
  UIEvent withPhase(EventPhase newPhase) {
    final event = UIEvent(
      type: type,
      data: data,
      phase: newPhase,
      targetId: targetId,
    );
    if (_defaultPrevented) event.preventDefault();
    return event;
  }

  /// Stop event from propagating further
  void stopPropagation() {
    _stopped = true;
  }

  /// Stop event from propagating and prevent other listeners on same target
  void stopImmediatePropagation() {
    _stopped = true;
    _immediateStopped = true;
  }

  /// Prevent the default action associated with this event
  void preventDefault() {
    _defaultPrevented = true;
  }

  /// Whether propagation has been stopped
  bool get isStopped => _stopped;

  /// Whether immediate propagation has been stopped
  bool get isImmediateStopped => _immediateStopped;

  /// Whether the default action has been prevented
  bool get isDefaultPrevented => _defaultPrevented;
}

/// Event bus for cross-component communication in MCP UI DSL v1.1
///
/// Provides a publish-subscribe pattern for decoupled component communication.
/// Components can emit events and listen for events by type.
///
/// Example usage:
/// ```dart
/// final bus = EventBus();
///
/// // Listen for events
/// bus.on('item.selected', (event) {
///   final itemId = event.data['id'];
/// });
///
/// // Emit an event
/// bus.emit('item.selected', data: {'id': '123'});
/// ```
/// A tree-aware event listener registered for a specific widget and event type.
class _TreeListener {
  /// Widget ID this listener is attached to
  final String widgetId;

  /// Event type this listener handles
  final String eventType;

  /// The handler callback
  final void Function(UIEvent) handler;

  /// Whether this listener fires during the capture phase
  final bool capture;

  /// Optional `when` condition evaluated before invoking [handler]
  final String? when;

  /// Whether this is a delegate listener (handles child events)
  final bool delegate;

  _TreeListener({
    required this.widgetId,
    required this.eventType,
    required this.handler,
    this.capture = false,
    this.when,
    this.delegate = false,
  });
}

class EventBus {
  final Map<String, StreamController<UIEvent>> _controllers = {};
  final Map<String, List<StreamSubscription<UIEvent>>> _subscriptions = {};

  /// Tree-aware listeners keyed by event type, then widget ID
  final Map<String, Map<String, List<_TreeListener>>> _treeListeners = {};

  /// Emit a custom event to all listeners of the given type
  void emit(String eventType, {dynamic data, String? targetId}) {
    final controller = _controllers[eventType];
    if (controller != null && !controller.isClosed) {
      final event = UIEvent(
        type: eventType,
        data: data,
        targetId: targetId,
      );
      controller.add(event);
    }
  }

  /// Listen to events of a specific type.
  ///
  /// Returns a [StreamSubscription] that can be used to cancel the listener.
  /// Optionally filter events by [filter] which matches against the targetId.
  ///
  /// When [when] is provided, it is evaluated as a condition string before
  /// invoking [handler]. The condition uses the same syntax supported by
  /// [EventDelegate.shouldHandle] (e.g., `"event.data.status == 'active'"`).
  StreamSubscription<UIEvent> on(
    String eventType,
    void Function(UIEvent) handler, {
    String? filter,
    String? when,
  }) {
    // Create controller if it doesn't exist
    _controllers.putIfAbsent(
      eventType,
      () => StreamController<UIEvent>.broadcast(),
    );

    Stream<UIEvent> stream = _controllers[eventType]!.stream;

    // Apply target filter if specified
    if (filter != null) {
      stream = stream.where((event) => event.targetId == filter);
    }

    // Apply `when` condition filter if specified
    if (when != null) {
      final whenExpr = when;
      stream = stream.where(
        (event) => EventDelegate.shouldHandleStatic(event, whenExpr),
      );
    }

    final subscription = stream.listen(handler);

    // Track subscriptions for cleanup
    _subscriptions.putIfAbsent(eventType, () => []);
    _subscriptions[eventType]!.add(subscription);

    return subscription;
  }

  /// Listen to an event type, but only fire once
  StreamSubscription<UIEvent> once(
    String eventType,
    void Function(UIEvent) handler, {
    String? filter,
  }) {
    late StreamSubscription<UIEvent> subscription;
    subscription = on(eventType, (event) {
      handler(event);
      subscription.cancel();
      _subscriptions[eventType]?.remove(subscription);
    }, filter: filter);
    return subscription;
  }

  /// Remove a specific event handler by subscription (per 07-events.md §8).
  ///
  /// Cancels the given [subscription] and removes it from internal tracking.
  /// If the event type has no remaining listeners, its controller is closed.
  void off(StreamSubscription subscription) {
    subscription.cancel();

    // Remove from tracking and clean up empty controllers
    for (final eventType in _subscriptions.keys.toList()) {
      final subs = _subscriptions[eventType];
      if (subs != null && subs.remove(subscription)) {
        // If no more subscriptions, close controller
        if (subs.isEmpty) {
          _subscriptions.remove(eventType);
          final controller = _controllers.remove(eventType);
          if (controller != null && !controller.isClosed) {
            controller.close();
          }
        }
        break;
      }
    }
  }

  /// Remove all listeners for an event type.
  void offAll(String eventType) {
    final subs = _subscriptions.remove(eventType);
    if (subs != null) {
      for (final sub in subs) {
        sub.cancel();
      }
    }

    final controller = _controllers.remove(eventType);
    if (controller != null && !controller.isClosed) {
      controller.close();
    }
  }

  /// Check if there are any listeners for the given event type
  bool hasListeners(String eventType) {
    return _controllers.containsKey(eventType) &&
        _subscriptions.containsKey(eventType) &&
        _subscriptions[eventType]!.isNotEmpty;
  }

  /// Get the number of listeners for the given event type
  int listenerCount(String eventType) {
    return _subscriptions[eventType]?.length ?? 0;
  }

  // ---------------------------------------------------------------------------
  // Tree-based event dispatch (W3C 3-phase propagation)
  // ---------------------------------------------------------------------------

  /// Register a tree-aware listener for a specific widget and event type.
  ///
  /// Unlike [on], tree listeners participate in 3-phase propagation via
  /// [dispatchEvent]. Set [capture] to `true` to receive events during the
  /// capture phase (root-to-target). By default, listeners fire during the
  /// bubble phase (target-to-root).
  ///
  /// An optional [when] condition string is evaluated before the handler is
  /// invoked using [EventDelegate.shouldHandleStatic].
  void registerTreeListener(
    String widgetId,
    String eventType,
    void Function(UIEvent) handler, {
    bool capture = false,
    String? when,
  }) {
    final listener = _TreeListener(
      widgetId: widgetId,
      eventType: eventType,
      handler: handler,
      capture: capture,
      when: when,
    );
    _treeListeners
        .putIfAbsent(eventType, () => {})
        .putIfAbsent(widgetId, () => [])
        .add(listener);
  }

  /// Register a delegate listener on [parentId] for [eventType].
  ///
  /// Delegate listeners only fire during the bubble phase when a *child*
  /// event reaches the parent. They skip events whose target is the parent
  /// itself, matching the semantics of event delegation where a parent
  /// manages events on behalf of its children.
  void registerDelegate(
    String parentId,
    String eventType,
    void Function(UIEvent) handler, {
    String? when,
  }) {
    final listener = _TreeListener(
      widgetId: parentId,
      eventType: eventType,
      handler: handler,
      capture: false,
      when: when,
      delegate: true,
    );
    _treeListeners
        .putIfAbsent(eventType, () => {})
        .putIfAbsent(parentId, () => [])
        .add(listener);
  }

  /// Remove all tree listeners for a given widget.
  void removeTreeListeners(String widgetId) {
    for (final byWidget in _treeListeners.values) {
      byWidget.remove(widgetId);
    }
  }

  /// Dispatch an event through the widget tree using W3C 3-phase propagation.
  ///
  /// [event] is the event to dispatch.
  /// [targetId] is the widget ID where the event originated.
  /// [ancestorIds] is the path from root to the target's direct parent,
  /// ordered root-first (i.e., `[rootId, ..., parentId]`).
  ///
  /// Phase 1 – Capture: iterate [ancestorIds] from root to parent, invoking
  ///   capture listeners on each node.
  /// Phase 2 – Target: invoke listeners registered on [targetId].
  /// Phase 3 – Bubble: iterate [ancestorIds] in reverse (parent to root),
  ///   invoking bubble listeners on each node.
  ///
  /// Propagation respects [UIEvent.stopPropagation] and
  /// [UIEvent.stopImmediatePropagation].
  void dispatchEvent(
    UIEvent event,
    String targetId,
    List<String> ancestorIds,
  ) {
    final byWidget = _treeListeners[event.type];
    if (byWidget == null) return;

    // Phase 1: Capture (root → target)
    for (final ancestorId in ancestorIds) {
      if (event.isStopped) return;
      final listeners = byWidget[ancestorId];
      if (listeners == null) continue;
      _invokeListeners(
        listeners.where((l) => l.capture && !l.delegate),
        event,
        EventPhase.capture,
        targetId,
      );
    }

    if (event.isStopped) return;

    // Phase 2: Target
    final targetListeners = byWidget[targetId];
    if (targetListeners != null) {
      _invokeListeners(
        targetListeners.where((l) => !l.delegate),
        event,
        EventPhase.target,
        targetId,
      );
    }

    if (event.isStopped) return;

    // Phase 3: Bubble (target → root)
    for (final ancestorId in ancestorIds.reversed) {
      if (event.isStopped) return;
      final listeners = byWidget[ancestorId];
      if (listeners == null) continue;
      _invokeListeners(
        // Include delegate listeners during bubble phase (they skip target)
        listeners.where((l) => !l.capture),
        event,
        EventPhase.bubble,
        targetId,
      );
    }
  }

  /// Invoke a set of listeners for a given phase, respecting propagation
  /// flags and `when` conditions.
  void _invokeListeners(
    Iterable<_TreeListener> listeners,
    UIEvent event,
    EventPhase phase,
    String targetId,
  ) {
    final phaseEvent = event.withPhase(phase);

    for (final listener in listeners) {
      if (event.isImmediateStopped) return;

      // Delegate listeners skip events targeting the parent itself
      if (listener.delegate && targetId == listener.widgetId) continue;

      // Evaluate `when` condition
      if (listener.when != null &&
          !EventDelegate.shouldHandleStatic(phaseEvent, listener.when)) {
        continue;
      }

      try {
        listener.handler(phaseEvent);
      } catch (_) {
        // Catch and continue propagation per design spec section 13
      }

      // Sync propagation state back to the original event
      if (phaseEvent.isStopped) event.stopPropagation();
      if (phaseEvent.isImmediateStopped) event.stopImmediatePropagation();
    }
  }

  /// Dispose all event streams and cancel all subscriptions
  void dispose() {
    // Cancel all subscriptions
    for (final subs in _subscriptions.values) {
      for (final sub in subs) {
        sub.cancel();
      }
    }
    _subscriptions.clear();

    // Close all controllers
    for (final controller in _controllers.values) {
      if (!controller.isClosed) {
        controller.close();
      }
    }
    _controllers.clear();

    // Clear tree listeners
    _treeListeners.clear();
  }
}
