import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Stack widgets
class StackWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Stack is a multi-child widget, so children should be at root level
    final childrenProp = definition['children'];

    // Resolve children if it's a binding expression
    final resolvedChildren = context.resolve(childrenProp);

    List<Widget> children = [];
    if (resolvedChildren is List<dynamic>) {
      children = resolvedChildren
          .map((child) => context.buildWidget(child as Map<String, dynamic>))
          .toList();
    }

    // Build stack
    Widget stack = Stack(
      alignment: _parseAlignment(properties['alignment']),
      textDirection: _parseTextDirection(properties['textDirection']),
      fit: _parseStackFit(properties['fit']),
      clipBehavior: _parseClipBehavior(properties['clipBehavior']),
      children: children,
    );

    return applyCommonWrappers(stack, properties, context);
  }

  AlignmentGeometry _parseAlignment(String? value) {
    switch (value) {
      // Design spec names (DSL v1.0)
      case 'topStart':
        return AlignmentDirectional.topStart;
      case 'topCenter':
        return Alignment.topCenter;
      case 'topEnd':
        return AlignmentDirectional.topEnd;
      case 'centerStart':
        return AlignmentDirectional.centerStart;
      case 'center':
        return Alignment.center;
      case 'centerEnd':
        return AlignmentDirectional.centerEnd;
      case 'bottomStart':
        return AlignmentDirectional.bottomStart;
      case 'bottomCenter':
        return Alignment.bottomCenter;
      case 'bottomEnd':
        return AlignmentDirectional.bottomEnd;
      // Legacy Flutter names (backward compat)
      case 'topLeft':
        return Alignment.topLeft;
      case 'topRight':
        return Alignment.topRight;
      case 'centerLeft':
        return Alignment.centerLeft;
      case 'centerRight':
        return Alignment.centerRight;
      case 'bottomLeft':
        return Alignment.bottomLeft;
      case 'bottomRight':
        return Alignment.bottomRight;
      default:
        return AlignmentDirectional.topStart;
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

  StackFit _parseStackFit(String? value) {
    switch (value) {
      case 'loose':
        return StackFit.loose;
      case 'expand':
        return StackFit.expand;
      case 'passthrough':
        return StackFit.passthrough;
      default:
        return StackFit.loose;
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
        return Clip.hardEdge;
    }
  }
}
