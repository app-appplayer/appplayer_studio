import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// Generic dialog scaffold — vibe-derived.
///
/// Visual: `Dialog(surface2)` → `ConstrainedBox(maxWidth/maxHeight)` →
/// `Padding(space4)` → `Column` of:
///   - Title row: optional leading icon + bold title + optional `·`
///     separator + subtitle.
///   - Body widget (host-supplied).
///   - Actions row: optional leading widget, spacer, trailing actions
///     (Cancel · primary).
///
/// Title styling defaults to mono 14 / w600 (vibe build / settings
/// dialogs). Pass [titleStyle] to override (clean / channel-diff
/// dialogs use sans 13). Pass [titleIcon] for destructive flows that
/// surface a leading affordance.
class VbuDialogScaffold extends StatelessWidget {
  const VbuDialogScaffold({
    super.key,
    required this.title,
    this.subtitle,
    this.titleIcon,
    this.titleIconColor,
    this.titleStyle,
    required this.body,
    this.actions = const <Widget>[],
    this.leadingAction,
    this.maxWidth = 640,
    this.maxHeight = 720,
    this.padding = const EdgeInsets.all(VbuTokens.space4),
  });

  final String title;
  final String? subtitle;

  /// Optional icon shown to the left of the title. clean / channel-diff
  /// dialogs use this to flag destructive flows.
  final IconData? titleIcon;

  /// Tint for [titleIcon]. Defaults to coral so destructive flows stand
  /// out; pass any color for non-destructive variants.
  final Color? titleIconColor;

  /// Override the default mono-14 title style.
  final TextStyle? titleStyle;

  final Widget body;
  final List<Widget> actions;
  final Widget? leadingAction;
  final double maxWidth;
  final double maxHeight;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Dialog(
      backgroundColor: c.surface2,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        child: Padding(
          padding: padding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _Title(
                title: title,
                subtitle: subtitle,
                icon: titleIcon,
                iconColor: titleIconColor,
                style: titleStyle,
              ),
              const SizedBox(height: VbuTokens.space2),
              Flexible(child: body),
              const SizedBox(height: VbuTokens.space4),
              Row(
                children: <Widget>[
                  if (leadingAction != null) leadingAction!,
                  const Spacer(),
                  for (var i = 0; i < actions.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(width: VbuTokens.space2),
                    actions[i],
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title({
    required this.title,
    this.subtitle,
    this.icon,
    this.iconColor,
    this.style,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? iconColor;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final effectiveStyle =
        style ??
        vbuMono(size: 14, weight: FontWeight.w600, color: c.textPrimary);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, size: 18, color: iconColor ?? c.coral),
          const SizedBox(width: VbuTokens.space2),
        ],
        Text(title, style: effectiveStyle),
        if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
          const SizedBox(width: VbuTokens.space2),
          Text('·', style: effectiveStyle.copyWith(color: c.textTertiary)),
          const SizedBox(width: VbuTokens.space2),
          Flexible(
            child: Text(
              subtitle!,
              style: effectiveStyle.copyWith(
                fontWeight: FontWeight.w500,
                color: c.textSecondary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }
}
