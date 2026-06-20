import 'package:flutter/material.dart';

import '../tokens.dart';

/// Drag handle between two resizable panels — vbu atom. Renders a
/// 1px divider with a wider invisible drag area, switches the cursor
/// to a column-resize icon on hover, and fires [onDrag] with the
/// per-frame pixel delta. Highlights the divider with the mint
/// accent during hover / active drag.
///
/// Pure visual — caller owns the actual width state and applies the
/// delta. Default axis is [Axis.horizontal] (column splitter); pass
/// [Axis.vertical] for a row splitter.
///
/// Hosts that previously hand-rolled a 1px Container + GestureDetector
/// chain (or worse, a Container with no GestureDetector — the bug we
/// hit on the chat panel) should compose this atom instead. The
/// invisible drag area is wider than the visible divider, so
/// hit-testing actually succeeds.
class VbuPanelSplitter extends StatefulWidget {
  const VbuPanelSplitter({
    super.key,
    required this.onDrag,
    this.onDragEnd,
    this.axis = Axis.horizontal,
    this.color,
    this.thickness = 1,
    this.hitWidth = 6,
  });

  /// Per-frame pixel delta. For horizontal axis, dx; for vertical,
  /// dy. Caller decides whether to add or subtract from the panel
  /// width / height.
  final ValueChanged<double> onDrag;

  /// Optional drag-end notification — useful for persisting the
  /// resulting size. Called once per drag.
  final VoidCallback? onDragEnd;

  /// Splitter orientation. Horizontal = vertical line between two
  /// columns (drag changes column widths). Vertical = horizontal line
  /// between two rows.
  final Axis axis;

  /// Divider line colour. Defaults to `VbuTokens.colorOf(context).borderDefault`.
  final Color? color;

  /// Visible divider thickness in px. Default 1.
  final double thickness;

  /// Invisible hit area thickness in px (perpendicular to the
  /// divider). Default 6 — enough to grab without precision.
  final double hitWidth;

  @override
  State<VbuPanelSplitter> createState() => _VbuPanelSplitterState();
}

class _VbuPanelSplitterState extends State<VbuPanelSplitter> {
  bool _hovered = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final base = widget.color ?? c.borderDefault;
    final highlight = _hovered || _dragging;
    final lineColor = highlight ? c.mint : base;
    final isHorizontal = widget.axis == Axis.horizontal;
    return MouseRegion(
      cursor:
          isHorizontal
              ? SystemMouseCursors.resizeColumn
              : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart:
            isHorizontal ? (_) => setState(() => _dragging = true) : null,
        onHorizontalDragUpdate:
            isHorizontal ? (d) => widget.onDrag(d.delta.dx) : null,
        onHorizontalDragEnd:
            isHorizontal
                ? (_) {
                  setState(() => _dragging = false);
                  widget.onDragEnd?.call();
                }
                : null,
        onVerticalDragStart:
            !isHorizontal ? (_) => setState(() => _dragging = true) : null,
        onVerticalDragUpdate:
            !isHorizontal ? (d) => widget.onDrag(d.delta.dy) : null,
        onVerticalDragEnd:
            !isHorizontal
                ? (_) {
                  setState(() => _dragging = false);
                  widget.onDragEnd?.call();
                }
                : null,
        child: SizedBox(
          width: isHorizontal ? widget.hitWidth : null,
          height: isHorizontal ? null : widget.hitWidth,
          child: Center(
            child: Container(
              width: isHorizontal ? widget.thickness : null,
              height: isHorizontal ? null : widget.thickness,
              color: lineColor,
            ),
          ),
        ),
      ),
    );
  }
}
