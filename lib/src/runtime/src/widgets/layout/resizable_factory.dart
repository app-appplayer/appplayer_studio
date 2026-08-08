import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../../utils/binding_path.dart';
import '../widget_factory.dart';

/// Factory for `resizable` (spec §10.29).
///
/// Sizes one box against whatever surrounds it. `splitter` is the other shape
/// — a fixed area divided between siblings.
class ResizableFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final childDef = properties['child'] as Map<String, dynamic>?;
    if (childDef == null) return const SizedBox.shrink();

    final widthBinding = twoWayPath(properties['width']);
    final heightBinding = twoWayPath(properties['height']);
    final handles = (context.resolve<List<dynamic>?>(properties['handles']) ??
            const ['bottomEnd'])
        .map((e) => e.toString())
        .toSet();
    final keepRatio =
        boolOf(properties['keepAspectRatio'], context) ?? false;
    final onResize = actionOf(properties['onResize'], context);
    final onResizeEnd = actionOf(properties['onResizeEnd'], context);

    // `resolve` handles both branches — a literal number and a binding
    // expression — so the read needs no special case for the bound form.
    double? read(dynamic raw) => numberOf(raw, context)?.toDouble();

    void emit(Map<String, dynamic>? action, double w, double h, String type) {
      if (action == null) return;
      context.actionHandler.execute(
        action,
        context.createChildContext(
          variables: {
            'event': {'width': w, 'height': h, 'type': type},
          },
        ),
      );
    }

    return _Resizable(
      width: read(properties['width']),
      height: read(properties['height']),
      minWidth: numberOf(properties['minWidth'], context)?.toDouble(),
      maxWidth: numberOf(properties['maxWidth'], context)?.toDouble(),
      minHeight: numberOf(properties['minHeight'], context)?.toDouble(),
      maxHeight: numberOf(properties['maxHeight'], context)?.toDouble(),
      handles: handles,
      keepAspectRatio: keepRatio,
      onResize: (w, h) {
        if (widthBinding != null) context.setValue(widthBinding, w);
        if (heightBinding != null) context.setValue(heightBinding, h);
        emit(onResize, w, h, 'resize');
      },
      // Prefer this for persistence — onResize fires per frame.
      onResizeEnd: (w, h) => emit(onResizeEnd, w, h, 'resizeEnd'),
      child: context.renderer.renderWidget(childDef, context),
    );
  }
}

class _Resizable extends StatefulWidget {
  const _Resizable({
    required this.handles,
    required this.keepAspectRatio,
    required this.onResize,
    required this.onResizeEnd,
    required this.child,
    this.width,
    this.height,
    this.minWidth,
    this.maxWidth,
    this.minHeight,
    this.maxHeight,
  });

  final Set<String> handles;
  final bool keepAspectRatio;
  final void Function(double width, double height) onResize;
  final void Function(double width, double height) onResizeEnd;
  final Widget child;
  final double? width;
  final double? height;
  final double? minWidth;
  final double? maxWidth;
  final double? minHeight;
  final double? maxHeight;

  @override
  State<_Resizable> createState() => _ResizableState();
}

class _ResizableState extends State<_Resizable> {
  double? _w;
  double? _h;

  @override
  void initState() {
    super.initState();
    _w = widget.width;
    _h = widget.height;
  }

  void _apply(double dw, double dh) {
    var w = (_w ?? 0) + dw;
    var h = (_h ?? 0) + dh;
    if (widget.keepAspectRatio && _w != null && _h != null && _w! > 0) {
      h = w * (_h! / _w!);
    }
    if (widget.minWidth != null && w < widget.minWidth!) w = widget.minWidth!;
    if (widget.maxWidth != null && w > widget.maxWidth!) w = widget.maxWidth!;
    if (widget.minHeight != null && h < widget.minHeight!) h = widget.minHeight!;
    if (widget.maxHeight != null && h > widget.maxHeight!) h = widget.maxHeight!;
    setState(() {
      _w = w;
      _h = h;
    });
    widget.onResize(w, h);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        SizedBox(width: _w, height: _h, child: widget.child),
        if (widget.handles.contains('end') ||
            widget.handles.contains('bottomEnd'))
          Positioned(
            right: 0,
            bottom: 0,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeDownRight,
              child: GestureDetector(
                onPanUpdate: (d) => _apply(d.delta.dx, d.delta.dy),
                onPanEnd: (_) => widget.onResizeEnd(_w ?? 0, _h ?? 0),
                child: Container(
                  width: 16,
                  height: 16,
                  color: Theme.of(context).dividerColor,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
