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

  /// Ordered breakpoint classes, smallest to largest.
  ///
  /// These are the names `BreakpointSystem` answers with. The list used to be
  /// `xs`/`sm`/`md`/`lg`/`xl`, which matched nothing it returned — so the
  /// exact-match branch never fired and the widget rendered whichever key
  /// happened to come first in that list, at every window width. A
  /// `mediaQuery` was, in effect, not responsive.
  static const _breakpointOrder = [
    'compact',
    'medium',
    'expanded',
    'large',
    'extraLarge',
  ];

  /// The pre-1.4 spelling of each class, still accepted so documents written
  /// against it keep choosing the same layout.
  static const _legacyAliases = <String, String>{
    'xs': 'compact',
    'sm': 'medium',
    'md': 'expanded',
    'lg': 'large',
    'xl': 'extraLarge',
  };

  /// The canonical class for [name], whichever spelling it arrived in.
  static String _canonical(String name) => _legacyAliases[name] ?? name;

  /// The declaration for [breakpointClass], under either spelling.
  static Map<String, dynamic>? _declaredFor(
    Map<String, dynamic> breakpoints,
    String breakpointClass,
  ) {
    if (breakpoints.containsKey(breakpointClass)) {
      return breakpoints[breakpointClass] as Map<String, dynamic>?;
    }
    for (final entry in _legacyAliases.entries) {
      if (entry.value == breakpointClass &&
          breakpoints.containsKey(entry.key)) {
        return breakpoints[entry.key] as Map<String, dynamic>?;
      }
    }
    return null;
  }

  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Check for conditional mode (condition + then/else)
    // `condition` is `object | binding`. Reading it as a Map threw on the
    // bound form, which the schema allows: a binding may land on the
    // constraint object or, per the property's own description, on a plain
    // boolean expression. A boolean decides directly — there is nothing to
    // measure against the viewport.
    final resolved = context.resolve<Object?>(properties['condition']);
    if (resolved is Map) {
      return _buildConditional(
        properties,
        context,
        Map<String, dynamic>.from(resolved),
      );
    }
    if (resolved != null) {
      final matched = resolved == true || resolved.toString() == 'true';
      final branch = matched
          ? properties['then']
          : (properties['else'] ?? properties['orElse']);
      if (branch is Map<String, dynamic>) {
        return applyCommonWrappers(
          context.buildWidget(branch),
          properties,
          context,
        );
      }
      return const SizedBox.shrink();
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
      if (currentBp != _canonical(breakpoint)) return false;
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
        childDef = _declaredFor(breakpoints, currentBp);

        // Fall back to next smaller breakpoint
        if (childDef == null) {
          for (int i = bpIndex - 1; i >= 0; i--) {
            childDef = _declaredFor(breakpoints, _breakpointOrder[i]);
            if (childDef != null) break;
          }
        }

        // Fall back to next larger breakpoint
        if (childDef == null) {
          for (int i = bpIndex + 1; i < _breakpointOrder.length; i++) {
            childDef = _declaredFor(breakpoints, _breakpointOrder[i]);
            if (childDef != null) break;
          }
        }

        // Use the declared default, then `defaultChild`
        childDef ??= breakpoints['default'] as Map<String, dynamic>?;
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
