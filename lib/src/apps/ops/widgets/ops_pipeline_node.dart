import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'ops_atoms.dart';
import 'ops_models.dart';

class OpsPipelineNode extends StatelessWidget {
  const OpsPipelineNode({
    super.key,
    required this.step,
    this.onApprove,
    this.onReject,
    this.onViewClause,
    this.onRequestEdit,
  });

  final PipelineStep step;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;
  final VoidCallback? onViewClause;
  final VoidCallback? onRequestEdit;

  @override
  Widget build(BuildContext context) {
    final s = step.state;
    final isGate = s == PipelineState.gate;
    final isPending = s == PipelineState.pending;

    final surface = Theme.of(context).colorScheme.surface;
    final cardBg =
        isGate
            ? Color.alphaBlend(OpsColors.warn.withValues(alpha: 0.06), surface)
            : surface;
    final cardBorder = isGate ? OpsColors.warn : OpsColors.border;

    return Opacity(
      opacity: isPending ? 0.55 : 1,
      child: Container(
        decoration: BoxDecoration(
          color: cardBg,
          border: Border.all(color: cardBorder),
          borderRadius: OpsRadius.all_md,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StateIcon(state: s, label: step.indexLabel),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        step.name,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: OpsType.semibold,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        step.actorCaption,
                        style: TextStyle(
                          fontFamily: OpsType.mono,
                          fontSize: 10,
                          color: OpsColors.text3,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    step.description,
                    style: TextStyle(
                      fontSize: 11,
                      color: OpsColors.text2,
                      height: 1.5,
                    ),
                  ),
                  if (isGate) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _GateButton.approve(onPressed: onApprove),
                        _GateButton.reject(onPressed: onReject),
                        _GateButton.secondary(
                          label: 'View clause',
                          onPressed: onViewClause,
                        ),
                        _GateButton.secondary(
                          label: 'Request edit',
                          onPressed: onRequestEdit,
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                OpsStatusPill.pipeline(s),
                const SizedBox(height: 4),
                Text(
                  step.timeLabel,
                  style: TextStyle(
                    fontFamily: OpsType.mono,
                    fontSize: 10,
                    color: OpsColors.text3,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StateIcon extends StatelessWidget {
  const _StateIcon({required this.state, required this.label});
  final PipelineState state;
  final String label;

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    switch (state) {
      case PipelineState.done:
        bg = Color.alphaBlend(
          OpsColors.success.withValues(alpha: 0.16),
          OpsColors.surface2,
        );
        fg = OpsColors.success;
        break;
      case PipelineState.running:
        bg = Color.alphaBlend(
          OpsColors.protocol.withValues(alpha: 0.16),
          OpsColors.surface2,
        );
        fg = OpsColors.accent;
        break;
      case PipelineState.gate:
        bg = OpsColors.warn;
        fg = OpsColors.bg;
        break;
      case PipelineState.pending:
        bg = OpsColors.surface2;
        fg = OpsColors.text3;
        break;
    }
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          fontFamily: OpsType.mono,
          fontSize: 11,
          fontWeight: OpsType.bold,
          color: fg,
        ),
      ),
    );
  }
}

class _GateButton extends StatelessWidget {
  const _GateButton._({
    required this.label,
    required this.bg,
    required this.fg,
    required this.borderColor,
    required this.bold,
    this.onPressed,
  });

  factory _GateButton.approve({VoidCallback? onPressed}) => _GateButton._(
    label: 'Approve',
    bg: OpsColors.success,
    fg: OpsColors.bg,
    borderColor: OpsColors.success,
    bold: true,
    onPressed: onPressed,
  );
  factory _GateButton.reject({VoidCallback? onPressed}) => _GateButton._(
    label: 'Reject',
    bg: Colors.transparent,
    fg: OpsColors.text,
    borderColor: OpsColors.borderStrong,
    bold: false,
    onPressed: onPressed,
  );
  factory _GateButton.secondary({
    required String label,
    VoidCallback? onPressed,
  }) => _GateButton._(
    label: label,
    bg: OpsColors.surface,
    fg: OpsColors.text,
    borderColor: OpsColors.borderStrong,
    bold: false,
    onPressed: onPressed,
  );

  final String label;
  final Color bg;
  final Color fg;
  final Color borderColor;
  final bool bold;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(5),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(5),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: OpsType.sans,
              fontSize: 11,
              fontWeight: bold ? OpsType.semibold : OpsType.medium,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

/// 2×22 vertical connector between consecutive nodes.
class OpsPipelineConnector extends StatelessWidget {
  const OpsPipelineConnector({super.key, this.dim = false});
  final bool dim;
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 33),
      width: 2,
      height: 22,
      color: dim ? OpsColors.border : OpsColors.borderStrong,
    );
  }
}
