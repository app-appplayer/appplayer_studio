import 'package:flutter/material.dart';

import '../tokens.dart';
import 'vbu_copy_on_hover.dart';

/// Centered, italicised note used for system / error messages in chat
/// columns. Hosts flag errors with `error: true` to surface the
/// `error_outline` icon in the status color.
class VbuSystemNote extends StatelessWidget {
  const VbuSystemNote({
    super.key,
    required this.text,
    this.error = false,
    this.onDelete,
  });

  final String text;
  final bool error;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return VbuCopyOnHover(
      text: text,
      onDelete: onDelete,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          0,
          VbuTokens.space1,
          24,
          VbuTokens.space1,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (error) ...<Widget>[
              Icon(
                Icons.error_outline,
                size: 12,
                color: VbuTokens.status.error,
              ),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: SelectableText(
                text,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: VbuTokens.colorOf(context).textTertiary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
