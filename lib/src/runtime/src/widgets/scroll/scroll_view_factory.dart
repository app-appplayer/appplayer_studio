import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for creating SingleChildScrollView widgets
class ScrollViewFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Get scroll direction (spec v1.0: 'direction', legacy: 'scrollDirection')
    final scrollDirectionStr =
        (properties['direction'] ?? properties['scrollDirection']) as String?;
    final scrollDirection =
        scrollDirectionStr == 'horizontal' ? Axis.horizontal : Axis.vertical;

    // Get other properties
    final reverse = properties['reverse'] as bool? ?? false;
    final padding = parseEdgeInsets(properties['padding']);
    final primary = properties['primary'] as bool?;
    // Spec § scrollView v1.3 — `scrollPhysics` (canonical) replaces
    // the legacy `physics` key. Both accepted for backward compat.
    final physics = _parseScrollPhysics(
        properties['scrollPhysics'] ?? properties['physics']);

    // The registry declares `child`, `children` **and** `slivers`; this
    // factory read only the first, so a document written with `children` —
    // the shape §2 uses for every other multi-child widget, and the shape
    // this widget's own example uses — scrolled an empty viewport. `slivers`
    // is a sliver protocol this SingleChildScrollView cannot host, so it is
    // laid out as ordinary children rather than dropped: a sliver-shaped
    // document then draws its content in order instead of drawing nothing.
    Widget? child;
    final childDef = properties['child'] as Map<String, dynamic>?;
    final childrenDef = (properties['children'] ?? properties['slivers'])
        as List<dynamic>?;
    if (childDef != null) {
      child = context.renderer.renderWidget(childDef, context);
    } else if (childrenDef != null && childrenDef.isNotEmpty) {
      final built = <Widget>[
        for (final def in childrenDef)
          if (def is Map<String, dynamic>)
            context.renderer.renderWidget(def, context),
      ];
      child = scrollDirection == Axis.horizontal
          ? Row(mainAxisSize: MainAxisSize.min, children: built)
          : Column(mainAxisSize: MainAxisSize.min, children: built);
    }

    final scrollView = SingleChildScrollView(
      scrollDirection: scrollDirection,
      reverse: reverse,
      padding: padding,
      primary: primary,
      physics: physics,
      child: child,
    );

    // Ensure scrollview has proper constraints in test environment
    // This prevents viewport assertion errors during widget tree construction
    if (primary != false) {
      return scrollView;
    }

    // Wrap in a constrained box to ensure stable rendering
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.hasBoundedHeight && constraints.hasBoundedWidth) {
          return scrollView;
        }
        // Provide default constraints for unbounded contexts
        return SizedBox(
          width: constraints.hasBoundedWidth ? null : double.infinity,
          height: constraints.hasBoundedHeight
              ? null
              : MediaQuery.of(context).size.height,
          child: scrollView,
        );
      },
    );
  }

  ScrollPhysics? _parseScrollPhysics(String? value) {
    switch (value) {
      case 'never':
      case 'neverScrollable':
        return const NeverScrollableScrollPhysics();
      case 'always':
      case 'alwaysScrollable':
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
