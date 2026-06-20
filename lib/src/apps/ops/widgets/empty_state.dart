// Empty-state component used across surfaces with no data yet.
// PRD §FM-ONBOARD-04.
//
// Two-line layout: icon + headline + (optional) hint + (optional) CTA
// button. Tone is welcoming, not apologetic — empty often means "ready
// to start", not "broken".

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.headline,
    this.hint,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });

  final IconData icon;
  final String headline;
  final String? hint;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: compact ? 16 : 32,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: compact ? 48 : 64,
                height: compact ? 48 : 64,
                decoration: BoxDecoration(
                  color: OpsColors.surface2,
                  borderRadius: BorderRadius.circular(compact ? 12 : 16),
                ),
                child: Icon(
                  icon,
                  size: compact ? 24 : 32,
                  color: OpsColors.text2,
                ),
              ),
              SizedBox(height: compact ? 10 : 16),
              Text(
                headline,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: OpsType.sans,
                  fontSize: compact ? 13 : 15,
                  fontWeight: OpsType.semibold,
                  color: OpsColors.text,
                ),
              ),
              if (hint != null) ...[
                const SizedBox(height: 6),
                Text(
                  hint!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: OpsType.sans,
                    fontSize: 12,
                    color: OpsColors.text3,
                    height: 1.4,
                  ),
                ),
              ],
              if (actionLabel != null && onAction != null) ...[
                SizedBox(height: compact ? 10 : 16),
                FilledButton(
                  onPressed: onAction,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                  child: Text(actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
