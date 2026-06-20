/// `VbuInstanceStrip` — instance card row used by app_builder's [3] slot
/// and similar layer-list surfaces. Two orientations:
///
/// - `horizontal` (default, 56px strip in the editor's top sub-row):
///   scrollable row, 152×32 cards.
/// - `vertical` (sidebar mode, 168px column inside preview): stacked list,
///   168×32 cards, with an optional section title (PAGES / TEMPLATES).
///
/// Each entry renders with a 3px left stripe (layer color), an id label
/// (mono), an optional coral "issue" pill, and a popup menu (`⋮`) whose
/// items the caller supplies via [VbuInstanceItem.menuItems].
/// Selection is external via [selectedId] (no internal state).
///
/// The strip also supports an optional trailing add affordance (`+ Add`).
library;

import 'package:flutter/material.dart';

import '../tokens.dart';

enum VbuInstanceStripOrientation { horizontal, vertical }

class VbuInstanceMenuItem {
  const VbuInstanceMenuItem({
    required this.label,
    this.onTap,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onTap;

  /// When true, renders the item in the coral "danger" tone (delete /
  /// destroy actions). Matches `vibe_app_builder/feat/instance_strip`
  /// menu items where `Delete` shows in coral.
  final bool danger;
}

class VbuInstanceItem {
  const VbuInstanceItem({
    required this.id,
    required this.label,
    this.color,
    this.subtitle,
    this.issue,
    this.menuItems = const <VbuInstanceMenuItem>[],
  });

  final String id;
  final String label;
  final String? color;
  final String? subtitle;

  /// When non-null, renders a coral "issue" pill (1-3 char glyph) next
  /// to the id — e.g. `!` for lint, `?` for missing schema.
  final String? issue;

  /// Items shown when the user taps the `⋮` menu button on this card.
  /// Empty = no menu button rendered.
  final List<VbuInstanceMenuItem> menuItems;
}

class VbuInstanceStrip extends StatelessWidget {
  const VbuInstanceStrip({
    super.key,
    this.items = const <VbuInstanceItem>[],
    this.selectedId,
    this.onSelect,
    this.orientation = VbuInstanceStripOrientation.horizontal,
    this.sectionTitle,
    this.sectionDotColor,
    this.addLabel,
    this.onAdd,
    this.emptyText = 'No instances yet',
  });

  final List<VbuInstanceItem> items;
  final String? selectedId;
  final ValueChanged<String>? onSelect;

  final VbuInstanceStripOrientation orientation;

  /// Rendered as the uppercase mono header in vertical mode (e.g.
  /// `PAGES`, `TEMPLATES`). Ignored in horizontal mode.
  final String? sectionTitle;

  /// Layer accent dot next to the section title. Hex string.
  final String? sectionDotColor;

  /// When non-null, renders a trailing `+ Add <label>` card after the
  /// last item. The card is 107px (horizontal) or full-width (vertical).
  final String? addLabel;
  final VoidCallback? onAdd;

  /// Rendered when [items] is empty and no add affordance is wired.
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final isVertical = orientation == VbuInstanceStripOrientation.vertical;

    if (items.isEmpty && addLabel == null) {
      return Center(
        child: Text(
          emptyText,
          style: TextStyle(
            fontFamily: VbuTokens.fontSans,
            fontSize: 12,
            color: c.textTertiary,
          ),
        ),
      );
    }

    if (isVertical) {
      return Container(
        width: 168,
        color: c.surface,
        padding: const EdgeInsets.symmetric(
          horizontal: VbuTokens.space2,
          vertical: VbuTokens.space2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (sectionTitle != null)
              _SectionTitle(
                title: sectionTitle!,
                dotColor: _parseColor(sectionDotColor),
              ),
            Expanded(
              child: ListView.separated(
                padding: EdgeInsets.zero,
                itemCount: items.length + (addLabel != null ? 1 : 0),
                separatorBuilder:
                    (_, __) => const SizedBox(height: VbuTokens.space1),
                itemBuilder: (context, i) {
                  if (i >= items.length) {
                    return _AddCard(
                      label: addLabel!,
                      onTap: onAdd,
                      width: double.infinity,
                    );
                  }
                  return _Card(
                    item: items[i],
                    selected: items[i].id == selectedId,
                    onSelect: onSelect,
                    width: double.infinity,
                  );
                },
              ),
            ),
          ],
        ),
      );
    }

    // Horizontal mode — 56px strip with scrollable row.
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.borderDefault, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: VbuTokens.space3,
        vertical: VbuTokens.space2,
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length + (addLabel != null ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(width: VbuTokens.space2),
        itemBuilder: (context, i) {
          if (i >= items.length) {
            return _AddCard(label: addLabel!, onTap: onAdd, width: 107);
          }
          return _Card(
            item: items[i],
            selected: items[i].id == selectedId,
            onSelect: onSelect,
            width: 152,
          );
        },
      ),
    );
  }

  static Color? _parseColor(String? hex) {
    if (hex == null) return null;
    var s = hex.trim();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length == 6) s = 'ff$s';
    final v = int.tryParse(s, radix: 16);
    return v == null ? null : Color(v);
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.dotColor});

  final String title;
  final Color? dotColor;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VbuTokens.space1,
        0,
        VbuTokens.space1,
        VbuTokens.space2,
      ),
      child: Row(
        children: [
          if (dotColor != null) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: dotColor,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            const SizedBox(width: VbuTokens.space1),
          ],
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
              color: c.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.item,
    required this.selected,
    required this.onSelect,
    required this.width,
  });

  final VbuInstanceItem item;
  final bool selected;
  final ValueChanged<String>? onSelect;
  final double width;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final stripeColor = VbuInstanceStrip._parseColor(item.color) ?? c.textMuted;
    final nameColor = selected ? c.textPrimary : c.textSecondary;
    return InkWell(
      onTap: onSelect == null ? null : () => onSelect!(item.id),
      borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
      child: SizedBox(
        width: width,
        height: 32,
        child: AnimatedContainer(
          duration: VbuTokens.durFast,
          curve: VbuTokens.easeStandard,
          decoration: BoxDecoration(
            color: selected ? c.surface3 : c.surface2,
            border: Border.all(
              color: selected ? stripeColor : c.borderDefault,
              width: selected ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, color: stripeColor),
              const SizedBox(width: VbuTokens.space2),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    item.label,
                    style: TextStyle(
                      fontFamily: VbuTokens.fontMono,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: nameColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (item.issue != null)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: _IssueBadge(text: item.issue!),
                ),
              if (item.menuItems.isNotEmpty) _MenuButton(items: item.menuItems),
            ],
          ),
        ),
      ),
    );
  }
}

class _IssueBadge extends StatelessWidget {
  const _IssueBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: c.surface3,
        border: Border.all(color: c.coral, width: 1),
        borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: VbuTokens.fontMono,
          fontSize: 10,
          color: c.coral,
        ),
      ),
    );
  }
}

class _MenuButton extends StatelessWidget {
  const _MenuButton({required this.items});

  final List<VbuInstanceMenuItem> items;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return PopupMenuButton<int>(
      tooltip: '',
      padding: EdgeInsets.zero,
      iconSize: 16,
      color: c.elevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
        side: BorderSide(color: c.borderStrong, width: 1),
      ),
      icon: Icon(Icons.more_vert, size: 16, color: c.textTertiary),
      onSelected: (i) {
        final cb = items[i].onTap;
        if (cb != null) cb();
      },
      itemBuilder:
          (context) => [
            for (var i = 0; i < items.length; i++)
              PopupMenuItem<int>(
                value: i,
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  items[i].label,
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 11,
                    color: items[i].danger ? c.coral : c.textPrimary,
                  ),
                ),
              ),
          ],
    );
  }
}

class _AddCard extends StatelessWidget {
  const _AddCard({
    required this.label,
    required this.onTap,
    required this.width,
  });

  final String label;
  final VoidCallback? onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
      child: SizedBox(
        width: width,
        height: 32,
        child: AnimatedContainer(
          duration: VbuTokens.durFast,
          curve: VbuTokens.easeStandard,
          decoration: BoxDecoration(
            color: c.surface2,
            border: Border.all(color: c.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add, size: 14, color: c.textSecondary),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontFamily: VbuTokens.fontSans,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: c.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
