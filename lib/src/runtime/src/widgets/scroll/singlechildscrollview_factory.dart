import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for SingleChildScrollView widgets
class SingleChildScrollViewWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    // Spec §2.9.2 canonical `direction`; `scrollDirection` kept as legacy
    // Flutter-style alias.
    final scrollDirection =
        _parseAxis(properties['direction'] ?? properties['scrollDirection']) ??
            Axis.vertical;
    final reverse = properties['reverse'] as bool? ?? false;
    final padding = parseEdgeInsets(properties['padding']);
    final primary = properties['primary'] as bool?;
    final physics = _parseScrollPhysics(properties['physics']);
    final clipBehavior =
        _parseClip(properties['clipBehavior']) ?? Clip.hardEdge;

    // Extract child widget
    final childDef = properties['child'] ?? definition['child'];
    Widget? child;
    if (childDef != null && childDef is Map<String, dynamic>) {
      child = context.buildWidget(childDef);
    }

    Widget scrollView = SingleChildScrollView(
      scrollDirection: scrollDirection,
      reverse: reverse,
      padding: padding,
      primary: primary,
      physics: physics,
      clipBehavior: clipBehavior,
      child: child,
    );

    return applyCommonWrappers(scrollView, properties, context);
  }

  Axis? _parseAxis(String? value) {
    switch (value) {
      case 'horizontal':
        return Axis.horizontal;
      case 'vertical':
        return Axis.vertical;
      default:
        return null;
    }
  }

  ScrollPhysics? _parseScrollPhysics(String? value) {
    switch (value) {
      case 'bouncing':
        return const BouncingScrollPhysics();
      case 'clamping':
        return const ClampingScrollPhysics();
      case 'never':
        return const NeverScrollableScrollPhysics();
      default:
        return null;
    }
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
