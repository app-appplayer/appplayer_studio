/// History dialog — reads chat jsonl files and renders the turns of
/// up to three context levels (Studio · Package · Project) as tabs in
/// a left sidebar. The host supplies one [HistoryLevel] per available
/// level; the dialog skips levels with non-existent files (they show
/// "no history yet"). Read-only.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../shell/app_theme.dart';
import '../shell/inspect_tag.dart';
import '../shell/tokens.dart';

class HistoryLevel {
  const HistoryLevel({
    required this.id,
    required this.label,
    required this.sublabel,
    required this.icon,
    required this.filePath,
  });

  final String id;
  final String label;
  final String sublabel;
  final IconData icon;
  final String filePath;
}

Future<void> showChatHistoryDialog(
  BuildContext context, {
  required List<HistoryLevel> levels,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _HistoryDialog(levels: levels),
  );
}

class _HistoryDialog extends StatefulWidget {
  const _HistoryDialog({required this.levels});
  final List<HistoryLevel> levels;

  @override
  State<_HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends State<_HistoryDialog> {
  late int _active;

  @override
  void initState() {
    super.initState();
    // Project (last in list) first if present — matches the Settings
    // dialog convention of leading with the most-specific context.
    _active = widget.levels.length - 1;
    if (_active < 0) _active = 0;
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final levels = widget.levels;
    if (levels.isEmpty) {
      return Dialog(
        backgroundColor: c.surface2,
        child: const Padding(
          padding: EdgeInsets.all(24),
          child: Text('No history available.'),
        ),
      );
    }
    final activeLevel = levels[_active];
    return Dialog(
      backgroundColor: c.surface2,
      child: SizedBox(
        width: 720,
        height: 560,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _Sidebar(
              levels: levels,
              active: _active,
              onPick: (i) => setState(() => _active = i),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(VibeTokens.space4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      '${activeLevel.label} · History',
                      style: TextStyle(
                        fontFamily: VibeTokens.fontSans,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: VibeTokens.space2),
                    Text(
                      activeLevel.filePath,
                      style: vibeMono(size: 10, color: c.textTertiary),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: VibeTokens.space3),
                    Expanded(child: _TurnList(filePath: activeLevel.filePath)),
                    const SizedBox(height: VibeTokens.space2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        inspectTag(
                          type: 'dialog_action',
                          id: 'chat_history.close',
                          label: 'Close',
                          child: TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('Close'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.levels,
    required this.active,
    required this.onPick,
  });
  final List<HistoryLevel> levels;
  final int active;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Container(
      width: 168,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(right: BorderSide(color: c.borderDefault)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: VibeTokens.space2,
        vertical: VibeTokens.space3,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (var i = 0; i < levels.length; i++) ...<Widget>[
            _Item(
              level: levels[i],
              selected: i == active,
              onTap: () => onPick(i),
            ),
            const SizedBox(height: 2),
          ],
        ],
      ),
    );
  }
}

class _Item extends StatefulWidget {
  const _Item({
    required this.level,
    required this.selected,
    required this.onTap,
  });
  final HistoryLevel level;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_Item> createState() => _ItemState();
}

class _ItemState extends State<_Item> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final bg =
        widget.selected
            ? c.surface3
            : (_hovered ? c.surface2 : Colors.transparent);
    final iconColor = widget.selected ? c.mint : c.textSecondary;
    final labelColor = widget.selected ? c.textPrimary : c.textSecondary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: VibeTokens.durFast,
          curve: VibeTokens.easeStandard,
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space2,
            vertical: VibeTokens.space2,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
          ),
          child: Row(
            children: <Widget>[
              Icon(widget.level.icon, size: 16, color: iconColor),
              const SizedBox(width: VibeTokens.space2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      widget.level.label,
                      style: TextStyle(
                        fontFamily: VibeTokens.fontSans,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: labelColor,
                      ),
                    ),
                    Text(
                      widget.level.sublabel,
                      style: vibeMono(size: 10, color: c.textTertiary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TurnList extends StatefulWidget {
  const _TurnList({required this.filePath});
  final String filePath;

  @override
  State<_TurnList> createState() => _TurnListState();
}

class _TurnListState extends State<_TurnList> {
  Future<List<Map<String, dynamic>>>? _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant _TurnList old) {
    super.didUpdateWidget(old);
    if (old.filePath != widget.filePath) {
      _future = _load();
    }
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final f = File(widget.filePath);
    if (!await f.exists()) return const <Map<String, dynamic>>[];
    try {
      final lines = await f.readAsLines();
      final out = <Map<String, dynamic>>[];
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          out.add(jsonDecode(line) as Map<String, dynamic>);
        } catch (_) {
          /* skip */
        }
      }
      return out;
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (_, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final entries = snap.data!;
        if (entries.isEmpty) {
          return Center(
            child: Text(
              'No history yet — turns appear here as you chat.',
              style: vibeMono(size: 11, color: c.textTertiary),
            ),
          );
        }
        return ListView.separated(
          itemCount: entries.length,
          separatorBuilder: (_, __) => const SizedBox(height: 6),
          itemBuilder: (_, i) {
            final e = entries[i];
            final role = (e['role'] as String?) ?? '';
            final text = (e['text'] as String?) ?? '';
            final at = (e['at'] as String?) ?? '';
            return Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
                border: Border.all(color: c.borderDefault),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(
                        role,
                        style: vibeMono(
                          size: 10,
                          weight: FontWeight.w600,
                          color:
                              role.startsWith('user')
                                  ? c.mint
                                  : c.textSecondary,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        at,
                        style: vibeMono(size: 10, color: c.textTertiary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    text,
                    style: TextStyle(
                      fontFamily: VibeTokens.fontSans,
                      fontSize: 12,
                      color: c.textPrimary,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
