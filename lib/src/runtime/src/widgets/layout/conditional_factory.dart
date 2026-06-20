import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for creating conditional widgets
/// Supports two modes:
/// 1. if/then/else: condition + then + else
/// 2. switch/cases/default: switch + cases[] + default (multi-branch)
class ConditionalFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    // Check for switch/cases mode (multi-branch conditional)
    final switchValue = definition['switch'];
    if (switchValue != null) {
      return _buildSwitch(definition, context, switchValue);
    }

    // if/then/else mode
    final condition = definition['condition'];
    if (condition == null) {
      throw Exception('Conditional widget requires a condition or switch property');
    }

    // Resolve the condition (handle bindings)
    final conditionResult = context.resolve<dynamic>(condition);
    final isTrue = _isTruthy(conditionResult);

    // Get then and else widgets
    final thenWidget = definition['then'];
    final elseWidget = definition['orElse'] ??
        definition['else']; // Support both 'orElse' (v1.0) and 'else'

    if (isTrue && thenWidget != null) {
      return context.renderer.renderWidget(thenWidget, context);
    } else if (!isTrue && elseWidget != null) {
      return context.renderer.renderWidget(elseWidget, context);
    }

    // Return empty container if no appropriate widget
    return const SizedBox.shrink();
  }

  /// Build switch/cases multi-branch conditional
  Widget _buildSwitch(
      Map<String, dynamic> definition, RenderContext context, dynamic switchExpr) {
    final resolvedValue = context.resolve<dynamic>(switchExpr);
    final cases = definition['cases'] as List<dynamic>?;
    final defaultWidget = definition['default'] as Map<String, dynamic>?;

    if (cases != null) {
      for (final caseItem in cases) {
        if (caseItem is Map<String, dynamic>) {
          final caseValue = caseItem['value'];
          // Design spec uses 'child'; 'widget' and 'then' kept for backward compat
          final caseWidget =
              caseItem['child'] ?? caseItem['widget'] ?? caseItem['then'];

          if (caseValue is List) {
            // Support multiple values for a single case
            if (caseValue.any((v) => _valuesMatch(context.resolve<dynamic>(v), resolvedValue))) {
              if (caseWidget is Map<String, dynamic>) {
                return context.renderer.renderWidget(caseWidget, context);
              }
            }
          } else if (_valuesMatch(context.resolve<dynamic>(caseValue), resolvedValue)) {
            if (caseWidget is Map<String, dynamic>) {
              return context.renderer.renderWidget(caseWidget, context);
            }
          }
        }
      }
    }

    // Fall through to default
    if (defaultWidget != null) {
      return context.renderer.renderWidget(defaultWidget, context);
    }

    return const SizedBox.shrink();
  }

  /// Compare two values for switch matching
  bool _valuesMatch(dynamic a, dynamic b) {
    if (a == b) return true;
    if (a == null || b == null) return false;
    return a.toString() == b.toString();
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
}
