import 'package:flutter/material.dart';

/// Compact panel-header bar — vibe-derived. 36px tall by default,
/// shows a bold label on the left and an optional row of actions on the
/// right. Used by chat columns, properties panes, library panes, and
/// any other side panel that needs a small title strip.
///
/// Hosts pass [actions] for icon buttons / counters / clear affordances.
/// `onClear` is a shorthand for the common "trash icon → clear panel
/// content" pattern; when set it appears at the end of [actions].
class VbuPaneHeader extends StatelessWidget {
  const VbuPaneHeader({
    super.key,
    required this.label,
    this.actions = const <Widget>[],
    this.onClear,
    this.clearTooltip = 'Clear',
    this.height = 36,
    this.padding = const EdgeInsets.symmetric(horizontal: 10),
    this.labelStyle,
  });

  final String label;
  final List<Widget> actions;
  final Future<void> Function()? onClear;
  final String clearTooltip;
  final double height;
  final EdgeInsets padding;
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      child: Padding(
        padding: padding,
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style:
                    labelStyle ??
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ...actions,
            if (onClear != null)
              IconButton(
                tooltip: clearTooltip,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.delete_outline,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                onPressed: () => onClear!(),
              ),
          ],
        ),
      ),
    );
  }
}
