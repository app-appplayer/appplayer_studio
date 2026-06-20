import 'package:flutter/material.dart';

import '../tokens.dart';

/// Generic chat-style composer — multi-line `TextField` + send button.
/// Hosts (vibe `_Composer`, kb chat column, kernel `ChatColumn`) wrap or
/// embed this atom and add their own affordances above (slash hints,
/// context attachments) when needed.
///
/// vibe-derived layout: `Padding` 8 around, multi-line TextField (1–6
/// lines), trailing send icon. `busy` disables the input and replaces
/// the send icon with a small spinner so dispatches in flight are
/// visible.
class VbuComposer extends StatelessWidget {
  const VbuComposer({
    super.key,
    required this.controller,
    required this.onSubmit,
    this.hint = 'Send a message…',
    this.busy = false,
    this.minLines = 1,
    this.maxLines = 6,
    this.padding = const EdgeInsets.all(VbuTokens.space2),
  });

  final TextEditingController controller;
  final Future<void> Function() onSubmit;
  final String hint;
  final bool busy;
  final int minLines;
  final int maxLines;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              minLines: minLines,
              maxLines: maxLines,
              enabled: !busy,
              decoration: InputDecoration(
                hintText: hint,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => onSubmit(),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Send',
            onPressed: busy ? null : onSubmit,
            icon:
                busy
                    ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : Icon(
                      Icons.send_outlined,
                      size: 18,
                      color: VbuTokens.colorOf(context).mint,
                    ),
          ),
        ],
      ),
    );
  }
}
