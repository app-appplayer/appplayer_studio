import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// Drop-down chevron that opens a popup menu listing recent items
/// (typically project / bundle paths). vibe-derived: chevron icon with
/// hover background, menu rendered via `showMenu` anchored to the
/// button. Each item shows the basename in mono + the full path in
/// muted text below.
///
/// Hosts pass a `List<String>` of paths and a callback for when the
/// user picks one. The header label defaults to `'RECENT'`; pass
/// [headerLabel] to localize / re-tone (`'RECENT PROJECTS'`).
class VbuRecentMenuButton extends StatefulWidget {
  const VbuRecentMenuButton({
    super.key,
    required this.recents,
    required this.onPick,
    this.tooltip = 'Recent',
    this.headerLabel = 'RECENT',
    this.minMenuWidth = 280,
    this.maxMenuWidth = 480,
  });

  final List<String> recents;
  final ValueChanged<String> onPick;
  final String tooltip;
  final String headerLabel;
  final double minMenuWidth;
  final double maxMenuWidth;

  @override
  State<VbuRecentMenuButton> createState() => _VbuRecentMenuButtonState();
}

class _VbuRecentMenuButtonState extends State<VbuRecentMenuButton> {
  bool _hovered = false;

  Future<void> _open(BuildContext context) async {
    final c = VbuTokens.colorOf(context);
    final box = context.findRenderObject();
    if (box is! RenderBox) return;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final overlaySize = overlayBox.size;
    final offset = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final size = box.size;
    final anchor = Rect.fromLTWH(
      offset.dx,
      offset.dy + size.height + 2,
      size.width,
      0,
    );
    final picked = await showMenu<String>(
      context: context,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      menuPadding: EdgeInsets.zero,
      color: c.elevated,
      constraints: BoxConstraints(
        minWidth: widget.minMenuWidth,
        maxWidth: widget.maxMenuWidth,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
        side: BorderSide(color: c.borderStrong),
      ),
      position: RelativeRect.fromRect(anchor, Offset.zero & overlaySize),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          enabled: false,
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            widget.headerLabel,
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
              color: c.textTertiary,
            ),
          ),
        ),
        for (final path in widget.recents)
          PopupMenuItem<String>(
            value: path,
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  path.split(Platform.pathSeparator).last,
                  style: vbuMono(
                    size: 12,
                    weight: FontWeight.w500,
                    color: c.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  path,
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 10,
                    color: c.textTertiary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
      ],
    );
    if (picked != null) widget.onPick(picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _open(context),
          child: AnimatedContainer(
            duration: VbuTokens.durFast,
            curve: VbuTokens.easeStandard,
            margin: const EdgeInsets.only(right: 2),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            decoration: BoxDecoration(
              color: _hovered ? c.surface3 : Colors.transparent,
              borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
            ),
            child: Icon(
              Icons.expand_more,
              size: 16,
              color: _hovered ? c.textPrimary : c.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
