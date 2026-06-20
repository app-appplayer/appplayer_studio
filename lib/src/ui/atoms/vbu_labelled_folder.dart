import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// Form row with a folder path display + native picker button. Shows
/// [hint] when [value] is null/empty, otherwise the path itself
/// (ellipsised). [onPick] runs the host's directory picker and
/// reports the chosen path back through state. Optional [onClear]
/// reveals an × button that resets to the default fallback.
///
/// Hosts that don't have an absolute path (e.g. tool that resolves a
/// repo-relative bundle path) wire `value` from their model and ignore
/// [onClear].
class VbuLabelledFolder extends StatelessWidget {
  const VbuLabelledFolder({
    super.key,
    required this.label,
    required this.value,
    required this.hint,
    required this.onPick,
    this.onClear,
    this.labelWidth = 92,
  });

  final String label;
  final String? value;
  final String hint;
  final Future<void> Function() onPick;
  final VoidCallback? onClear;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final empty = value == null || value!.isEmpty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        SizedBox(
          width: labelWidth,
          child: Text(label, style: vbuMono(size: 11, color: c.textSecondary)),
        ),
        Expanded(
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: c.surface2,
              borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
              border: Border.all(color: c.borderDefault),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                empty ? hint : value!,
                style: vbuMono(
                  size: 12,
                  color: empty ? c.textTertiary : c.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        const SizedBox(width: VbuTokens.space2),
        Tooltip(
          message: 'Choose folder',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onPick,
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: c.surface2,
                borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
                border: Border.all(color: c.borderDefault),
              ),
              child: Center(
                child: Icon(
                  Icons.folder_open_outlined,
                  size: 14,
                  color: c.textSecondary,
                ),
              ),
            ),
          ),
        ),
        if (onClear != null) ...<Widget>[
          const SizedBox(width: VbuTokens.space1),
          Tooltip(
            message: 'Reset to default',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onClear,
              child: Padding(
                padding: const EdgeInsets.all(VbuTokens.space1),
                child: Icon(Icons.close, size: 14, color: c.textTertiary),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
