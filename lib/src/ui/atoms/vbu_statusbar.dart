import 'package:flutter/material.dart';

import '../tokens.dart';

/// Bottom status bar — vbu atom. Pure container that lays out the
/// [left] slot, a flexible spacer, and the [right] slot in a single
/// row. Surface palette + top border + 24px height match the
/// titlebar / tab strip so the shell reads as one tone.
///
/// Caller passes whatever cells they want — typically
/// [VbuStatusDot] + mono Text for state, [VbuStatusBadge] for
/// click-through indicators (lint, errors, warnings). Default
/// typography: mono 11px tertiary tint. Cells handle their own colour
/// when they need to deviate.
///
/// Hosts that previously hand-rolled a Row + surface bg + spacer
/// chain should compose this atom instead.
class VbuStatusbar extends StatelessWidget {
  const VbuStatusbar({
    super.key,
    this.left = const <Widget>[],
    this.right = const <Widget>[],
    this.height = VbuTokens.statusbarHeight,
    this.gap = VbuTokens.space4,
  });

  /// Left-aligned cells (state dot, counts, etc.).
  final List<Widget> left;

  /// Right-aligned cells (locale, version, …).
  final List<Widget> right;

  final double height;

  /// Horizontal gap inserted between adjacent cells in each slot.
  final double gap;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.borderDefault, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: VbuTokens.space3),
      child: Row(
        children: <Widget>[
          for (var i = 0; i < left.length; i++) ...<Widget>[
            if (i > 0) SizedBox(width: gap),
            left[i],
          ],
          const Spacer(),
          for (var i = 0; i < right.length; i++) ...<Widget>[
            if (i > 0) SizedBox(width: gap),
            right[i],
          ],
        ],
      ),
    );
  }
}

/// Small filled circle — typically used as a state indicator at the
/// left of a [VbuStatusbar] cell or inside a [VbuStatusBadge].
class VbuStatusDot extends StatelessWidget {
  const VbuStatusDot({super.key, required this.color, this.size = 6});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// Dot + label cell — optionally tappable. Used for compact
/// indicators inside a [VbuStatusbar] (lint counts, error counts,
/// connection state, …). Caller picks the dot colour to encode
/// severity.
class VbuStatusBadge extends StatelessWidget {
  const VbuStatusBadge({
    super.key,
    required this.color,
    required this.label,
    this.onTap,
  });

  final Color color;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final cell = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          VbuStatusDot(color: color),
          const SizedBox(width: VbuTokens.space2),
          Text(
            label,
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 11,
              color: c.textTertiary,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return cell;
    return InkWell(onTap: onTap, child: cell);
  }
}
