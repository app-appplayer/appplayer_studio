import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../../responsive/breakpoint_system.dart';
import '../widget_factory.dart';

/// Factory for MediaQuery-based conditional rendering.
///
/// Evaluates conditions based on screen dimensions and renders `then`/`else`
/// children based on the result. Also supports per-breakpoint children as a
/// fallback.
///
/// Conditional mode example:
/// ```json
/// {
///   "type": "mediaQuery",
///   "condition": { "minWidth": 600 },
///   "then": { "type": "text", "text": "Wide layout" },
///   "else": { "type": "text", "text": "Narrow layout" }
/// }
/// ```
///
/// Breakpoint mode example:
/// ```json
/// {
///   "type": "mediaQuery",
///   "breakpoints": {
///     "xs": { "type": "text", "text": "Mobile" },
///     "md": { "type": "text", "text": "Tablet" },
///     "lg": { "type": "text", "text": "Desktop" }
///   },
///   "defaultChild": { "type": "text", "text": "Default" }
/// }
/// ```
class MediaQueryWidgetFactory extends WidgetFactory {
  /// Breakpoint system used for width-based resolution
  final BreakpointSystem _breakpointSystem = BreakpointSystem();

  /// Ordered breakpoint names from smallest to largest
  static const _breakpointOrder = ['xs', 'sm', 'md', 'lg', 'xl'];

  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Check for conditional mode (condition + then/else)
    final condition = properties['condition'] as Map<String, dynamic>?;
    if (condition != null) {
      return _buildConditional(properties, context, condition);
    }

    // Breakpoint mode (legacy)
    return _buildBreakpointMode(properties, context);
  }

  /// Build conditional rendering based on media query conditions.
  ///
  /// Supported condition properties:
  /// - `minWidth`: minimum viewport width
  /// - `maxWidth`: maximum viewport width
  /// - `minHeight`: minimum viewport height
  /// - `maxHeight`: maximum viewport height
  /// - `orientation`: 'portrait' or 'landscape'
  /// - `breakpoint`: exact breakpoint name to match
  Widget _buildConditional(
    Map<String, dynamic> properties,
    RenderContext context,
    Map<String, dynamic> condition,
  ) {
    final thenChild = properties['then'] as Map<String, dynamic>?;
    final elseChild =
        (properties['else'] ?? properties['orElse']) as Map<String, dynamic>?;

    return LayoutBuilder(
      builder: (buildContext, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;

        final matches = _evaluateCondition(condition, width, height);

        if (matches && thenChild != null) {
          final widget = context.buildWidget(thenChild);
          return applyCommonWrappers(widget, properties, context);
        } else if (!matches && elseChild != null) {
          final widget = context.buildWidget(elseChild);
          return applyCommonWrappers(widget, properties, context);
        }

        return const SizedBox.shrink();
      },
    );
  }

  /// Evaluate a media query condition against the current dimensions.
  bool _evaluateCondition(
    Map<String, dynamic> condition,
    double width,
    double height,
  ) {
    final minWidth = (condition['minWidth'] as num?)?.toDouble();
    final maxWidth = (condition['maxWidth'] as num?)?.toDouble();
    final minHeight = (condition['minHeight'] as num?)?.toDouble();
    final maxHeight = (condition['maxHeight'] as num?)?.toDouble();
    final orientation = condition['orientation'] as String?;
    final breakpoint = condition['breakpoint'] as String?;

    if (minWidth != null && width < minWidth) return false;
    if (maxWidth != null && width > maxWidth) return false;
    if (minHeight != null && height < minHeight) return false;
    if (maxHeight != null && height > maxHeight) return false;

    if (orientation != null) {
      final isPortrait = height >= width;
      if (orientation == 'portrait' && !isPortrait) return false;
      if (orientation == 'landscape' && isPortrait) return false;
    }

    if (breakpoint != null) {
      final currentBp = _breakpointSystem.getCurrentBreakpoint(width);
      if (currentBp != breakpoint) return false;
    }

    return true;
  }

  /// Build breakpoint-based rendering (original behavior).
  Widget _buildBreakpointMode(
    Map<String, dynamic> properties,
    RenderContext context,
  ) {
    final breakpoints =
        properties['breakpoints'] as Map<String, dynamic>? ?? {};
    final defaultChild = properties['defaultChild'] as Map<String, dynamic>?;

    return LayoutBuilder(
      builder: (buildContext, constraints) {
        final width = constraints.maxWidth;
        final currentBp = _breakpointSystem.getCurrentBreakpoint(width);
        final bpIndex = _breakpointOrder.indexOf(currentBp);

        // Find the best matching breakpoint definition
        Map<String, dynamic>? childDef;

        // Try exact match first
        if (breakpoints.containsKey(currentBp)) {
          childDef = breakpoints[currentBp] as Map<String, dynamic>?;
        }

        // Fall back to next smaller breakpoint
        if (childDef == null) {
          for (int i = bpIndex - 1; i >= 0; i--) {
            final fallbackKey = _breakpointOrder[i];
            if (breakpoints.containsKey(fallbackKey)) {
              childDef = breakpoints[fallbackKey] as Map<String, dynamic>?;
              break;
            }
          }
        }

        // Fall back to next larger breakpoint
        if (childDef == null) {
          for (int i = bpIndex + 1; i < _breakpointOrder.length; i++) {
            final fallbackKey = _breakpointOrder[i];
            if (breakpoints.containsKey(fallbackKey)) {
              childDef = breakpoints[fallbackKey] as Map<String, dynamic>?;
              break;
            }
          }
        }

        // Use default child if no breakpoint matched
        childDef ??= defaultChild;

        if (childDef != null) {
          final widget = context.buildWidget(childDef);
          return applyCommonWrappers(widget, properties, context);
        }

        return const SizedBox.shrink();
      },
    );
  }
}
