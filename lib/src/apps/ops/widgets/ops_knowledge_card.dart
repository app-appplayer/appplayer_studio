import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'ops_models.dart';

class OpsKnowledgeCard extends StatelessWidget {
  const OpsKnowledgeCard({super.key, required this.entry, this.onTap});

  final KnowledgeEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final swatch = switch (entry.kind) {
      KnowledgeKind.fact => OpsColors.protocol,
      KnowledgeKind.pattern => OpsColors.knowledge,
      KnowledgeKind.summary => OpsColors.io,
    };

    return InkWell(
      onTap: onTap,
      borderRadius: OpsRadius.all_md,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: OpsColors.border),
          borderRadius: OpsRadius.all_md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: swatch,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  entry.kind.label.toUpperCase(),
                  style: TextStyle(
                    fontFamily: OpsType.mono,
                    fontSize: 9,
                    fontWeight: OpsType.semibold,
                    color: OpsColors.text3,
                    letterSpacing: 0.54,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              entry.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: OpsType.semibold,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              entry.body,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: OpsColors.text2,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              entry.meta,
              style: TextStyle(
                fontFamily: OpsType.mono,
                fontSize: 10,
                color: OpsColors.text3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
