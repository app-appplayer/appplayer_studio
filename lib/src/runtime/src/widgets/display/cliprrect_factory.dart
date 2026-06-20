import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for ClipRRect widgets
class ClipRRectWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final borderRadius =
        _parseBorderRadius(properties['borderRadius']) ?? BorderRadius.zero;
    final clipBehavior =
        _parseClip(properties['clipBehavior']) ?? Clip.antiAlias;

    // Extract child widget (support both 'child' and 'children' per MCP UI DSL spec)
    final childDef = (properties['child'] ?? definition['child'])
        as Map<String, dynamic>?;
    final childrenDef = properties['children'] as List<dynamic>? ??
        definition['children'] as List<dynamic>?;
    Widget? child;
    if (childDef != null) {
      child = context.buildWidget(childDef);
    } else if (childrenDef != null && childrenDef.isNotEmpty) {
      child = context.buildWidget(childrenDef.first as Map<String, dynamic>);
    }

    Widget clipRRect = ClipRRect(
      borderRadius: borderRadius,
      clipBehavior: clipBehavior,
      child: child,
    );

    return applyCommonWrappers(clipRRect, properties, context);
  }

  BorderRadius? _parseBorderRadius(dynamic value) {
    if (value == null) return null;

    if (value is num) {
      return BorderRadius.circular(value.toDouble());
    }

    if (value is Map<String, dynamic>) {
      if (value.containsKey('all')) {
        return BorderRadius.circular(value['all'].toDouble());
      }

      // Spec § BorderRadius primitive: directional canonical
      // (topStart / topEnd / bottomStart / bottomEnd). Visual aliases
      // (topLeft / topRight / bottomLeft / bottomRight) are accepted
      // at runtime for backward compat.
      final tl = (value['topStart'] ?? value['topLeft']) as num?;
      final tr = (value['topEnd'] ?? value['topRight']) as num?;
      final bl = (value['bottomStart'] ?? value['bottomLeft']) as num?;
      final br = (value['bottomEnd'] ?? value['bottomRight']) as num?;
      return BorderRadius.only(
        topLeft: Radius.circular(tl?.toDouble() ?? 0),
        topRight: Radius.circular(tr?.toDouble() ?? 0),
        bottomLeft: Radius.circular(bl?.toDouble() ?? 0),
        bottomRight: Radius.circular(br?.toDouble() ?? 0),
      );
    }

    return null;
  }

  Clip? _parseClip(String? value) {
    switch (value) {
      case 'none':
        return Clip.none;
      case 'hardEdge':
        return Clip.hardEdge;
      case 'antiAlias':
        return Clip.antiAlias;
      case 'antiAliasWithSaveLayer':
        return Clip.antiAliasWithSaveLayer;
      default:
        return null;
    }
  }
}
