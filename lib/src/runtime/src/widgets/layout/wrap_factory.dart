import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Wrap widgets
class WrapWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final direction = _parseAxis(properties['direction']);
    final alignment = _parseWrapAlignment(properties['alignment']);
    final spacing = properties['spacing']?.toDouble() ?? 0.0;
    final runSpacing = properties['runSpacing']?.toDouble() ?? 0.0;
    final runAlignment = _parseWrapAlignment(properties['runAlignment']);
    final crossAxisAlignment =
        _parseWrapCrossAlignment(properties['crossAxisAlignment']);
    final textDirection = _parseTextDirection(properties['textDirection']);
    final verticalDirection =
        _parseVerticalDirection(properties['verticalDirection']);
    final clipBehavior = _parseClip(properties['clipBehavior']);

    // Wrap is a multi-child widget, so children should be at root level
    final childrenData = definition['children'] as List<dynamic>? ?? [];
    final children = childrenData
        .map((child) => context.renderer.renderWidget(child, context))
        .toList();

    Widget wrap = Wrap(
      direction: direction,
      alignment: alignment,
      spacing: spacing,
      runSpacing: runSpacing,
      runAlignment: runAlignment,
      crossAxisAlignment: crossAxisAlignment,
      textDirection: textDirection,
      verticalDirection: verticalDirection,
      clipBehavior: clipBehavior,
      children: children,
    );

    return applyCommonWrappers(wrap, properties, context);
  }

  Axis _parseAxis(String? value) {
    switch (value) {
      case 'horizontal':
        return Axis.horizontal;
      case 'vertical':
        return Axis.vertical;
      default:
        return Axis.horizontal;
    }
  }

  WrapAlignment _parseWrapAlignment(String? value) {
    switch (value) {
      case 'start':
        return WrapAlignment.start;
      case 'end':
        return WrapAlignment.end;
      case 'center':
        return WrapAlignment.center;
      case 'spaceBetween':
        return WrapAlignment.spaceBetween;
      case 'spaceAround':
        return WrapAlignment.spaceAround;
      case 'spaceEvenly':
        return WrapAlignment.spaceEvenly;
      default:
        return WrapAlignment.start;
    }
  }

  WrapCrossAlignment _parseWrapCrossAlignment(String? value) {
    switch (value) {
      case 'start':
        return WrapCrossAlignment.start;
      case 'end':
        return WrapCrossAlignment.end;
      case 'center':
        return WrapCrossAlignment.center;
      default:
        return WrapCrossAlignment.start;
    }
  }

  TextDirection? _parseTextDirection(String? value) {
    switch (value) {
      case 'ltr':
        return TextDirection.ltr;
      case 'rtl':
        return TextDirection.rtl;
      default:
        return null;
    }
  }

  VerticalDirection _parseVerticalDirection(String? value) {
    switch (value) {
      case 'down':
        return VerticalDirection.down;
      case 'up':
        return VerticalDirection.up;
      default:
        return VerticalDirection.down;
    }
  }

  Clip _parseClip(String? value) {
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
        return Clip.none;
    }
  }
}
