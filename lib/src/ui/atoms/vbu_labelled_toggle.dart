import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// Form row with a checkbox + label + optional one-line hint. Used for
/// boolean settings (debug toggle, telemetry opt-in, …). Mint-tint when
/// checked.
class VbuLabelledToggle extends StatelessWidget {
  const VbuLabelledToggle({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.hint,
  });

  final String label;
  final String? hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                value ? Icons.check_box : Icons.check_box_outline_blank,
                size: 16,
                color: value ? c.mint : c.textTertiary,
              ),
            ),
            const SizedBox(width: VbuTokens.space2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: VbuTokens.fontSans,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: c.textPrimary,
                    ),
                  ),
                  if (hint != null && hint!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        hint!,
                        style: vbuMono(size: 10, color: c.textTertiary),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
