import 'package:flutter/material.dart';
import 'renderer.dart';
import '../binding/binding_engine.dart';
import '../actions/action_handler.dart';
import '../state/state_manager.dart';
import '../theme/theme_manager.dart';
import '../i18n/i18n_manager.dart';
import '../utils/mcp_logger.dart';

/// Render context that provides access to runtime services during widget rendering
class RenderContext {
  static final MCPLogger _logger = MCPLogger('RenderContext');
  final Renderer renderer;
  final StateManager stateManager;
  final BindingEngine bindingEngine;
  final ActionHandler actionHandler;
  final ThemeManager themeManager;
  final String? parentId;
  final Map<String, dynamic> localVariables;
  final List<String> _idPath;
  final BuildContext? buildContext;

  /// The RuntimeEngine instance. Typed as dynamic to avoid circular import
  /// (RuntimeEngine imports render_context.dart). Use [runtimeEngine] getter
  /// for type-safe access.
  final dynamic engine;
  final bool Function(String action, String route, Map<String, dynamic> params)?
      navigationHandler;
  final Future<dynamic> Function(
          String resource, String method, String target, dynamic data)?
      resourceHandler;

  RenderContext({
    required this.renderer,
    required this.stateManager,
    required this.bindingEngine,
    required this.actionHandler,
    required this.themeManager,
    this.parentId,
    this.buildContext,
    this.engine,
    this.navigationHandler,
    this.resourceHandler,
    Map<String, dynamic>? localVariables,
    List<String>? idPath,
  })  : localVariables = localVariables ?? {},
        _idPath = idPath ?? [];

  /// Type-safe access to the RuntimeEngine instance.
  /// Returns the engine cast to its actual type. Avoids circular import
  /// since RuntimeEngine imports render_context.dart.
  /// Usage: context.runtimeEngine (instead of context.engine)
  T getEngine<T>() => engine as T;

  /// Create a child context with additional local variables
  RenderContext createChildContext({
    String? id,
    Map<String, dynamic>? variables,
  }) {
    final childVars = Map<String, dynamic>.from(localVariables);
    if (variables != null) {
      childVars.addAll(variables);
    }

    final childPath = List<String>.from(_idPath);
    if (id != null) {
      childPath.add(id);
    }

    return RenderContext(
      renderer: renderer,
      stateManager: stateManager,
      bindingEngine: bindingEngine,
      actionHandler: actionHandler,
      themeManager: themeManager,
      parentId: id ?? parentId,
      buildContext: buildContext,
      engine: engine,
      navigationHandler: navigationHandler,
      resourceHandler: resourceHandler,
      localVariables: childVars,
      idPath: childPath,
    );
  }

  /// Generate a unique ID for the current context
  String get contextId => _idPath.join('.');

  /// Resolve a value that might contain bindings
  T resolve<T>(dynamic value) {
    if (value == null) return null as T;

    // Responsive override resolution is opt-in via [pickResponsive] —
    // factories that accept a per-form-factor override map call it
    // explicitly. Auto-detection here is unsafe because configuration
    // maps that happen to be keyed by FormFactor labels (notably
    // `theme.breakpoints: {compact: 0, medium: 600, …}` per § 14.1.2)
    // would otherwise be hijacked and collapsed to a single value.

    // Handle different value types
    if (value is Map<String, dynamic>) {
      // Check if it's an action definition (has 'type' property)
      // Action objects should not be resolved even if they have a 'binding' property
      if (value.containsKey('type')) {
        // This is likely an action or widget definition, not a binding
        // Don't try to resolve it as a binding
        return value as T;
      }

      // Check if it's a binding definition
      if (value.containsKey('binding')) {
        return bindingEngine.resolve<T>(value['binding'], this);
      }
      // Otherwise resolve each value in the map
      final resolved = <String, dynamic>{};
      for (final entry in value.entries) {
        resolved[entry.key] = resolve(entry.value);
      }
      return resolved as T;
    } else if (value is List) {
      // Resolve each item in the list
      return value.map((item) => resolve(item)).toList() as T;
    } else if (value is String) {
      // Check for i18n strings first
      if (value.startsWith('i18n:')) {
        final translated = I18nManager.instance.resolveI18nString(value);
        return (translated ?? value) as T;
      }
      // Check if it contains any binding expressions
      if (value.contains('{{') && value.contains('}}')) {
        return bindingEngine.resolve<T>(value, this);
      }
    }

    return value as T;
  }

  /// Build a child widget
  Widget buildWidget(Map<String, dynamic> definition) {
    return renderer.renderWidget(definition, this);
  }

  /// Handle an action
  Future<void> handleAction(Map<String, dynamic>? action) async {
    if (action == null) return;

    // Resolve any bindings in the action
    final resolvedAction = resolve<Map<String, dynamic>>(action);
    await actionHandler.execute(resolvedAction, this);
  }

  /// Get current theme
  ThemeData get theme => themeManager.currentTheme;

  /// Get a value from state (handles local.* and app.* prefixes per v1.0 spec)
  T? getState<T>(String path) {
    // Handle v1.0 state prefixes
    if (path.startsWith('local.')) {
      // Page-local state (stored in localVariables)
      final localPath = path.substring(6);
      return localVariables[localPath] as T?;
    } else if (path.startsWith('app.')) {
      // Global application state
      final globalPath = path.substring(4);
      final result = stateManager.get<T>(globalPath);
      _logger.debug('getState app.$globalPath: $result');
      return result;
    } else {
      // No prefix - default to global state for backward compatibility
      final result = stateManager.get<T>(path);
      _logger.debug('getState path: $path, result: $result');
      return result;
    }
  }

  /// Set a value in state (handles local.* and app.* prefixes per v1.0 spec).
  ///
  /// [source] tags the resulting [StateChangeEvent] per spec §3.11.
  /// Callers that originate from a `state` action should pass `'action'`;
  /// the default `null` causes the underlying [StateManager.set] to leave
  /// the source unset (treated as `system` downstream).
  void setState(String path, dynamic value, {String? source}) {
    // Handle v1.0 state prefixes
    if (path.startsWith('local.')) {
      // Page-local state (stored in localVariables) — no change event.
      final localPath = path.substring(6);
      localVariables[localPath] = value;
      _logger.debug('setState local.$localPath: $value');
    } else if (path.startsWith('app.')) {
      // Global application state
      final globalPath = path.substring(4);
      stateManager.set(globalPath, value, source: source);
      _logger.debug('setState app.$globalPath: $value');
    } else {
      // No prefix - default to global state for backward compatibility
      stateManager.set(path, value, source: source);
      _logger.debug('setState path: $path, value: $value');
    }
  }

  /// Update state
  void updateState(Map<String, dynamic> updates) {
    stateManager.updateAll(updates);
  }

  /// Get a value from state (alias for getState)
  T? getValue<T>(String path) {
    // Check local variables first (including nested paths)
    if (path.contains('.')) {
      final parts = path.split('.');
      final firstPart = parts[0];

      // Check if the first part is in local variables
      if (localVariables.containsKey(firstPart)) {
        dynamic current = localVariables[firstPart];

        // Navigate the rest of the path
        for (int i = 1; i < parts.length; i++) {
          if (current is Map<String, dynamic>) {
            current = current[parts[i]];
          } else {
            return null;
          }
        }

        return current as T?;
      }
    } else if (localVariables.containsKey(path)) {
      return localVariables[path] as T?;
    }

    // Check for complex paths like items[index].name
    if (path.contains('[') && path.contains(']')) {
      // Parse the path
      final match = RegExp(r'(\w+)\[(\w+)\](?:\.(.+))?').firstMatch(path);
      if (match != null) {
        final arrayName = match.group(1)!;
        final indexName = match.group(2)!;
        final propertyPath = match.group(3);

        // Get the index value from local variables
        final indexValue = localVariables[indexName];
        if (indexValue is int) {
          // Get the array from state
          final array = getState<List<dynamic>>(arrayName);
          if (array != null && indexValue < array.length) {
            final item = array[indexValue];
            if (propertyPath != null && item is Map<String, dynamic>) {
              // Navigate the property path
              dynamic current = item;
              for (final part in propertyPath.split('.')) {
                if (current is Map<String, dynamic>) {
                  current = current[part];
                } else {
                  return null;
                }
              }
              return current as T?;
            } else {
              return item as T?;
            }
          }
        }
      }
    }

    return getState<T>(path);
  }

  /// Set a value in state (alias for setState).
  ///
  /// [source] forwards to [setState] for spec §3.11 source tagging.
  void setValue(String path, dynamic value, {String? source}) {
    setState(path, value, source: source);
  }

  /// Get a local variable
  T? getLocal<T>(String key) {
    return localVariables[key] as T?;
  }

  /// Set a local variable
  void setLocal(String key, dynamic value) {
    localVariables[key] = value;
  }

  /// Get the current list item (from list/grid context)
  dynamic get item => getLocal<dynamic>('item');

  /// Get the current list index
  int? get index => getLocal<int>('index');

  /// Check if this is the first item in the list
  bool? get isFirst => getLocal<bool>('isFirst');

  /// Check if this is the last item in the list
  bool? get isLast => getLocal<bool>('isLast');

  /// Check if this item is at an even index
  bool? get isEven => getLocal<bool>('isEven');

  /// Check if this item is at an odd index
  bool? get isOdd => getLocal<bool>('isOdd');

  /// Create a child context with list item data
  RenderContext withItem(dynamic item, int index, int total) {
    return createChildContext(variables: {
      'item': item,
      'index': index,
      'isFirst': index == 0,
      'isLast': index == total - 1,
      'isEven': index.isEven,
      'isOdd': index.isOdd,
    });
  }

  /// Check if a condition is true
  bool checkCondition(dynamic condition) {
    if (condition == null) return true;
    if (condition is bool) return condition;
    if (condition is String) {
      final resolved = resolve<dynamic>(condition);
      if (resolved is bool) return resolved;
      if (resolved is String) {
        // Handle string conditions
        return resolved.isNotEmpty && resolved.toLowerCase() != 'false';
      }
      return resolved != null;
    }
    if (condition is Map<String, dynamic>) {
      // Handle complex conditions
      return _evaluateComplexCondition(condition);
    }
    return true;
  }

  bool _evaluateComplexCondition(Map<String, dynamic> condition) {
    final operator = condition['operator'] as String?;
    final left = resolve<dynamic>(condition['left']);
    final right = resolve<dynamic>(condition['right']);

    switch (operator) {
      case '==':
      case 'equals':
        return left == right;
      case '!=':
      case 'notEquals':
        return left != right;
      case '>':
      case 'greaterThan':
        return _compareNumeric(left, right) > 0;
      case '>=':
      case 'greaterThanOrEquals':
        return _compareNumeric(left, right) >= 0;
      case '<':
      case 'lessThan':
        return _compareNumeric(left, right) < 0;
      case '<=':
      case 'lessThanOrEquals':
        return _compareNumeric(left, right) <= 0;
      case 'contains':
        if (left is String && right is String) return left.contains(right);
        if (left is List) return left.contains(right);
        if (left is Map) return left.containsKey(right);
        return false;
      case 'startsWith':
        if (left is String && right is String) return left.startsWith(right);
        return false;
      case 'endsWith':
        if (left is String && right is String) return left.endsWith(right);
        return false;
      case 'matches':
        if (left is String && right is String) {
          try {
            return RegExp(right).hasMatch(left);
          } catch (e) {
            return false;
          }
        }
        return false;
      case 'and':
      case '&&':
        final conditions = condition['conditions'] as List?;
        if (conditions != null) {
          return conditions.every((c) => checkCondition(c));
        }
        return checkCondition(left) && checkCondition(right);
      case 'or':
      case '||':
        final conditions = condition['conditions'] as List?;
        if (conditions != null) {
          return conditions.any((c) => checkCondition(c));
        }
        return checkCondition(left) || checkCondition(right);
      case 'not':
      case '!':
        return !checkCondition(left ?? condition['condition']);
      default:
        return true;
    }
  }

  int _compareNumeric(dynamic a, dynamic b) {
    final numA = _toNumber(a);
    final numB = _toNumber(b);
    if (numA == null || numB == null) return 0;
    return numA.compareTo(numB);
  }

  num? _toNumber(dynamic value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value);
    return null;
  }

  /// Get resource subscribe handler
  Function(String, String)? get onResourceSubscribe =>
      engine?.onResourceSubscribe as Function(String, String)?;

  /// Get resource unsubscribe handler
  Function(String)? get onResourceUnsubscribe =>
      engine?.onResourceUnsubscribe as Function(String)?;

  /// Optional host-supplied callback for the spec §4.5 `read` sub-action.
  /// Hosts that want `read` to behave as a true one-shot fetch — rather
  /// than re-using `subscribe` semantics — register this callback. It
  /// returns the resource payload directly; the runtime stores it at the
  /// declared binding without subscribing.
  Function(String uri, String binding)? get onResourceRead =>
      engine?.onResourceRead as Function(String, String)?;

  /// Optional host-supplied callback for the spec §4.5 `list` sub-action.
  /// Hosts that want `list` to behave as a true directory query — rather
  /// than re-using `subscribe` semantics — register this callback. It
  /// returns a list of resource descriptors; the runtime stores the list
  /// at the declared binding without subscribing.
  Function(String uri, String binding)? get onResourceList =>
      engine?.onResourceList as Function(String, String)?;

  /// Format a value using a formatter
  String format(dynamic value, String? formatter) {
    if (formatter == null) return value.toString();

    // Handle common formatters
    switch (formatter) {
      case 'uppercase':
        return value.toString().toUpperCase();
      case 'lowercase':
        return value.toString().toLowerCase();
      case 'capitalize':
        final str = value.toString();
        if (str.isEmpty) return str;
        return str[0].toUpperCase() + str.substring(1).toLowerCase();
      case 'trim':
        return value.toString().trim();
      case 'currency':
        if (value is num) {
          return '\$${value.toStringAsFixed(2)}';
        }
        break;
      case 'percent':
        if (value is num) {
          return '${(value * 100).toStringAsFixed(1)}%';
        }
        break;
      case 'date':
        if (value is DateTime) {
          return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
        }
        break;
      case 'time':
        if (value is DateTime) {
          return '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
        }
        break;
      case 'datetime':
        if (value is DateTime) {
          return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
              '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
        }
        break;
    }

    return value.toString();
  }

  /// Pick the form-factor-specific entry from a responsive map, or
  /// return null when [value] is not a responsive map. A map qualifies
  /// when **every** key is one of the canonical FormFactor labels
  /// (`compact` / `medium` / `expanded` / `large` / `extraLarge` /
  /// `embedded`) plus the optional `default`. Falls back to a smaller
  /// class when the active one is missing (extraLarge → large → expanded
  /// → medium → compact → default).
  ///
  /// **Opt-in**: factories that accept per-form-factor overrides should
  /// call this BEFORE other parsing. [resolve] does not auto-call it —
  /// theme tables (notably `theme.breakpoints`) share the same key
  /// shape and must not be collapsed.
  dynamic pickResponsive(Map value) => _pickResponsive(value);

  dynamic _pickResponsive(Map value) {
    const ffKeys = {
      'compact',
      'medium',
      'expanded',
      'large',
      'extraLarge',
      'embedded',
    };
    // Strict detection: only treat as a responsive override map when
    // EVERY key is a FormFactor label (plus the optional `default`).
    // A map that mixes FF-shaped keys with arbitrary other fields (e.g.
    // a widget definition that happens to use `medium` as a value
    // somewhere) must not be auto-picked — that broke rendering before.
    final allowedKeys = {...ffKeys, 'default'};
    if (value.isEmpty) return null;
    final hasFf = value.keys.any((k) => ffKeys.contains(k));
    if (!hasFf) return null;
    final allKeysAllowed =
        value.keys.every((k) => allowedKeys.contains(k));
    if (!allKeysAllowed) return null;
    final ctx = buildContext;
    final activeKey = ctx == null ? 'compact' : _formFactorKey(ctx);
    if (activeKey == 'embedded') {
      if (value.containsKey('embedded')) return value['embedded'];
      if (value.containsKey('compact')) return value['compact'];
      if (value.containsKey('default')) return value['default'];
      return null;
    }
    const order = ['extraLarge', 'large', 'expanded', 'medium', 'compact'];
    final start = order.indexOf(activeKey);
    if (start < 0) return value['default'];
    for (var i = start; i < order.length; i++) {
      final k = order[i];
      if (value.containsKey(k)) return value[k];
    }
    if (value.containsKey('default')) return value['default'];
    return null;
  }

  String _formFactorKey(BuildContext context) {
    final width = MediaQuery.maybeSizeOf(context)?.width ?? 0;
    if (width < 600) return 'compact';
    if (width < 840) return 'medium';
    if (width < 1200) return 'expanded';
    if (width < 1600) return 'large';
    return 'extraLarge';
  }
}
