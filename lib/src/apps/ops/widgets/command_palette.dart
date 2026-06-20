// Command palette overlay — Cmd+K (macOS) / Ctrl+K (Linux/Windows).
// PRD §FM-POWER-01.
//
// Mounted as a global Shortcuts/Actions wrapper just below the booted
// ProviderScope. Pressing Cmd+K opens a centered modal with a search
// field and a fuzzy-filtered list of [OpsCommand]s. Up/Down navigates,
// Enter executes, Escape closes.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/command_registry.dart';
import '../theme/tokens.dart';

class _OpenPaletteIntent extends Intent {
  const _OpenPaletteIntent();
}

/// Wraps [child] with the global Cmd+K shortcut and an Overlay-friendly
/// open helper.
class CommandPaletteHost extends ConsumerStatefulWidget {
  const CommandPaletteHost({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<CommandPaletteHost> createState() => _CommandPaletteHostState();
}

class _CommandPaletteHostState extends ConsumerState<CommandPaletteHost> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            const _OpenPaletteIntent(),
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            const _OpenPaletteIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _OpenPaletteIntent: CallbackAction<_OpenPaletteIntent>(
            onInvoke: (_) {
              if (!_open) _show();
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: widget.child),
      ),
    );
  }

  Future<void> _show() async {
    setState(() => _open = true);
    final commands = await buildCommandList(ref);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => _PaletteDialog(commands: commands, ref: ref),
    );
    if (mounted) setState(() => _open = false);
  }
}

class _PaletteDialog extends StatefulWidget {
  const _PaletteDialog({required this.commands, required this.ref});
  final List<OpsCommand> commands;
  final WidgetRef ref;

  @override
  State<_PaletteDialog> createState() => _PaletteDialogState();
}

class _PaletteDialogState extends State<_PaletteDialog> {
  final _query = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<OpsCommand> _filtered() {
    final q = _query.text.trim();
    if (q.isEmpty) return widget.commands;
    final scored = <({double score, OpsCommand cmd})>[];
    for (final c in widget.commands) {
      final hit =
          fuzzyScore(q, c.label) ??
          (c.hint == null ? null : fuzzyScore(q, c.hint!)) ??
          fuzzyScore(q, c.category);
      if (hit != null) scored.add((score: hit.score, cmd: c));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return [for (final s in scored) s.cmd];
  }

  void _runSelected() {
    final list = _filtered();
    if (list.isEmpty) return;
    final cmd = list[_selected.clamp(0, list.length - 1)];
    Navigator.of(context).pop();
    cmd.run(widget.ref);
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered();
    if (_selected >= list.length)
      _selected = list.isEmpty ? 0 : list.length - 1;

    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.only(top: 96, left: 24, right: 24),
      backgroundColor: Colors.transparent,
      elevation: 24,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 480),
        child: KeyboardListener(
          focusNode: FocusNode(),
          onKeyEvent: _onKey,
          child: Container(
            decoration: BoxDecoration(
              color: OpsColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: OpsColors.borderStrong),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 24,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    controller: _query,
                    focusNode: _focus,
                    onChanged: (_) => setState(() => _selected = 0),
                    onSubmitted: (_) => _runSelected(),
                    style: const TextStyle(
                      fontFamily: OpsType.sans,
                      fontSize: 15,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Search commands, agents, skills…',
                      prefixIcon: Icon(Icons.search, size: 18),
                      border: InputBorder.none,
                      filled: false,
                    ),
                  ),
                ),
                Divider(height: 1, color: OpsColors.border),
                Expanded(
                  child:
                      list.isEmpty
                          ? Center(
                            child: Text(
                              'No matches',
                              style: TextStyle(color: OpsColors.text3),
                            ),
                          )
                          : ListView.builder(
                            controller: _scroll,
                            itemCount: list.length,
                            itemBuilder:
                                (ctx, i) => _PaletteRow(
                                  cmd: list[i],
                                  selected: i == _selected,
                                  onTap: () {
                                    Navigator.of(context).pop();
                                    list[i].run(widget.ref);
                                  },
                                ),
                          ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: OpsColors.surface1,
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(12),
                      bottomRight: Radius.circular(12),
                    ),
                  ),
                  child: Row(
                    children: [
                      const _Hint(label: '↑↓', hint: 'navigate'),
                      const SizedBox(width: 12),
                      const _Hint(label: '⏎', hint: 'open'),
                      const SizedBox(width: 12),
                      const _Hint(label: 'esc', hint: 'close'),
                      const Spacer(),
                      Text(
                        'makemind ops · command palette',
                        style: TextStyle(
                          fontFamily: OpsType.mono,
                          fontSize: 10,
                          color: OpsColors.text3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return;
    final list = _filtered();
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _selected = (_selected + 1).clamp(0, list.length - 1));
      _ensureVisible();
    } else if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _selected = (_selected - 1).clamp(0, list.length - 1));
      _ensureVisible();
    } else if (e.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
    } else if (e.logicalKey == LogicalKeyboardKey.enter) {
      _runSelected();
    }
  }

  void _ensureVisible() {
    if (!_scroll.hasClients) return;
    const rowHeight = 44.0;
    final target = _selected * rowHeight;
    if (target < _scroll.offset) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    } else if (target >
        _scroll.offset + _scroll.position.viewportDimension - rowHeight) {
      _scroll.animateTo(
        target - _scroll.position.viewportDimension + rowHeight,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }
  }
}

class _PaletteRow extends StatelessWidget {
  const _PaletteRow({
    required this.cmd,
    required this.selected,
    required this.onTap,
  });
  final OpsCommand cmd;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? OpsColors.surface2 : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(
                cmd.icon ?? Icons.chevron_right,
                size: 16,
                color: OpsColors.text2,
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 80,
                child: Text(
                  cmd.category,
                  style: TextStyle(
                    fontFamily: OpsType.mono,
                    fontSize: 10,
                    color: OpsColors.text3,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  cmd.label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: OpsType.sans,
                    fontSize: 13,
                  ),
                ),
              ),
              if (cmd.hint != null)
                Text(
                  cmd.hint!,
                  style: TextStyle(
                    fontFamily: OpsType.mono,
                    fontSize: 10,
                    color: OpsColors.text3,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.label, required this.hint});
  final String label;
  final String hint;
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: OpsColors.surface3,
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: OpsType.mono,
              fontSize: 10,
              color: OpsColors.text2,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          hint,
          style: TextStyle(
            fontFamily: OpsType.mono,
            fontSize: 10,
            color: OpsColors.text3,
          ),
        ),
      ],
    );
  }
}
