import 'package:flutter/foundation.dart';
import '../utils/json_path.dart';
import '../utils/mcp_logger.dart';

/// Represents a computed property that derives its value from other state
/// according to MCP UI DSL v1.0 specification.
///
/// Once [ManagedComputedProperty] from `computed_manager.dart` (which delegates
/// expression evaluation to [BindingEngine]) supports all the features below,
/// this class should be replaced. Until then it remains the active implementation
/// used by [StateManager].
///
/// Features not yet available in [ManagedComputedProperty]:
/// - Ternary operator evaluation (`condition ? trueValue : falseValue`)
/// - Logical operator evaluation (`&&`, `||`)
/// - Comparison operators (`>`, `<`, `>=`, `<=`, `==`, `!=`)
/// - Arithmetic operators (`+`, `-`, `*`, `/`, `%`)
/// - Pipe/transform operations (`| uppercase`, `| round`, etc.)
/// - Function calls (`length()`, `sum()`)
/// - Array access with index expressions
/// - Circular dependency detection
class ComputedProperty {
  ComputedProperty({
    required this.name,
    required this.expression,
    required this.compute,
    this.dependencies = const [],
    this.enableDebugMode = kDebugMode,
  }) : _logger = MCPLogger('ComputedProperty[$name]',
            enableLogging: enableDebugMode);

  /// The name/path of this computed property
  final String name;

  /// The expression string used to compute this property
  final String expression;

  /// Function that computes the property value from state
  final dynamic Function(Map<String, dynamic> state) compute;

  /// List of state paths this property depends on
  final List<String> dependencies;

  /// Whether debug mode is enabled
  final bool enableDebugMode;

  /// Logger instance
  final MCPLogger _logger;

  /// Static logger for static methods
  static final _staticLogger = MCPLogger('ComputedProperty');

  dynamic _cachedValue;
  bool _isInitialized = false;
  bool _isComputing = false;

  /// Gets the cached value if available
  dynamic get cachedValue => _cachedValue;

  /// Gets whether this property has been computed
  bool get isInitialized => _isInitialized;

  /// Computes and caches the property value
  dynamic computeAndCache(Map<String, dynamic> state) {
    if (_isComputing) {
      // Circular dependency detected: return null and log warning instead of throwing
      _logger.warning('Circular dependency detected in computed property: $name, returning null');
      return null;
    }

    try {
      _isComputing = true;
      _cachedValue = compute(state);
      _isInitialized = true;

      _logger.debug('Computed property "$name" = $_cachedValue');

      return _cachedValue;
    } catch (error) {
      _logger.error('Error computing property "$name": $error');
      rethrow;
    } finally {
      _isComputing = false;
    }
  }

  /// Invalidates the cached value
  void invalidate() {
    _cachedValue = null;
    _isInitialized = false;

    _logger.debug('Invalidated computed property "$name"');
  }

  /// Checks if any of the dependencies have changed
  bool shouldRecompute(Map<String, String> changedPaths) {
    for (final dependency in dependencies) {
      if (changedPaths.containsKey(dependency)) {
        return true;
      }

      // Check if any changed path is a parent or child of this dependency
      for (final changedPath in changedPaths.keys) {
        if (changedPath.startsWith('$dependency.') ||
            dependency.startsWith('$changedPath.')) {
          return true;
        }
      }
    }
    return false;
  }

  /// Creates a computed property from an expression string
  static ComputedProperty fromExpression(String name, String expression,
      {List<String>? dependencies}) {
    return ComputedProperty(
      name: name,
      expression: expression,
      dependencies: dependencies ?? _extractDependencies(expression),
      compute: (state) => _evaluateExpression(expression, state),
    );
  }

  /// Extracts dependency paths from an expression
  static List<String> _extractDependencies(String expression) {
    final dependencies = <String>[];
    final regex = RegExp(r'\{\{([^}]+)\}\}');
    final matches = regex.allMatches(expression);

    for (final match in matches) {
      final content = match.group(1)?.trim();
      if (content != null) {
        // Extract the main variable name (before any operators or functions)
        final parts = content.split(RegExp(r'[\s\+\-\*\/\|\&\>\<\!\=\?\:]'));
        final mainVar = parts.first.trim();

        // Remove function calls and pipes
        final cleanVar = mainVar.split('(').first.split('|').first.trim();

        if (cleanVar.isNotEmpty && !_isLiteral(cleanVar)) {
          dependencies.add(cleanVar);
        }
      }
    }

    return dependencies.toSet().toList(); // Remove duplicates
  }

  /// Evaluates an expression against the current state
  static dynamic _evaluateExpression(
      String expression, Map<String, dynamic> state) {
    // Simple expression evaluation
    // This is a basic implementation - a real implementation might use a proper expression parser

    try {
      // Handle simple variable substitution
      final regex = RegExp(r'\{\{([^}]+)\}\}');
      String result = expression;

      final matches = regex.allMatches(expression).toList();
      for (final match in matches.reversed) {
        final content = match.group(1)?.trim();
        if (content != null) {
          final value = _evaluateExpressionContent(content, state);
          result =
              result.replaceRange(match.start, match.end, value.toString());
        }
      }

      // If the entire expression was a single substitution, return the actual value
      if (matches.length == 1 &&
          matches.first.start == 0 &&
          matches.first.end == expression.length) {
        final content = matches.first.group(1)?.trim();
        if (content != null) {
          return _evaluateExpressionContent(content, state);
        }
      }

      return result;
    } catch (error) {
      _staticLogger.error(
          'Error evaluating expression "$expression": $error');
      return null;
    }
  }

  /// Evaluates the content inside {{ }}
  static dynamic _evaluateExpressionContent(
      String content, Map<String, dynamic> state) {
    content = content.trim();

    // Handle string literals
    if ((content.startsWith('"') && content.endsWith('"')) ||
        (content.startsWith("'") && content.endsWith("'"))) {
      return content.substring(1, content.length - 1);
    }

    // Handle boolean and null literals
    if (content == 'true') return true;
    if (content == 'false') return false;
    if (content == 'null') return null;

    // Handle numeric literals
    final numValue = num.tryParse(content);
    if (numValue != null) return numValue;

    // Handle ternary operator (condition ? trueValue : falseValue)
    if (content.contains('?') && content.contains(':')) {
      return _evaluateTernary(content, state);
    }

    // Handle logical operators
    if (content.contains('&&') || content.contains('||')) {
      return _evaluateLogical(content, state);
    }

    // Handle comparison operators
    if (RegExp(r'[><=!]=?').hasMatch(content)) {
      return _evaluateComparison(content, state);
    }

    // Handle arithmetic operators
    if (RegExp(r'[\+\-\*\/\%]').hasMatch(content)) {
      return _evaluateArithmetic(content, state);
    }

    // Handle pipe operations (transforms)
    if (content.contains('|')) {
      return _evaluatePipe(content, state);
    }

    // Handle function calls
    if (content.contains('(') && content.contains(')')) {
      return _evaluateFunction(content, state);
    }

    // Handle array access
    if (content.contains('[') && content.contains(']')) {
      return _evaluateArrayAccess(content, state);
    }

    // Handle simple variable access
    return _getStateValue(content, state);
  }

  /// Gets a value from state using dot notation
  static dynamic _getStateValue(String path, Map<String, dynamic> state) {
    try {
      return JsonPath.get(state, path);
    } catch (error) {
      return null;
    }
  }

  /// Evaluates a ternary expression
  static dynamic _evaluateTernary(String content, Map<String, dynamic> state) {
    final parts = content.split('?');
    if (parts.length != 2) return null;

    final condition = parts[0].trim();
    final remaining = parts[1].split(':');
    if (remaining.length != 2) return null;

    final trueValue = remaining[0].trim();
    final falseValue = remaining[1].trim();

    final conditionResult = _evaluateExpressionContent(condition, state);
    final isTrue = _isTruthy(conditionResult);

    return isTrue
        ? _evaluateExpressionContent(trueValue, state)
        : _evaluateExpressionContent(falseValue, state);
  }

  /// Evaluates logical expressions (&&, ||)
  static dynamic _evaluateLogical(String content, Map<String, dynamic> state) {
    if (content.contains('&&')) {
      final parts = content.split('&&');
      for (final part in parts) {
        if (!_isTruthy(_evaluateExpressionContent(part.trim(), state))) {
          return false;
        }
      }
      return true;
    } else if (content.contains('||')) {
      final parts = content.split('||');
      for (final part in parts) {
        if (_isTruthy(_evaluateExpressionContent(part.trim(), state))) {
          return true;
        }
      }
      return false;
    }
    return null;
  }

  /// Evaluates comparison expressions
  static dynamic _evaluateComparison(
      String content, Map<String, dynamic> state) {
    final operators = ['>=', '<=', '!=', '==', '>', '<'];

    for (final op in operators) {
      if (content.contains(op)) {
        final parts = content.split(op);
        if (parts.length == 2) {
          final left = _evaluateExpressionContent(parts[0].trim(), state);
          final right = _evaluateExpressionContent(parts[1].trim(), state);

          switch (op) {
            case '==':
              return left == right;
            case '!=':
              return left != right;
            case '>':
              return _compareValues(left, right) > 0;
            case '<':
              return _compareValues(left, right) < 0;
            case '>=':
              return _compareValues(left, right) >= 0;
            case '<=':
              return _compareValues(left, right) <= 0;
          }
        }
        break;
      }
    }
    return null;
  }

  /// Evaluates arithmetic expressions
  static dynamic _evaluateArithmetic(
      String content, Map<String, dynamic> state) {
    // Find the last occurrence of operators for left-to-right evaluation
    final operators = ['+', '-', '*', '/', '%'];

    for (final op in operators) {
      final opIndex = content.lastIndexOf(op);
      if (opIndex > 0 && opIndex < content.length - 1) {
        final left = content.substring(0, opIndex).trim();
        final right = content.substring(opIndex + 1).trim();

        final leftValue = _evaluateExpressionContent(left, state);
        final rightValue = _evaluateExpressionContent(right, state);

        if (op == '+') {
          // Handle both numeric addition and string concatenation
          final leftNum = _toNumber(leftValue);
          final rightNum = _toNumber(rightValue);

          if (leftNum != null && rightNum != null) {
            return leftNum + rightNum;
          } else {
            // String concatenation
            return leftValue.toString() + rightValue.toString();
          }
        } else {
          // Other operators require numeric values
          final leftNum = _toNumber(leftValue);
          final rightNum = _toNumber(rightValue);

          if (leftNum != null && rightNum != null) {
            switch (op) {
              case '-':
                return leftNum - rightNum;
              case '*':
                return leftNum * rightNum;
              case '/':
                return rightNum != 0 ? leftNum / rightNum : null;
              case '%':
                return rightNum != 0 ? leftNum % rightNum : null;
            }
          }
        }
        break;
      }
    }
    return null;
  }

  /// Evaluates pipe operations (transforms)
  static dynamic _evaluatePipe(String content, Map<String, dynamic> state) {
    final parts = content.split('|');
    dynamic value = _evaluateExpressionContent(parts[0].trim(), state);

    for (int i = 1; i < parts.length; i++) {
      final transform = parts[i].trim();
      value = _applyTransform(value, transform);
    }

    return value;
  }

  /// Evaluates function calls
  static dynamic _evaluateFunction(String content, Map<String, dynamic> state) {
    final parenIndex = content.indexOf('(');
    final funcName = content.substring(0, parenIndex).trim();
    final argsString =
        content.substring(parenIndex + 1, content.lastIndexOf(')')).trim();

    final args = argsString.isEmpty
        ? <dynamic>[]
        : argsString
            .split(',')
            .map((arg) => _evaluateExpressionContent(arg.trim(), state))
            .toList();

    return _callFunction(funcName, args);
  }

  /// Evaluates array access
  static dynamic _evaluateArrayAccess(
      String content, Map<String, dynamic> state) {
    final bracketIndex = content.indexOf('[');
    final arrayPath = content.substring(0, bracketIndex).trim();
    final indexString =
        content.substring(bracketIndex + 1, content.lastIndexOf(']')).trim();

    final array = _getStateValue(arrayPath, state);
    final index = _evaluateExpressionContent(indexString, state);

    if (array is List && index is int && index >= 0 && index < array.length) {
      return array[index];
    }

    return null;
  }

  /// Helper methods
  static bool _isLiteral(String value) {
    return value == 'true' ||
        value == 'false' ||
        value == 'null' ||
        double.tryParse(value) != null ||
        (value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"));
  }

  static bool _isTruthy(dynamic value) {
    if (value == null) return false;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value.isNotEmpty;
    if (value is List) return value.isNotEmpty;
    if (value is Map) return value.isNotEmpty;
    return true;
  }

  static int _compareValues(dynamic a, dynamic b) {
    if (a is num && b is num) {
      return a.compareTo(b);
    }
    if (a is String && b is String) {
      return a.compareTo(b);
    }
    return a.toString().compareTo(b.toString());
  }

  static num? _toNumber(dynamic value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value);
    return null;
  }

  static dynamic _applyTransform(dynamic value, String transform) {
    switch (transform) {
      case 'uppercase':
        return value.toString().toUpperCase();
      case 'lowercase':
        return value.toString().toLowerCase();
      case 'capitalize':
        final str = value.toString();
        return str.isEmpty ? str : str[0].toUpperCase() + str.substring(1);
      case 'round':
        final num = _toNumber(value);
        return num?.round();
      case 'floor':
        final num = _toNumber(value);
        return num?.floor();
      case 'ceil':
        final num = _toNumber(value);
        return num?.ceil();
      case 'abs':
        final num = _toNumber(value);
        return num?.abs();
      default:
        return value;
    }
  }

  static dynamic _callFunction(String funcName, List<dynamic> args) {
    switch (funcName) {
      case 'length':
        if (args.isNotEmpty) {
          final value = args[0];
          if (value is List) return value.length;
          if (value is Map) return value.length;
          if (value is String) return value.length;
        }
        return 0;
      case 'sum':
        if (args.isNotEmpty && args[0] is List) {
          final list = args[0] as List;
          if (args.length > 1) {
            // Sum by property
            final property = args[1].toString();
            return list
                .map((item) =>
                    (_toNumber(_getProperty(item, property)) ?? 0).toDouble())
                .fold(0.0, (a, b) => a + b);
          } else {
            // Sum values directly
            return list
                .map((item) => (_toNumber(item) ?? 0).toDouble())
                .fold(0.0, (a, b) => a + b);
          }
        }
        return 0;
      default:
        return null;
    }
  }

  static dynamic _getProperty(dynamic object, String property) {
    if (object is Map) {
      return object[property];
    }
    return null;
  }

  @override
  String toString() {
    return 'ComputedProperty(expression: $expression, dependencies: $dependencies, initialized: $_isInitialized)';
  }
}
