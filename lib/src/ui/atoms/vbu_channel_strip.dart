/// `VbuChannelStrip` — compact pill row representing build channels
/// (e.g. `serving / native / preview`). Selection is external via
/// [activeChannel]; the caller wires `onSelect` to mutate state.
///
/// Used in app_builder's action row ([1] slot) as the left-side
/// affordance, mirroring the right-side Editor/Debug toggle.
///
/// Optional [tone] overrides the per-label accent (used when the strip
/// hosts non-channel toggles like `editor`/`debug` and the host wants a
/// uniform accent instead of the built-in `serving`/`native` palette).
///
/// Optional [menuItems] + [onMenuSelect] render a chevron button after
/// the last pill that opens a `showMenu` dropdown — used for channel
/// management actions (rename, copy, diff, manage…) that don't belong
/// inline as separate pills.
library;

import 'package:flutter/material.dart';

import '../tokens.dart';

/// One row in the [VbuChannelStrip] dropdown menu. `id` is the value
/// passed to `onMenuSelect`; `label` is shown; `danger` paints the row
/// in coral.
class VbuChannelMenuItem {
  const VbuChannelMenuItem({
    required this.id,
    required this.label,
    this.icon,
    this.danger = false,
  });

  final String id;
  final String label;
  final IconData? icon;
  final bool danger;
}

class VbuChannelStrip extends StatelessWidget {
  const VbuChannelStrip({
    super.key,
    this.channels = const <String>[],
    this.activeChannel,
    this.onSelect,
    this.tone,
    this.menuItems = const <VbuChannelMenuItem>[],
    this.onMenuSelect,
  });

  final List<String> channels;
  final String? activeChannel;
  final ValueChanged<String>? onSelect;

  /// When non-null, overrides the per-label accent — every pill uses
  /// this color for its active border / fill instead of the built-in
  /// `serving=violet / native=coral` palette.
  final Color? tone;

  /// Items shown in the trailing chevron dropdown. Empty → chevron is
  /// hidden.
  final List<VbuChannelMenuItem> menuItems;

  /// Fires with the selected item's `id` when the user picks a row.
  final ValueChanged<String>? onMenuSelect;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    if (channels.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: VbuTokens.space3),
        child: Text(
          'No channels',
          style: TextStyle(
            fontFamily: VbuTokens.fontMono,
            fontSize: 11,
            color: c.textTertiary,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VbuTokens.space2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final ch in channels) ...[
            _ChannelPill(
              label: ch,
              active: ch == activeChannel,
              accent: tone ?? _channelAccent(context, ch),
              onTap: onSelect == null ? null : () => onSelect!(ch),
            ),
            const SizedBox(width: VbuTokens.space1),
          ],
          if (menuItems.isNotEmpty)
            _MenuButton(items: menuItems, onSelect: onMenuSelect),
        ],
      ),
    );
  }
}

/// Per-channel tone — `serving` carries the build-default violet accent,
/// `native` carries a coral warning tone (native run sidesteps the
/// serving sandbox). Unknown labels fall back to the neutral border tone.
Color _channelAccent(BuildContext context, String label) {
  final c = VbuTokens.colorOf(context);
  switch (label.toLowerCase()) {
    case 'serving':
      return c.violet;
    case 'native':
      return c.coral;
    default:
      return c.borderStrong;
  }
}

class _ChannelPill extends StatelessWidget {
  const _ChannelPill({
    required this.label,
    required this.active,
    required this.accent,
    required this.onTap,
  });

  final String label;
  final bool active;
  final Color accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(VbuTokens.radiusLg),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: VbuTokens.space3,
          vertical: VbuTokens.space1,
        ),
        decoration: BoxDecoration(
          color: active ? accent.withValues(alpha: 0.14) : Colors.transparent,
          border: Border.all(
            color: active ? accent : accent.withValues(alpha: 0.5),
            width: active ? 1.4 : 1,
          ),
          borderRadius: BorderRadius.circular(VbuTokens.radiusLg),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: VbuTokens.fontMono,
            fontSize: 11,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color: active ? c.textPrimary : c.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// Trailing chevron — same height as the pills (24px), surface2 bg with
/// borderDefault. Tapping opens `showMenu` anchored just below the
/// button, listing each [VbuChannelMenuItem].
class _MenuButton extends StatelessWidget {
  const _MenuButton({required this.items, required this.onSelect});

  final List<VbuChannelMenuItem> items;
  final ValueChanged<String>? onSelect;

  Future<void> _open(BuildContext context) async {
    final c = VbuTokens.colorOf(context);
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final origin = renderBox.localToGlobal(Offset.zero, ancestor: overlay);
    final size = renderBox.size;
    final position = RelativeRect.fromLTRB(
      origin.dx,
      origin.dy + size.height + 2,
      overlay.size.width - origin.dx - size.width,
      overlay.size.height - origin.dy - size.height,
    );
    final picked = await showMenu<String>(
      context: context,
      position: position,
      color: c.surface2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
        side: BorderSide(color: c.borderDefault),
      ),
      items: <PopupMenuEntry<String>>[
        for (final it in items)
          PopupMenuItem<String>(
            value: it.id,
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (it.icon != null) ...<Widget>[
                  Icon(
                    it.icon,
                    size: 14,
                    color: it.danger ? c.coral : c.textSecondary,
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                  it.label,
                  style: TextStyle(
                    fontFamily: VbuTokens.fontSans,
                    fontSize: 12,
                    color: it.danger ? c.coral : c.textPrimary,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    if (picked != null) onSelect?.call(picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _open(context),
      child: Tooltip(
        message: 'More channels…',
        child: Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
            border: Border.all(color: c.borderDefault),
          ),
          child: Icon(Icons.expand_more, size: 14, color: c.textSecondary),
        ),
      ),
    );
  }
}
