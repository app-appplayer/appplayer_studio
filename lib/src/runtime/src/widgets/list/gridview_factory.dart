import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for GridView widgets
class GridViewWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final scrollDirection = _parseAxis(properties['scrollDirection']);
    final reverse = properties['reverse'] as bool? ?? false;
    final shrinkWrap = properties['shrinkWrap'] as bool? ?? false;
    final physics = _parseScrollPhysics(properties['physics']);
    final padding = parseEdgeInsets(properties['padding']);

    // Grid specific properties
    // Support both 'columns' (MCP UI DSL v1.0) and 'crossAxisCount' (Flutter style)
    final crossAxisCount =
        (properties['columns'] ?? properties['crossAxisCount']) as int?;
    final maxCrossAxisExtent = parseDimension(properties['maxCrossAxisExtent']);
    // Spec §2.7.2 canonical `rowGap` / `columnGap`; legacy
    // `mainAxisSpacing` / `crossAxisSpacing` (Flutter field names) and
    // `spacing` (shared shorthand) accepted.
    final spacing = parseDimension(properties['spacing']);
    final mainAxisSpacing =
        parseDimension(properties['rowGap'] ?? properties['mainAxisSpacing']) ??
            spacing ??
            0.0;
    final crossAxisSpacing = parseDimension(
            properties['columnGap'] ?? properties['crossAxisSpacing']) ??
        spacing ??
        0.0;
    // Spec §2.7.2 canonical `itemAspectRatio`; `childAspectRatio` kept as
    // legacy Flutter-style alias.
    final childAspectRatio = parseDimension(
            properties['itemAspectRatio'] ?? properties['childAspectRatio']) ??
        1.0;
    final mainAxisExtent = parseDimension(properties['mainAxisExtent']);

    // Get data source
    final staticChildren = definition['children'] as List<dynamic>?;
    // Support both direct list and path-based items
    final itemsProp = properties['items'];
    final directItems = itemsProp is List ? itemsProp : null;
    final itemsPath = itemsProp is String ? itemsProp : null;
    // Support both 'itemTemplate' (MCP UI DSL v1.0) and 'template' (legacy)
    final itemTemplate = (properties['itemTemplate'] ?? properties['template'])
        as Map<String, dynamic>?;

    Widget gridView;

    // Determine which delegate to use
    SliverGridDelegate gridDelegate;
    if (crossAxisCount != null) {
      gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: mainAxisSpacing,
        crossAxisSpacing: crossAxisSpacing,
        childAspectRatio: childAspectRatio,
        mainAxisExtent: mainAxisExtent,
      );
    } else if (maxCrossAxisExtent != null) {
      gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxCrossAxisExtent,
        mainAxisSpacing: mainAxisSpacing,
        crossAxisSpacing: crossAxisSpacing,
        childAspectRatio: childAspectRatio,
        mainAxisExtent: mainAxisExtent,
      );
    } else {
      // Default to 2 columns if not specified
      gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: mainAxisSpacing,
        crossAxisSpacing: crossAxisSpacing,
        childAspectRatio: childAspectRatio,
      );
    }

    if ((itemsPath != null || directItems != null) && itemTemplate != null) {
      // Dynamic grid with data binding
      final items = itemsPath != null
          ? context.resolve<List<dynamic>>(itemsPath) as List<dynamic>? ?? []
          : directItems ?? [];

      gridView = GridView.builder(
        scrollDirection: scrollDirection,
        reverse: reverse,
        shrinkWrap: shrinkWrap,
        physics: physics,
        padding: padding,
        gridDelegate: gridDelegate,
        itemCount: items.length,
        itemBuilder: (buildContext, index) {
          // Create child context with item data
          final row = index ~/ (crossAxisCount ?? 2);
          final col = index % (crossAxisCount ?? 2);

          final childContext = context.createChildContext(
            variables: {
              'item': items[index],
              'index': index,
              'row': row,
              'col': col,
              'isFirst': index == 0,
              'isLast': index == items.length - 1,
              'isEven': index % 2 == 0,
              'isOdd': index % 2 == 1,
            },
          );

          return context.renderer.renderWidget(itemTemplate, childContext);
        },
      );
    } else if (directItems != null &&
        directItems.isNotEmpty &&
        itemTemplate == null) {
      // Direct items list (like in showcase_definition.dart)
      final items = directItems;

      gridView = GridView.builder(
        scrollDirection: scrollDirection,
        reverse: reverse,
        shrinkWrap: shrinkWrap,
        physics: physics,
        padding: padding,
        gridDelegate: gridDelegate,
        itemCount: items.length,
        itemBuilder: (buildContext, index) {
          // Render each item directly as a widget
          return context.renderer.renderWidget(items[index], context);
        },
      );
    } else if (staticChildren != null && staticChildren.isNotEmpty) {
      // Static grid with predefined children
      final children = staticChildren
          .map((child) => context.renderer.renderWidget(child, context))
          .toList();

      gridView = GridView(
        scrollDirection: scrollDirection,
        reverse: reverse,
        shrinkWrap: shrinkWrap,
        physics: physics,
        padding: padding,
        gridDelegate: gridDelegate,
        children: children,
      );
    } else {
      // Empty grid
      gridView = GridView(
        shrinkWrap: shrinkWrap,
        physics: physics,
        padding: padding,
        gridDelegate: gridDelegate,
      );
    }

    // Ensure GridView has proper constraints for stability
    final wrappedGridView = _ensureStableConstraints(gridView, shrinkWrap);

    return applyCommonWrappers(wrappedGridView, properties, context);
  }

  Widget _ensureStableConstraints(Widget gridView, bool shrinkWrap) {
    // If shrinkWrap is true, the GridView handles its own constraints
    if (shrinkWrap) {
      return gridView;
    }

    // For non-shrinkWrap GridViews, ensure they have bounded constraints
    return LayoutBuilder(
      builder: (context, constraints) {
        // If constraints are already bounded, use them as-is
        if (constraints.hasBoundedHeight) {
          return gridView;
        }

        // Provide a default height for unbounded contexts
        // This prevents viewport assertion errors in tests
        return SizedBox(
          height: MediaQuery.of(context).size.height,
          child: gridView,
        );
      },
    );
  }

  Axis _parseAxis(String? value) {
    switch (value) {
      case 'horizontal':
        return Axis.horizontal;
      case 'vertical':
      default:
        return Axis.vertical;
    }
  }

  ScrollPhysics? _parseScrollPhysics(String? value) {
    switch (value) {
      case 'never':
        return const NeverScrollableScrollPhysics();
      case 'always':
        return const AlwaysScrollableScrollPhysics();
      case 'bouncing':
        return const BouncingScrollPhysics();
      case 'clamping':
        return const ClampingScrollPhysics();
      default:
        return null;
    }
  }
}
