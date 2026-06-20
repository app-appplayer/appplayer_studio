import 'package:flutter/material.dart';

import '../tokens.dart';

/// Compact icon-only button with tooltip + hover. vibe-derived atom —
/// 16px icon, surface3 hover background, optional `emphasised` accent
/// (mint) for primary actions like Save when dirty.
///
/// Hosts pass `onTap: null` to disable; the icon dims to textTertiary
/// and the hover state is suppressed.
class VbuIconButton extends StatefulWidget {
  const VbuIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.emphasised = false,
    this.iconSize = 16,
  });

  final String tooltip;
  final IconData icon;

  /// Null disables the button (no hover, dimmed icon, no tap).
  final VoidCallback? onTap;

  /// Highlights the icon (mint tone) when there is something to act on
  /// — used by Save while dirty so the affordance is doubly obvious.
  final bool emphasised;

  final double iconSize;

  @override
  State<VbuIconButton> createState() => _VbuIconButtonState();
}

class _VbuIconButtonState extends State<VbuIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final enabled = widget.onTap != null;
    final iconColor =
        !enabled
            ? c.textTertiary
            : widget.emphasised
            ? c.mint
            : (_hovered ? c.textPrimary : c.textSecondary);
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) {
          if (!enabled) return;
          setState(() => _hovered = true);
        },
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: VbuTokens.durFast,
            curve: VbuTokens.easeStandard,
            margin: const EdgeInsets.only(right: 1),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
            decoration: BoxDecoration(
              color: enabled && _hovered ? c.surface3 : Colors.transparent,
              borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
            ),
            child: Icon(widget.icon, size: widget.iconSize, color: iconColor),
          ),
        ),
      ),
    );
  }
}
