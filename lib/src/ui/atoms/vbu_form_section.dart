import 'package:flutter/material.dart';

import '../tokens.dart';

/// Form section — uppercase tertiary-tinted header + vertically stacked
/// child rows with consistent gap. Builder Settings dialogs (vibe ·
/// kb · follow-on tools) all share the same `WORKSPACE / MCP / LLM …`
/// section shape; hosts only supply the rows.
class VbuFormSection extends StatelessWidget {
  const VbuFormSection({
    super.key,
    required this.label,
    required this.children,
    this.rowGap = VbuTokens.space2,
  });

  final String label;
  final List<Widget> children;
  final double rowGap;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: VbuTokens.space1),
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              fontFamily: VbuTokens.fontSans,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
              color: c.textTertiary,
            ),
          ),
        ),
        for (final child in children)
          Padding(padding: EdgeInsets.only(bottom: rowGap), child: child),
      ],
    );
  }
}
