import 'package:flutter/material.dart';

import '../tokens.dart';

/// One entry in a [VbuDomainActionsRow] — a single icon chip with a
/// tooltip plus an optional onTap. Mirrors the shape vibe_studio chrome
/// uses for `manifest.wiring.domainActions[]` entries on row 2 of the
/// ProjectHeader. The widget itself is inert (no manifest reads, no
/// callbacks beyond what the host wires) so the builder can render the
/// same shape with sample data without standing up the activation
/// pipeline.
class VbuDomainActionItem {
  const VbuDomainActionItem({
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.divider = false,
  });

  /// Material icon to draw inside the chip. Hosts are responsible for
  /// mapping a manifest-supplied `icon: "<name>"` string to an IconData;
  /// this atom only consumes the resolved IconData so it stays
  /// presentation-pure.
  final IconData icon;

  /// Hover label. Standard pattern is "<tooltip>\ntool: <name>\nid:
  /// <fullId>" so the user can read what the verb does AND copy the
  /// full MCP tool id.
  final String tooltip;

  /// Optional click handler. When null the chip still renders but
  /// doesn't react to taps — useful for preview rows inside the
  /// builder.
  final VoidCallback? onTap;

  /// When true, the row inserts a thin separator immediately before
  /// this item. Mirrors the convention chrome uses to mark a "this is
  /// where the bundle's own actions start" boundary after a set of
  /// built-in icons.
  final bool divider;
}

/// Horizontal strip of compact icon-chip actions — the canonical shape
/// of vibe_studio chrome's ProjectHeader row 2 (after the built-in
/// Import / Export / mode icons). Inert atom: feed it an [entries]
/// list and it lays out chips left-to-right with the same dimensions
/// the chrome uses, so the studio builder's Tools mode can render the
/// exact same strip as a preview without depending on activation
/// state or the live header sync. The host that wires real entries
/// supplies `onTap` per item (typically a dispatch into the bundle's
/// exposed MCP tool).
class VbuDomainActionsRow extends StatelessWidget {
  const VbuDomainActionsRow({
    super.key,
    required this.entries,
    this.iconSize = 16,
    this.chipSize = 26,
    this.spacing = 6,
  });

  final List<VbuDomainActionItem> entries;

  /// Inner icon size in logical pixels. 16 matches chrome row 2.
  final double iconSize;

  /// Outer chip side length (square). 26 matches chrome row 2.
  final double chipSize;

  /// Horizontal gap between chips. 6 matches chrome row 2.
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final children = <Widget>[];
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (e.divider && children.isNotEmpty) {
        children.add(SizedBox(width: spacing));
        children.add(
          Container(width: 1, height: chipSize - 8, color: c.borderSubtle),
        );
        children.add(SizedBox(width: spacing));
      } else if (i > 0) {
        children.add(SizedBox(width: spacing));
      }
      Widget chip = Container(
        width: chipSize,
        height: chipSize,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
          border: Border.all(color: c.borderDefault),
        ),
        child: Icon(e.icon, size: iconSize, color: c.mint),
      );
      if (e.onTap != null) {
        chip = InkWell(
          onTap: e.onTap,
          borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
          child: chip,
        );
      }
      children.add(Tooltip(message: e.tooltip, child: chip));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}
