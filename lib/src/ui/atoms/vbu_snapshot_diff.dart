import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// Diff row status — vibe `_ChannelDiffStatus` lifted to a generic
/// shape. Hosts (channel diff · history audit · agent prompt diff ·
/// validation snapshot diff) reuse the same enum so badges render
/// consistently.
enum VbuDiffStatus { identical, leftOnly, rightOnly, modified }

extension VbuDiffStatusBadge on VbuDiffStatus {
  String get label {
    switch (this) {
      case VbuDiffStatus.identical:
        return '=';
      case VbuDiffStatus.leftOnly:
        return '−';
      case VbuDiffStatus.rightOnly:
        return '+';
      case VbuDiffStatus.modified:
        return '~';
    }
  }

  Color color({
    Color? identicalColor,
    Color? leftOnlyColor,
    Color? rightOnlyColor,
    Color? modifiedColor,
  }) {
    switch (this) {
      case VbuDiffStatus.identical:
        return identicalColor ?? VbuTokens.color.textTertiary;
      case VbuDiffStatus.leftOnly:
        return leftOnlyColor ?? VbuTokens.color.coral;
      case VbuDiffStatus.rightOnly:
        return rightOnlyColor ?? VbuTokens.color.mint;
      case VbuDiffStatus.modified:
        return modifiedColor ?? VbuTokens.color.amber;
    }
  }
}

/// One diff row.
class VbuDiffRow {
  const VbuDiffRow({
    required this.id,
    required this.status,
    this.leftValue,
    this.rightValue,
  });

  final String id;
  final VbuDiffStatus status;
  final Object? leftValue;
  final Object? rightValue;
}

/// One titled section in a snapshot diff (e.g. 'PAGES', 'TEMPLATES',
/// 'DASHBOARD'). Empty `rows` is OK — the section renders the title +
/// "no entries" placeholder.
class VbuDiffSection {
  const VbuDiffSection({required this.title, required this.rows});

  final String title;
  final List<VbuDiffRow> rows;
}

/// Header strip for snapshot diff dialogs — title + left/right channel
/// chips with a `compare_arrows` icon between them. vibe-derived.
class VbuDiffHeader extends StatelessWidget {
  const VbuDiffHeader({
    super.key,
    required this.title,
    required this.leftLabel,
    required this.rightLabel,
    this.leftAccent,
    this.rightAccent,
    this.titleStyle,
  });

  final String title;
  final String leftLabel;
  final String rightLabel;
  final Color? leftAccent;
  final Color? rightAccent;
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VbuTokens.space4,
        VbuTokens.space4,
        VbuTokens.space4,
        VbuTokens.space2,
      ),
      child: Row(
        children: <Widget>[
          Text(
            title,
            style:
                titleStyle ??
                TextStyle(
                  fontFamily: VbuTokens.fontSans,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: c.textPrimary,
                ),
          ),
          const Spacer(),
          _Chip(label: leftLabel, color: leftAccent ?? c.mint),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Icon(Icons.compare_arrows, size: 14, color: c.textTertiary),
          ),
          _Chip(label: rightLabel, color: rightAccent ?? c.amber),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        label,
        style: vbuMono(size: 10, weight: FontWeight.w600, color: color),
      ),
    );
  }
}

/// Renders one diff section — title + row list. Hosts pass an optional
/// `rowBuilder` to customize how each row renders (vibe shows the id,
/// status badge, and a tooltip with full JSON). When `rowBuilder` is
/// null, `VbuDiffSectionView` falls back to a compact one-line row.
class VbuDiffSectionView extends StatelessWidget {
  const VbuDiffSectionView({
    super.key,
    required this.section,
    this.rowBuilder,
    this.emptyText = '— no entries —',
  });

  final VbuDiffSection section;
  final Widget Function(BuildContext, VbuDiffRow)? rowBuilder;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            section.title,
            style: vbuMono(
              size: 10,
              weight: FontWeight.w500,
              color: c.textTertiary,
            ),
          ),
        ),
        if (section.rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              emptyText,
              style: vbuMono(size: 11, color: c.textTertiary),
            ),
          )
        else
          for (final row in section.rows)
            rowBuilder?.call(context, row) ?? _DefaultRow(row: row),
      ],
    );
  }
}

class _DefaultRow extends StatelessWidget {
  const _DefaultRow({required this.row});
  final VbuDiffRow row;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          Container(
            width: 16,
            alignment: Alignment.center,
            child: Text(
              row.status.label,
              style: vbuMono(
                size: 12,
                weight: FontWeight.w700,
                color: row.status.color(),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              row.id,
              style: vbuMono(size: 11, color: c.textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
