import 'package:flutter/material.dart';
import '../decoration/box_decoration_resolver.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for the `decoration` widget. Wraps a child in a
/// `DecoratedBox` whose decoration is built by the shared
/// [BoxDecorationResolver] — same resolver the `box` widget uses, so
/// the two stay aligned with the spec § 1.3 `BoxDecoration` primitive.
class DecorationWidgetFactory extends WidgetFactory {
  // Documented property contract (read via [BoxDecorationResolver],
  // recorded here so the spec ↔ runtime drift audit captures the
  // surface — the resolver consumes `properties['decoration']`,
  // `properties['color']`, `properties['gradient']`,
  // `properties['image']`, `properties['border']`,
  // `properties['borderRadius']`, `properties['boxShadow']`,
  // `properties['shape']`, and `properties['backdropBlur']`).

  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final childDef = (properties['child'] ?? definition['child'])
        as Map<String, dynamic>?;
    final children = definition['children'] as List<dynamic>? ?? [];

    final decoration = BoxDecorationResolver.resolve(
          properties,
          context,
          host: this,
        ) ??
        const BoxDecoration();
    final backdropSigma = BoxDecorationResolver.backdropBlurSigma(properties);

    Widget child = childDef != null
        ? context.buildWidget(childDef)
        : (children.isNotEmpty
            ? context.buildWidget(children.first as Map<String, dynamic>)
            : Container());

    Widget result = DecoratedBox(
      decoration: decoration,
      position: _resolveDecorationPosition(properties['position']),
      child: child,
    );

    if (backdropSigma != null) {
      result = BoxDecorationResolver.wrapWithBackdrop(
        result,
        sigma: backdropSigma,
        radius: decoration.borderRadius is BorderRadius
            ? decoration.borderRadius as BorderRadius
            : null,
      );
    }

    return result;
  }

  DecorationPosition _resolveDecorationPosition(String? position) {
    switch (position) {
      case 'foreground':
        return DecorationPosition.foreground;
      case 'background':
      default:
        return DecorationPosition.background;
    }
  }
}
