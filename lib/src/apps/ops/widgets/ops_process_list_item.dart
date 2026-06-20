import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'ops_atoms.dart';
import 'ops_models.dart';

class OpsProcessListItem extends StatelessWidget {
  const OpsProcessListItem({
    super.key,
    required this.process,
    required this.selected,
    required this.onTap,
  });

  final ProcessSummary process;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color:
              selected
                  ? Color.alphaBlend(
                    OpsColors.accent.withValues(alpha: 0.06),
                    surface,
                  )
                  : surface,
          border: Border.all(
            color: selected ? OpsColors.accent : OpsColors.border,
          ),
          borderRadius: OpsRadius.all_md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    process.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: OpsType.semibold,
                    ),
                  ),
                ),
                OpsStatusPill.process(process.state, compact: true),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              process.meta,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: OpsType.mono,
                fontSize: 10,
                color: OpsColors.text3,
              ),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: process.progress.clamp(0.0, 1.0),
                minHeight: 3,
                backgroundColor: OpsColors.surface2,
                valueColor: AlwaysStoppedAnimation(
                  process.state == ProcessRunState.paused
                      ? OpsColors.warn
                      : OpsColors.accent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
