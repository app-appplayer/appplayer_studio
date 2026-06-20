import 'package:flutter/material.dart';

import '../theme/tokens.dart';

enum OpsKpiTrend { up, down, neutral }

class OpsKpiTile extends StatelessWidget {
  const OpsKpiTile({
    super.key,
    required this.label,
    required this.value,
    this.delta,
    this.deltaTrend = OpsKpiTrend.neutral,
  });

  final String label;
  final String value;
  final String? delta;
  final OpsKpiTrend deltaTrend;

  @override
  Widget build(BuildContext context) {
    final deltaColor = switch (deltaTrend) {
      OpsKpiTrend.up => OpsColors.success,
      OpsKpiTrend.down => OpsColors.danger,
      OpsKpiTrend.neutral => OpsColors.text3,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: OpsColors.border),
        borderRadius: OpsRadius.all_md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontFamily: OpsType.mono,
              fontSize: 10,
              fontWeight: OpsType.semibold,
              color: OpsColors.text3,
              letterSpacing: 0.7,
            ),
          ),
          const SizedBox(height: 4),
          Text(value, style: Theme.of(context).textTheme.displayLarge),
          const SizedBox(height: 6),
          // Always reserve the delta line's height so tiles with and
          // without a delta keep identical height — no shrink.
          Text(
            delta ?? '',
            style: TextStyle(
              fontFamily: OpsType.mono,
              fontSize: 11,
              color: deltaColor,
            ),
          ),
        ],
      ),
    );
  }
}
