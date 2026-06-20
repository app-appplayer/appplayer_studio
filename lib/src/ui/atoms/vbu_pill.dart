import 'package:flutter/material.dart';

import '../tokens.dart';

/// Compact rounded pill — vibe-derived. surface2 background, full
/// radius, optional leading widget (icon, status dot, color swatch),
/// mono 11px label. Hosts wrap with `Tooltip` if they need a hint.
///
/// Use cases: url chips, transport status, build target hints,
/// inline chips inside a status row.
class VbuPill extends StatelessWidget {
  const VbuPill({
    super.key,
    required this.label,
    this.leading,
    this.onTap,
    this.background,
    this.foreground,
  });

  final String label;
  final Widget? leading;
  final VoidCallback? onTap;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final body = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VbuTokens.space2,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: background ?? c.surface2,
        borderRadius: BorderRadius.circular(VbuTokens.radiusFull),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (leading != null) ...<Widget>[leading!, const SizedBox(width: 4)],
          Text(
            label,
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 11,
              color: foreground ?? c.textSecondary,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return body;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(VbuTokens.radiusFull),
      child: body,
    );
  }
}
