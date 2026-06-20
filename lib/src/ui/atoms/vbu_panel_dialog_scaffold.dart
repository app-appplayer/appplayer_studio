import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// Panel-style dialog scaffold — narrow modal with a small mono header
/// + optional `headerExtra` (radio rows describing modes) + optional
/// `quickActions` (chip-shaped quick selectors) + scrollable body +
/// bottom action row, all separated by edge-to-edge dividers.
///
/// Different visual idiom from [VbuDialogScaffold] (which is a single
/// padded card). Used for export / import / asset-management flows
/// where the user picks slices from a list and the dividers visually
/// separate "what to do" (header) from "narrow it down" (quick actions)
/// from "the picks themselves" (scrollable body).
class VbuPanelDialogScaffold extends StatelessWidget {
  const VbuPanelDialogScaffold({
    super.key,
    required this.title,
    required this.body,
    required this.actions,
    this.titleStyle,
    this.titleTrailing,
    this.headerExtra,
    this.quickActions,
    this.actionsLeading,
    this.width = 460,
    this.height,
  });

  /// Header text (e.g. `'EXPORT $channelLabel'`). Default style is mono
  /// 11 secondary; pass [titleStyle] for a sans 13 primary look (assets
  /// dialog uses that).
  final String title;

  /// Override the default mono-11 title style.
  final TextStyle? titleStyle;

  /// Optional widget rendered to the right of [title] in the header row
  /// — typical use is a small toolbar (count badge + + / - / refresh
  /// IconButtons).
  final Widget? titleTrailing;

  /// Optional extra header content shown directly below [title], inside
  /// the same padded box. Typical use — radio rows describing alternate
  /// modes ("Whole .mbd" vs "Pick").
  final Widget? headerExtra;

  /// Optional row of compact quick-select chips. Renders as a [Wrap] so
  /// chips reflow on narrow widths.
  final List<Widget>? quickActions;

  /// Scrollable picks body. Caller wraps in `SingleChildScrollView` /
  /// `ListView` etc. — scaffold imposes only the [Flexible] container.
  final Widget body;

  /// Bottom row buttons. Right-aligned with horizontal gaps.
  final List<Widget> actions;

  /// Optional widget rendered on the left side of the actions row —
  /// typical use is an info / warning line (assets dialog: "Asset
  /// edits are committed immediately"). Surfaces inside an `Expanded`
  /// so it can shrink under crowded action rows.
  final Widget? actionsLeading;

  /// Custom dialog width (defaults to 460 — vibe convention for panel
  /// dialogs).
  final double width;

  /// Custom fixed height. Null = let the body shrink-wrap.
  final double? height;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final defaultTitleStyle = vbuMono(size: 11, color: c.textSecondary);
    final card = SizedBox(
      width: width,
      height: height,
      child: Column(
        mainAxisSize: height == null ? MainAxisSize.min : MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              VbuTokens.space4,
              VbuTokens.space3,
              VbuTokens.space4,
              VbuTokens.space2,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        title,
                        style: titleStyle ?? defaultTitleStyle,
                      ),
                    ),
                    if (titleTrailing != null) titleTrailing!,
                  ],
                ),
                if (headerExtra != null) ...<Widget>[
                  const SizedBox(height: VbuTokens.space2),
                  headerExtra!,
                ],
              ],
            ),
          ),
          Divider(height: 1, color: c.borderDefault),
          if (quickActions != null && quickActions!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: VbuTokens.space2,
                vertical: VbuTokens.space2,
              ),
              child: Wrap(
                spacing: VbuTokens.space1,
                runSpacing: VbuTokens.space1,
                children: quickActions!,
              ),
            ),
          (height == null) ? Flexible(child: body) : Expanded(child: body),
          Divider(height: 1, color: c.borderDefault),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: VbuTokens.space3,
              vertical: VbuTokens.space2,
            ),
            child: Row(
              children: <Widget>[
                if (actionsLeading != null) Expanded(child: actionsLeading!),
                if (actionsLeading == null) const Spacer(),
                for (var i = 0; i < actions.length; i++) ...<Widget>[
                  if (i > 0) const SizedBox(width: VbuTokens.space2),
                  actions[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
    return Dialog(
      backgroundColor: c.surface2,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: card,
    );
  }
}
