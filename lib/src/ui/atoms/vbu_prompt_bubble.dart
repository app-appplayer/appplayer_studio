import 'package:flutter/material.dart';

import '../tokens.dart';
import 'vbu_copy_on_hover.dart';

/// Right-aligned bubble used for the user's prompt in chat columns.
/// vibe-derived: `surface3` background, 240 max width, copy-on-hover
/// affordance, drag-selectable body. Hosts pass plain text — domain
/// metadata (turn id / agent / etc.) stays out of the atom.
class VbuPromptBubble extends StatelessWidget {
  const VbuPromptBubble({
    super.key,
    required this.text,
    this.onDelete,
    this.maxWidth = 240,
  });

  final String text;
  final VoidCallback? onDelete;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Align(
      alignment: Alignment.centerRight,
      child: VbuCopyOnHover(
        text: text,
        onDelete: onDelete,
        child: Container(
          constraints: BoxConstraints(maxWidth: maxWidth),
          padding: const EdgeInsets.fromLTRB(10, 8, 26, 8),
          decoration: BoxDecoration(
            color: c.surface3,
            borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
          ),
          child: SelectableText(
            text,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ),
    );
  }
}
