import '../binding/binding_engine.dart';
import '../renderer/render_context.dart';
import 'event_system.dart';

/// Event delegation for MCP UI DSL v1.1
///
/// Provides event delegation support, allowing parent components to handle
/// events from child components using conditional matching.
///
/// Delegation reduces the number of event listeners needed by allowing
/// a single parent handler to manage events from multiple children.
///
/// When a `when` condition is a string expression and a [BindingEngine] is
/// available, the condition is evaluated via the full expression language
/// (comparisons, method calls, ternary, etc.). Event data is injected into
/// the binding context under the `event.*` prefix.
///
/// Example DSL usage:
/// ```json
/// {
///   "on": {
///     "click": {
///       "delegate": true,
///       "when": "event.targetId.startsWith('item-')",
///       "action": { "type": "setState", "path": "selected", "value": "{{event.data.id}}" }
///     }
///   }
/// }
/// ```
class EventDelegate {
  /// Optional binding engine for evaluating `when` expressions using the
  /// full expression language. When provided, string conditions are
  /// delegated to the engine instead of the simple regex-based parser.
  final BindingEngine? _bindingEngine;

  /// Optional render context used as the base context for expression
  /// evaluation. Event-specific data is merged in before evaluation.
  final RenderContext? _renderContext;

  /// The event name this delegate handles (per 07-events.md §9).
  final String? eventName;

  /// The handler callback for delegated events (per 07-events.md §9).
  final void Function(dynamic eventData)? handler;

  /// The parent widget definition this delegate is attached to.
  Map<String, dynamic>? _attachedParent;

  EventDelegate({
    BindingEngine? bindingEngine,
    RenderContext? renderContext,
    this.eventName,
    this.handler,
  })  : _bindingEngine = bindingEngine,
        _renderContext = renderContext;

  /// Attach delegation to a parent widget definition.
  /// Child events matching [eventName] are forwarded to [handler].
  void attach(Map<String, dynamic> parentDefinition) {
    _attachedParent = parentDefinition;
    if (eventName != null && handler != null) {
      final on = parentDefinition.putIfAbsent('on', () => <String, dynamic>{});
      if (on is Map<String, dynamic>) {
        on[eventName!] = {
          'delegate': true,
          'action': 'custom',
        };
      }
    }
  }

  /// Detach delegation from the parent widget definition.
  void detach() {
    if (_attachedParent != null && eventName != null) {
      final on = _attachedParent!['on'];
      if (on is Map<String, dynamic>) {
        on.remove(eventName);
      }
    }
    _attachedParent = null;
  }

  /// Check if an event handler should fire based on 'when' condition
  ///
  /// The [whenCondition] can be:
  /// - A [String] expression to evaluate against the event
  /// - A [Map] with field matchers (e.g., {'targetId': 'button-1'})
  /// - A [bool] value for unconditional handling
  /// - `null` to always handle the event
  ///
  /// When a [BindingEngine] is available, string conditions are evaluated
  /// via the full expression language. Otherwise the legacy regex-based
  /// parser is used as a fallback.
  bool shouldHandle(UIEvent event, dynamic whenCondition) {
    if (whenCondition == null) {
      return true;
    }

    if (whenCondition is bool) {
      return whenCondition;
    }

    if (whenCondition is String) {
      // Prefer BindingEngine for full expression language support
      if (_bindingEngine != null && _renderContext != null) {
        return _evaluateWithBindingEngine(event, whenCondition);
      }
      return _evaluateStringCondition(event, whenCondition);
    }

    if (whenCondition is Map<String, dynamic>) {
      return _evaluateMapCondition(event, whenCondition);
    }

    return true;
  }

  /// Static convenience for callers that do not have a BindingEngine.
  /// Delegates to the legacy regex-based evaluation.
  static bool shouldHandleStatic(UIEvent event, dynamic whenCondition) {
    final delegate = EventDelegate();
    return delegate.shouldHandle(event, whenCondition);
  }

  /// Evaluate a string condition using the BindingEngine.
  ///
  /// Injects event properties (type, targetId, data fields) into a child
  /// render context under the `event.*` prefix, then delegates evaluation
  /// to the binding engine. This supports the full expression language
  /// including comparisons, method calls, ternary, null coalescing, etc.
  bool _evaluateWithBindingEngine(UIEvent event, String condition) {
    try {
      // Build event data map for binding context injection
      final eventData = <String, dynamic>{
        'type': event.type,
        'targetId': event.targetId,
        'phase': event.phase.name,
      };

      // Merge event.data fields if available
      if (event.data is Map<String, dynamic>) {
        eventData['data'] = event.data;
      } else if (event.data != null) {
        eventData['data'] = event.data;
      }

      // Create a child context with event data injected as local variables
      final evalContext = _renderContext!.createChildContext(
        variables: {'event': eventData},
      );

      // Wrap the condition in binding syntax if not already wrapped
      final expr = condition.contains('{{') ? condition : '{{$condition}}';
      final result = _bindingEngine!.resolve<dynamic>(expr, evalContext);

      // Coerce the result to a boolean
      if (result is bool) return result;
      if (result is String) return result.isNotEmpty && result != 'false';
      return result != null;
    } catch (_) {
      // Fall back to legacy evaluation on any error
      return _evaluateStringCondition(event, condition);
    }
  }

  /// Create an event handler with delegation support
  ///
  /// Parameters:
  /// - [handler]: The actual event handler to invoke
  /// - [delegate]: Whether this handler uses delegation (handles child events)
  /// - [when]: Condition that must be met for the handler to fire
  /// - [propagation]: Controls propagation behavior ('stop', 'stopImmediate', 'preventDefault')
  /// - [bindingEngine]: Optional engine for full expression evaluation
  /// - [renderContext]: Optional context for expression evaluation
  static void Function(UIEvent) createDelegatedHandler({
    required void Function(UIEvent) handler,
    bool delegate = false,
    String? when,
    String? propagation,
    BindingEngine? bindingEngine,
    RenderContext? renderContext,
  }) {
    final eventDelegate = EventDelegate(
      bindingEngine: bindingEngine,
      renderContext: renderContext,
    );

    return (UIEvent event) {
      // For delegated handlers, only process events from children (not self)
      if (delegate && event.phase == EventPhase.target) {
        // In delegation mode, we only handle bubbled events
        // Skip if this is a direct target event (non-delegated)
        return;
      }

      // Check 'when' condition
      if (when != null && !eventDelegate.shouldHandle(event, when)) {
        return;
      }

      // Apply propagation control before handling
      _applyPropagation(event, propagation);

      // Invoke the actual handler
      handler(event);
    };
  }

  /// Create a handler that filters events by target ID pattern
  ///
  /// The [pattern] supports:
  /// - Exact match: 'button-1'
  /// - Prefix match: 'item-*'
  /// - Suffix match: '*-delete'
  /// - Contains match: '*item*'
  static void Function(UIEvent) createFilteredHandler({
    required void Function(UIEvent) handler,
    required String pattern,
    String? propagation,
  }) {
    return (UIEvent event) {
      if (event.targetId == null) return;

      if (!_matchesPattern(event.targetId!, pattern)) {
        return;
      }

      _applyPropagation(event, propagation);
      handler(event);
    };
  }

  /// Evaluate a string condition against an event using regex-based parsing
  ///
  /// Supports simple expressions:
  /// - 'type == "click"' - match event type
  /// - 'targetId == "btn-1"' - match target ID
  /// - 'targetId.startsWith("item-")' - prefix matching
  /// - 'data.status == "active"' - data field matching
  static bool _evaluateStringCondition(UIEvent event, String condition) {
    final trimmed = condition.trim();

    // Strip optional 'event.' prefix so both 'event.type == ...' and
    // 'type == ...' work with the legacy parser.
    final normalized = trimmed.startsWith('event.')
        ? trimmed.substring(6)
        : trimmed;

    // Handle 'type == "value"' pattern
    final typeMatch = RegExp(r'^type\s*==\s*["\x27](.+?)["\x27]$').firstMatch(normalized);
    if (typeMatch != null) {
      return event.type == typeMatch.group(1);
    }

    // Handle 'targetId == "value"' pattern
    final targetMatch =
        RegExp(r'^targetId\s*==\s*["\x27](.+?)["\x27]$').firstMatch(normalized);
    if (targetMatch != null) {
      return event.targetId == targetMatch.group(1);
    }

    // Handle 'targetId.startsWith("prefix")' pattern
    final startsWithMatch =
        RegExp(r'^targetId\.startsWith\(["\x27](.+?)["\x27]\)$')
            .firstMatch(normalized);
    if (startsWithMatch != null) {
      return event.targetId?.startsWith(startsWithMatch.group(1)!) ?? false;
    }

    // Handle 'targetId.endsWith("suffix")' pattern
    final endsWithMatch =
        RegExp(r'^targetId\.endsWith\(["\x27](.+?)["\x27]\)$')
            .firstMatch(normalized);
    if (endsWithMatch != null) {
      return event.targetId?.endsWith(endsWithMatch.group(1)!) ?? false;
    }

    // Handle 'targetId.contains("substring")' pattern
    final containsMatch =
        RegExp(r'^targetId\.contains\(["\x27](.+?)["\x27]\)$')
            .firstMatch(normalized);
    if (containsMatch != null) {
      return event.targetId?.contains(containsMatch.group(1)!) ?? false;
    }

    // Handle 'data.field == "value"' pattern
    final dataMatch =
        RegExp(r'^data\.(\w+)\s*==\s*["\x27](.+?)["\x27]$').firstMatch(normalized);
    if (dataMatch != null) {
      final field = dataMatch.group(1)!;
      final value = dataMatch.group(2)!;
      if (event.data is Map<String, dynamic>) {
        return (event.data as Map<String, dynamic>)[field]?.toString() == value;
      }
      return false;
    }

    // Unknown condition format - default to true for forward compatibility
    return true;
  }

  /// Evaluate a map condition against an event
  ///
  /// Each key-value pair in the map must match for the condition to pass.
  /// Supported keys: 'type', 'targetId', 'phase', 'data.*'
  static bool _evaluateMapCondition(
      UIEvent event, Map<String, dynamic> condition) {
    for (final entry in condition.entries) {
      switch (entry.key) {
        case 'type':
          if (event.type != entry.value) return false;
          break;
        case 'targetId':
          if (entry.value is String && !_matchesPattern(event.targetId ?? '', entry.value as String)) {
            return false;
          }
          break;
        case 'phase':
          if (event.phase.name != entry.value) return false;
          break;
        default:
          // Check data fields (e.g., 'data.status')
          if (entry.key.startsWith('data.') && event.data is Map) {
            final dataKey = entry.key.substring(5);
            if ((event.data as Map)[dataKey]?.toString() !=
                entry.value?.toString()) {
              return false;
            }
          }
          break;
      }
    }
    return true;
  }

  /// Apply propagation control to an event
  static void _applyPropagation(UIEvent event, String? propagation) {
    if (propagation == null) return;

    switch (propagation) {
      case 'stop':
        event.stopPropagation();
        break;
      case 'stopImmediate':
        event.stopImmediatePropagation();
        break;
      case 'preventDefault':
        event.preventDefault();
        break;
      case 'stopAll':
        event.stopImmediatePropagation();
        event.preventDefault();
        break;
    }
  }

  /// Check if a string matches a glob-like pattern
  ///
  /// Supports:
  /// - '*' at start: suffix match
  /// - '*' at end: prefix match
  /// - '*' at both: contains match
  /// - No '*': exact match
  static bool _matchesPattern(String value, String pattern) {
    if (pattern == '*') return true;

    final startsWithWild = pattern.startsWith('*');
    final endsWithWild = pattern.endsWith('*');

    if (startsWithWild && endsWithWild) {
      // Contains match
      final inner = pattern.substring(1, pattern.length - 1);
      return value.contains(inner);
    } else if (startsWithWild) {
      // Suffix match
      final suffix = pattern.substring(1);
      return value.endsWith(suffix);
    } else if (endsWithWild) {
      // Prefix match
      final prefix = pattern.substring(0, pattern.length - 1);
      return value.startsWith(prefix);
    } else {
      // Exact match
      return value == pattern;
    }
  }
}
