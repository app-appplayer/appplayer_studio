import 'package:flutter/material.dart';

import '../tokens.dart';

/// One icon entry in a [VbuActivityBar]. `onTap == null` renders as
/// disabled (tertiary tint, no hover, no cursor change). Set
/// [emphasised] for the mint accent — typically reserved for "needs
/// attention" verbs (e.g. unsaved changes → Save).
class VbuActivityBarItem {
  const VbuActivityBarItem({
    required this.tooltip,
    required this.icon,
    this.onTap,
    this.emphasised = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;
  final bool emphasised;
}

/// Thin vertical icon bar — vbu atom. Renders the icons passed in
/// [groups], inserting a divider between each group. Pure visual:
/// no knowledge of projects, undo/redo, history, or any host concept.
/// The host (or LLM-generated shell) builds the [groups] list from
/// whatever data binding it owns.
///
/// Surface palette + spacing match the Settings dialog and tab strip,
/// so the bar reads as part of the same shell tone. Width defaults to
/// 36 px — the standard sliver column on the studio's left edge.
///
/// Hosts that previously hand-rolled an activity bar (and re-derived
/// hover / disabled / emphasised colouring each time) should compose
/// this atom instead. That handroll was the original source of token
/// drift across builders.
class VbuActivityBar extends StatelessWidget {
  const VbuActivityBar({super.key, required this.groups, this.width = 36.0});

  /// Icon groups, top-to-bottom. A divider is drawn between each
  /// group. Pass a single-group list to render a flat bar with no
  /// dividers.
  final List<List<VbuActivityBarItem>> groups;

  final double width;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final children = <Widget>[];
    for (var g = 0; g < groups.length; g++) {
      if (g > 0) children.add(_divider(c));
      for (final it in groups[g]) {
        children.add(_VbuActivityBarIcon(item: it));
      }
    }
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(right: BorderSide(color: c.borderDefault)),
      ),
      padding: const EdgeInsets.symmetric(vertical: VbuTokens.space2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: children,
      ),
    );
  }

  Widget _divider(dynamic c) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: 6,
      vertical: VbuTokens.space2,
    ),
    child: Container(height: 1, color: c.borderDefault),
  );
}

class _VbuActivityBarIcon extends StatefulWidget {
  const _VbuActivityBarIcon({required this.item});
  final VbuActivityBarItem item;

  @override
  State<_VbuActivityBarIcon> createState() => _VbuActivityBarIconState();
}

class _VbuActivityBarIconState extends State<_VbuActivityBarIcon> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final enabled = widget.item.onTap != null;
    final iconColor =
        !enabled
            ? c.textTertiary
            : widget.item.emphasised
            ? c.mint
            : (_hovered ? c.textPrimary : c.textSecondary);
    return Tooltip(
      message: widget.item.tooltip,
      waitDuration: const Duration(milliseconds: 150),
      preferBelow: false,
      verticalOffset: 18,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
        border: Border.all(color: c.borderDefault),
      ),
      textStyle: TextStyle(
        fontFamily: VbuTokens.fontMono,
        fontSize: 11,
        color: c.textPrimary,
      ),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) {
          if (!enabled) return;
          setState(() => _hovered = true);
        },
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.item.onTap,
          child: AnimatedContainer(
            duration: VbuTokens.durFast,
            curve: VbuTokens.easeStandard,
            margin: const EdgeInsets.symmetric(vertical: 1),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            decoration: BoxDecoration(
              color: enabled && _hovered ? c.surface3 : Colors.transparent,
              borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
            ),
            child: Icon(widget.item.icon, size: 16, color: iconColor),
          ),
        ),
      ),
    );
  }
}
