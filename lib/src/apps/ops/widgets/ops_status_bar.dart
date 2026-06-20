import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'ops_atoms.dart';
import 'ops_models.dart';

class OpsStatusBar extends StatelessWidget {
  const OpsStatusBar({
    super.key,
    required this.state,
    this.onConnectionTap,
    this.onKnowledgeTap,
    this.onLlmTap,
    this.onTokensTap,
  });
  final OpsStatusBarState state;
  final VoidCallback? onConnectionTap;
  final VoidCallback? onKnowledgeTap;
  final VoidCallback? onLlmTap;
  final VoidCallback? onTokensTap;

  @override
  Widget build(BuildContext context) {
    final txt = TextStyle(
      fontFamily: OpsType.mono,
      fontSize: 10,
      color: OpsColors.text3,
    );
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: OpsColors.border)),
      ),
      child: DefaultTextStyle(
        style: txt,
        child: Row(
          children: [
            _Cell(
              onTap: onConnectionTap,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OpsDot(color: state.connDot),
                  const SizedBox(width: 5),
                  Text('connected · ${state.mcpServers} MCP servers'),
                ],
              ),
            ),
            const SizedBox(width: 16),
            _Cell(
              onTap: onKnowledgeTap,
              child: Text(
                'kg: ${state.facts} facts · ${state.patterns} patterns · ${state.summaries} summaries',
              ),
            ),
            const SizedBox(width: 16),
            _Cell(
              onTap: onTokensTap,
              child: Text(
                'tok ${_compact(state.tokensIn)} → ${_compact(state.tokensOut)} · '
                '${state.llmCalls} calls'
                '${state.errors > 0 ? " · ${state.errors} err" : ""}',
                style: TextStyle(
                  fontFamily: OpsType.mono,
                  fontSize: 10,
                  color: state.errors > 0 ? OpsColors.warn : OpsColors.text3,
                ),
              ),
            ),
            const Spacer(),
            _Cell(onTap: onLlmTap, child: Text('llm: ${state.llm}')),
            const SizedBox(width: 16),
            Text('build ${state.build}'),
          ],
        ),
      ),
    );
  }

  static String _compact(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '${(n / 1000000).toStringAsFixed(1)}M';
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    if (onTap == null) return child;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: child,
      ),
    );
  }
}
