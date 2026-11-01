import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// Body of a yes/no prompt: the whole question, scrollable. A question that
/// carries what a person must read before answering (a diff, a command line)
/// is never cut at the dialog's height, and its text can be selected.
class VbuPromptBody extends StatelessWidget {
  const VbuPromptBody({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Scrollbar(
      child: SingleChildScrollView(
        child: SelectableText(
          text,
          style: vbuMono(size: 12, color: c.textPrimary),
        ),
      ),
    );
  }
}
