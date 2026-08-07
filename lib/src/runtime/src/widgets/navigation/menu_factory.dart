import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for `menu` (spec §2.8.9).
///
/// Standing navigation, unlike `popupMenuButton` which is a trigger opening a
/// transient list. `navigationRail` covers the icon-rail form with a flat item
/// set; this covers nesting, collapsing, and the sidebar admin screens are
/// built from.
class MenuFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final items = context.resolve<List<dynamic>?>(properties['items']) ?? const [];
    final mode = context.resolve<String?>(properties['mode']) ?? 'vertical';
    final collapsed = context.resolve<bool?>(properties['collapsed']) ?? false;
    final selectedBinding = stringOf(properties['selectedKey'], context);
    final openBinding = stringOf(properties['openKeys'], context);
    final onSelect = actionOf(properties['onSelect'], context);

    final selectedKey = selectedBinding != null
        ? context.getState(selectedBinding)?.toString()
        : context.resolve<String?>(properties['selectedKey']);

    final openKeys = <String>{
      if (openBinding != null)
        ...((context.getState(openBinding) as List?) ?? const [])
            .map((e) => e.toString()),
    };

    void select(Map<String, dynamic> item) {
      final key = item['key']?.toString();
      if (key == null) return;
      if (selectedBinding != null) context.setValue(selectedBinding, key);
      final route = item['route']?.toString();
      if (route != null) {
        context.actionHandler.execute({
          'type': 'navigation',
          'action': 'push',
          'route': route,
          if (item['params'] != null) 'params': item['params'],
        }, context);
      }
      if (onSelect != null) {
        context.actionHandler.execute(
          onSelect,
          context.createChildContext(
            variables: {
              'event': {'value': key, 'item': item, 'type': 'select'},
            },
          ),
        );
      }
    }

    void toggleGroup(String key) {
      if (openBinding == null) return;
      final next = Set<String>.from(openKeys);
      next.contains(key) ? next.remove(key) : next.add(key);
      context.setValue(openBinding, next.toList());
    }

    final rendered = <Widget>[
      for (final raw in items)
        if (raw is Map)
          _MenuEntry(
            item: Map<String, dynamic>.from(raw),
            depth: 0,
            collapsed: collapsed,
            selectedKey: selectedKey,
            openKeys: openKeys,
            onSelect: select,
            onToggle: toggleGroup,
          ),
    ];

    return mode == 'horizontal'
        ? Row(mainAxisSize: MainAxisSize.min, children: rendered)
        : Column(mainAxisSize: MainAxisSize.min, children: rendered);
  }
}

class _MenuEntry extends StatelessWidget {
  const _MenuEntry({
    required this.item,
    required this.depth,
    required this.collapsed,
    required this.selectedKey,
    required this.openKeys,
    required this.onSelect,
    required this.onToggle,
  });

  final Map<String, dynamic> item;
  final int depth;
  final bool collapsed;
  final String? selectedKey;
  final Set<String> openKeys;
  final void Function(Map<String, dynamic>) onSelect;
  final void Function(String) onToggle;

  @override
  Widget build(BuildContext context) {
    final key = item['key']?.toString() ?? '';
    final label = item['label']?.toString() ?? '';
    final children = item['children'];
    final isGroup = children is List && children.isNotEmpty;
    final enabled = item['enabled'] != false;
    final selected = key == selectedKey;
    final open = openKeys.contains(key);

    final tile = ListTile(
      dense: true,
      selected: selected,
      enabled: enabled,
      contentPadding: EdgeInsets.only(left: 16.0 + depth * 16, right: 8),
      leading: item['icon'] != null ? const Icon(Icons.circle, size: 8) : null,
      // Collapsed labels move into tooltips rather than disappearing, so the
      // rail stays usable without a legend.
      title: collapsed ? null : Text(label),
      trailing: isGroup && !collapsed
          ? Icon(open ? Icons.expand_less : Icons.expand_more)
          : null,
      // Group items are not destinations and do not fire onSelect.
      onTap: !enabled
          ? null
          : isGroup
              ? () => onToggle(key)
              : () => onSelect(item),
    );

    final row = collapsed ? Tooltip(message: label, child: tile) : tile;

    if (!isGroup || collapsed || !open) return row;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        for (final child in children)
          if (child is Map)
            _MenuEntry(
              item: Map<String, dynamic>.from(child),
              depth: depth + 1,
              collapsed: collapsed,
              selectedKey: selectedKey,
              openKeys: openKeys,
              onSelect: onSelect,
              onToggle: onToggle,
            ),
      ],
    );
  }
}
