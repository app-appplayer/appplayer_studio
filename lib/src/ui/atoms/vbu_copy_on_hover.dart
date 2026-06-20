import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';

/// Hover affordance — overlays clipboard-copy + (optional) delete icons
/// at the top-right of [child] when the pointer enters its bounds. The
/// rest of the body stays interactive (e.g. `SelectableText` for drag
/// selection) because the icons live in a `Stack`-positioned overlay
/// rather than gating the child.
///
/// vibe-derived atom. Used by chat bubbles, code cards, log entries —
/// anywhere a row should let the user copy its text without a separate
/// menu, and optionally remove it.
class VbuCopyOnHover extends StatefulWidget {
  const VbuCopyOnHover({
    super.key,
    required this.text,
    required this.child,
    this.onDelete,
    this.copiedSnackText = 'Copied',
  });

  /// Plain text placed on the clipboard when the copy icon is tapped.
  final String text;

  /// Body widget — typically a `SelectableText` or a card.
  final Widget child;

  /// Optional delete handler. When null, the close icon is hidden.
  final VoidCallback? onDelete;

  /// Toast shown after a successful copy. Hosts can shorten / localize.
  final String copiedSnackText;

  @override
  State<VbuCopyOnHover> createState() => _VbuCopyOnHoverState();
}

class _VbuCopyOnHoverState extends State<VbuCopyOnHover> {
  bool _hover = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          widget.copiedSnackText,
          style: const TextStyle(fontSize: 12),
        ),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required VoidCallback onTap,
    Color? color,
  }) {
    final c = VbuTokens.colorOf(context);
    return Material(
      color: c.surface3,
      borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 12, color: color ?? c.textSecondary),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Stack(
        children: <Widget>[
          widget.child,
          if (_hover)
            Positioned(
              top: 2,
              right: 2,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _iconButton(icon: Icons.copy, onTap: _copy),
                  if (widget.onDelete != null) ...<Widget>[
                    const SizedBox(width: 2),
                    _iconButton(
                      icon: Icons.close,
                      color: c.coral,
                      onTap: widget.onDelete!,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
