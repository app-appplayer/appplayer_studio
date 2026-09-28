import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for the `progressBar` family.
///
/// One widget, several names, two shapes. The shape comes from three places,
/// in this order:
///
///   1. `indicatorType` on the definition.
///   2. The widget type itself — `linearProgressIndicator` is linear and
///      `circularProgressIndicator` is circular, because a name that states
///      the shape and then draws the other one is worse than no name.
///   3. [defaultIndicatorType], which the registry sets per name.
///
/// The spec's `type` property cannot be used for this: the widget type and
/// that property share the key `type`, and `extractProperties` strips it. The
/// widget-type route above is what makes the choice expressible without it.
///
/// `progressBar` / `progress` / `loadingIndicator` keep `circular` as their
/// undeclared shape. The spec's table says `linear`, but a bar has no
/// intrinsic width, so a bare `progressBar` inside a `linear` row — a shape
/// already shipped in distributed bundles — would go from drawing a spinner
/// to asserting on infinite constraints. A document that wants the bar now
/// says so by name.
class ProgressWidgetFactory extends WidgetFactory {
  ProgressWidgetFactory({this.defaultIndicatorType = 'circular'});

  /// The shape used when the definition names none.
  final String defaultIndicatorType;

  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final type = context.resolve<String>(properties['indicatorType'] ??
        properties['type'] ??
        defaultIndicatorType);

    return type == 'linear'
        ? LinearProgressWidgetFactory().build(definition, context)
        : CircularProgressWidgetFactory().build(definition, context);
  }
}

/// Factory for circular progress indicator
class CircularProgressWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final value = parseDimension(context.resolve((properties['value'])));
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context);
    final color = parseColor(context.resolve(properties['color']), context);
    final strokeWidth =
        parseDimension(context.resolve(properties['strokeWidth'])) ?? 4.0;
    final size = parseDimension(context.resolve(properties['size']));

    Widget widget = CircularProgressIndicator(
      value: value,
      backgroundColor: backgroundColor,
      valueColor: color != null ? AlwaysStoppedAnimation<Color>(color) : null,
      strokeWidth: strokeWidth,
    );

    // Apply size if specified
    if (size != null) {
      widget = SizedBox(
        width: size,
        height: size,
        child: widget,
      );
    }

    return applyCommonWrappers(widget, properties, context);
  }
}

/// Factory for linear progress indicator
class LinearProgressWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final value = parseDimension(context.resolve((properties['value'])));
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context);
    final color = parseColor(context.resolve(properties['color']), context);
    final height = parseDimension(context.resolve(properties['height'])) ??
        parseDimension(context.resolve(properties['minHeight']));

    Widget widget = LinearProgressIndicator(
      value: value,
      backgroundColor: backgroundColor,
      valueColor: color != null ? AlwaysStoppedAnimation<Color>(color) : null,
      minHeight: height,
    );

    return applyCommonWrappers(widget, properties, context);
  }
}
