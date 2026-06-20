import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for BottomSheet widgets
class BottomSheetWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context);
    final elevation = properties['elevation']?.toDouble();
    final shape = _parseShapeBorder(properties['shape']);
    final clipBehavior = _parseClip(properties['clipBehavior']);
    final constraints = _parseBoxConstraints(properties['constraints']);
    final enableDrag = properties['enableDrag'] as bool? ?? true;
    final showDragHandle = properties['showDragHandle'] as bool? ?? false;
    final dragHandleColor =
        parseColor(context.resolve(properties['dragHandleColor']), context);
    final dragHandleSize = _parseSize(properties['dragHandleSize']);
    final shadowColor = parseColor(context.resolve(properties['shadowColor']), context);

    // Extract action handlers
    final onClosing = properties['onClosing'] as Map<String, dynamic>?;

    // Build child widget
    final childrenData = definition['children'] as List<dynamic>?;
    Widget? child;
    if (childrenData != null && childrenData.isNotEmpty) {
      if (childrenData.length == 1) {
        child = context.renderer.renderWidget(childrenData.first, context);
      } else {
        // Multiple children - wrap in Column
        final children = childrenData
            .map((child) => context.renderer.renderWidget(child, context))
            .toList();
        child = Column(
          mainAxisSize: MainAxisSize.min,
          children: children,
        );
      }
    }

    // BottomSheet requires an AnimationController, typically used with showModalBottomSheet
    // For standalone use, wrap in a simple container
    Widget bottomSheet = Container(
      clipBehavior: clipBehavior,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius:
            shape is RoundedRectangleBorder ? shape.borderRadius : null,
        boxShadow: elevation != null
            ? [
                BoxShadow(
                  color: shadowColor ?? Colors.black26,
                  blurRadius: elevation,
                  offset: Offset(0, -elevation / 2),
                ),
              ]
            : null,
      ),
      constraints: constraints,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDragHandle)
            Container(
              width: dragHandleSize?.width ?? 32,
              height: dragHandleSize?.height ?? 4,
              margin: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: dragHandleColor ??
                    context.themeManager.getColorValue('outlineVariant') ??
                    Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          if (child != null) child,
        ],
      ),
    );

    // Apply drag behavior if enabled
    if (enableDrag) {
      bottomSheet = GestureDetector(
        onVerticalDragUpdate: (details) {
          // Handle drag if needed
          if (details.delta.dy > 10 && onClosing != null) {
            // User is dragging down, trigger onClosing
            context.actionHandler.execute(onClosing, context);
          }
        },
        child: bottomSheet,
      );
    }

    // If onClosing is specified but drag is disabled, wrap with NotificationListener
    if (onClosing != null && !enableDrag) {
      bottomSheet = NotificationListener<DraggableScrollableNotification>(
        onNotification: (notification) {
          if (notification.extent <= notification.minExtent) {
            context.actionHandler.execute(onClosing, context);
          }
          return false;
        },
        child: bottomSheet,
      );
    }

    return bottomSheet;
  }

  ShapeBorder? _parseShapeBorder(Map<String, dynamic>? shape) {
    if (shape == null) return null;

    final type = shape['type'] as String?;
    switch (type) {
      case 'rounded':
        final radius = shape['radius']?.toDouble() ?? 16.0;
        return RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(radius),
          ),
        );
      default:
        return null;
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

  BoxConstraints? _parseBoxConstraints(Map<String, dynamic>? constraints) {
    if (constraints == null) return null;

    return BoxConstraints(
      minWidth: constraints['minWidth']?.toDouble() ?? 0.0,
      maxWidth: constraints['maxWidth']?.toDouble() ?? double.infinity,
      minHeight: constraints['minHeight']?.toDouble() ?? 0.0,
      maxHeight: constraints['maxHeight']?.toDouble() ?? double.infinity,
    );
  }

  Size? _parseSize(Map<String, dynamic>? size) {
    if (size == null) return null;

    return Size(
      size['width']?.toDouble() ?? 0.0,
      size['height']?.toDouble() ?? 0.0,
    );
  }
}
