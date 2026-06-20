import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'ops_models.dart';

class OpsAgentDetail extends StatelessWidget {
  const OpsAgentDetail({super.key, required this.agent});
  final AgentSummary agent;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 320, child: _IdentityCard(agent: agent)),
        const SizedBox(width: 18),
        Expanded(child: _GrowthPanel(agent: agent)),
      ],
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.agent});
  final AgentSummary agent;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return Container(
      decoration: BoxDecoration(
        color: surface,
        border: Border.all(color: OpsColors.border),
        borderRadius: OpsRadius.all_lg,
        boxShadow: OpsElevation.e1,
      ),
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: SizedBox(
              width: 80,
              height: 80,
              child: Stack(
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      gradient: agent.actor.gradient,
                      borderRadius: BorderRadius.circular(22),
                      boxShadow: OpsElevation.e2,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      agent.actor.initials,
                      style: const TextStyle(
                        fontFamily: OpsType.sans,
                        fontSize: 30,
                        fontWeight: OpsType.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  if (agent.online)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: OpsColors.success,
                          shape: BoxShape.circle,
                          border: Border.all(color: surface, width: 3),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            agent.name,
            style: const TextStyle(
              fontFamily: OpsType.sans,
              fontSize: 18,
              fontWeight: OpsType.bold,
              letterSpacing: -0.18,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            agent.role.toUpperCase(),
            style: TextStyle(
              fontFamily: OpsType.mono,
              fontSize: 11,
              color: OpsColors.text3,
              letterSpacing: 0.66,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              for (final tag in agent.tags)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: OpsColors.accentSoft,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    tag,
                    style: TextStyle(
                      fontFamily: OpsType.mono,
                      fontSize: 10,
                      color: OpsColors.accent,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 12),
          for (final row in agent.metaRows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Text(
                    row.key.toUpperCase(),
                    style: TextStyle(
                      fontFamily: OpsType.mono,
                      fontSize: 10,
                      color: OpsColors.text3,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    row.value,
                    style: const TextStyle(
                      fontFamily: OpsType.sans,
                      fontSize: 12,
                      fontWeight: OpsType.medium,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _GrowthPanel extends StatelessWidget {
  const _GrowthPanel({required this.agent});
  final AgentSummary agent;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return Container(
      decoration: BoxDecoration(
        color: surface,
        border: Border.all(color: OpsColors.border),
        borderRadius: OpsRadius.all_lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '3-layer growth',
                  style: TextStyle(
                    fontSize: OpsType.xl,
                    fontWeight: OpsType.semibold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Profile → Skills → Philosophy · derived from observed task outcomes',
                  style: TextStyle(
                    fontSize: 11,
                    color: OpsColors.text2,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < agent.layers.length; i++) ...[
                  _LayerPip(layer: agent.layers[i]),
                  if (i < agent.layers.length - 1) const SizedBox(height: 14),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
            child: Row(
              children: [
                Expanded(
                  child: _FooterCol(
                    label: 'Last skill gained',
                    title: agent.lastSkill.title,
                    subtitle: agent.lastSkill.subtitle,
                  ),
                ),
                Expanded(
                  child: _FooterCol(
                    label: 'Open tension',
                    title: agent.openTension.title,
                    subtitle: agent.openTension.subtitle,
                  ),
                ),
                Expanded(
                  child: _FooterCol(
                    label: 'Next milestone',
                    title: agent.nextMilestone.title,
                    subtitle: agent.nextMilestone.subtitle,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LayerPip extends StatelessWidget {
  const _LayerPip({required this.layer});
  final AgentLayerProgress layer;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        border: Border.all(color: OpsColors.border),
        borderRadius: OpsRadius.all_md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                layer.color.withValues(alpha: 0.16),
                OpsColors.surface2,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Text(
              layer.label,
              style: TextStyle(
                fontFamily: OpsType.mono,
                fontSize: 13,
                fontWeight: OpsType.bold,
                color: layer.color,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  layer.title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: OpsType.semibold,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  layer.description,
                  style: TextStyle(
                    fontSize: 11,
                    color: OpsColors.text2,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  layer.stats,
                  style: TextStyle(
                    fontFamily: OpsType.mono,
                    fontSize: 10,
                    color: OpsColors.text3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SizedBox(
                width: 110,
                height: 6,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: TweenAnimationBuilder<double>(
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeOutCubic,
                    tween: Tween(begin: 0, end: layer.percent.clamp(0.0, 1.0)),
                    builder:
                        (_, v, __) => LinearProgressIndicator(
                          value: v,
                          backgroundColor: OpsColors.surface2,
                          valueColor: AlwaysStoppedAnimation(layer.color),
                        ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${(layer.percent * 100).round()}%',
                style: TextStyle(
                  fontFamily: OpsType.mono,
                  fontSize: 11,
                  fontWeight: OpsType.semibold,
                  color: OpsColors.text2,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FooterCol extends StatelessWidget {
  const _FooterCol({
    required this.label,
    required this.title,
    required this.subtitle,
  });
  final String label;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontFamily: OpsType.mono,
            fontSize: 10,
            color: OpsColors.text3,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          title,
          style: const TextStyle(fontSize: 12, fontWeight: OpsType.semibold),
        ),
        const SizedBox(height: 2),
        Text(subtitle, style: TextStyle(fontSize: 11, color: OpsColors.text2)),
      ],
    );
  }
}
