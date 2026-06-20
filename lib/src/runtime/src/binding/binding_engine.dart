import 'dart:async';
import 'dart:convert';

import '../renderer/render_context.dart';
import 'binding_expression.dart';
import 'client_binding_resolver.dart';
import 'permission_binding_resolver.dart';
import 'channel_binding_resolver.dart';
import 'resource_binding_resolver.dart';
import 'sync_binding_resolver.dart';
import '../i18n/i18n_manager.dart';
import '../utils/mcp_logger.dart';

/// Configuration for expression evaluation sandboxing.
///
/// Provides configurable limits to prevent runaway or deeply nested
/// expressions from consuming excessive resources.
class ExpressionSandbox {
  /// Maximum time allowed for a single expression evaluation (in milliseconds).
  /// Defaults to 1000ms.
  final int timeout;

  /// Maximum nesting depth for recursive expression evaluation.
  /// Defaults to 32.
  final int maxDepth;

  /// Maximum iterations for aggregate operations (filter/reduce/map on lists).
  /// Defaults to 10000.
  final int maxIterations;

  /// Maximum memory usage approximation for expression results.
  /// Defaults to 1MB. Enforced via result size limits since Dart does not
  /// expose direct memory measurement.
  final int maxMemoryBytes;

  const ExpressionSandbox({
    this.timeout = 1000,
    this.maxDepth = 32,
    this.maxIterations = 10000,
    this.maxMemoryBytes = 1024 * 1024,
  });

  /// Create from JSON config (e.g., from runtime definition)
  factory ExpressionSandbox.fromJson(Map<String, dynamic> json) {
    return ExpressionSandbox(
      timeout: json['timeout'] as int? ?? 1000,
      maxDepth: json['maxDepth'] as int? ?? 32,
      maxIterations: json['maxIterations'] as int? ?? 10000,
      maxMemoryBytes: json['maxMemoryBytes'] as int? ?? 1024 * 1024,
    );
  }
}

/// Engine for handling data bindings
class BindingEngine {
  final Map<String, Binding> _bindings = {};
  final Map<String, StreamSubscription> _subscriptions = {};
  final Map<String, Function> _transforms = {};
  final MCPLogger _logger = MCPLogger('BindingEngine');

  /// Sandboxing configuration for expression evaluation
  ExpressionSandbox sandbox = const ExpressionSandbox();

  /// Current evaluation depth (tracked during recursive evaluation)
  int _currentDepth = 0;

  /// Stopwatch for timeout enforcement during expression evaluation
  Stopwatch? _evaluationStopwatch;

  /// v1.1: Client binding resolver for {{client.*}} expressions
  final ClientBindingResolver _clientBindingResolver = ClientBindingResolver();

  /// v1.1: Permission binding resolver for {{permissions.*}} expressions
  final PermissionBindingResolver _permissionBindingResolver =
      PermissionBindingResolver();

  /// v1.1: Channel binding resolver for {{channels.*}} expressions
  final ChannelBindingResolver _channelBindingResolver =
      ChannelBindingResolver();

  /// v1.1: Resource binding resolver for {{resources.*}} expressions
  final ResourceBindingResolver _resourceBindingResolver =
      ResourceBindingResolver();

  /// v1.1: Sync binding resolver for {{sync.*}} expressions
  final SyncBindingResolver _syncBindingResolver = SyncBindingResolver();

  /// Get the permission binding resolver for external configuration
  PermissionBindingResolver get permissionBindingResolver =>
      _permissionBindingResolver;

  /// Get the channel binding resolver for external configuration
  ChannelBindingResolver get channelBindingResolver => _channelBindingResolver;

  /// Get the client binding resolver for external configuration
  ClientBindingResolver get clientBindingResolver => _clientBindingResolver;

  /// Get the resource binding resolver for external configuration
  ResourceBindingResolver get resourceBindingResolver =>
      _resourceBindingResolver;

  /// Get the sync binding resolver for external configuration
  SyncBindingResolver get syncBindingResolver => _syncBindingResolver;

  BindingEngine() {
    _registerDefaultTransforms();
  }

  void _registerDefaultTransforms() {
    _transforms['uppercase'] = (value) => value?.toString().toUpperCase();
    _transforms['lowercase'] = (value) => value?.toString().toLowerCase();
    _transforms['capitalize'] = (value) {
      final str = value?.toString() ?? '';
      if (str.isEmpty) return str;
      return str[0].toUpperCase() + str.substring(1).toLowerCase();
    };
    _transforms['round'] = (value) {
      if (value is num) return value.round();
      return value;
    };
    _transforms['floor'] = (value) {
      if (value is num) return value.floor();
      return value;
    };
    _transforms['ceil'] = (value) {
      if (value is num) return value.ceil();
      return value;
    };
    _transforms['abs'] = (value) {
      if (value is num) return value.abs();
      return value;
    };
    _transforms['truncate'] = (value) {
      if (value is num) return value.truncate();
      return value;
    };
    _transforms['currency'] = (value) {
      if (value is num) return '\$${value.toStringAsFixed(2)}';
      return value;
    };
    _transforms['percentage'] = (value) {
      if (value is num) return '${(value * 100).toStringAsFixed(1)}%';
      return value;
    };
    _transforms['date'] = (value) {
      if (value is String) {
        final dt = DateTime.tryParse(value);
        if (dt != null) {
          return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
        }
      }
      return value;
    };
    _transforms['time'] = (value) {
      if (value is String) {
        final dt = DateTime.tryParse(value);
        if (dt != null) {
          return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
        }
      }
      return value;
    };
    _transforms['json'] = (value) {
      try {
        return const JsonEncoder().convert(value);
      } catch (_) {
        return value?.toString();
      }
    };
    _transforms['padLeft'] = (value) {
      final str = value?.toString() ?? '';
      return str.padLeft(2, '0');
    };
    _transforms['padRight'] = (value) {
      final str = value?.toString() ?? '';
      return str.padRight(2, ' ');
    };
  }

  /// Register a custom transform function
  void registerTransform(String name, Function transform) {
    _transforms[name] = transform;
  }

  /// Register a binding definition
  void registerBinding(Map<String, dynamic> bindingDef) {
    final id = bindingDef['id'] as String;
    final source = bindingDef['source'] as String;
    final path = bindingDef['path'] as String?;
    final defaultValue = bindingDef['default'];
    final transform = bindingDef['transform'] as String?;

    _bindings[id] = Binding(
      id: id,
      source: _parseBindingSource(source),
      path: path,
      defaultValue: defaultValue,
      transform: transform,
    );
  }

  /// Check if a string is a binding expression (single, complete binding)
  bool isBindingExpression(String value) {
    if (!value.startsWith('{{') || !value.endsWith('}}')) {
      return false;
    }

    // Count the number of {{ and }} to ensure it's a single complete binding
    final openCount = RegExp(r'\{\{').allMatches(value).length;
    final closeCount = RegExp(r'\}\}').allMatches(value).length;

    // For a single binding expression, should have exactly one {{ and one }}
    return openCount == 1 && closeCount == 1;
  }

  /// Check if a string contains binding expressions
  bool containsBindingExpression(String value) {
    return value.contains('{{') && value.contains('}}');
  }

  /// Check if text contains any binding expressions
  /// Alias for containsBindingExpression for spec compliance
  bool hasBindings(String text) {
    return containsBindingExpression(text);
  }

  /// Extract all state dependencies from an expression
  Set<String> extractDependencies(String expression) {
    final deps = <String>{};
    final regex = RegExp(r'\{\{(.+?)\}\}');
    for (final match in regex.allMatches(expression)) {
      final expr = match.group(1)!.trim();
      // Extract the root identifier paths
      final identRegex = RegExp(r'[a-zA-Z_]\w*(?:\.[a-zA-Z_]\w*)*');
      for (final identMatch in identRegex.allMatches(expr)) {
        deps.add(identMatch.group(0)!);
      }
    }
    return deps;
  }

  /// Resolve a text template with embedded binding expressions
  /// e.g., "Hello {{name}}, you have {{count}} items"
  String resolveText(String template, RenderContext context) {
    if (!containsBindingExpression(template)) return template;
    return template.replaceAllMapped(
      RegExp(r'\{\{(.+?)\}\}'),
      (match) {
        final result = resolve<dynamic>(match.group(0)!, context);
        return result?.toString() ?? '';
      },
    );
  }

  /// Resolve a value (handle bindings)
  T resolve<T>(dynamic value, RenderContext context) {
    if (value is String) {
      _logger.debug('resolve called with value: "$value" for type: $T');

      // Check for theme binding
      if (value.startsWith('{{theme.') && value.endsWith('}}')) {
        final path = value.substring(8, value.length - 2);
        final themeValue = context.themeManager.getThemeValue(path);
        _logger.debug('Theme binding resolved: $path -> $themeValue');
        if (themeValue != null) {
          return _convertToType<T>(themeValue);
        }
      }

      // v1.1: Check for client binding
      if (_clientBindingResolver.isClientBinding(value)) {
        final clientValue = _clientBindingResolver.resolve(value);
        _logger.debug('Client binding resolved: $value -> $clientValue');
        return _convertToType<T>(clientValue);
      }

      // v1.1: Check for permissions binding
      if (_permissionBindingResolver.isPermissionBinding(value)) {
        final permValue = _permissionBindingResolver.resolve(value);
        _logger.debug('Permission binding resolved: $value -> $permValue');
        return _convertToType<T>(permValue);
      }

      // v1.1: Check for channels binding
      if (_channelBindingResolver.isChannelBinding(value)) {
        final channelValue = _channelBindingResolver.resolve(value);
        _logger.debug('Channel binding resolved: $value -> $channelValue');
        return _convertToType<T>(channelValue);
      }

      // v1.1: Check for resources binding
      if (_resourceBindingResolver.isResourceBinding(value)) {
        final resourceValue = _resourceBindingResolver.resolve(value);
        _logger.debug('Resource binding resolved: $value -> $resourceValue');
        return _convertToType<T>(resourceValue);
      }

      // v1.1: Check for sync binding
      if (_syncBindingResolver.isSyncBinding(value)) {
        final syncValue = _syncBindingResolver.resolve(value);
        _logger.debug('Sync binding resolved: $value -> $syncValue');
        return _convertToType<T>(syncValue);
      }

      if (isBindingExpression(value)) {
        _logger.debug('isBindingExpression true for: "$value"');
        return _resolveBinding<T>(value, context);
      } else if (containsBindingExpression(value)) {
        _logger.debug('containsBindingExpression true for: "$value"');
        return _resolveMixedContent<T>(value, context);
      }
    }

    // Responsive resolution is opt-in (call [RenderContext.pickResponsive]
    // explicitly) — see render_context.dart for the rationale.
    return _convertToType<T>(value);
  }


  /// Convert a value to the requested type
  T _convertToType<T>(dynamic value) {
    // If the value is already of the correct type, return it
    if (value is T) {
      return value;
    }

    // Handle null values
    if (value == null) {
      if (null is T) {
        return null as T;
      }
      // For non-nullable types, provide default values
      if (T == String) return '' as T;
      if (T == int) return 0 as T;
      if (T == double) return 0.0 as T;
      if (T == bool) return false as T;
      throw Exception('Cannot convert null to non-nullable type $T');
    }

    // Handle type conversions to String
    if (T == String || T.toString() == 'String?') {
      return value.toString() as T;
    }

    // Handle type conversions to int
    if (T == int || T.toString() == 'int?') {
      if (value is double) return value.toInt() as T;
      if (value is String) {
        final parsed = int.tryParse(value);
        if (parsed != null) return parsed as T;
        if (null is T) return null as T;
        return 0 as T;
      }
    }

    // Handle type conversions to double
    if (T == double || T.toString() == 'double?') {
      if (value is int) return value.toDouble() as T;
      if (value is String) {
        final parsed = double.tryParse(value);
        if (parsed != null) return parsed as T;
        if (null is T) return null as T;
        return 0.0 as T;
      }
    }

    // Handle type conversions to bool
    if (T == bool || T.toString() == 'bool?') {
      if (value is String) return (value.toLowerCase() == 'true') as T;
      if (value is int) return (value != 0) as T;
    }

    // Default: try direct cast
    return value as T;
  }

  /// Resolve mixed content with embedded bindings
  T _resolveMixedContent<T>(String content, RenderContext context) {
    _logger.debug('_resolveMixedContent called with: $content');
    String result = content;

    // Find all binding expressions in the content
    final bindingPattern = RegExp(r'\{\{([^}]+)\}\}');
    final matches = bindingPattern.allMatches(content);

    for (final match in matches) {
      final fullMatch = match.group(0)!; // e.g., "{{count}}"
      final expression = match.group(1)!; // e.g., "count"

      try {
        // Convert to BindingExpression for evaluation (with caching)
        final parsed = _convertCachedToBinding(expression);
        final resolvedValue = _evaluateExpression(parsed, context);

        // Apply transform if specified
        dynamic finalValue = resolvedValue;
        if (parsed.transform != null &&
            _transforms.containsKey(parsed.transform)) {
          finalValue = _transforms[parsed.transform]!(resolvedValue);
        }

        // Replace the binding with the resolved value (format numbers nicely)
        String valueString;
        if (finalValue == null) {
          // Null values should be rendered as empty strings per spec
          valueString = '';
        } else if (finalValue is double && finalValue == finalValue.toInt()) {
          // If it's a whole number, display without decimal
          valueString = finalValue.toInt().toString();
        } else {
          valueString = finalValue.toString();
        }
        result = result.replaceAll(fullMatch, valueString);
        _logger.debug('Resolved $fullMatch to $finalValue');
      } catch (e) {
        // If evaluation fails, leave the binding as-is
        _logger.warning('Failed to resolve binding $fullMatch: $e');
      }
    }

    _logger.debug('_resolveMixedContent final result: $result');

    return _convertToType<T>(result);
  }

  /// Resolve a binding expression
  T _resolveBinding<T>(String expression, RenderContext context) {
    // Extract expression content
    final expr = expression.substring(2, expression.length - 2).trim();

    // Check for empty expression
    if (expr.isEmpty) {
      _logger.warning('Empty binding expression found: $expression');
      return _convertToType<T>(expression);
    }

    // Convert to BindingExpression for evaluation (with caching)
    final parsed = _convertCachedToBinding(expr);

    // Evaluate expression
    dynamic result = _evaluateExpression(parsed, context);

    // Apply transform if specified
    if (parsed.transform != null && _transforms.containsKey(parsed.transform)) {
      result = _transforms[parsed.transform]!(result);
    }

    return _convertToType<T>(result);
  }

  /// Convert cached expression to BindingExpression
  ///
  /// Uses a secondary cache keyed by expression string to avoid
  /// re-parsing the same expression with BindingExpression.parse().
  static final Map<String, BindingExpression> _bindingExpressionCache = {};

  BindingExpression _convertCachedToBinding(String originalExpr) {
    final existing = _bindingExpressionCache[originalExpr];
    if (existing != null) {
      return existing;
    }
    final parsed = BindingExpression.parse(originalExpr);
    _bindingExpressionCache[originalExpr] = parsed;
    return parsed;
  }

  dynamic _evaluateExpression(BindingExpression expr, RenderContext context) {
    // Start stopwatch at top-level evaluation only
    final isTopLevel = _currentDepth == 0;
    if (isTopLevel) {
      _evaluationStopwatch = Stopwatch()..start();
    }

    // Enforce max depth sandbox limit
    _currentDepth++;
    if (_currentDepth > sandbox.maxDepth) {
      _currentDepth--;
      _logger.warning(
          'Expression evaluation exceeded max depth (${sandbox.maxDepth})');
      return null;
    }

    // Check timeout at each recursive entry
    if (_evaluationStopwatch != null &&
        _evaluationStopwatch!.elapsedMilliseconds > sandbox.timeout) {
      _currentDepth--;
      _logger.warning(
          'Expression evaluation exceeded timeout (${sandbox.timeout}ms)');
      return null;
    }

    try {
      final result = _evaluateExpressionInner(expr, context);
      return _enforceMemoryLimit(result);
    } finally {
      _currentDepth--;
      if (isTopLevel) {
        _evaluationStopwatch?.stop();
        _evaluationStopwatch = null;
      }
    }
  }

  /// Enforce memory limits on expression results (P8: FR-SANDBOX-003)
  dynamic _enforceMemoryLimit(dynamic result) {
    final maxChars = sandbox.maxMemoryBytes ~/ 2;
    if (result is String && result.length > maxChars) {
      _logger.warning('Expression result exceeds memory limit');
      return result.substring(0, maxChars);
    }
    if (result is List && result.length > sandbox.maxIterations) {
      _logger.warning('Expression result list exceeds size limit');
      return result.sublist(0, sandbox.maxIterations);
    }
    return result;
  }

  dynamic _evaluateExpressionInner(
      BindingExpression expr, RenderContext context) {
    // Check if this expression has a literal value (including null literal)
    if (expr.hasValue) {
      return expr.value;
    }

    switch (expr.type) {
      case ExpressionType.simple:
        return _evaluateSimple(expr.path, context);

      case ExpressionType.conditional:
        return _evaluateConditional(expr, context);

      case ExpressionType.arithmetic:
        return _evaluateArithmetic(expr, context);

      case ExpressionType.comparison:
        return _evaluateComparison(expr, context);

      case ExpressionType.logical:
        return _evaluateLogical(expr, context);

      case ExpressionType.nullCoalescing:
        return _evaluateNullCoalescing(expr, context);

      case ExpressionType.methodCall:
        return _evaluateMethodCall(expr, context);

      case ExpressionType.functionCall:
        return _evaluateFunctionCall(expr, context);

      case ExpressionType.optionalChaining:
        return _evaluateOptionalChaining(expr, context);

      case ExpressionType.indexAccess:
        return _evaluateIndexAccess(expr, context);

      case ExpressionType.lambda:
        // Lambda expressions are not directly evaluated; they are used by
        // filter/reduce as predicates. Return the expression itself as a
        // marker so callers can detect and apply it.
        return expr;
    }
  }

  /// Evaluate an optional chaining expression (a?.b?.c)
  dynamic _evaluateOptionalChaining(
      BindingExpression expr, RenderContext context) {
    // Path has already been converted from a?.b?.c to a.b.c
    // We need to safely traverse the path, returning null if any part is null
    final parts = expr.path.split('.');
    dynamic current = context.getValue(parts[0]);

    for (int i = 1; i < parts.length; i++) {
      if (current == null) return null;
      if (current is Map) {
        current = current[parts[i]];
      } else {
        return null;
      }
    }
    return current;
  }

  /// Evaluate an index access expression (items[0], data['key'])
  dynamic _evaluateIndexAccess(BindingExpression expr, RenderContext context) {
    final obj = _evaluateSimple(expr.path, context);
    if (obj == null) return null;

    final index = _evaluateExpression(expr.left!, context);

    if (obj is List && index is num) {
      final idx = index.toInt();
      if (idx >= 0 && idx < obj.length) return obj[idx];
      return null;
    }
    if (obj is Map) {
      return obj[index is String ? index : index.toString()];
    }
    return null;
  }

  /// Evaluate a lambda body expression with a bound parameter.
  ///
  /// Creates a temporary context where the lambda parameter name resolves to
  /// [paramValue], then evaluates the lambda body expression within it.
  dynamic _evaluateLambdaBody(
    BindingExpression lambdaExpr,
    dynamic paramValue,
    RenderContext context,
  ) {
    final paramName = lambdaExpr.parameterName!;
    final body = lambdaExpr.left!;

    // Create a child context with the lambda parameter bound
    final childContext = context.createChildContext(variables: {paramName: paramValue});
    return _evaluateExpression(body, childContext);
  }

  /// Evaluate a simple path expression
  dynamic _evaluateSimple(String path, RenderContext context) {
    // Check for theme path
    if (path.startsWith('theme.')) {
      final themeValue = context.themeManager.getThemeValue(path.substring(6));
      _logger.debug('Theme path resolved: $path -> $themeValue');
      return themeValue;
    }

    // Check for i18n.* prefix - resolves i18n translation keys
    if (path.startsWith('i18n.')) {
      final i18nKey = path.substring(5);
      final translated = I18nManager.instance.translate(i18nKey);
      _logger.debug('I18n binding resolved: $path -> $translated');
      return translated;
    }

    // Check for event.* prefix - resolves event data from render context
    if (path.startsWith('event.')) {
      final eventPath = path.substring(6);
      final eventData = context.getLocal<dynamic>('event');
      if (eventData is Map<String, dynamic>) {
        return _resolveNestedPath(eventData, eventPath);
      }
      _logger.debug('Event binding resolved: $path -> null (no event data)');
      return null;
    }

    // Check for route.params.* prefix - resolves route parameters
    if (path.startsWith('route.params.')) {
      final paramName = path.substring(13);
      final routeParams = context.stateManager.get<dynamic>('route.params');
      if (routeParams is Map<String, dynamic>) {
        return routeParams[paramName];
      }
      return null;
    }

    // Check for sync.* prefix - resolves sync operation status
    if (path.startsWith('sync.')) {
      return _resolveSyncBinding(path.substring(5), context);
    }

    // Check for runtime.* prefix - resolves runtime capability info
    if (path.startsWith('runtime.')) {
      return _resolveRuntimeBinding(path.substring(8), context);
    }

    // Check if this is a registered binding
    if (_bindings.containsKey(path)) {
      final binding = _bindings[path]!;
      // For now, just return the default value
      // In a full implementation, this would connect to the actual data source
      return binding.defaultValue;
    }

    // Handle prefixed paths (app.*, local.*, page.*) via context
    if (path.contains('.')) {
      final prefix = path.substring(0, path.indexOf('.'));
      if (prefix == 'app' || prefix == 'local' || prefix == 'page') {
        final result = context.getValue(path);
        _logger.debug('_evaluateSimple prefixed path: $path, result: $result');
        return result;
      }
    }

    // Non-prefixed fallback chain: local -> page -> app -> theme -> context (final fallback)
    // Follows lexical scoping: inner scope shadows outer scope
    final localResult = context.localVariables[path];
    if (localResult != null) {
      _logger.debug('_evaluateSimple resolved $path from local vars: $localResult');
      return localResult;
    }

    // Try page state
    final pageResult = context.stateManager.get('page.$path');
    if (pageResult != null) {
      _logger.debug('_evaluateSimple resolved $path from page state: $pageResult');
      return pageResult;
    }

    // Try app state
    final appResult = context.stateManager.get('app.$path');
    if (appResult != null) {
      _logger.debug('_evaluateSimple resolved $path from app state: $appResult');
      return appResult;
    }

    // Try theme
    final themeResult = context.themeManager.getThemeValue(path);
    if (themeResult != null) {
      _logger.debug('_evaluateSimple resolved $path from theme: $themeResult');
      return themeResult;
    }

    // Fall back to direct context.getValue (which checks state manager directly)
    final result = context.getValue(path);
    _logger.debug(
        '_evaluateSimple path: $path, result: $result, stateManager: ${context.stateManager.getState()}');
    return result;
  }

  /// Resolve a nested path within a map (e.g., "data.name" in a map)
  dynamic _resolveNestedPath(Map<String, dynamic> map, String path) {
    final parts = path.split('.');
    dynamic current = map;
    for (final part in parts) {
      if (current is Map<String, dynamic>) {
        current = current[part];
      } else {
        return null;
      }
    }
    return current;
  }

  /// Resolve sync.* bindings from the sync manager
  dynamic _resolveSyncBinding(String path, RenderContext context) {
    // Access the sync manager via the runtime engine if available
    final engine = context.engine;
    if (engine == null) {
      _logger.debug('Sync binding: no engine available for $path');
      return null;
    }

    try {
      // Try to get sync manager from the engine
      final syncManager = engine.syncManager;
      if (syncManager == null) {
        _logger.debug('Sync binding: no sync manager available for $path');
        return null;
      }

      switch (path) {
        case 'status':
          return syncManager.status.name;
        case 'saving':
        case 'syncing':
          return syncManager.status.name == 'syncing';
        case 'pending':
          return syncManager.hasPending;
        case 'pendingCount':
          return syncManager.pendingCount;
        case 'lastError':
          return syncManager.lastError;
        case 'lastSyncAt':
        case 'lastSyncTime':
          return syncManager.lastSyncTime?.toIso8601String();
        case 'syncedCount':
          return syncManager.syncedCount;
        case 'failedCount':
          return syncManager.failedCount;
        default:
          _logger.warning('Unknown sync binding path: $path');
          return null;
      }
    } catch (e) {
      _logger.debug('Sync binding resolution failed for $path: $e');
      return null;
    }
  }

  /// Resolve runtime.* bindings for runtime capability info
  dynamic _resolveRuntimeBinding(String path, RenderContext context) {
    switch (path) {
      case 'version':
        // Return the detected MCP UI DSL version
        return '1.1';
      case 'platform':
        return _clientBindingResolver.resolve('{{client.platform}}');
      case 'locale':
        return _clientBindingResolver.resolve('{{client.locale}}');
      case 'debug':
        return _clientBindingResolver.resolve('{{client.isDebug}}');
      default:
        _logger.debug('Unknown runtime binding path: $path');
        return null;
    }
  }

  /// Evaluate a conditional expression
  dynamic _evaluateConditional(BindingExpression expr, RenderContext context) {
    final condition = _evaluateExpression(expr.left!, context);
    if (_isTruthy(condition)) {
      return _evaluateExpression(expr.trueValue!, context);
    } else {
      return _evaluateExpression(expr.falseValue!, context);
    }
  }

  /// Evaluate an arithmetic expression
  dynamic _evaluateArithmetic(BindingExpression expr, RenderContext context) {
    dynamic left = _evaluateExpression(expr.left!, context);
    dynamic right = _evaluateExpression(expr.right!, context);

    // Boolean arithmetic coercion: convert boolean to int (true->1, false->0)
    if (left is bool) left = left ? 1 : 0;
    if (right is bool) right = right ? 1 : 0;

    if (left is num && right is num) {
      switch (expr.operator) {
        case '+':
          return left + right;
        case '-':
          return left - right;
        case '*':
          return left * right;
        case '/':
          if (right == 0) {
            _logger.warning('Division by zero in expression, returning null');
            return null;
          }
          return left / right;
        case '%':
          if (right == 0) {
            _logger.warning('Modulo by zero in expression, returning null');
            return null;
          }
          return left % right;
      }
    }

    // String concatenation
    if (expr.operator == '+') {
      return '${left ?? ''}${right ?? ''}';
    }

    return null;
  }

  /// Evaluate a comparison expression
  bool _evaluateComparison(BindingExpression expr, RenderContext context) {
    final left = _evaluateExpression(expr.left!, context);
    final right = _evaluateExpression(expr.right!, context);

    switch (expr.operator) {
      case '==':
        return left == right;
      case '!=':
        return left != right;
      case '>':
        return (left is num && right is num) ? left > right : false;
      case '<':
        return (left is num && right is num) ? left < right : false;
      case '>=':
        return (left is num && right is num) ? left >= right : false;
      case '<=':
        return (left is num && right is num) ? left <= right : false;
      default:
        return false;
    }
  }

  /// Evaluate a null coalescing expression
  dynamic _evaluateNullCoalescing(
      BindingExpression expr, RenderContext context) {
    final left = _evaluateExpression(expr.left!, context);
    if (left != null) {
      return left;
    }
    return _evaluateExpression(expr.right!, context);
  }

  /// Evaluate a logical expression
  dynamic _evaluateLogical(BindingExpression expr, RenderContext context) {
    switch (expr.operator) {
      case '&&':
        final left = _evaluateExpression(expr.left!, context);
        if (!_isTruthy(left)) return false;
        final right = _evaluateExpression(expr.right!, context);
        return _isTruthy(right);

      case '||':
        // For ||, if left is truthy return left value, otherwise return right value
        // This allows || to work as both logical OR and null coalescing
        final left = _evaluateExpression(expr.left!, context);
        if (_isTruthy(left)) return left;
        return _evaluateExpression(expr.right!, context);

      case '!':
        final operand = _evaluateExpression(expr.left!, context);
        return !_isTruthy(operand);

      default:
        return false;
    }
  }

  /// Evaluate a method call expression
  dynamic _evaluateMethodCall(BindingExpression expr, RenderContext context) {
    // Handle format.number() / format.date() namespace
    if (expr.path == 'format') {
      final args = <dynamic>[];
      if (expr.arguments != null) {
        for (final arg in expr.arguments!) {
          args.add(_evaluateExpression(arg, context));
        }
      }
      return _evaluateFormatCall(expr.methodName!, args);
    }

    // Get the object
    final obj = _evaluateSimple(expr.path, context);
    if (obj == null) return null;

    // Evaluate arguments
    final args = <dynamic>[];
    if (expr.arguments != null) {
      for (final arg in expr.arguments!) {
        args.add(_evaluateExpression(arg, context));
      }
    }

    _logger.debug(
        'Method call: ${expr.methodName} on ${obj.runtimeType} with args: $args');

    // Handle built-in methods
    switch (expr.methodName) {
      case 'toString':
        return obj.toString();

      case 'toStringAsFixed':
        if (obj is num && args.isNotEmpty && args[0] is num) {
          return obj.toStringAsFixed(args[0].toInt());
        }
        break;

      case 'substring':
        if (obj is String) {
          if (args.length == 1 && args[0] is num) {
            return obj.substring(args[0].toInt());
          } else if (args.length == 2 && args[0] is num && args[1] is num) {
            return obj.substring(args[0].toInt(), args[1].toInt());
          }
        }
        break;

      case 'toUpperCase':
        if (obj is String) {
          return obj.toUpperCase();
        }
        break;

      case 'toLowerCase':
        if (obj is String) {
          return obj.toLowerCase();
        }
        break;

      case 'trim':
        if (obj is String) {
          return obj.trim();
        }
        break;

      case 'contains':
        if (obj is String && args.isNotEmpty) {
          return obj.contains(args[0].toString());
        } else if (obj is List && args.isNotEmpty) {
          return obj.contains(args[0]);
        }
        break;

      case 'indexOf':
        if (obj is String && args.isNotEmpty) {
          return obj.indexOf(args[0].toString());
        } else if (obj is List && args.isNotEmpty) {
          return obj.indexOf(args[0]);
        }
        break;

      case 'replaceAll':
        if (obj is String && args.length >= 2) {
          return obj.replaceAll(args[0].toString(), args[1].toString());
        }
        break;

      case 'split':
        if (obj is String && args.isNotEmpty) {
          return obj.split(args[0].toString());
        }
        break;

      case 'join':
        if (obj is List && args.isNotEmpty) {
          return obj.join(args[0].toString());
        }
        break;

      case 'add':
        if (obj is List && args.isNotEmpty) {
          obj.add(args[0]);
          return obj;
        }
        break;

      case 'remove':
        if (obj is List && args.isNotEmpty) {
          obj.remove(args[0]);
          return obj;
        }
        break;

      case 'clear':
        if (obj is List) {
          obj.clear();
          return obj;
        }
        break;

      case 'length':
        if (obj is String) return obj.length;
        if (obj is List) return obj.length;
        if (obj is Map) return obj.length;
        return 0;

      case 'replace':
        // Method form: str.replace(from, to) - use replaceAll for all occurrences
        if (obj is String && args.length >= 2) {
          return obj.replaceAll(args[0].toString(), args[1].toString());
        }
        break;

      case 'startsWith':
        if (obj is String && args.isNotEmpty) {
          return obj.startsWith(args[0].toString());
        }
        break;

      case 'endsWith':
        if (obj is String && args.isNotEmpty) {
          return obj.endsWith(args[0].toString());
        }
        break;

      case 'isEmpty':
        if (obj is String) return obj.isEmpty;
        if (obj is List) return obj.isEmpty;
        if (obj is Map) return obj.isEmpty;
        return true;

      case 'isNotEmpty':
        if (obj is String) return obj.isNotEmpty;
        if (obj is List) return obj.isNotEmpty;
        if (obj is Map) return obj.isNotEmpty;
        return false;

      case 'first':
        if (obj is List && obj.isNotEmpty) return obj.first;
        return null;

      case 'last':
        if (obj is List && obj.isNotEmpty) return obj.last;
        return null;

      case 'reversed':
        if (obj is List) return obj.reversed.toList();
        return null;

      case 'map':
        if (obj is List && args.isNotEmpty) {
          final prop = args[0].toString();
          final limit = sandbox.maxIterations;
          final capped = obj.length > limit ? obj.sublist(0, limit) : obj;
          return capped.map((item) {
            if (item is Map) return item[prop];
            return item;
          }).toList();
        }
        break;

      case 'where':
      case 'filter':
        if (obj is List) {
          final limit = sandbox.maxIterations;
          final capped = obj.length > limit ? obj.sublist(0, limit) : obj;
          // Support lambda: items.filter(item => item.price > 100)
          if (expr.arguments != null && expr.arguments!.length == 1 &&
              expr.arguments![0].type == ExpressionType.lambda) {
            final lambdaExpr = expr.arguments![0];
            return capped.where((item) {
              final result = _evaluateLambdaBody(lambdaExpr, item, context);
              if (result is bool) return result;
              return result != null;
            }).toList();
          }
          // Support property/value shorthand: items.filter(prop, value)
          if (args.length >= 2) {
            final prop = args[0].toString();
            final value = args[1];
            return capped.where((item) {
              if (item is Map) return item[prop] == value;
              return false;
            }).toList();
          }
          // Support object shorthand: items.filter({property: 'status', value: 'active'})
          if (args.length == 1 && args[0] is Map) {
            final filterConfig = args[0] as Map;
            final prop = filterConfig['property']?.toString();
            final value = filterConfig['value'];
            if (prop != null) {
              return capped.where((item) {
                if (item is Map) return item[prop] == value;
                return false;
              }).toList();
            }
          }
        }
        break;

      case 'reduce':
        if (obj is List) {
          final limit = sandbox.maxIterations;
          final capped = obj.length > limit ? obj.sublist(0, limit) : obj;
          // Support lambda: items.reduce((acc, item) => acc + item.price, 0)
          // For simplicity, lambda reduce uses single-param form that maps
          // each item, then sums. Full two-param accumulator lambdas are
          // complex to parse; use property reduction for accumulator patterns.
          if (expr.arguments != null && expr.arguments!.isNotEmpty &&
              expr.arguments![0].type == ExpressionType.lambda) {
            final lambdaExpr = expr.arguments![0];
            num initialValue = 0;
            if (args.length >= 2 && args[1] is num) {
              initialValue = args[1] as num;
            }
            dynamic accumulator = initialValue;
            for (var i = 0; i < capped.length; i++) {
              // Periodic timeout check during iteration
              if (i % 100 == 0 && _evaluationStopwatch != null &&
                  _evaluationStopwatch!.elapsedMilliseconds > sandbox.timeout) {
                _logger.warning('Reduce iteration timeout exceeded');
                break;
              }
              final mapped = _evaluateLambdaBody(lambdaExpr, capped[i], context);
              if (mapped is num) {
                accumulator = (accumulator as num) + mapped;
              }
            }
            return accumulator;
          }
          // Support property reduction: items.reduce(prop)
          if (args.isNotEmpty) {
            final prop = args[0].toString();
            num sum = 0;
            for (var i = 0; i < capped.length; i++) {
              if (i % 100 == 0 && _evaluationStopwatch != null &&
                  _evaluationStopwatch!.elapsedMilliseconds > sandbox.timeout) {
                _logger.warning('Reduce iteration timeout exceeded');
                break;
              }
              final item = capped[i];
              if (item is Map && item[prop] is num) {
                sum += item[prop] as num;
              }
            }
            return sum;
          }
          // Sum numeric items directly
          num sum = 0;
          for (var i = 0; i < capped.length; i++) {
            if (i % 100 == 0 && _evaluationStopwatch != null &&
                _evaluationStopwatch!.elapsedMilliseconds > sandbox.timeout) {
              _logger.warning('Reduce iteration timeout exceeded');
              break;
            }
            final item = capped[i];
            if (item is num) sum += item;
          }
          return sum;
        }
        break;
    }

    _logger.warning('Unknown method: ${expr.methodName} on ${obj.runtimeType}');
    return null;
  }

  /// Evaluate a function call expression
  dynamic _evaluateFunctionCall(BindingExpression expr, RenderContext context) {
    // Evaluate arguments
    final args = <dynamic>[];
    if (expr.arguments != null) {
      for (final arg in expr.arguments!) {
        args.add(_evaluateExpression(arg, context));
      }
    }

    // Handle built-in functions
    switch (expr.methodName) {
      case 'min':
        if (args.length == 2 && args[0] is num && args[1] is num) {
          return args[0] < args[1] ? args[0] : args[1];
        }
        break;

      case 'max':
        if (args.length == 2 && args[0] is num && args[1] is num) {
          return args[0] > args[1] ? args[0] : args[1];
        }
        break;

      case 'abs':
        if (args.isNotEmpty && args[0] is num) {
          return args[0].abs();
        }
        break;

      case 'round':
        if (args.isNotEmpty && args[0] is num) {
          // Support optional digits parameter: round(value, digits)
          if (args.length >= 2 && args[1] is num) {
            final digits = (args[1] as num).toInt();
            final multiplier = _pow10(digits);
            return ((args[0] as num) * multiplier).round() / multiplier;
          }
          return args[0].round();
        }
        break;

      case 'floor':
        if (args.isNotEmpty && args[0] is num) {
          return args[0].floor();
        }
        break;

      case 'ceil':
        if (args.isNotEmpty && args[0] is num) {
          return args[0].ceil();
        }
        break;

      case 'parseInt':
        if (args.isNotEmpty) {
          return int.tryParse(args[0].toString());
        }
        break;

      case 'parseDouble':
        if (args.isNotEmpty) {
          return double.tryParse(args[0].toString());
        }
        break;

      case 'now':
        return DateTime.now().toIso8601String();

      case 'length':
        if (args.isNotEmpty) {
          final val = args[0];
          if (val is String) return val.length;
          if (val is List) return val.length;
          if (val is Map) return val.length;
        }
        return 0;

      // Independent function forms of string methods
      case 'toUpperCase':
        if (args.isNotEmpty) {
          return args[0].toString().toUpperCase();
        }
        break;

      case 'toLowerCase':
        if (args.isNotEmpty) {
          return args[0].toString().toLowerCase();
        }
        break;

      case 'trim':
        if (args.isNotEmpty) {
          return args[0].toString().trim();
        }
        break;

      case 'contains':
        if (args.length >= 2) {
          if (args[0] is String) {
            return (args[0] as String).contains(args[1].toString());
          }
          if (args[0] is List) {
            return (args[0] as List).contains(args[1]);
          }
        }
        break;

      case 'substring':
        if (args.isNotEmpty && args[0] is String) {
          if (args.length == 2 && args[1] is num) {
            return (args[0] as String).substring((args[1] as num).toInt());
          } else if (args.length >= 3 && args[1] is num && args[2] is num) {
            return (args[0] as String).substring(
                (args[1] as num).toInt(), (args[2] as num).toInt());
          }
        }
        break;

      case 'replace':
        // replace(str, from, to) - use replaceAll for all occurrences
        if (args.length >= 3 && args[0] is String) {
          return (args[0] as String)
              .replaceAll(args[1].toString(), args[2].toString());
        }
        break;

      case 'format':
        if (args.isNotEmpty && args.length >= 2) {
          final value = args[0];
          final pattern = args[1].toString();

          // Date formatting: format(date, 'YYYY-MM-DD')
          if (value is String) {
            final dt = DateTime.tryParse(value);
            if (dt != null) {
              return _formatDate(dt, pattern);
            }
          }

          // Number formatting: format(price, '#,##0.00')
          if (value is num) {
            return _formatNumber(value, pattern);
          }

          return value.toString();
        }
        if (args.isNotEmpty) {
          return args[0].toString();
        }
        break;

      case 'map':
        // map(array, key) - extract property from each item
        if (args.length >= 2 && args[0] is List) {
          final list = args[0] as List;
          final limit = sandbox.maxIterations;
          final capped = list.length > limit ? list.sublist(0, limit) : list;
          final prop = args[1].toString();
          return capped.map((item) {
            if (item is Map) return item[prop];
            return item;
          }).toList();
        }
        break;

      case 'filter':
        // filter(list, lambda) - filter with lambda predicate
        if (args.length >= 2 && args[0] is List && args[1] is BindingExpression) {
          final list = args[0] as List;
          final limit = sandbox.maxIterations;
          final capped = list.length > limit ? list.sublist(0, limit) : list;
          final lambdaExpr = args[1] as BindingExpression;
          return capped.where((item) {
            final result = _evaluateLambdaBody(lambdaExpr, item, context);
            if (result is bool) return result;
            return result != null;
          }).toList();
        }
        // filter(list, property, value) - filter list items where item[property] == value
        if (args.length >= 3 && args[0] is List) {
          final list = args[0] as List;
          final limit = sandbox.maxIterations;
          final capped = list.length > limit ? list.sublist(0, limit) : list;
          final prop = args[1].toString();
          final value = args[2];
          return capped.where((item) {
            if (item is Map) return item[prop] == value;
            return false;
          }).toList();
        }
        break;

      case 'reduce':
        // reduce(list, lambda, initialValue) - reduce with lambda mapper
        if (args.length >= 2 && args[0] is List && args[1] is BindingExpression) {
          final list = args[0] as List;
          final limit = sandbox.maxIterations;
          final capped = list.length > limit ? list.sublist(0, limit) : list;
          final lambdaExpr = args[1] as BindingExpression;
          num initialValue = 0;
          if (args.length >= 3 && args[2] is num) {
            initialValue = args[2] as num;
          }
          dynamic accumulator = initialValue;
          for (final item in capped) {
            final mapped = _evaluateLambdaBody(lambdaExpr, item, context);
            if (mapped is num) {
              accumulator = (accumulator as num) + mapped;
            }
          }
          return accumulator;
        }
        // reduce(list, property) - sum numeric values of property in list
        if (args.length >= 2 && args[0] is List) {
          final list = args[0] as List;
          final limit = sandbox.maxIterations;
          final capped = list.length > limit ? list.sublist(0, limit) : list;
          final prop = args[1].toString();
          num sum = 0;
          for (final item in capped) {
            if (item is Map && item[prop] is num) {
              sum += item[prop] as num;
            }
          }
          return sum;
        }
        break;

      case 'split':
        // split(text, separator) - independent function form
        if (args.length >= 2 && args[0] is String) {
          return (args[0] as String).split(args[1].toString());
        }
        break;

      case 'join':
        // join(array, separator) - independent function form
        if (args.length >= 2 && args[0] is List) {
          return (args[0] as List).join(args[1].toString());
        }
        break;

      case 'calculateDuration':
        // calculateDuration(startDate, endDate, unit?) → num?
        // Returns duration between two ISO 8601 date strings
        // unit: 'days' (default), 'hours', 'minutes', 'seconds', 'milliseconds'
        if (args.length >= 2) {
          final start = DateTime.tryParse(args[0].toString());
          final end = DateTime.tryParse(args[1].toString());
          if (start == null || end == null) return null;
          final duration = end.difference(start);
          final unit = args.length >= 3 ? args[2].toString() : 'days';
          switch (unit) {
            case 'milliseconds':
              return duration.inMilliseconds;
            case 'seconds':
              return duration.inSeconds;
            case 'minutes':
              return duration.inMinutes;
            case 'hours':
              return duration.inHours;
            case 'days':
            default:
              return duration.inDays;
          }
        }
        return null;
    }

    _logger.warning('Unknown function: ${expr.methodName}');
    return null;
  }

  /// Helper: compute 10^n
  static num _pow10(int n) {
    num result = 1;
    for (int i = 0; i < n; i++) {
      result *= 10;
    }
    return result;
  }

  /// Format a DateTime according to a pattern string
  /// Supports: YYYY, YY, MM, DD, HH, hh, mm, ss, SSS
  /// Evaluate format.number() / format.date() calls per spec
  /// format.number(value, style, currencyCode)
  /// format.date(value, style)
  dynamic _evaluateFormatCall(String method, List<dynamic> args) {
    if (args.isEmpty) return null;

    switch (method) {
      case 'number':
        final value = args[0] is num
            ? args[0] as num
            : num.tryParse(args[0].toString());
        if (value == null) return args[0].toString();

        final style = args.length > 1 ? args[1].toString() : 'decimal';
        switch (style) {
          case 'currency':
            final code = args.length > 2 ? args[2].toString() : 'USD';
            final symbol = _currencySymbols[code] ?? code;
            return '$symbol${_formatNumber(value, '#,##0.00')}';
          case 'percent':
            return '${(value * 100).toStringAsFixed(0)}%';
          case 'decimal':
          default:
            return _formatNumber(value, '#,##0.##');
        }

      case 'date':
        DateTime? dt;
        if (args[0] is String) {
          dt = DateTime.tryParse(args[0] as String);
        }
        if (dt == null) return args[0].toString();

        final style = args.length > 1 ? args[1].toString() : 'medium';
        switch (style) {
          case 'short':
            return _formatDate(dt, 'MM/DD/YY');
          case 'long':
            return _formatDate(dt, 'YYYY-MM-DD HH:mm:ss');
          case 'full':
            return _formatDate(dt, 'YYYY-MM-DD HH:mm:ss.SSS');
          case 'medium':
          default:
            return _formatDate(dt, 'YYYY-MM-DD');
        }

      default:
        return args[0].toString();
    }
  }

  /// Common currency symbols
  static const Map<String, String> _currencySymbols = {
    'USD': '\$', 'EUR': '€', 'GBP': '£', 'JPY': '¥',
    'KRW': '₩', 'CNY': '¥', 'INR': '₹', 'BRL': 'R\$',
    'RUB': '₽', 'TRY': '₺', 'THB': '฿', 'CHF': 'CHF ',
  };

  String _formatDate(DateTime dt, String pattern) {
    String result = pattern;
    result = result.replaceAll('YYYY', dt.year.toString().padLeft(4, '0'));
    result = result.replaceAll('YY', (dt.year % 100).toString().padLeft(2, '0'));
    result = result.replaceAll('MM', dt.month.toString().padLeft(2, '0'));
    result = result.replaceAll('DD', dt.day.toString().padLeft(2, '0'));
    result = result.replaceAll('HH', dt.hour.toString().padLeft(2, '0'));
    result = result.replaceAll('hh', (dt.hour > 12 ? dt.hour - 12 : dt.hour).toString().padLeft(2, '0'));
    result = result.replaceAll('mm', dt.minute.toString().padLeft(2, '0'));
    result = result.replaceAll('ss', dt.second.toString().padLeft(2, '0'));
    result = result.replaceAll('SSS', dt.millisecond.toString().padLeft(3, '0'));
    return result;
  }

  /// Format a number according to a pattern string
  /// Supports patterns like '#,##0.00', '#,##0', '0.00'
  String _formatNumber(num value, String pattern) {
    // Determine decimal places from pattern
    final dotIndex = pattern.indexOf('.');
    int decimals = 0;
    if (dotIndex >= 0) {
      decimals = pattern.length - dotIndex - 1;
    }

    // Format with specified decimal places
    String formatted = value.toStringAsFixed(decimals);

    // Add thousands separator if pattern contains comma
    if (pattern.contains(',')) {
      final parts = formatted.split('.');
      final intPart = parts[0];
      final buffer = StringBuffer();
      int count = 0;
      final startIndex = intPart.startsWith('-') ? 1 : 0;

      for (int i = intPart.length - 1; i >= startIndex; i--) {
        if (count > 0 && count % 3 == 0) {
          buffer.write(',');
        }
        buffer.write(intPart[i]);
        count++;
      }

      String result = String.fromCharCodes(buffer.toString().codeUnits.reversed);
      if (startIndex == 1) result = '-$result';
      if (parts.length > 1) {
        result = '$result.${parts[1]}';
      }
      formatted = result;
    }

    return formatted;
  }

  /// Check if a value is truthy
  bool _isTruthy(dynamic value) {
    if (value == null) return false;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value.isNotEmpty;
    if (value is List) return value.isNotEmpty;
    if (value is Map) return value.isNotEmpty;
    return true;
  }

  /// Parse binding source from string
  BindingSource _parseBindingSource(String source) {
    switch (source) {
      case 'state':
        return BindingSource.state;
      case 'tool':
        return BindingSource.tool;
      case 'stream':
        return BindingSource.stream;
      case 'resource':
        return BindingSource.resource;
      default:
        return BindingSource.state;
    }
  }

  /// Clear static caches used by the binding engine
  static void clearStaticCaches() {
    _bindingExpressionCache.clear();
  }

  /// Dispose resources
  void dispose() {
    for (final subscription in _subscriptions.values) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _bindings.clear();

    _transforms.clear();
    _registerDefaultTransforms(); // Re-register default transforms
  }
}

/// Binding definition
class Binding {
  final String id;
  final BindingSource source;
  final String? path;
  final dynamic defaultValue;
  final String? transform;

  Binding({
    required this.id,
    required this.source,
    this.path,
    this.defaultValue,
    this.transform,
  });
}

/// Binding source types
enum BindingSource {
  state,
  tool,
  stream,
  resource,
}
