import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for creating Draggable widgets
class DraggableFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    // Get drag data
    final data = definition['data'];

    // Get child widget
    final childData = definition['child'];
    Widget child = const SizedBox();
    if (childData != null) {
      child = context.renderer.renderWidget(childData, context);
    }

    // Get feedback widget (widget shown while dragging)
    final feedbackData = definition['feedback'];
    Widget feedback;
    if (feedbackData != null) {
      feedback = Material(
        color: Colors.transparent,
        child: context.renderer.renderWidget(feedbackData, context),
      );
    } else {
      // Default feedback is semi-transparent version of child
      feedback = Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.7,
          child: child,
        ),
      );
    }

    // Get child when dragging
    final childWhenDraggingData = definition['childWhenDragging'];
    Widget childWhenDragging;
    if (childWhenDraggingData != null) {
      childWhenDragging =
          context.renderer.renderWidget(childWhenDraggingData, context);
    } else {
      // Default is semi-transparent version
      childWhenDragging = Opacity(
        opacity: 0.3,
        child: child,
      );
    }

    // Get other properties
    final affinity = definition['affinity'];
    final axis = definition['axis'];
    final dragAnchorStrategy = definition['dragAnchorStrategy'];

    return Draggable<Object>(
      data: data,
      feedback: feedback,
      childWhenDragging: childWhenDragging,
      affinity: affinity != null
          ? Axis.values.firstWhere(
              (e) => e.name == affinity,
              orElse: () => Axis.vertical,
            )
          : null,
      axis: axis != null
          ? Axis.values.firstWhere(
              (e) => e.name == axis,
              orElse: () => Axis.vertical,
            )
          : null,
      dragAnchorStrategy: dragAnchorStrategy == 'pointerDragAnchorStrategy'
          ? pointerDragAnchorStrategy
          : childDragAnchorStrategy,
      onDragStarted: () {
        final onDragStarted = definition['onDragStarted'];
        if (onDragStarted != null) {
          context.actionHandler.execute(onDragStarted, context);
        }
      },
      onDragEnd: (details) {
        final onDragEnd = definition['onDragEnd'];
        if (onDragEnd != null) {
          // Could pass drag details if needed
          context.actionHandler.execute(onDragEnd, context);
        }
      },
      onDragCompleted: () {
        final onDragCompleted = definition['onDragCompleted'];
        if (onDragCompleted != null) {
          context.actionHandler.execute(onDragCompleted, context);
        }
      },
      onDraggableCanceled: (velocity, offset) {
        final onDraggableCanceled = definition['onDraggableCanceled'];
        if (onDraggableCanceled != null) {
          context.actionHandler.execute(onDraggableCanceled, context);
        }
      },
      child: child,
    );
  }
}
