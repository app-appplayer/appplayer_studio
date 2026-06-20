// Keyboard-shortcut cheatsheet — opened via `?` (or `Shift+/`) anywhere
// in the app. Lists every active shortcut + a short description so the
// user doesn't have to discover them by accident. PRD §FM-POWER (P1).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

class _OpenShortcutsIntent extends Intent {
  const _OpenShortcutsIntent();
}

class ShortcutsHost extends StatefulWidget {
  const ShortcutsHost({super.key, required this.child});
  final Widget child;
  @override
  State<ShortcutsHost> createState() => _ShortcutsHostState();
}

class _ShortcutsHostState extends State<ShortcutsHost> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.slash, shift: true):
            const _OpenShortcutsIntent(),
        const SingleActivator(LogicalKeyboardKey.question):
            const _OpenShortcutsIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _OpenShortcutsIntent: CallbackAction<_OpenShortcutsIntent>(
            onInvoke: (_) {
              if (!_open) _show();
              return null;
            },
          ),
        },
        child: widget.child,
      ),
    );
  }

  Future<void> _show() async {
    setState(() => _open = true);
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => const _ShortcutsDialog(),
    );
    if (mounted) setState(() => _open = false);
  }
}

class _ShortcutsDialog extends StatelessWidget {
  const _ShortcutsDialog();

  static const _rows = <_ShortcutRow>[
    _ShortcutRow(
      keys: ['⌘ K', 'Ctrl K'],
      label: 'Open command palette',
      hint: 'Search routes, agents, skills, workspaces, recipes, actions.',
    ),
    _ShortcutRow(
      keys: ['?', 'Shift /'],
      label: 'Open this cheatsheet',
      hint: 'Anywhere in the app.',
    ),
    _ShortcutRow(
      keys: ['Esc'],
      label: 'Close any modal',
      hint: 'Dialogs, palette, dropdowns.',
    ),
    _ShortcutRow(
      keys: ['↑', '↓'],
      label: 'Navigate palette / tree',
      hint: 'Inside Cmd+K results, file tree, etc.',
    ),
    _ShortcutRow(
      keys: ['Enter'],
      label: 'Activate the highlighted item',
      hint: 'In palette, dialogs.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Dialog(
      alignment: Alignment.center,
      backgroundColor: Colors.transparent,
      elevation: 24,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: OpsColors.borderStrong),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Row(
                  children: [
                    const Icon(Icons.keyboard_alt_outlined, size: 18),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Keyboard shortcuts',
                        style: TextStyle(
                          fontFamily: OpsType.sans,
                          fontSize: 15,
                          fontWeight: OpsType.semibold,
                        ),
                      ),
                    ),
                    IconButton(
                      iconSize: 16,
                      splashRadius: 14,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: OpsColors.border),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [for (final r in _rows) _ShortcutTile(row: r)],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
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
                    Text(
                      'More shortcuts will land per surface as the app grows.',
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
    );
  }
}

class _ShortcutRow {
  const _ShortcutRow({
    required this.keys,
    required this.label,
    required this.hint,
  });
  final List<String> keys;
  final String label;
  final String hint;
}

class _ShortcutTile extends StatelessWidget {
  const _ShortcutTile({required this.row});
  final _ShortcutRow row;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [for (final k in row.keys) _Kbd(label: k)],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.label,
                  style: const TextStyle(
                    fontFamily: OpsType.sans,
                    fontSize: 13,
                    fontWeight: OpsType.medium,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  row.hint,
                  style: TextStyle(
                    fontFamily: OpsType.sans,
                    fontSize: 11,
                    color: OpsColors.text3,
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

class _Kbd extends StatelessWidget {
  const _Kbd({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: OpsColors.surface3,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: OpsColors.border),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: OpsType.mono,
          fontSize: 11,
          color: OpsColors.text2,
        ),
      ),
    );
  }
}
