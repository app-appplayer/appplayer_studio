import 'package:flutter/material.dart';

import '../tokens.dart';

/// Chrome-style title bar at the top of an authored bundle's page —
/// matches the studio's own [VibeTitlebar] tone exactly: 28px tall,
/// `surface` background, `borderDefault` 1px bottom border, tight
/// monospaced label.
///
/// This is a TOOL aesthetic, not a mobile AppBar. Keep it thin and
/// quiet — the surrounding studio chrome is also 28px, so a taller
/// page-title bar would read as out-of-place.
///
/// Distinct from [VbuPaneHeader] (uppercase section label inside a
/// panel) — VbuTitleBar is window chrome for a bundle's page.
class VbuTitleBar extends StatelessWidget {
  const VbuTitleBar({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing = const <Widget>[],
    this.height = VbuTokens.titlebarHeight,
    this.background,
    this.padding = const EdgeInsets.symmetric(horizontal: VbuTokens.space3),
    this.titleStyle,
    this.subtitleStyle,
  });

  /// Bundle / page name displayed on the left.
  final String title;

  /// Optional small secondary line shown after the title with a dot
  /// separator (kept on the same row — never stacked, this is a thin
  /// tool strip).
  final String? subtitle;

  /// Optional leading widget (e.g. small icon).
  final Widget? leading;

  /// Trailing widgets — typically small icon buttons or pills.
  final List<Widget> trailing;

  /// Strip height. Default is [VbuTokens.titlebarHeight] (28px) to
  /// match the studio's own chrome.
  final double height;

  /// Strip background colour. Defaults to `surface` so it sits flush
  /// against the studio's titlebar / tab strip.
  final Color? background;

  /// Inner horizontal padding. Vertical centering is implicit.
  final EdgeInsets padding;

  /// Optional override for the title text style. Defaults to mono
  /// 12pt w600 in `textPrimary` — same tone as the studio titlebar.
  final TextStyle? titleStyle;

  /// Optional override for the subtitle text style. Defaults to mono
  /// 11pt in `textSecondary`.
  final TextStyle? subtitleStyle;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final titleEffective =
        titleStyle ??
        TextStyle(
          fontFamily: VbuTokens.fontMono,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: c.textPrimary,
        );
    final subtitleEffective =
        subtitleStyle ??
        TextStyle(
          fontFamily: VbuTokens.fontMono,
          fontSize: 11,
          color: c.textSecondary,
        );
    final hasSubtitle = subtitle != null && subtitle!.isNotEmpty;
    return Container(
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: background ?? c.surface,
        border: Border(
          bottom: BorderSide(
            color: c.borderDefault,
            width: VbuTokens.borderThin,
          ),
        ),
      ),
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (leading != null) ...<Widget>[
            leading!,
            const SizedBox(width: VbuTokens.space2),
          ],
          Flexible(
            child: Text(
              title,
              style: titleEffective,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (hasSubtitle) ...<Widget>[
            const SizedBox(width: VbuTokens.space2),
            Text('·', style: TextStyle(fontSize: 11, color: c.textTertiary)),
            const SizedBox(width: VbuTokens.space2),
            Flexible(
              child: Text(
                subtitle!,
                style: subtitleEffective,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          const Spacer(),
          for (var i = 0; i < trailing.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 4),
            trailing[i],
          ],
        ],
      ),
    );
  }
}
