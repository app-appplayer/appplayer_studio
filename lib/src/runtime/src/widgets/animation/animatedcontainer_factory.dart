import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for AnimatedContainer widgets
class AnimatedContainerWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final duration =
        Duration(milliseconds: properties['duration'] as int? ?? 300);
    final curve = _parseCurve(properties['curve'] as String?);
    final width = parseDimension(properties['width']);
    final height = parseDimension(properties['height']);
    final padding = parseEdgeInsets(properties['padding']);
    final margin = parseEdgeInsets(properties['margin']);
    final alignment = parseAlignment(properties['alignment']);
    final decoration = _parseDecoration(properties['decoration'], context);
    final foregroundDecoration =
        _parseDecoration(properties['foregroundDecoration'], context);
    final constraints = parseConstraints(properties['constraints']);
    final transform = _parseMatrix4(properties['transform']);
    final transformAlignment = parseAlignment(properties['transformAlignment']);
    final clipBehavior = _parseClip(properties['clipBehavior']) ?? Clip.none;

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

    // Extract action handlers
    final onEnd = properties['onEnd'] as Map<String, dynamic>?;

    Widget animatedContainer = AnimatedContainer(
      duration: duration,
      curve: curve,
      width: width,
      height: height,
      padding: padding,
      margin: margin,
      alignment: alignment,
      decoration: decoration,
      foregroundDecoration: foregroundDecoration,
      constraints: constraints,
      transform: transform,
      transformAlignment: transformAlignment,
      clipBehavior: clipBehavior,
      onEnd: onEnd != null
          ? () {
              context.actionHandler.execute(onEnd, context);
            }
          : null,
      child: child,
    );

    return applyCommonWrappers(animatedContainer, properties, context);
  }

  Curve _parseCurve(String? value) {
    switch (value) {
      case 'linear':
        return Curves.linear;
      case 'easeIn':
        return Curves.easeIn;
      case 'easeOut':
        return Curves.easeOut;
      case 'easeInOut':
        return Curves.easeInOut;
      case 'bounceIn':
        return Curves.bounceIn;
      case 'bounceOut':
        return Curves.bounceOut;
      case 'bounceInOut':
        return Curves.bounceInOut;
      case 'elasticIn':
        return Curves.elasticIn;
      case 'elasticOut':
        return Curves.elasticOut;
      case 'elasticInOut':
        return Curves.elasticInOut;
      default:
        return Curves.linear;
    }
  }

  Decoration? _parseDecoration(dynamic decoration, RenderContext context) {
    if (decoration == null) return null;

    // String binding form — resolves to a Map.
    if (decoration is String) {
      final resolved = context.resolve<dynamic>(decoration);
      if (resolved is Map) {
        decoration = Map<String, dynamic>.from(resolved);
      } else {
        return null;
      }
    }

    if (decoration is Map<String, dynamic>) {
      return BoxDecoration(
        color: parseColor(context.resolve(decoration['color']), context),
        borderRadius: _parseBorderRadius(decoration['borderRadius']),
        border: _parseBorder(decoration['border'], context),
      );
    }

    return null;
  }

  BorderRadius? _parseBorderRadius(dynamic value) {
    if (value == null) return null;

    if (value is num) {
      return BorderRadius.circular(value.toDouble());
    }

    return null;
  }

  Border? _parseBorder(dynamic border, RenderContext context) {
    if (border == null) return null;

    if (border is Map<String, dynamic>) {
      final color =
          parseColor(context.resolve(border['color']), context) ?? Colors.black;
      final width = border['width']?.toDouble() ?? 1.0;

      return Border.all(color: color, width: width);
    }

    return null;
  }

  Matrix4? _parseMatrix4(dynamic transform) {
    if (transform == null) return null;

    if (transform is Map<String, dynamic>) {
      final type = transform['type'] as String?;
      switch (type) {
        case 'scale':
          final scale = transform['scale']?.toDouble() ?? 1.0;
          return Matrix4.identity()..scale(scale);
        case 'rotate':
          final angle = transform['angle']?.toDouble() ?? 0.0;
          return Matrix4.identity()..rotateZ(angle);
        case 'translate':
          final x = transform['x']?.toDouble() ?? 0.0;
          final y = transform['y']?.toDouble() ?? 0.0;
          return Matrix4.identity()..translate(x, y);
        default:
          return null;
      }
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
