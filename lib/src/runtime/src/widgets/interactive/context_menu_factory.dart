import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for `contextMenu` (spec §2.8.10).
///
/// Cannot be composed: the raising gesture is platform-specific — and on touch
/// competes with scroll and text selection — and the menu must appear **at the
/// pointer** rather than against the child's box. A `gestureDetector` wrapping
/// a `popupMenuButton` gets neither.
class ContextMenuFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final childDef = properties['child'] as Map<String, dynamic>?;
    if (childDef == null) return const SizedBox.shrink();

    final items = context.resolve<List<dynamic>?>(properties['items']) ?? const [];
    final enabled = context.resolve<bool?>(properties['enabled']) ?? true;
    final onSelect = actionOf(properties['onSelect'], context);

    final child = context.renderer.renderWidget(childDef, context);
    if (!enabled) return child;

    Future<void> show(BuildContext buildContext, Offset globalPosition) async {
      final overlay =
          Overlay.of(buildContext).context.findRenderObject() as RenderBox?;
      if (overlay == null) return;

      final entries = <PopupMenuEntry<String>>[];
      for (final raw in items) {
        if (raw is! Map) continue;
        if (raw['divider'] == true) {
          entries.add(const PopupMenuDivider());
          continue;
        }
        entries.add(
          PopupMenuItem<String>(
            value: raw['key']?.toString(),
            enabled: raw['enabled'] != false,
            child: Text(raw['label']?.toString() ?? ''),
          ),
        );
      }
      if (entries.isEmpty) return;

      final selected = await showMenu<String>(
        context: buildContext,
        // Positioned at the pointer — the reason this is a widget.
        position: RelativeRect.fromLTRB(
          globalPosition.dx,
          globalPosition.dy,
          overlay.size.width - globalPosition.dx,
          overlay.size.height - globalPosition.dy,
        ),
        items: entries,
      );

      if (selected == null || onSelect == null) return;
      context.actionHandler.execute(
        onSelect,
        context.createChildContext(
          variables: {
            'event': {'value': selected, 'type': 'select'},
          },
        ),
      );
    }

    return Builder(
      builder: (buildContext) => GestureDetector(
        // Secondary tap on pointer devices, long press on touch — the same
        // menu from either, which is what "platform-specific gesture" means.
        onSecondaryTapDown: (d) => show(buildContext, d.globalPosition),
        onLongPressStart: (d) => show(buildContext, d.globalPosition),
        child: child,
      ),
    );
  }
}
