import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for tab bar view widget
class TabBarViewWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final children = definition['children'] as List<dynamic>? ?? [];

    // Spec §2.8.4: `selectedIndex` selects the initial active page.
    final selectedIndex = (properties['selectedIndex'] is int)
        ? properties['selectedIndex'] as int
        : 0;

    return DefaultTabController(
      length: children.isEmpty ? 1 : children.length,
      initialIndex:
          selectedIndex.clamp(0, children.isEmpty ? 0 : children.length - 1),
      child: TabBarView(
        physics: _resolveScrollPhysics(properties['physics']),
        dragStartBehavior:
            _resolveDragStartBehavior(properties['dragStartBehavior']),
        children: children
            .map((child) => context.buildWidget(child as Map<String, dynamic>))
            .toList(),
      ),
    );
  }

  ScrollPhysics? _resolveScrollPhysics(String? physics) {
    switch (physics) {
      case 'bounce':
        return const BouncingScrollPhysics();
      case 'clamp':
        return const ClampingScrollPhysics();
      case 'never':
        return const NeverScrollableScrollPhysics();
      default:
        return null;
    }
  }

  DragStartBehavior _resolveDragStartBehavior(String? behavior) {
    switch (behavior) {
      case 'down':
        return DragStartBehavior.down;
      case 'start':
        return DragStartBehavior.start;
      default:
        return DragStartBehavior.start;
    }
  }
}
