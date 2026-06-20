import 'package:flutter/material.dart';
import 'package:appplayer_studio/ui.dart';

import '../main/chrome_bridge.dart';
import 'tokens.dart';

/// Per `handoff/widgets/statusbar.md` — 24px mono status row at the foot
/// of the window. **Wiring layer** for [VbuStatusbar]; owns the
/// `state / latency / patches / pages / lint` data binding and builds
/// the left/right slot lists from there.
class VibeStatusbar extends StatelessWidget {
  const VibeStatusbar({
    super.key,
    required this.state,
    required this.latencyMs,
    required this.patches,
    required this.pages,
    required this.lastActivity,
    this.locale = 'UTC',
    this.specVersion = '',
    this.lintBlocks = 0,
    this.lintWarns = 0,
    this.onTapLint,
    this.chromeBridge,
  });

  /// Optional chrome bridge — when supplied, the statusbar listens to
  /// `statusbarText` and renders the active bundle's user-zone
  /// payload between the host's fixed left group and the right group
  /// (spec + locale).
  final ChromeBridge? chromeBridge;

  final StatusbarState state;
  final int latencyMs;
  final int patches;
  final int pages;
  final String lastActivity;
  final String locale;
  final String specVersion;

  /// Block-level (must-fix) findings from the spec validator. Drives
  /// the lint badge colour — coral when non-zero overrides any warns.
  final int lintBlocks;

  /// Warn-level (should-fix) findings. Surface as amber when there
  /// are no blocks; otherwise the block colour wins.
  final int lintWarns;

  /// Click handler for the lint badge — typically opens a modal
  /// listing every issue with code + path + message. Null hides the
  /// chevron affordance and disables the tap.
  final VoidCallback? onTapLint;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final mono = TextStyle(
      fontFamily: VibeTokens.fontMono,
      fontSize: 11,
      color: c.textTertiary,
    );
    final clean = lintBlocks == 0 && lintWarns == 0;
    final lintColor =
        lintBlocks > 0
            ? c.coral
            : (lintWarns > 0 ? c.amber : VibeTokens.status.ok);
    final lintLabel =
        clean
            ? 'lint: clean'
            : 'lint: ${lintBlocks > 0 ? '$lintBlocks block' : ''}'
                '${lintBlocks > 0 && lintWarns > 0 ? ' · ' : ''}'
                '${lintWarns > 0 ? '$lintWarns warn' : ''}';
    return MetaData(
      metaData: <String, dynamic>{
        'type': 'studio.chrome.statusbar',
        'id': 'statusbar',
        'label': _stateLabel(),
        'title': 'spec $specVersion',
      },
      child: VbuStatusbar(
        left: <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              VbuStatusDot(color: _stateDotColor()),
              const SizedBox(width: VibeTokens.space2),
              Text(_stateLabel(), style: mono),
            ],
          ),
          Text('${latencyMs}ms', style: mono),
          Text('patches: $patches', style: mono),
          Text('pages: $pages', style: mono),
          Text('last: $lastActivity', style: mono),
          VbuStatusBadge(color: lintColor, label: lintLabel, onTap: onTapLint),
        ],
        right: <Widget>[
          if (chromeBridge != null)
            ValueListenableBuilder<String>(
              valueListenable: chromeBridge!.statusbarText,
              builder:
                  (_, txt, __) =>
                      txt.isEmpty
                          ? const SizedBox.shrink()
                          : Text(txt, style: mono),
            ),
          Text(specVersion, style: mono),
          Text(locale, style: mono),
        ],
      ),
    );
  }

  Color _stateDotColor() {
    switch (state) {
      case StatusbarState.synced:
        return VibeTokens.status.ok;
      case StatusbarState.patching:
        return VibeTokens.status.warn;
      case StatusbarState.conflict:
        return VibeTokens.status.error;
      case StatusbarState.disconnected:
        return VibeTokens.color.textTertiary;
      case StatusbarState.saving:
        return VibeTokens.status.info;
    }
  }

  String _stateLabel() {
    switch (state) {
      case StatusbarState.synced:
        return 'synced';
      case StatusbarState.patching:
        return 'patching';
      case StatusbarState.conflict:
        return 'conflict';
      case StatusbarState.disconnected:
        return 'disconnected';
      case StatusbarState.saving:
        return 'saving';
    }
  }
}

enum StatusbarState { synced, patching, conflict, disconnected, saving }
