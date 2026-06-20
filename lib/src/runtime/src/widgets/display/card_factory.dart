import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Card widgets
class CardWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties. `elevation` and `shape` accept either:
    //   * a numeric / object form (legacy, still supported), or
    //   * an M3 token shorthand string — `elevation: "level1"` (resolves
    //     through `theme.elevation.level1.shadow`) and `shape: "medium"`
    //     (resolves through `theme.shape.medium`).
    final rawElevation = context.resolve(properties['elevation']);
    final double elevation = (rawElevation is String
            ? parseElevationToken(rawElevation, context)
            : (rawElevation as num?)?.toDouble()) ??
        1.0;
    final shadowColor = parseColor(context.resolve(properties['shadowColor']), context);
    final surfaceTintColor =
        parseColor(context.resolve(properties['surfaceTintColor']), context);
    final color = parseColor(context.resolve(properties['color']), context);
    final rawShape = context.resolve(properties['shape']);
    ShapeBorder? shape;
    if (rawShape is String) {
      // Token shorthand — resolves through theme.shape.<token>.
      shape = parseShapeToken(rawShape, context);
    } else if (rawShape is Map<String, dynamic>) {
      // Either the legacy `{type: "rounded", radius: N}` literal or a
      // theme.shape.* map (`{uniform: N}` / per-corner) supplied via a
      // binding expression like `shape: "{{theme.shape.medium}}"`.
      shape = _parseShape(rawShape) ?? parseThemeShapeMap(rawShape);
    }
    final clipBehavior = _parseClipBehavior(properties['clipBehavior']);
    final semanticContainer = properties['semanticContainer'] as bool? ?? true;

    // Extract margin (external spacing)
    final margin = parseEdgeInsets(properties['margin']);

    // Card is a single-child widget, so child should be in properties
    Widget? child;
    final childDef = properties['child'] as Map<String, dynamic>?;
    if (childDef != null) {
      child = context.renderer.renderWidget(childDef, context);
    }

    Widget card = Card(
      elevation: elevation,
      shadowColor: shadowColor,
      surfaceTintColor: surfaceTintColor,
      color: color,
      shape: shape,
      clipBehavior: clipBehavior,
      margin: margin,
      semanticContainer: semanticContainer,
      child: child,
    );

    return applyCommonWrappers(card, properties, context);
  }

  ShapeBorder? _parseShape(Map<String, dynamic>? shape) {
    if (shape == null) return null;

    final type = shape['type'] as String?;
    switch (type) {
      case 'rounded':
        final radius = shape['radius']?.toDouble() ?? 8.0;
        return RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        );
      case 'circle':
        return const CircleBorder();
      case 'stadium':
        return const StadiumBorder();
      case 'continuous':
        final radius = shape['radius']?.toDouble() ?? 8.0;
        return ContinuousRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        );
      default:
        return null;
    }
  }

  Clip _parseClipBehavior(String? value) {
    switch (value) {
      case 'antiAlias':
        return Clip.antiAlias;
      case 'antiAliasWithSaveLayer':
        return Clip.antiAliasWithSaveLayer;
      case 'hardEdge':
        return Clip.hardEdge;
      case 'none':
        return Clip.none;
      default:
        return Clip.none;
    }
  }
}
