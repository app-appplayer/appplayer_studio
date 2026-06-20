import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// UI-level history entry. vibe-derived layout. Hosts (vibe `HistoryLog`
/// rows · kernel `HistoryLog` rows · ops audit log · agent prompt log)
/// map their own entry shape onto this for display.
class VbuHistoryEntry {
  const VbuHistoryEntry({
    required this.timestamp,
    required this.kindLabel,
    this.kindColor,
    this.originatorLabel,
    this.changedPaths = const <String>[],
  });

  final DateTime timestamp;

  /// Short label for the entry kind — `'patch'`, `'open'`, `'revert'`,
  /// `'agent_invoked'`, etc. Hosts decide vocabulary.
  final String kindLabel;

  /// Optional tint for the kind label. `VbuTokens.colorOf(context).mint` is the
  /// vibe convention for "normal patch"; coral / amber for destructive
  /// or attention-worthy entries.
  final Color? kindColor;

  /// `'user'`, `'llm'`, `'cli'`, etc. — single-line attribution.
  final String? originatorLabel;

  /// JSON Pointer paths the entry touched. The viewer renders the first
  /// path inline and a `(+N)` count when there are more.
  final List<String> changedPaths;
}

/// Read-only history viewer — list of `VbuHistoryEntry` rows with header
/// + count + empty state. vibe `HistoryDialog` body extracted as a
/// reusable atom; other builders mount this anywhere they need an
/// audit-log surface.
class VbuHistoryViewer extends StatelessWidget {
  const VbuHistoryViewer({
    super.key,
    required this.entries,
    this.title = 'Recent changes',
    this.emptyText = 'No changes recorded yet.',
    this.padding = const EdgeInsets.symmetric(
      horizontal: VbuTokens.space3,
      vertical: VbuTokens.space2,
    ),
  });

  /// Newest first.
  final List<VbuHistoryEntry> entries;
  final String title;
  final String emptyText;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            VbuTokens.space4,
            VbuTokens.space4,
            VbuTokens.space4,
            VbuTokens.space2,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  style: vbuMono(
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
                      emptyText,
                      style: TextStyle(
                        fontSize: 12,
                        color: c.textSecondary,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  )
                  : ListView.separated(
                    padding: padding,
                    itemCount: entries.length,
                    separatorBuilder:
                        (_, __) => const SizedBox(height: VbuTokens.space1),
                    itemBuilder: (_, i) => _Row(entry: entries[i]),
                  ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.entry});
  final VbuHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final originator = entry.originatorLabel ?? '—';
    final paths =
        entry.changedPaths.isEmpty
            ? '—'
            : entry.changedPaths.length == 1
            ? entry.changedPaths.first
            : '${entry.changedPaths.first} (+${entry.changedPaths.length - 1})';
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VbuTokens.space2,
        vertical: VbuTokens.space2,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
        border: Border.all(color: c.borderDefault),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  _formatTime(entry.timestamp.toLocal()),
                  style: vbuMono(size: 11, color: c.textPrimary),
                ),
                Text(
                  entry.kindLabel,
                  style: TextStyle(
                    fontSize: 10,
                    color: entry.kindColor ?? c.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: VbuTokens.space2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  originator,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  paths,
                  style: vbuMono(size: 10, color: c.textSecondary),
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
}
