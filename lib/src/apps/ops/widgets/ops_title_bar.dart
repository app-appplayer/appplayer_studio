import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'ops_atoms.dart';

/// 36px window-chrome strip. App + workspace name in mono on the left,
/// status pills on the right. Drag region behavior is host-app responsibility.
class OpsTitleBar extends StatelessWidget {
  const OpsTitleBar({
    super.key,
    required this.appName,
    required this.workspace,
    required this.branch,
    this.onlineAgents = 0,
    this.runningProcesses = 0,
    this.onAgentsTap,
    this.onProcessesTap,
    this.chatDockOpen = false,
    this.onChatToggle,
  });

  final String appName;
  final String workspace;
  final String branch;
  final int onlineAgents;
  final int runningProcesses;
  final VoidCallback? onAgentsTap;
  final VoidCallback? onProcessesTap;

  /// Whether the right-side chat dock is currently expanded — controls the
  /// pressed/highlighted state of the chat toggle button on the title bar.
  final bool chatDockOpen;

  /// Tapping the chat icon toggles the right-side dock. The full-screen
  /// chat route remains accessible via the sidebar; the dock is a
  /// supplementary surface so chat stays available while looking at any
  /// other page.
  final VoidCallback? onChatToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(bottom: BorderSide(color: OpsColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: _TitleText(
              app: appName,
              workspace: workspace,
              branch: branch,
            ),
          ),
          const SizedBox(width: 16),
          _Pill(
            dotColor: OpsColors.success,
            label: '$onlineAgents agents online',
            onTap: onAgentsTap,
          ),
          const SizedBox(width: 14),
          _Pill(
            dotColor: OpsColors.accent,
            label: '$runningProcesses processes running',
            onTap: onProcessesTap,
          ),
          if (onChatToggle != null) ...[
            const SizedBox(width: 14),
            _ChatToggle(open: chatDockOpen, onTap: onChatToggle!),
          ],
        ],
      ),
    );
  }
}

class _ChatToggle extends StatelessWidget {
  const _ChatToggle({required this.open, required this.onTap});
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: open ? 'Hide chat' : 'Show chat',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: open ? OpsColors.accent.withValues(alpha: 0.18) : null,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: open ? OpsColors.accent : OpsColors.border,
            ),
          ),
          child: Icon(
            open ? Icons.chat_bubble : Icons.chat_bubble_outline,
            size: 14,
            color: open ? OpsColors.accent : OpsColors.text2,
          ),
        ),
      ),
    );
  }
}

class _TitleText extends StatelessWidget {
  const _TitleText({
    required this.app,
    required this.workspace,
    required this.branch,
  });
  final String app;
  final String workspace;
  final String branch;

  @override
  Widget build(BuildContext context) {
    return RichText(
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: TextStyle(
          fontFamily: OpsType.mono,
          fontSize: OpsType.md,
          fontWeight: OpsType.medium,
          color: OpsColors.text2,
        ),
        children: [
          TextSpan(text: '$app · '),
          TextSpan(
            text: workspace,
            style: TextStyle(
              color: OpsColors.text,
              fontWeight: OpsType.semibold,
            ),
          ),
          TextSpan(text: ' · $branch'),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.dotColor, required this.label, this.onTap});
  final Color dotColor;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: OpsColors.surface2,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          OpsDot(color: dotColor),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontFamily: OpsType.mono,
              fontSize: 11,
              color: OpsColors.text2,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return pill;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: pill,
    );
  }
}
