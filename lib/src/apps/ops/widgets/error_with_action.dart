// Self-healing error surface — pairs the error message with one or more
// suggested actions so the user can act without leaving the page.
// PRD §FM-OBSERVE-06.

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class ErrorAction {
  const ErrorAction({
    required this.label,
    required this.onPressed,
    this.icon,
    this.primary = false,
  });
  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool primary;
}

class ErrorWithAction extends StatelessWidget {
  const ErrorWithAction({
    super.key,
    required this.message,
    this.detail,
    this.actions = const [],
    this.compact = false,
  });

  final String message;
  final String? detail;
  final List<ErrorAction> actions;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? 10 : 14),
      decoration: BoxDecoration(
        color: OpsColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: OpsColors.danger.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline, color: OpsColors.danger, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    fontFamily: OpsType.sans,
                    fontSize: 13,
                    color: OpsColors.danger,
                    fontWeight: OpsType.semibold,
                  ),
                ),
              ),
            ],
          ),
          if (detail != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Text(
                detail!,
                style: TextStyle(
                  fontFamily: OpsType.mono,
                  fontSize: 11,
                  color: OpsColors.text2,
                  height: 1.4,
                ),
              ),
            ),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final a in actions)
                    a.primary
                        ? FilledButton.icon(
                          onPressed: a.onPressed,
                          icon:
                              a.icon != null
                                  ? Icon(a.icon, size: 14)
                                  : const SizedBox.shrink(),
                          label: Text(a.label),
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                          ),
                        )
                        : OutlinedButton.icon(
                          onPressed: a.onPressed,
                          icon:
                              a.icon != null
                                  ? Icon(a.icon, size: 14)
                                  : const SizedBox.shrink(),
                          label: Text(a.label),
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                          ),
                        ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
