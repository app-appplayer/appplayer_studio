import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for creating DragTarget widgets
class DragTargetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    // Canonical `builder` per spec §2.10.4; `child` accepted as legacy alias.
    // The registry also documents `children` — multiple widgets wrapped into
    // a linear column — which this factory used to reject, so a document
    // written the way the registry describes it threw.
    final rawChildren = definition['children'];
    final builderDef = definition['builder'] ??
        definition['child'] ??
        (rawChildren is List && rawChildren.isNotEmpty
            ? <String, dynamic>{
                'type': 'linear',
                'direction': 'vertical',
                'children': rawChildren,
              }
            : null);
    if (builderDef == null) {
      throw Exception(
          'DragTarget requires a builder (or child / children) property');
    }

    // Event handlers — canonical `onDrop` per spec, `onAccept` accepted as
    // Flutter-terminology alias.
    final onDrop =
        definition['onDrop'] ?? definition['onAccept'] ?? definition['drop'];
    final canDrop = definition['canDrop'];
    final onDragEnter = definition['onDragEnter'] ?? definition['dragEnter'];
    final onDragLeave = definition['onDragLeave'] ?? definition['dragLeave'];

    return DragTarget<Object>(
      builder: (BuildContext dragContext, List<Object?> candidateData,
          List<dynamic> rejectedData) {
        // Create context with drag state variables
        final childContext = context.createChildContext(
          variables: {
            'dragData': {
              'candidateData': candidateData,
              'rejectedData': rejectedData,
              'hasCandidates': candidateData.isNotEmpty,
            },
          },
        );
        return context.renderer.renderWidget(builderDef, childContext);
      },
      onWillAcceptWithDetails: (details) {
        // Maps to spec's onDragEnter (fired when draggable enters target area)
        if (onDragEnter != null) {
          final eventContext = context.createChildContext(
            variables: {
              'event': {
                'data': details.data,
                'offset': {
                  'dx': details.offset.dx,
                  'dy': details.offset.dy,
                },
              },
            },
          );
          context.actionHandler.execute(onDragEnter, eventContext);
        }
        // canDrop: binding expression evaluating drop eligibility
        if (canDrop != null) {
          final resolved = context.resolve(canDrop);
          return resolved == true || resolved == 'true';
        }
        return true;
      },
      onAcceptWithDetails: (details) {
        // Maps to spec's onDrop (fired when item is dropped)
        if (onDrop != null) {
          final eventContext = context.createChildContext(
            variables: {
              'event': {
                'data': details.data,
                'offset': {
                  'dx': details.offset.dx,
                  'dy': details.offset.dy,
                },
              },
            },
          );
          context.actionHandler.execute(onDrop, eventContext);
        }
      },
      onLeave: (data) {
        // Maps to spec's onDragLeave (fired when draggable leaves target area)
        if (onDragLeave != null) {
          final eventContext = context.createChildContext(
            variables: {
              'event': {
                'data': data,
              },
            },
          );
          context.actionHandler.execute(onDragLeave, eventContext);
        }
      },
    );
  }
}
