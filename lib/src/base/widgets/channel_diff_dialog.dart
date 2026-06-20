// Channel diff view — side-by-side summary of what differs between
// the two enabled channels (serving / native). Reads each channel's
// bundle JSON via the existing fs port, walks the top-level `ui`
// sections (templates, pages, dashboard), and renders one row per
// id with an ADDED / MISSING / MODIFIED / IDENTICAL badge plus the
// origin label. Designed as a quick triage tool — for full content
// diff the user can switch channel and use the editor.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:appplayer_studio/base.dart';

/// Possible per-id diff states between two channels.
enum _ChannelDiffStatus {
  /// Present in `left` only.
  leftOnly,

  /// Present in `right` only.
  rightOnly,

  /// Present in both, content differs (JSON-encoded comparison).
  modified,

  /// Present in both, content matches byte-for-byte.
  identical,
}

class _DiffRow {
  const _DiffRow({
    required this.id,
    required this.status,
    this.leftValue,
    this.rightValue,
  });
  final String id;
  final _ChannelDiffStatus status;

  /// Raw maps backing the row, fed into the LCS line diff when the
  /// user expands a MODIFIED entry. null when the side is missing
  /// (LEFT_ONLY / RIGHT_ONLY rows).
  final Map<String, dynamic>? leftValue;
  final Map<String, dynamic>? rightValue;
}

/// One step in a line-level Longest Common Subsequence diff. `same`
/// rows render dimmed; `add` (only in right) renders mint; `remove`
/// (only in left) renders coral. Backed by a dynamic-programming
/// table — O(n*m) time / memory which is fine for page-sized JSON.
enum _LineKind { same, add, remove }

class _DiffLine {
  const _DiffLine({required this.kind, required this.text});
  final _LineKind kind;
  final String text;
}

/// Pretty-print [v] then split on newlines so the diff operates over
/// readable chunks rather than one giant blob.
List<String> _toLines(Map<String, dynamic>? v) {
  if (v == null) return const <String>[];
  try {
    final encoded = const JsonEncoder.withIndent('  ').convert(v);
    return encoded.split('\n');
  } catch (_) {
    return const <String>[];
  }
}

/// Compute an LCS-based line diff between [left] and [right]. Walks
/// the DP table backward to produce a single ordered op stream
/// (remove/add/same) so the renderer can stream the result top-down
/// without separate alignment passes.
List<_DiffLine> _lcsDiff(List<String> left, List<String> right) {
  final n = left.length;
  final m = right.length;
  final dp = List<List<int>>.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      if (left[i - 1] == right[j - 1]) {
        dp[i][j] = dp[i - 1][j - 1] + 1;
      } else {
        dp[i][j] = dp[i - 1][j] >= dp[i][j - 1] ? dp[i - 1][j] : dp[i][j - 1];
      }
    }
  }
  final out = <_DiffLine>[];
  var i = n;
  var j = m;
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && left[i - 1] == right[j - 1]) {
      out.add(_DiffLine(kind: _LineKind.same, text: left[i - 1]));
      i--;
      j--;
    } else if (j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j])) {
      out.add(_DiffLine(kind: _LineKind.add, text: right[j - 1]));
      j--;
    } else {
      out.add(_DiffLine(kind: _LineKind.remove, text: left[i - 1]));
      i--;
    }
  }
  return out.reversed.toList();
}

class _ChannelSnapshot {
  _ChannelSnapshot({
    required this.label,
    required this.pages,
    required this.templates,
    required this.dashboard,
  });
  final String label;
  final Map<String, Map<String, dynamic>> pages;
  final Map<String, Map<String, dynamic>> templates;
  final Map<String, dynamic>? dashboard;
}

Future<void> showChannelDiffDialog({
  required BuildContext context,
  required String projectPath,
  required List<({String id, String label, String subdir})> channels,
}) {
  return showDialog<void>(
    context: context,
    builder:
        (ctx) =>
            _ChannelDiffDialog(projectPath: projectPath, channels: channels),
  );
}

class _ChannelDiffDialog extends StatefulWidget {
  const _ChannelDiffDialog({required this.projectPath, required this.channels});
  final String projectPath;
  final List<({String id, String label, String subdir})> channels;

  @override
  State<_ChannelDiffDialog> createState() => _ChannelDiffDialogState();
}

class _ChannelDiffDialogState extends State<_ChannelDiffDialog> {
  late Future<List<_ChannelSnapshot>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  /// Read the first two enabled channels' bundles. Diff is binary —
  /// extra channels (if the model ever grows past serving / native)
  /// would need a different view, so we just take the first pair.
  Future<List<_ChannelSnapshot>> _load() async {
    final fs = FileWorkspaceFsPort();
    final out = <_ChannelSnapshot>[];
    for (final ch in widget.channels.take(2)) {
      final path = p.join(widget.projectPath, ch.subdir);
      final json = await fs.readJson(path);
      Map<String, Map<String, dynamic>> mapOfMaps(dynamic m) {
        if (m is! Map) return <String, Map<String, dynamic>>{};
        final res = <String, Map<String, dynamic>>{};
        for (final e in m.entries) {
          final v = e.value;
          if (v is Map) {
            res[e.key.toString()] = Map<String, dynamic>.from(v);
          }
        }
        return res;
      }

      final ui = json?['ui'];
      out.add(
        _ChannelSnapshot(
          label: ch.label,
          pages: ui is Map ? mapOfMaps(ui['pages']) : {},
          templates: ui is Map ? mapOfMaps(ui['templates']) : {},
          dashboard:
              ui is Map && ui['dashboard'] is Map
                  ? Map<String, dynamic>.from(ui['dashboard'] as Map)
                  : null,
        ),
      );
    }
    return out;
  }

  /// Compare two id→json maps and produce a sorted list of diff rows.
  /// Identical rows fall to the bottom so changes are visible first.
  List<_DiffRow> _diffMaps(
    Map<String, Map<String, dynamic>> left,
    Map<String, Map<String, dynamic>> right,
  ) {
    final ids = <String>{...left.keys, ...right.keys}.toList()..sort();
    final rows = <_DiffRow>[];
    for (final id in ids) {
      final l = left[id];
      final r = right[id];
      _ChannelDiffStatus status;
      if (l == null && r != null) {
        status = _ChannelDiffStatus.rightOnly;
      } else if (l != null && r == null) {
        status = _ChannelDiffStatus.leftOnly;
      } else if (l != null && r != null) {
        status =
            jsonEncode(l) == jsonEncode(r)
                ? _ChannelDiffStatus.identical
                : _ChannelDiffStatus.modified;
      } else {
        continue; // both null — shouldn't happen
      }
      rows.add(_DiffRow(id: id, status: status, leftValue: l, rightValue: r));
    }
    rows.sort((a, b) {
      // Non-identical first.
      if (a.status == _ChannelDiffStatus.identical &&
          b.status != _ChannelDiffStatus.identical) {
        return 1;
      }
      if (b.status == _ChannelDiffStatus.identical &&
          a.status != _ChannelDiffStatus.identical) {
        return -1;
      }
      return a.id.compareTo(b.id);
    });
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Dialog(
      backgroundColor: c.surface2,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: SizedBox(
        width: 720,
        height: 560,
        child: FutureBuilder<List<_ChannelSnapshot>>(
          future: _future,
          builder: (ctx, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final list = snap.data ?? const <_ChannelSnapshot>[];
            if (list.length < 2) {
              return Center(
                child: Text(
                  'Need two enabled channels to compare.',
                  style: vibeMono(size: 11, color: c.textTertiary),
                ),
              );
            }
            final left = list[0];
            final right = list[1];
            final pageRows = _diffMaps(left.pages, right.pages);
            final templateRows = _diffMaps(left.templates, right.templates);
            final dashboardRow = _dashboardRow(left.dashboard, right.dashboard);
            return Column(
              children: <Widget>[
                _Header(leftLabel: left.label, rightLabel: right.label),
                Divider(color: c.borderSubtle, height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(VibeTokens.space3),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _Section(
                          title: 'PAGES (${pageRows.length})',
                          rows: pageRows,
                        ),
                        const SizedBox(height: VibeTokens.space3),
                        _Section(
                          title: 'TEMPLATES (${templateRows.length})',
                          rows: templateRows,
                        ),
                        const SizedBox(height: VibeTokens.space3),
                        _Section(
                          title: 'DASHBOARD',
                          rows:
                              dashboardRow == null
                                  ? const <_DiffRow>[]
                                  : <_DiffRow>[dashboardRow],
                        ),
                      ],
                    ),
                  ),
                ),
                Divider(color: c.borderSubtle, height: 1),
                Padding(
                  padding: const EdgeInsets.all(VibeTokens.space3),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      inspectTag(
                        type: 'dialog_action',
                        id: 'channel_diff.close',
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
            );
          },
        ),
      ),
    );
  }

  _DiffRow? _dashboardRow(Map<String, dynamic>? l, Map<String, dynamic>? r) {
    if (l == null && r == null) return null;
    _ChannelDiffStatus status;
    if (l == null) {
      status = _ChannelDiffStatus.rightOnly;
    } else if (r == null) {
      status = _ChannelDiffStatus.leftOnly;
    } else {
      status =
          jsonEncode(l) == jsonEncode(r)
              ? _ChannelDiffStatus.identical
              : _ChannelDiffStatus.modified;
    }
    return _DiffRow(
      id: 'dashboard',
      status: status,
      leftValue: l,
      rightValue: r,
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.leftLabel, required this.rightLabel});
  final String leftLabel;
  final String rightLabel;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VibeTokens.space4,
        VibeTokens.space4,
        VibeTokens.space4,
        VibeTokens.space2,
      ),
      child: Row(
        children: <Widget>[
          Text(
            'Channel diff',
            style: TextStyle(
              fontFamily: VibeTokens.fontSans,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: c.textPrimary,
            ),
          ),
          const Spacer(),
          _channelChip(leftLabel, c.mint),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Icon(Icons.compare_arrows, size: 14, color: c.textTertiary),
          ),
          _channelChip(rightLabel, c.amber),
        ],
      ),
    );
  }

  Widget _channelChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        label,
        style: vibeMono(size: 10, weight: FontWeight.w600, color: color),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.rows});
  final String title;
  final List<_DiffRow> rows;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            title,
            style: vibeMono(
              size: 10,
              weight: FontWeight.w500,
              color: c.textTertiary,
            ),
          ),
        ),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'no entries',
              style: vibeMono(size: 10, color: c.textTertiary),
            ),
          )
        else
          for (final row in rows) _Row(row: row),
      ],
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({required this.row});
  final _DiffRow row;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _expanded = false;

  bool get _expandable =>
      widget.row.status == _ChannelDiffStatus.modified ||
      widget.row.status == _ChannelDiffStatus.leftOnly ||
      widget.row.status == _ChannelDiffStatus.rightOnly;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final (Color color, String label) = switch (widget.row.status) {
      _ChannelDiffStatus.leftOnly => (c.mint, 'LEFT ONLY'),
      _ChannelDiffStatus.rightOnly => (c.amber, 'RIGHT ONLY'),
      _ChannelDiffStatus.modified => (c.coral, 'MODIFIED'),
      _ChannelDiffStatus.identical => (c.textTertiary, 'IDENTICAL'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          onTap:
              _expandable ? () => setState(() => _expanded = !_expanded) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: <Widget>[
                if (_expandable)
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 14,
                    color: c.textTertiary,
                  )
                else
                  const SizedBox(width: 14),
                const SizedBox(width: 4),
                Container(
                  width: 90,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    border: Border.all(color: color),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: VibeTokens.fontMono,
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(width: VibeTokens.space2),
                Expanded(
                  child: Text(
                    widget.row.id,
                    style: vibeMono(size: 11, color: c.textPrimary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded && _expandable) _ContentDiff(row: widget.row),
      ],
    );
  }
}

/// Renders the LCS line diff for the expanded row's content. Maps
/// each `_DiffLine` to a colored mono row (`+ ` mint / `- ` coral
/// / `  ` dim) so the user can scan the actual change inline.
class _ContentDiff extends StatelessWidget {
  const _ContentDiff({required this.row});
  final _DiffRow row;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final lines = _lcsDiff(_toLines(row.leftValue), _toLines(row.rightValue));
    if (lines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(28, 4, 0, 4),
        child: Text(
          'no content to diff',
          style: vibeMono(size: 10, color: c.textTertiary),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(28, 2, 0, 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
        border: Border.all(color: c.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[for (final line in lines) _DiffLineRow(line: line)],
      ),
    );
  }
}

class _DiffLineRow extends StatelessWidget {
  const _DiffLineRow({required this.line});
  final _DiffLine line;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final (Color color, Color bg, String marker) = switch (line.kind) {
      _LineKind.add => (c.mint, c.mint.withValues(alpha: 0.08), '+'),
      _LineKind.remove => (c.coral, c.coral.withValues(alpha: 0.08), '-'),
      _LineKind.same => (c.textTertiary, Colors.transparent, ' '),
    };
    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 12,
            child: Text(
              marker,
              style: vibeMono(size: 10, weight: FontWeight.w600, color: color),
            ),
          ),
          Expanded(
            child: Text(line.text, style: vibeMono(size: 10, color: color)),
          ),
        ],
      ),
    );
  }
}
