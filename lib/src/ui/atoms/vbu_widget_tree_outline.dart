import 'package:flutter/material.dart';

import '../tokens.dart';

/// One node in a [VbuWidgetTreeOutline] — `id` (stable key) + `label`
/// (shown) + optional `icon` + optional `children`. `selected` flag is
/// computed by the host against the current selection path.
class VbuWidgetTreeNode {
  const VbuWidgetTreeNode({
    required this.id,
    required this.label,
    this.icon,
    this.children = const <VbuWidgetTreeNode>[],
  });

  final String id;
  final String label;
  final IconData? icon;
  final List<VbuWidgetTreeNode> children;
}

/// Inspector widget-tree outline — expand/collapse caret nodes with
/// indentation per depth, hover/selected states. Catalog Part E.23.
///
/// Stateless above the expansion state; expansion is tracked in this
/// widget. Selection is reported via `onSelect(id)` so the host owns
/// the canonical selection (mirrored back via `selectedId`).
class VbuWidgetTreeOutline extends StatefulWidget {
  const VbuWidgetTreeOutline({
    super.key,
    required this.root,
    this.selectedId,
    this.onSelect,
    this.indent = 14,
    this.rowHeight = 24,
  });

  final List<VbuWidgetTreeNode> root;
  final String? selectedId;
  final ValueChanged<String>? onSelect;
  final double indent;
  final double rowHeight;

  @override
  State<VbuWidgetTreeOutline> createState() => _VbuWidgetTreeOutlineState();
}

class _VbuWidgetTreeOutlineState extends State<VbuWidgetTreeOutline> {
  final Set<String> _expanded = <String>{};

  void _toggle(String id) {
    setState(() {
      if (_expanded.contains(id)) {
        _expanded.remove(id);
      } else {
        _expanded.add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final flat = <_FlatRow>[];
    void walk(VbuWidgetTreeNode n, int depth) {
      flat.add(_FlatRow(node: n, depth: depth));
      if (n.children.isEmpty) return;
      if (!_expanded.contains(n.id)) return;
      for (final ch in n.children) {
        walk(ch, depth + 1);
      }
    }

    for (final r in widget.root) {
      walk(r, 0);
    }

    return ListView.builder(
      itemCount: flat.length,
      itemExtent: widget.rowHeight,
      itemBuilder: (ctx, i) {
        final row = flat[i];
        return _NodeRow(
          row: row,
          indent: widget.indent,
          selected: widget.selectedId == row.node.id,
          isExpanded: _expanded.contains(row.node.id),
          onTap: () => widget.onSelect?.call(row.node.id),
          onToggle:
              row.node.children.isEmpty ? null : () => _toggle(row.node.id),
        );
      },
    );
  }
}

class _FlatRow {
  const _FlatRow({required this.node, required this.depth});
  final VbuWidgetTreeNode node;
  final int depth;
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({
    required this.row,
    required this.indent,
    required this.selected,
    required this.isExpanded,
    required this.onTap,
    this.onToggle,
  });

  final _FlatRow row;
  final double indent;
  final bool selected;
  final bool isExpanded;
  final VoidCallback onTap;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          color: selected ? c.surface3 : Colors.transparent,
          padding: EdgeInsets.only(left: 4 + row.depth * indent),
          child: Row(
            children: <Widget>[
              if (onToggle != null)
                GestureDetector(
                  onTap: onToggle,
                  child: Icon(
                    isExpanded ? Icons.expand_more : Icons.chevron_right,
                    size: 14,
                    color: c.textSecondary,
                  ),
                )
              else
                const SizedBox(width: 14),
              if (row.node.icon != null) ...<Widget>[
                Icon(row.node.icon, size: 12, color: c.textSecondary),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  row.node.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 12,
                    color: selected ? c.textPrimary : c.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
