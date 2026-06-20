import 'package:flutter/material.dart';

import '../../base/shell/inspect_tag.dart';
import '../tokens.dart';

/// One action button on a [VbuHeroPanel]. The first action with
/// `emphasised: true` renders as a mint FilledButton (call-to-action);
/// the rest render as OutlinedButton with neutral border.
class VbuHeroAction {
  const VbuHeroAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.emphasised = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  /// When true, renders as the primary mint CTA. Use sparingly — at
  /// most one per panel.
  final bool emphasised;
}

/// Centred hero panel — the empty/onboarding state for any workspace
/// view. Title + subtitle + 1-N action buttons + optional footer slot
/// (recent list, hint text, status pill, etc.).
///
/// Same surface palette and typography as Settings + tab strip so the
/// whole studio reads as one tone. Consumers (and LLM-generated
/// shells) reach for this instead of re-rolling Container + Column +
/// Text + button styling — that handroll was the source of token
/// drift across the codebase.
///
/// Layout: centred, [maxWidth] cap (default 520), `space5` outer
/// padding. Title is sans 20/w600, subtitle sans 13/secondary,
/// buttons in a centred Row with `space3` gap.
class VbuHeroPanel extends StatelessWidget {
  const VbuHeroPanel({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const <VbuHeroAction>[],
    this.footer,
    this.maxWidth = 520,
    this.titleStyle,
    this.subtitleStyle,
  });

  final String title;
  final String? subtitle;
  final List<VbuHeroAction> actions;

  /// Anything that should sit below the actions — a recents list, a
  /// hint paragraph, a status pill, etc. Hosts compose using their
  /// own widgets; this atom only owns the chrome.
  final Widget? footer;

  final double maxWidth;
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Container(
      color: c.bg,
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: const EdgeInsets.all(VbuTokens.space5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                title,
                textAlign: TextAlign.center,
                style:
                    titleStyle ??
                    TextStyle(
                      fontFamily: VbuTokens.fontSans,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
              ),
              if (subtitle != null) ...<Widget>[
                const SizedBox(height: VbuTokens.space2),
                Text(
                  subtitle!,
                  textAlign: TextAlign.center,
                  style:
                      subtitleStyle ??
                      TextStyle(
                        fontFamily: VbuTokens.fontSans,
                        fontSize: 13,
                        color: c.textSecondary,
                      ),
                ),
              ],
              if (actions.isNotEmpty) ...<Widget>[
                const SizedBox(height: VbuTokens.space5),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    for (var i = 0; i < actions.length; i++) ...<Widget>[
                      if (i > 0) const SizedBox(width: VbuTokens.space3),
                      _actionButton(context, actions[i]),
                    ],
                  ],
                ),
              ],
              if (footer != null) ...<Widget>[
                const SizedBox(height: VbuTokens.space4),
                footer!,
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionButton(BuildContext context, VbuHeroAction a) {
    final c = VbuTokens.colorOf(context);
    const pad = EdgeInsets.symmetric(
      horizontal: VbuTokens.space4,
      vertical: VbuTokens.space3,
    );
    final Widget button =
        a.emphasised
            ? FilledButton.icon(
              onPressed: a.onPressed,
              style: FilledButton.styleFrom(
                backgroundColor: c.mint,
                foregroundColor: c.bg,
                padding: pad,
              ),
              icon: Icon(a.icon, size: 16),
              label: Text(a.label),
            )
            : OutlinedButton.icon(
              onPressed: a.onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: c.textPrimary,
                side: BorderSide(color: c.borderStrong),
                padding: pad,
              ),
              icon: Icon(a.icon, size: 16),
              label: Text(a.label),
            );
    return inspectTag(
      type: 'hero_action',
      id: _slug(a.label),
      label: a.label,
      child: button,
    );
  }

  String _slug(String label) =>
      label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
}
