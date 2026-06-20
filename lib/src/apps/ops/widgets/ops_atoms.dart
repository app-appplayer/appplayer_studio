import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'ops_models.dart';

/// Avatar for an actor (agent / human / process). Square / squircle / circle
/// shape selected by [actor.kind]. Online ring on bottom-right when [online]
/// is true.
class OpsActorAvatar extends StatelessWidget {
  const OpsActorAvatar({
    super.key,
    required this.actor,
    this.size = 32,
    this.online = false,
    this.showInitials = true,
  });

  final ActivityActor actor;
  final double size;
  final bool online;
  final bool showInitials;

  @override
  Widget build(BuildContext context) {
    final radius = switch (actor.kind) {
      ActorKind.process => size * 0.22,
      ActorKind.human => size,
      ActorKind.agent => size * 0.28,
    };
    final ringSize = (size * 0.28).clamp(8, 18).toDouble();
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              gradient: actor.gradient,
              borderRadius: BorderRadius.circular(radius),
            ),
            alignment: Alignment.center,
            child:
                showInitials
                    ? Text(
                      actor.initials,
                      style: TextStyle(
                        fontFamily: OpsType.sans,
                        fontSize: size * 0.42,
                        fontWeight: OpsType.bold,
                        color: Colors.white,
                        letterSpacing: -0.2,
                      ),
                    )
                    : null,
          ),
          if (online)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: ringSize,
                height: ringSize,
                decoration: BoxDecoration(
                  color: OpsColors.success,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.surface,
                    width: 2,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Compact AI / Human role chip used next to a member's name.
class OpsRoleTag extends StatelessWidget {
  const OpsRoleTag({super.key, required this.kind});
  final MemberKind kind;

  @override
  Widget build(BuildContext context) {
    final isAi = kind == MemberKind.ai;
    final bg = isAi ? OpsColors.accentSoft : OpsColors.surface2;
    final fg = isAi ? OpsColors.accent : OpsColors.text3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.all(Radius.circular(3)),
      ),
      child: Text(
        isAi ? 'AI' : 'HUMAN',
        style: TextStyle(
          fontFamily: OpsType.mono,
          fontSize: 9,
          fontWeight: OpsType.medium,
          color: fg,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// 3 vertical bars representing growth across L0/L1/L2 layers. Height of
/// each bar is proportional to the corresponding value in [levels] (0..1).
class OpsLevelBars extends StatelessWidget {
  const OpsLevelBars({super.key, required this.levels});
  final List<double> levels;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++) ...[
            _bar(levels.length > i ? levels[i].clamp(0.0, 1.0) : 0.0),
            if (i < 2) const SizedBox(width: 2),
          ],
        ],
      ),
    );
  }

  Widget _bar(double v) {
    final h = (18 * v).clamp(2.0, 18.0);
    return Container(
      width: 4,
      height: h,
      decoration: BoxDecoration(
        color: v > 0.05 ? OpsColors.knowledge : OpsColors.surface3,
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }
}

/// Status pill — uses [OpsStatus] colors from app_theme.
class OpsStatusPill extends StatelessWidget {
  const OpsStatusPill({
    super.key,
    required this.status,
    required this.label,
    this.compact = false,
  });

  final OpsStatus status;
  final String label;
  final bool compact;

  factory OpsStatusPill.pipeline(PipelineState state, {bool compact = false}) {
    final s = switch (state) {
      PipelineState.done => OpsStatus.ok,
      PipelineState.running => OpsStatus.running,
      PipelineState.gate => OpsStatus.gate,
      PipelineState.pending => OpsStatus.queued,
    };
    final label = switch (state) {
      PipelineState.done => 'done',
      PipelineState.running => 'running',
      PipelineState.gate => 'GATE',
      PipelineState.pending => 'queued',
    };
    return OpsStatusPill(status: s, label: label, compact: compact);
  }

  factory OpsStatusPill.process(ProcessRunState state, {bool compact = false}) {
    final s = switch (state) {
      ProcessRunState.running => OpsStatus.running,
      ProcessRunState.gate => OpsStatus.gate,
      ProcessRunState.ok => OpsStatus.ok,
      ProcessRunState.scheduled => OpsStatus.ok,
      ProcessRunState.paused => OpsStatus.gate,
    };
    final label = switch (state) {
      ProcessRunState.running => 'RUN',
      ProcessRunState.gate => 'GATE',
      ProcessRunState.ok => 'OK',
      ProcessRunState.scheduled => 'CRON',
      ProcessRunState.paused => 'PAUSED',
    };
    return OpsStatusPill(status: s, label: label, compact: compact);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 7,
        vertical: compact ? 2 : 2,
      ),
      decoration: BoxDecoration(
        color: status.bg,
        borderRadius: const BorderRadius.all(Radius.circular(3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: OpsType.mono,
          fontSize: compact ? 9 : 10,
          fontWeight: OpsType.semibold,
          color: status.fg,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Reusable card chrome: surface bg, 1px border, [OpsRadius.md] corners, no
/// elevation. Optional [header] (with title + sub + trailing) and [body].
class OpsCard extends StatelessWidget {
  const OpsCard({
    super.key,
    this.header,
    this.body,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    this.flushBody = false,
  });

  final OpsCardHeader? header;
  final Widget? body;
  final EdgeInsets padding;
  final bool flushBody;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: OpsColors.border),
        borderRadius: OpsRadius.all_md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: header!,
            ),
            const Divider(height: 1, thickness: 1),
          ],
          if (body != null)
            Padding(
              padding: flushBody ? EdgeInsets.zero : padding,
              child: body!,
            ),
        ],
      ),
    );
  }
}

class OpsCardHeader extends StatelessWidget {
  const OpsCardHeader({
    super.key,
    required this.title,
    this.sub,
    this.trailing,
  });
  final String title;
  final String? sub;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: const TextStyle(
            fontFamily: OpsType.sans,
            fontSize: OpsType.lg,
            fontWeight: OpsType.semibold,
          ),
        ),
        if (sub != null) ...[
          const SizedBox(width: 8),
          Text(
            sub!,
            style: TextStyle(
              fontFamily: OpsType.mono,
              fontSize: 10,
              color: OpsColors.text3,
            ),
          ),
        ],
        const Spacer(),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// Mono uppercase section eyebrow used at the top of each screen header.
class OpsCrumb extends StatelessWidget {
  const OpsCrumb(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontFamily: OpsType.mono,
        fontSize: 11,
        fontWeight: OpsType.semibold,
        color: OpsColors.text3,
        letterSpacing: 0.66,
      ),
    );
  }
}

/// Status-bar / activity / sidebar dot.
class OpsDot extends StatelessWidget {
  const OpsDot({super.key, required this.color, this.size = 6});
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
