import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../../utils/icon_resolver.dart';
import '../widget_factory.dart';

/// Factory for Drawer widgets
class DrawerWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final width = parseDimension(properties['width']);
    final elevation = parseDimension(properties['elevation']) ?? 16.0;
    final shadowColor = parseColor(context.resolve(properties['shadowColor']), context);
    final surfaceTintColor =
        parseColor(context.resolve(properties['surfaceTintColor']), context);
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context);
    final shape = _parseShapeBorder(properties['shape']);
    final semanticLabel = context.resolve<String?>(properties['semanticLabel']);

    // Spec §2.8.5: when used standalone, render `header` + `items` (each with
    // icon/label/route) and fire `onSelect` when an item is tapped.
    final items = (properties['items'] as List<dynamic>?) ??
        (definition['items'] as List<dynamic>?);
    final headerDef = properties['header'] as Map<String, dynamic>?;
    final onSelect = properties['onSelect'] as Map<String, dynamic>?;

    // Build child widget (support both 'child' and 'children' per MCP UI DSL spec)
    final childDef = (properties['child'] ?? definition['child'])
        as Map<String, dynamic>?;
    final childrenData = properties['children'] as List<dynamic>? ??
        definition['children'] as List<dynamic>?;
    Widget? child;

    if (items != null) {
      // Build a standard drawer layout from the spec-shape `items` list.
      final listChildren = <Widget>[];
      if (headerDef != null) {
        listChildren.add(context.renderer.renderWidget(headerDef, context));
      }
      for (final raw in items) {
        if (raw is! Map<String, dynamic>) continue;
        final iconName = raw['icon'] as String?;
        // §17.3.2: canonical 'label', legacy alias 'title'.
        final label = (raw['label'] ?? raw['title'])?.toString() ?? '';
        final route = raw['route'] as String?;
        listChildren.add(ListTile(
          leading: iconName != null
              ? Icon(_iconFromName(iconName))
              : null,
          title: Text(label),
          onTap: () {
            if (onSelect != null) {
              final eventContext = context.createChildContext(
                variables: {
                  'event': {
                    'value': raw['value'] ?? route ?? label,
                    'route': route,
                    'label': label,
                    'type': 'select',
                  },
                },
              );
              context.actionHandler.execute(onSelect, eventContext);
            }
          },
        ));
      }
      child = ListView(padding: EdgeInsets.zero, children: listChildren);
    } else if (childDef != null) {
      child = context.renderer.renderWidget(childDef, context);
    } else if (childrenData != null && childrenData.isNotEmpty) {
      if (childrenData.length == 1) {
        child = context.renderer.renderWidget(childrenData.first, context);
      } else {
        // Multiple children - wrap in Column
        final children = childrenData
            .map((child) => context.renderer.renderWidget(child, context))
            .toList();
        child = Column(
          children: children,
        );
      }
    }

    // Default drawer structure if no child provided. Header uses
    // `onPrimary` for the text so it contrasts against the primary
    // swatch correctly in both light and dark modes.
    final cs = Theme.of(context.buildContext!).colorScheme;
    child ??= Column(
      children: [
        DrawerHeader(
          decoration: BoxDecoration(color: cs.primary),
          child: Text(
            'Menu',
            style: TextStyle(
              color: cs.onPrimary,
              fontSize: 24,
            ),
          ),
        ),
      ],
    );

    Widget drawer = Drawer(
      width: width,
      elevation: elevation,
      shadowColor: shadowColor,
      surfaceTintColor: surfaceTintColor,
      backgroundColor: backgroundColor,
      shape: shape,
      semanticLabel: semanticLabel,
      child: child,
    );

    return drawer;
  }

  IconData _iconFromName(String name) => resolveIconData(name);

  ShapeBorder? _parseShapeBorder(Map<String, dynamic>? shape) {
    if (shape == null) return null;

    final type = shape['type'] as String?;
    switch (type) {
      case 'rounded':
        final radius = parseDimension(shape['radius']) ?? 8.0;
        final side = shape['onlyRight'] as bool? ?? false;
        return RoundedRectangleBorder(
          borderRadius: side
              ? BorderRadius.only(
                  topRight: Radius.circular(radius),
                  bottomRight: Radius.circular(radius),
                )
              : BorderRadius.circular(radius),
        );
      default:
        return null;
    }
  }
}
