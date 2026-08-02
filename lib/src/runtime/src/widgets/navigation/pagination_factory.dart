import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for `pagination` (spec §2.8.12).
///
/// The composed version is where off-by-one bugs live: first/last bounds, the
/// ellipsis window, and disabling prev/next at the ends get re-derived by
/// every author. Stating it once also fixes what a screen reader hears —
/// "page 3 of 12", not "3".
class PaginationFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final binding = properties['binding'] as String?;
    final total = context.resolve<num?>(properties['total'])?.toInt() ?? 0;
    final pageSize = context.resolve<num?>(properties['pageSize'])?.toInt() ?? 20;
    final siblings = context.resolve<num?>(properties['siblingCount'])?.toInt() ?? 1;
    final showTotal = context.resolve<bool?>(properties['showTotal']) ?? false;
    final showSizeChanger =
        context.resolve<bool?>(properties['showSizeChanger']) ?? false;
    final sizeOptions =
        context.resolve<List<dynamic>?>(properties['pageSizeOptions']) ?? const [10, 20, 50];
    final onChange = properties['onChange'] as Map<String, dynamic>?;

    final pageCount = pageSize <= 0 ? 1 : (total / pageSize).ceil().clamp(1, 1 << 30);
    final rawCurrent = binding != null
        ? (context.getState(binding) as num?)?.toInt()
        : context.resolve<num?>(properties['current'])?.toInt();
    final current = (rawCurrent ?? 1).clamp(1, pageCount);

    void goTo(int page) {
      final target = page.clamp(1, pageCount);
      if (target == current) return;
      if (binding != null) context.setValue(binding, target);
      if (onChange != null) {
        context.actionHandler.execute(
          onChange,
          context.createChildContext(
            variables: {
              'event': {'value': target, 'pageSize': pageSize, 'type': 'change'},
            },
          ),
        );
      }
    }

    final pages = _window(current, pageCount, siblings);

    return Semantics(
      container: true,
      label: 'Page $current of $pageCount',
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            // Disabled at the ends rather than clamping silently, so the
            // control tells the truth about where the user is.
            onPressed: current > 1 ? () => goTo(current - 1) : null,
            tooltip: 'Previous page',
          ),
          for (final p in pages)
            if (p == null)
              const Text('…')
            else
              _PageButton(
                page: p,
                selected: p == current,
                onTap: () => goTo(p),
              ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: current < pageCount ? () => goTo(current + 1) : null,
            tooltip: 'Next page',
          ),
          if (showTotal)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('$total items'),
            ),
          if (showSizeChanger)
            DropdownButton<int>(
              value: sizeOptions.contains(pageSize) ? pageSize : null,
              items: [
                for (final o in sizeOptions)
                  DropdownMenuItem(
                    value: (o as num).toInt(),
                    child: Text('$o / page'),
                  ),
              ],
              onChanged: (size) {
                if (size == null || onChange == null) return;
                context.actionHandler.execute(
                  onChange,
                  context.createChildContext(
                    variables: {
                      'event': {
                        'value': 1,
                        'pageSize': size,
                        'type': 'change',
                      },
                    },
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  /// Page numbers to show; `null` marks an elision.
  ///
  /// Always includes the first and last page so the ends stay reachable in one
  /// tap, which is the part a hand-rolled window usually drops.
  static List<int?> _window(int current, int count, int siblings) {
    if (count <= 1) return [1];
    final pages = <int?>[];
    final start = (current - siblings).clamp(1, count);
    final end = (current + siblings).clamp(1, count);

    pages.add(1);
    if (start > 2) pages.add(null);
    for (var p = start; p <= end; p++) {
      if (p != 1 && p != count) pages.add(p);
    }
    if (end < count - 1) pages.add(null);
    if (count > 1) pages.add(count);
    return pages;
  }
}

class _PageButton extends StatelessWidget {
  const _PageButton({
    required this.page,
    required this.selected,
    required this.onTap,
  });

  final int page;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      label: 'Page $page',
      child: InkWell(
        onTap: selected ? null : onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? scheme.primaryContainer : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text('$page'),
        ),
      ),
    );
  }
}
