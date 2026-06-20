import 'package:flutter/material.dart';

import 'package:appplayer_studio/base.dart';
import 'package:brain_kernel/brain_kernel.dart' show CanonicalChangeKind;

/// Modal that lists the most recent canonical mutations from
/// `<projectPath>/history.jsonl`. Read-only — undo / redo lives on the
/// header buttons. Useful for spotting "what changed in the last
/// minute" or audit-style sanity checks.
Future<void> showHistoryDialog(
  BuildContext context, {
  required VibeHistoryLog historyLog,
  int limit = 200,
}) async {
  final entries = await historyLog.readAll();
  final tail =
      entries.length > limit
          ? entries.sublist(entries.length - limit)
          : entries;
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => _HistoryDialog(entries: tail.reversed.toList()),
  );
}

class _HistoryDialog extends StatelessWidget {
  const _HistoryDialog({required this.entries});

  /// Newest first.
  final List<HistoryEntry> entries;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Dialog(
      backgroundColor: c.surface2,
      child: SizedBox(
        width: 520,
        height: 540,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                VibeTokens.space4,
                VibeTokens.space4,
                VibeTokens.space4,
                VibeTokens.space2,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Recent changes',
                      style: vibeMono(
                        size: 14,
                        weight: FontWeight.w600,
                        color: c.textPrimary,
                      ),
                    ),
                  ),
                  Text(
                    '${entries.length} entr${entries.length == 1 ? 'y' : 'ies'}',
                    style: TextStyle(fontSize: 11, color: c.textTertiary),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child:
                  entries.isEmpty
                      ? Center(
                        child: Text(
                          'No changes recorded yet.',
                          style: TextStyle(
                            fontSize: 12,
                            color: c.textSecondary,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      )
                      : ListView.separated(
                        padding: const EdgeInsets.symmetric(
                          horizontal: VibeTokens.space3,
                          vertical: VibeTokens.space2,
                        ),
                        itemCount: entries.length,
                        separatorBuilder:
                            (_, __) =>
                                const SizedBox(height: VibeTokens.space1),
                        itemBuilder: (_, i) => _HistoryRow(entry: entries[i]),
                      ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(VibeTokens.space3),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  inspectTag(
                    type: 'dialog_action',
                    id: 'history.close',
                    label: 'Close',
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry});
  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final kindLabel = _kindLabel(entry.kind);
    final originator = entry.originatorKind ?? '—';
    final paths =
        entry.changedPaths.isEmpty
            ? '—'
            : entry.changedPaths.length == 1
            ? entry.changedPaths.first
            : '${entry.changedPaths.first} (+${entry.changedPaths.length - 1})';
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VibeTokens.space2,
        vertical: VibeTokens.space2,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
        border: Border.all(color: c.borderDefault),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // Time + kind column.
          SizedBox(
            width: 96,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  _formatTime(entry.at.toLocal()),
                  style: vibeMono(size: 11, color: c.textPrimary),
                ),
                Text(
                  kindLabel,
                  style: TextStyle(fontSize: 10, color: _kindColor(entry.kind)),
                ),
              ],
            ),
          ),
          const SizedBox(width: VibeTokens.space2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  originator +
                      (entry.originatorId != null
                          ? ' · ${entry.originatorId}'
                          : ''),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  paths,
                  style: vibeMono(size: 10, color: c.textSecondary),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _formatTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  String _kindLabel(CanonicalChangeKind kind) {
    switch (kind) {
      case CanonicalChangeKind.patch:
        return 'patch';
      case CanonicalChangeKind.open:
        return 'open';
      case CanonicalChangeKind.saveAs:
        return 'save as';
      case CanonicalChangeKind.revert:
        return 'revert';
    }
  }

  Color _kindColor(CanonicalChangeKind kind) {
    final c = VibeTokens.color;
    switch (kind) {
      case CanonicalChangeKind.patch:
        return c.mint;
      case CanonicalChangeKind.open:
      case CanonicalChangeKind.saveAs:
        return c.textSecondary;
      case CanonicalChangeKind.revert:
        return c.amber;
    }
  }
}
