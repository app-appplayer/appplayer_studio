import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for `breadcrumb` (spec §2.8.11).
class BreadcrumbFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final items = context.resolve<List<dynamic>?>(properties['items']) ?? const [];
    final separator = context.resolve<String?>(properties['separator']) ?? '/';
    final maxItems = context.resolve<num?>(properties['maxItems'])?.toInt();
    final onClick = actionOf(properties['onClick'], context);

    final entries = [
      for (final raw in items)
        if (raw is Map) Map<String, dynamic>.from(raw),
    ];
    if (entries.isEmpty) return const SizedBox.shrink();

    // Collapse the middle, keeping the first and the current location — the
    // two a reader actually needs.
    final visible = maxItems != null && entries.length > maxItems
        ? [entries.first, <String, dynamic>{'_ellipsis': true}, ...entries.sublist(entries.length - (maxItems - 1))]
        : entries;

    final children = <Widget>[];
    for (var i = 0; i < visible.length; i++) {
      final entry = visible[i];
      final isLast = i == visible.length - 1;

      if (entry['_ellipsis'] == true) {
        children.add(const Text('…'));
      } else {
        final label = entry['label']?.toString() ?? '';
        final route = entry['route']?.toString();
        // The final entry is the current location and is never a link, even
        // when it carries a route.
        final tappable = !isLast && route != null;
        children.add(
          Semantics(
            // Marks the current page for assistive technology.
            selected: isLast,
            child: tappable
                ? Builder(
                    builder: (ctx) => InkWell(
                      onTap: () => _navigate(context, entry, onClick),
                      child: Text(
                        label,
                        style: TextStyle(
                          color: Theme.of(ctx).colorScheme.primary,
                        ),
                      ),
                    ),
                  )
                : Text(
                    label,
                    style: TextStyle(
                      fontWeight: isLast ? FontWeight.w600 : null,
                    ),
                  ),
          ),
        );
      }

      if (!isLast) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            // Decorative — kept out of the accessibility tree so a reader
            // does not hear "slash" between every step.
            child: ExcludeSemantics(
              child: Builder(
                builder: (ctx) => Text(
                  separator,
                  style: TextStyle(color: Theme.of(ctx).disabledColor),
                ),
              ),
            ),
          ),
        );
      }
    }

    return Semantics(
      container: true,
      label: 'Breadcrumb',
      child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: children),
    );
  }

  void _navigate(
    RenderContext context,
    Map<String, dynamic> entry,
    Map<String, dynamic>? onClick,
  ) {
    final route = entry['route']?.toString();
    if (route != null) {
      context.actionHandler.execute({
        'type': 'navigation',
        'action': 'push',
        'route': route,
        if (entry['params'] != null) 'params': entry['params'],
      }, context);
    }
    if (onClick != null) {
      context.actionHandler.execute(
        onClick,
        context.createChildContext(
          variables: {
            'event': {'value': entry, 'type': 'click'},
          },
        ),
      );
    }
  }
}
