/// One-line tile representing a file or folder — icon + name + meta
/// row + optional trailing. Used in any path list (recordings,
/// scenarios, sources, assets, …) so a studio doesn't re-roll the
/// same layout per surface.
library;

import 'package:flutter/material.dart';

import '../tokens.dart';

class VbuPathTile extends StatelessWidget {
  const VbuPathTile({
    super.key,
    required this.label,
    this.meta,
    this.leading,
    this.trailing,
    this.selected = false,
    this.onTap,
  });

  /// Display name (basename / friendly title).
  final String label;

  /// Secondary single-line text (modified date, size, kind, etc.).
  /// Renders in textTertiary mono 11px.
  final String? meta;

  /// Optional leading widget (icon, thumbnail, status dot). When null
  /// a default folder/file icon shows depending on whether `label`
  /// ends with `/`.
  final Widget? leading;

  /// Optional trailing widget (button row, badge, etc.).
  final Widget? trailing;

  /// Selected state — paints surface3 background + mint border.
  final bool selected;

  /// Tap handler; null = display-only.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final defaultLeading = Icon(
      label.endsWith('/')
          ? Icons.folder_outlined
          : Icons.insert_drive_file_outlined,
      size: 16,
      color: c.textTertiary,
    );
    final body = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VbuTokens.space3,
        vertical: VbuTokens.space2,
      ),
      decoration: BoxDecoration(
        color: selected ? c.surface3 : Colors.transparent,
        border: Border.all(
          color: selected ? c.mint : Colors.transparent,
          width: 1,
        ),
        borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
      ),
      child: Row(
        children: <Widget>[
          leading ?? defaultLeading,
          const SizedBox(width: VbuTokens.space2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: VbuTokens.fontSans,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: c.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (meta != null && meta!.isNotEmpty)
                  Text(
                    meta!,
                    style: TextStyle(
                      fontFamily: VbuTokens.fontMono,
                      fontSize: 11,
                      color: c.textTertiary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: VbuTokens.space2),
            trailing!,
          ],
        ],
      ),
    );
    if (onTap == null) return body;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
      child: body,
    );
  }
}
