import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for IndexedStack widgets
///
/// IndexedStack shows a single child from a list of children,
/// based on the current index value.
class IndexedStackWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // IndexedStack is a multi-child widget, so children should be at root level
    final childrenProp = definition['children'];

    // Resolve children if it's a binding expression
    final resolvedChildren = context.resolve(childrenProp);

    List<Widget> children = [];
    if (resolvedChildren is List<dynamic>) {
      children = resolvedChildren
          .map((child) => context.buildWidget(child as Map<String, dynamic>))
          .toList();
    }

    // Resolve index - supports both direct int and binding expression
    final resolvedIndex = context.resolve(properties['index']);
    int index = 0;
    if (resolvedIndex is int) {
      index = resolvedIndex;
    } else if (resolvedIndex is num) {
      index = resolvedIndex.toInt();
    }

    // Clamp index to valid range
    if (children.isNotEmpty) {
      index = index.clamp(0, children.length - 1);
    }

    // Build indexed stack
    Widget indexedStack = IndexedStack(
      alignment: _parseAlignment(properties['alignment']),
      textDirection: _parseTextDirection(properties['textDirection']),
      clipBehavior: _parseClipBehavior(properties['clipBehavior']),
      sizing: _parseStackFit(properties['sizing']),
      index: index,
      children: children,
    );

    return applyCommonWrappers(indexedStack, properties, context);
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
