import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for ListView widgets
class ListViewWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties (spec v1.0: 'orientation', legacy: 'scrollDirection')
    final scrollDirection = _parseAxis(
        properties['orientation'] ?? properties['scrollDirection']);
    final reverse = properties['reverse'] as bool? ?? false;
    // Follow MCP UI DSL v1.0 spec: shrinkWrap defaults to false
    final shrinkWrap = properties['shrinkWrap'] as bool? ?? false;
    final physics = _parseScrollPhysics(properties['physics']);
    final padding = parseEdgeInsets(properties['padding']);
    // spec v1.0: 'spacing', legacy: 'itemSpacing'
    final itemSpacing = parseDimension(
        properties['spacing'] ?? properties['itemSpacing']) ?? 0.0;
    final emptyMessage = context.resolve<String?>(properties['emptyMessage']);
    final virtual = properties['virtual'] as bool? ?? false;
    final cacheExtent = parseDimension(properties['cacheExtent']);
    final itemExtent = parseDimension(properties['itemExtent']);

    // Get data source - support both static children and dynamic items
    final childrenProp = definition['children'];
    final resolvedChildren = context.resolve(childrenProp);
    final staticChildren =
        resolvedChildren is List<dynamic> ? resolvedChildren : null;

    // Support both direct list and path-based items
    final itemsProp = properties['items'];
    final resolvedItems = context.resolve(itemsProp);
    final directItems = itemsProp is List ? itemsProp : null;
    final itemsPath = itemsProp is String ? itemsProp : null;
    // Support both 'itemTemplate' (MCP UI DSL v1.0) and 'template' (legacy)
    final itemTemplate = (properties['itemTemplate'] ?? properties['template'])
        as Map<String, dynamic>?;

    // Also support itemCount/itemBuilder pattern
    final itemCountValue = properties['itemCount'];
    final itemBuilder = properties['itemBuilder'] as Map<String, dynamic>?;

    Widget listView;

    if (itemCountValue != null && itemBuilder != null) {
      // Dynamic list with itemCount/itemBuilder pattern
      final itemCount = context.resolve(itemCountValue) as int? ?? 0;

      listView = ListView.separated(
        scrollDirection: scrollDirection,
        reverse: reverse,
        shrinkWrap: shrinkWrap,
        physics: physics,
        padding: padding,
        cacheExtent: cacheExtent,
        itemCount: itemCount,
        separatorBuilder: itemSpacing > 0
            ? (context, index) => scrollDirection == Axis.horizontal
                ? SizedBox(width: itemSpacing)
                : SizedBox(height: itemSpacing)
            : (context, index) => Container(),
        itemBuilder: (buildContext, index) {
          // Create child context with index
          final childContext = context.createChildContext(
            variables: {
              'index': index,
              'isFirst': index == 0,
              'isLast': index == itemCount - 1,
              'isEven': index % 2 == 0,
              'isOdd': index % 2 == 1,
            },
          );

          return context.renderer.renderWidget(itemBuilder, childContext);
        },
      );
    } else if ((itemsPath != null || resolvedItems != null) &&
        itemTemplate != null) {
      // Dynamic list with data binding
      final items = resolvedItems as List<dynamic>? ?? [];

      // Show emptyMessage when items list is empty
      if (items.isEmpty && emptyMessage != null && emptyMessage.isNotEmpty) {
        listView = Center(
          child: Padding(
            padding: padding ?? EdgeInsets.zero,
            child: Text(
              emptyMessage,
              style: TextStyle(color: Theme.of(context.buildContext!).colorScheme.onSurface.withValues(alpha: 0.6)),
            ),
          ),
        );
      } else if (virtual && itemExtent != null) {
        // Virtualized rendering with fixed item extent
        listView = ListView.builder(
          scrollDirection: scrollDirection,
          reverse: reverse,
          shrinkWrap: shrinkWrap,
          physics: physics,
          padding: padding,
          cacheExtent: cacheExtent,
          itemExtent: itemExtent,
          itemCount: items.length,
          itemBuilder: (buildContext, index) {
            final childContext = context.createChildContext(
              variables: {
                'item': items[index],
                'index': index,
                'isFirst': index == 0,
                'isLast': index == items.length - 1,
                'isEven': index % 2 == 0,
                'isOdd': index % 2 == 1,
              },
            );
            return context.renderer.renderWidget(itemTemplate, childContext);
          },
        );
      } else {
        listView = ListView.separated(
          scrollDirection: scrollDirection,
          reverse: reverse,
          shrinkWrap: shrinkWrap,
          physics: physics,
          padding: padding,
          cacheExtent: cacheExtent,
          itemCount: items.length,
          separatorBuilder: itemSpacing > 0
              ? (context, index) => scrollDirection == Axis.horizontal
                  ? SizedBox(width: itemSpacing)
                  : SizedBox(height: itemSpacing)
              : (context, index) => Container(),
          itemBuilder: (buildContext, index) {
            // Create child context with item data
            final childContext = context.createChildContext(
              variables: {
                'item': items[index],
                'index': index,
                'isFirst': index == 0,
                'isLast': index == items.length - 1,
                'isEven': index % 2 == 0,
                'isOdd': index % 2 == 1,
              },
            );

            return context.renderer.renderWidget(itemTemplate, childContext);
          },
        );
      }
    } else if (directItems != null && directItems.isNotEmpty) {
      // Direct items list (like in showcase_definition.dart)
      final items = directItems;

      listView = ListView.separated(
        scrollDirection: scrollDirection,
        reverse: reverse,
        shrinkWrap: shrinkWrap,
        physics: physics,
        padding: padding,
        cacheExtent: cacheExtent,
        itemCount: items.length,
        separatorBuilder: itemSpacing > 0
            ? (buildContext, index) => scrollDirection == Axis.horizontal
                ? SizedBox(width: itemSpacing)
                : SizedBox(height: itemSpacing)
            : (buildContext, index) => Container(),
        itemBuilder: (buildContext, index) {
          // Render each item directly as a widget
          return context.renderer.renderWidget(items[index], context);
        },
      );
    } else if (staticChildren != null && staticChildren.isNotEmpty) {
      // Static list with predefined children
      final children = staticChildren
          .map((child) => context.renderer.renderWidget(child, context))
          .toList();

      if (itemSpacing > 0) {
        // Use ListView.separated for spacing
        listView = ListView.separated(
          scrollDirection: scrollDirection,
          reverse: reverse,
          shrinkWrap: shrinkWrap,
          physics: physics,
          padding: padding,
          cacheExtent: cacheExtent,
          itemCount: children.length,
          separatorBuilder: (context, index) =>
              scrollDirection == Axis.horizontal
                  ? SizedBox(width: itemSpacing)
                  : SizedBox(height: itemSpacing),
          itemBuilder: (context, index) => children[index],
        );
      } else {
        // Regular ListView
        listView = ListView(
          scrollDirection: scrollDirection,
          reverse: reverse,
          shrinkWrap: shrinkWrap,
          physics: physics,
          padding: padding,
          cacheExtent: cacheExtent,
          itemExtent: itemExtent,
          children: children,
        );
      }
    } else {
      // Empty list - show emptyMessage if provided
      if (emptyMessage != null && emptyMessage.isNotEmpty) {
        listView = Center(
          child: Padding(
            padding: padding ?? EdgeInsets.zero,
            child: Text(
              emptyMessage,
              style: TextStyle(color: Theme.of(context.buildContext!).colorScheme.onSurface.withValues(alpha: 0.6)),
            ),
          ),
        );
      } else {
        listView = ListView(
          shrinkWrap: shrinkWrap,
          physics: physics,
          padding: padding,
        );
      }
    }

    // Ensure ListView has proper constraints for stability
    final wrappedListView =
        _ensureStableConstraints(listView, shrinkWrap, scrollDirection);

    return applyCommonWrappers(wrappedListView, properties, context);
  }

  Widget _ensureStableConstraints(
      Widget listView, bool shrinkWrap, Axis scrollDirection) {
    // If shrinkWrap is true, the ListView handles its own constraints
    if (shrinkWrap) {
      return listView;
    }

    // For non-shrinkWrap ListViews, ensure they have bounded constraints
    // along the scroll axis. A horizontal ListView in a parent with
    // unbounded width — the typical bug being a list nested in a Row
    // with a Spacer / Expanded sibling — throws `Horizontal viewport
    // given unbounded width` at layout time. Mirror the existing
    // vertical fallback for horizontal so author mistakes degrade
    // gracefully to a viewport-sized scroller instead of an assertion.
    return LayoutBuilder(
      builder: (context, constraints) {
        final mq = MediaQuery.of(context).size;
        if (scrollDirection == Axis.horizontal) {
          if (constraints.hasBoundedWidth) return listView;
          return SizedBox(width: mq.width, child: listView);
        }
        if (constraints.hasBoundedHeight) return listView;
        return SizedBox(height: mq.height, child: listView);
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
