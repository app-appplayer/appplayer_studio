import 'package:flutter/material.dart';
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for creating linear layout widgets (spec v1.0)
/// Supports both vertical and horizontal directions
class LinearLayoutFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Get direction. Canonical `direction`; spec §17.3.2 legacy aliases:
    // `orientation` (static-layout authors) and `scrollDirection` (authors
    // coming from Flutter's Row/Column wrapped in scroll views).
    final direction = context.resolve<String>(properties['direction'] ??
            properties['orientation'] ??
            properties['scrollDirection'] ??
            'vertical');
    final isVertical = direction == 'vertical';

    // Get distribution (spec v1.0 replacement for mainAxisAlignment)
    final distribution = context.resolve<String?>(properties['distribution']) ??
        context.resolve<String?>(properties['mainAxisAlignment']) ??
        'start';

    // Get alignment (spec v1.0 for crossAxisAlignment, default 'start' per spec)
    final alignment = context.resolve<String?>(properties['alignment']) ??
        context.resolve<String?>(properties['crossAxisAlignment']) ??
        'start';

    // Get spacing. Canonical `spacing`; legacy aliases `gap` and
    // `itemSpacing` per §17.3.2.
    final gapValue = context.resolve(properties['spacing'] ??
            properties['gap'] ??
            properties['itemSpacing']) ??
        0.0;
    final gap =
        gapValue is int ? gapValue.toDouble() : (gapValue as double? ?? 0.0);

    // Get wrap (spec v1.0 for whether items should wrap)
    final wrap = context.resolve<bool>(properties['wrap'] ?? false);

    // Build children
    final childrenDefs = definition['children'] as List<dynamic>? ?? [];
    final children = <Widget>[];

    for (final childDef in childrenDefs) {
      if (childDef is Map<String, dynamic>) {
        final child = context.buildWidget(childDef);

        // Check if child has flex property
        final flex = childDef['flex'];
        final childType = childDef['type'] as String?;
        // Skip Flexible wrapping for types that are already ParentDataWidgets
        final isFlexWidget = childType == 'expanded' ||
            childType == 'flexible' ||
            childType == 'spacer';
        if (flex != null && flex is int && !wrap && !isFlexWidget) {
          // Wrap in Flexible if flex is specified and not in wrap mode
          children.add(Flexible(
            flex: flex,
            child: child,
          ));
        } else {
          children.add(child);
        }
      }
    }

    // If gap is specified, add spacing between children
    List<Widget> spacedChildren = children;
    if (gap > 0 && children.length > 1) {
      spacedChildren = [];
      for (int i = 0; i < children.length; i++) {
        spacedChildren.add(children[i]);
        if (i < children.length - 1) {
          spacedChildren.add(SizedBox(
            width: isVertical ? 0 : gap,
            height: isVertical ? gap : 0,
          ));
        }
      }
    }

    // If wrap is true, use Wrap widget
    if (wrap) {
      return Wrap(
        direction: isVertical ? Axis.vertical : Axis.horizontal,
        alignment: _parseWrapAlignment(distribution),
        crossAxisAlignment: _parseWrapCrossAlignment(alignment),
        spacing: gap,
        runSpacing: gap,
        children: children,
      );
    }

    // Main-axis sizing — spec: default is `max` when any child is
    // `expanded` / `flexible` / `spacer` (so they can distribute the
    // remaining space), `min` otherwise (safe inside unbounded parents like
    // SingleChildScrollView). Authors can override with the explicit
    // `mainAxisSize` property.
    final hasFlexChild = childrenDefs.any((c) {
      if (c is! Map<String, dynamic>) return false;
      final t = c['type'];
      return t == 'expanded' ||
          t == 'flexible' ||
          t == 'spacer' ||
          c['flex'] != null;
    });
    final explicitMainAxisSize =
        context.resolve<String?>(properties['mainAxisSize']);
    final mainAxisSize = switch (explicitMainAxisSize) {
      'max' => MainAxisSize.max,
      'min' => MainAxisSize.min,
      _ => hasFlexChild ? MainAxisSize.max : MainAxisSize.min,
    };

    // Otherwise use Column or Row
    Widget widget = isVertical
        ? Column(
            mainAxisAlignment: _parseMainAxisAlignment(distribution),
            crossAxisAlignment: _parseCrossAxisAlignment(alignment),
            mainAxisSize: mainAxisSize,
            children: spacedChildren,
          )
        : Row(
            mainAxisAlignment: _parseMainAxisAlignment(distribution),
            crossAxisAlignment: _parseCrossAxisAlignment(alignment),
            mainAxisSize: mainAxisSize,
            children: spacedChildren,
          );

    // Apply padding if specified
    final padding = properties['padding'];
    if (padding != null) {
      widget = Padding(
        padding: parseEdgeInsets(padding) ?? EdgeInsets.zero,
        child: widget,
      );
    }

    return applyCommonWrappers(widget, properties, context);
  }

  MainAxisAlignment _parseMainAxisAlignment(String? value) {
    switch (value) {
      case 'start':
        return MainAxisAlignment.start;
      case 'end':
        return MainAxisAlignment.end;
      case 'center':
        return MainAxisAlignment.center;
      case 'space-between':
      case 'spaceBetween':
        return MainAxisAlignment.spaceBetween;
      case 'space-around':
      case 'spaceAround':
        return MainAxisAlignment.spaceAround;
      case 'space-evenly':
      case 'spaceEvenly':
        return MainAxisAlignment.spaceEvenly;
      default:
        return MainAxisAlignment.start;
    }
  }

  CrossAxisAlignment _parseCrossAxisAlignment(String? value) {
    switch (value) {
      case 'start':
        return CrossAxisAlignment.start;
      case 'end':
        return CrossAxisAlignment.end;
      case 'center':
        return CrossAxisAlignment.center;
      case 'stretch':
        return CrossAxisAlignment.stretch;
      case 'baseline':
        return CrossAxisAlignment.baseline;
      default:
        return CrossAxisAlignment.start;
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
      case 'space-between':
      case 'spaceBetween':
        return WrapAlignment.spaceBetween;
      case 'space-around':
      case 'spaceAround':
        return WrapAlignment.spaceAround;
      case 'space-evenly':
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
}
