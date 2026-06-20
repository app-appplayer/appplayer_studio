/// `VbuMasterDetail` — studio's canonical master-detail layout. Left
/// labeled panel with sectioned vertical lists of clickable rows + right
/// detail body. Mirrors the visual tone of `PropertiesPanel` /
/// `InspectorPanel` (uppercase section header + indented item rows)
/// without their domain-specific argument surface so DSL authors get
/// the same shell shape via a single registered widget.
library;

import 'package:flutter/material.dart';

import '../tokens.dart';

/// One row inside a section — icon + label + selected flag + tap.
/// Optional secondary label rendered beneath the main label (used to
/// show kind / namespace / source hints).
class VbuMasterDetailItem {
  const VbuMasterDetailItem({
    required this.label,
    required this.icon,
    this.sub,
    this.trailingPill,
    this.selected = false,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final String? sub;
  final String? trailingPill;
  final bool selected;
  final VoidCallback? onTap;
}

/// A section header + its row list. Rendered as uppercase title atop
/// indented rows. Matches `_Section` from `properties_panel.dart`.
class VbuMasterDetailSection {
  const VbuMasterDetailSection({
    required this.title,
    this.items = const <VbuMasterDetailItem>[],
  });

  final String title;
  final List<VbuMasterDetailItem> items;
}

class VbuMasterDetail extends StatelessWidget {
  const VbuMasterDetail({
    super.key,
    required this.panelLabel,
    required this.sections,
    required this.body,
    this.panelWidth = 240,
  });

  /// Uppercase section label rendered at the top of the master panel.
  final String panelLabel;

  /// Vertical list of sections. Each section renders its own uppercase
  /// header + rows.
  final List<VbuMasterDetailSection> sections;

  /// Detail body rendered to the right of the panel — fills remaining
  /// space.
  final Widget body;

  /// Left panel width in logical pixels. Defaults to 240.
  final double panelWidth;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          width: panelWidth,
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(right: BorderSide(color: c.borderDefault)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: VbuTokens.space3,
                  vertical: VbuTokens.space3,
                ),
                child: Text(
                  panelLabel.toUpperCase(),
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                    color: c.textSecondary,
                  ),
                ),
              ),
              Container(height: 1, color: c.borderDefault),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final section in sections)
                        _Section(section: section),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(child: body),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.section});
  final VbuMasterDetailSection section;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    // Section header tone mirrors `_surfaceHeader` in
    // bundle_tools_view.dart (line 1011) — 28px tall, surface2 bg,
    // borderSubtle bottom, mono 10pt w600 letterSpacing 1.0
    // textTertiary. Item count appended in parens.
    final headerText =
        '${section.title.toUpperCase()} (${section.items.length})';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: VbuTokens.space3),
          decoration: BoxDecoration(
            color: c.surface2,
            border: Border(bottom: BorderSide(color: c.borderSubtle)),
          ),
          alignment: Alignment.centerLeft,
          child: Text(
            headerText,
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
              color: c.textTertiary,
            ),
          ),
        ),
        for (final item in section.items) _Row(item: item),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.item});
  final VbuMasterDetailItem item;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final selected = item.selected;
    return InkWell(
      onTap: item.onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: VbuTokens.space3,
          vertical: 6,
        ),
        color: selected ? c.surface3 : Colors.transparent,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.surface2,
                borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
                border: Border.all(color: c.borderSubtle),
              ),
              child: Icon(
                item.icon,
                size: 13,
                color: selected ? c.mint : c.textSecondary,
              ),
            ),
            const SizedBox(width: VbuTokens.space2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: VbuTokens.fontMono,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: selected ? c.textPrimary : c.textSecondary,
                    ),
                  ),
                  if (item.sub != null && item.sub!.isNotEmpty)
                    Text(
                      item.sub!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: VbuTokens.fontMono,
                        fontSize: 10,
                        color: c.textTertiary,
                      ),
                    ),
                ],
              ),
            ),
            if (item.trailingPill != null &&
                item.trailingPill!.isNotEmpty) ...<Widget>[
              const SizedBox(width: VbuTokens.space1),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: c.surface2,
                  borderRadius: BorderRadius.circular(VbuTokens.radiusFull),
                  border: Border.all(color: c.borderSubtle),
                ),
                child: Text(
                  item.trailingPill!,
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 9,
                    color: c.mintDim,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
