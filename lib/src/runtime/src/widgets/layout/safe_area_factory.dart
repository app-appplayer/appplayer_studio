import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for SafeArea wrapper widgets.
///
/// Wraps child content in a SafeArea to avoid system UI intrusions
/// (status bar, notch, navigation bar, etc.).
///
/// Example definition:
/// ```json
/// {
///   "type": "safeArea",
///   "top": true,
///   "bottom": true,
///   "left": true,
///   "right": true,
///   "minimum": { "all": 16 },
///   "children": [
///     { "type": "text", "text": "Safe content" }
///   ]
/// }
/// ```
class SafeAreaWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // SafeArea edge toggles (default to true)
    final top = boolOf(properties['top'], context) ?? true;
    final bottom = boolOf(properties['bottom'], context) ?? true;
    final left = boolOf(properties['left'], context) ?? true;
    final right = boolOf(properties['right'], context) ?? true;

    // Minimum padding
    final minimum = edgeInsetsOf(properties['minimum'], context) ?? EdgeInsets.zero;

    // Maintain bottom view padding (useful for keyboard avoidance)
    final maintainBottomViewPadding =
        boolOf(properties['maintainBottomViewPadding'], context) ?? false;

    // Build child widget
    Widget? child;
    final childrenDef = properties['children'] as List<dynamic>?;
    if (childrenDef != null && childrenDef.isNotEmpty) {
      if (childrenDef.length == 1) {
        child = context.buildWidget(childrenDef.first as Map<String, dynamic>);
      } else {
        // Wrap multiple children in a Column
        child = Column(
          mainAxisSize: MainAxisSize.min,
          children: childrenDef
              .map((c) => context.buildWidget(c as Map<String, dynamic>))
              .toList(),
        );
      }
    }

    // Single child property support
    final childDef = properties['child'] as Map<String, dynamic>?;
    if (child == null && childDef != null) {
      child = context.buildWidget(childDef);
    }

    final safeArea = SafeArea(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      minimum: minimum,
      maintainBottomViewPadding: maintainBottomViewPadding,
      child: child ?? const SizedBox.shrink(),
    );

    return applyCommonWrappers(safeArea, properties, context);
  }
}
