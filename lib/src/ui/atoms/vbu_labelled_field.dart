import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// Form row with a fixed-width mono label on the left and a [TextField]
/// stretching to fill. Optional [trailing] (visibility toggle, copy
/// button, …). [obscure] flips secret-mode for API keys / passwords.
class VbuLabelledField extends StatelessWidget {
  const VbuLabelledField({
    super.key,
    required this.label,
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.trailing,
    this.labelWidth = 92,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final Widget? trailing;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        SizedBox(
          width: labelWidth,
          child: Text(label, style: vbuMono(size: 11, color: c.textSecondary)),
        ),
        Expanded(
          child: TextField(
            controller: controller,
            obscureText: obscure,
            style: vbuMono(size: 12, color: c.textPrimary),
            decoration: InputDecoration(hintText: hint, isDense: true),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}
