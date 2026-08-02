import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for `splitter` (spec §10.28).
///
/// Divides a fixed area between siblings: dragging a gutter takes space from
/// one pane and gives it to the next, so the total never changes. `resizable`
/// is the other shape — one box sized against the layout around it.
class SplitterFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final childDefs = properties['children'] as List<dynamic>? ?? const [];
    if (childDefs.length < 2) {
      // One pane has nothing to divide against.
      return childDefs.isEmpty
          ? const SizedBox.shrink()
          : context.renderer.renderWidget(
              Map<String, dynamic>.from(childDefs.first as Map), context);
    }

    final horizontal =
        (context.resolve<String?>(properties['orientation']) ?? 'horizontal') ==
            'horizontal';
    final gutterSize =
        context.resolve<num?>(properties['gutterSize'])?.toDouble() ?? 8.0;
    // §10: `sizes` is `array<number> | binding`. A bare state path is read
    // from state; anything else (a literal array, a `{{...}}` expression)
    // goes through the normal resolver.
    final rawSizesProperty = properties['sizes'];
    final sizesBinding = rawSizesProperty is String ? rawSizesProperty : null;
    final onDragEnd = properties['onDragEnd'] as Map<String, dynamic>?;

    final rawSizes = sizesBinding != null
        ? context.getState(sizesBinding)
        : context.resolve<dynamic>(rawSizesProperty);
    final sizes = rawSizes is List && rawSizes.length == childDefs.length
        ? rawSizes.map((e) => (e as num).toDouble()).toList()
        : List<double>.filled(childDefs.length, 1 / childDefs.length);

    final minSizes = context.resolve<List<dynamic>?>(properties['minSizes'])
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        List<double>.filled(childDefs.length, 0.05);

    return _Splitter(
      horizontal: horizontal,
      gutterSize: gutterSize,
      sizes: sizes,
      minSizes: minSizes,
      children: [
        for (final def in childDefs)
          context.renderer
              .renderWidget(Map<String, dynamic>.from(def as Map), context),
      ],
      onChanged: (next) {
        if (sizesBinding != null) context.setValue(sizesBinding, next);
      },
      onDragEnd: (next) {
        if (onDragEnd == null) return;
        context.actionHandler.execute(
          onDragEnd,
          context.createChildContext(
            variables: {
              'event': {'value': next, 'type': 'dragEnd'},
            },
          ),
        );
      },
    );
  }
}

class _Splitter extends StatefulWidget {
  const _Splitter({
    required this.children,
    required this.sizes,
    required this.minSizes,
    required this.horizontal,
    required this.gutterSize,
    required this.onChanged,
    required this.onDragEnd,
  });

  final List<Widget> children;
  final List<double> sizes;
  final List<double> minSizes;
  final bool horizontal;
  final double gutterSize;
  final ValueChanged<List<double>> onChanged;
  final ValueChanged<List<double>> onDragEnd;

  @override
  State<_Splitter> createState() => _SplitterState();
}

class _SplitterState extends State<_Splitter> {
  late List<double> _sizes = List<double>.from(widget.sizes);

  @override
  void didUpdateWidget(_Splitter old) {
    super.didUpdateWidget(old);
    if (old.sizes != widget.sizes) _sizes = List<double>.from(widget.sizes);
  }

  void _drag(int gutter, double deltaFraction) {
    final next = List<double>.from(_sizes);
    final a = gutter, b = gutter + 1;
    // Space moves between the two adjacent panes only, so the total stays 1.
    var moved = deltaFraction;
    if (next[a] + moved < widget.minSizes[a]) {
      moved = widget.minSizes[a] - next[a];
    }
    if (next[b] - moved < widget.minSizes[b]) {
      moved = next[b] - widget.minSizes[b];
    }
    next[a] += moved;
    next[b] -= moved;
    setState(() => _sizes = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, constraints) {
        final extent =
            widget.horizontal ? constraints.maxWidth : constraints.maxHeight;
        final gutters = widget.children.length - 1;
        final available = extent - gutters * widget.gutterSize;

        final slivers = <Widget>[];
        for (var i = 0; i < widget.children.length; i++) {
          slivers.add(
            SizedBox(
              width: widget.horizontal ? available * _sizes[i] : null,
              height: widget.horizontal ? null : available * _sizes[i],
              child: widget.children[i],
            ),
          );
          if (i < gutters) {
            slivers.add(
              MouseRegion(
                cursor: widget.horizontal
                    ? SystemMouseCursors.resizeColumn
                    : SystemMouseCursors.resizeRow,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: widget.horizontal
                      ? (d) => _drag(i, d.delta.dx / available)
                      : null,
                  onVerticalDragUpdate: widget.horizontal
                      ? null
                      : (d) => _drag(i, d.delta.dy / available),
                  onHorizontalDragEnd:
                      widget.horizontal ? (_) => widget.onDragEnd(_sizes) : null,
                  onVerticalDragEnd:
                      widget.horizontal ? null : (_) => widget.onDragEnd(_sizes),
                  child: Container(
                    width: widget.horizontal ? widget.gutterSize : null,
                    height: widget.horizontal ? null : widget.gutterSize,
                    color: Theme.of(context).dividerColor,
                  ),
                ),
              ),
            );
          }
        }

        return widget.horizontal
            ? Row(children: slivers)
            : Column(children: slivers);
      },
    );
  }
}
