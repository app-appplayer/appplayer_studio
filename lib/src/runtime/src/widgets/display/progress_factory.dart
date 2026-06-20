import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for generic progress indicator
class ProgressWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    // Design: type → Implementation: indicatorType
    final type =
        context.resolve<String>(properties['type'] ?? properties['indicatorType'] ?? 'circular');
    final value = context.resolve<double?>(properties['value']);
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context);
    final color = parseColor(context.resolve(properties['color']), context);

    if (type == 'linear') {
      return LinearProgressIndicator(
        value: value,
        backgroundColor: backgroundColor,
        valueColor: color != null ? AlwaysStoppedAnimation<Color>(color) : null,
      );
    } else {
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

      return widget;
    }
  }
}

/// Factory for circular progress indicator
class CircularProgressWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final value = context.resolve<double?>(properties['value']);
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
    final value = context.resolve<double?>(properties['value']);
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
