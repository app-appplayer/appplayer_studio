import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for `diffViewer` (spec §10.26).
///
/// Separate from `codeEditor` rather than a mode on it, because the input is
/// two documents: a `mode` flag on a single-value widget would leave one of
/// the two with nowhere to bind. Read-only by design — editing a diff means
/// editing one side, which is `codeEditor`'s job.
class DiffViewerFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final oldText = context.resolve<String?>(properties['oldValue']) ?? '';
    final newText = context.resolve<String?>(properties['newValue']) ?? '';
    final split = context.resolve<bool?>(properties['splitView']) ?? true;
    final showLineNumbers =
        context.resolve<bool?>(properties['showLineNumbers']) ?? true;
    final contextLines =
        context.resolve<num?>(properties['contextLines'])?.toInt();
    // Read and carried so the widget declares what it was given. Token
    // colouring is not implemented here; the value reaches the rendering as a
    // semantics label so a document that sets it is not silently ignored.
    final language = context.resolve<String?>(properties['language']);

    final rows = _diff(oldText.split('\n'), newText.split('\n'));
    final visible =
        contextLines == null ? rows : _withContext(rows, contextLines);

    return Semantics(
      label: language == null ? 'Diff' : 'Diff ($language)',
      child: SingleChildScrollView(
      child: split
          ? _SplitView(rows: visible, showLineNumbers: showLineNumbers)
          : _UnifiedView(rows: visible, showLineNumbers: showLineNumbers),
      ),
    );
  }

  /// Longest-common-subsequence diff over lines.
  ///
  /// Line-level rather than character-level on purpose: a reviewer reads
  /// changed lines, and a character diff of unrelated text produces noise that
  /// reads as a rewrite.
  static List<_Row> _diff(List<String> a, List<String> b) {
    final n = a.length, m = b.length;
    // Bounded so a large pair degrades to a plain replacement rather than
    // allocating an n*m table.
    if (n * m > 4000000) {
      return [
        for (var i = 0; i < n; i++) _Row(_Kind.removed, a[i], i + 1, null),
        for (var j = 0; j < m; j++) _Row(_Kind.added, b[j], null, j + 1),
      ];
    }

    final lcs = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        lcs[i][j] = a[i] == b[j]
            ? lcs[i + 1][j + 1] + 1
            : (lcs[i + 1][j] > lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
      }
    }

    final rows = <_Row>[];
    var i = 0, j = 0;
    while (i < n && j < m) {
      if (a[i] == b[j]) {
        rows.add(_Row(_Kind.same, a[i], i + 1, j + 1));
        i++;
        j++;
      } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
        rows.add(_Row(_Kind.removed, a[i], i + 1, null));
        i++;
      } else {
        rows.add(_Row(_Kind.added, b[j], null, j + 1));
        j++;
      }
    }
    while (i < n) {
      rows.add(_Row(_Kind.removed, a[i], i + 1, null));
      i++;
    }
    while (j < m) {
      rows.add(_Row(_Kind.added, b[j], null, j + 1));
      j++;
    }
    return rows;
  }

  static List<_Row> _withContext(List<_Row> rows, int contextLines) {
    final keep = List<bool>.filled(rows.length, false);
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].kind == _Kind.same) continue;
      final from = (i - contextLines).clamp(0, rows.length - 1);
      final to = (i + contextLines).clamp(0, rows.length - 1);
      for (var k = from; k <= to; k++) {
        keep[k] = true;
      }
    }
    final out = <_Row>[];
    var elided = false;
    for (var i = 0; i < rows.length; i++) {
      if (keep[i]) {
        out.add(rows[i]);
        elided = false;
      } else if (!elided) {
        out.add(const _Row(_Kind.elision, '…', null, null));
        elided = true;
      }
    }
    return out;
  }
}

enum _Kind { same, added, removed, elision }

@immutable
class _Row {
  const _Row(this.kind, this.text, this.oldLine, this.newLine);
  final _Kind kind;
  final String text;
  final int? oldLine;
  final int? newLine;
}

Color? _background(BuildContext context, _Kind kind) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  switch (kind) {
    case _Kind.added:
      return dark ? const Color(0xFF1B3A24) : const Color(0xFFE6FFEC);
    case _Kind.removed:
      return dark ? const Color(0xFF3A1B1B) : const Color(0xFFFFEBE9);
    case _Kind.same:
    case _Kind.elision:
      return null;
  }
}

class _UnifiedView extends StatelessWidget {
  const _UnifiedView({required this.rows, required this.showLineNumbers});

  final List<_Row> rows;
  final bool showLineNumbers;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in rows)
          Container(
            color: _background(context, row.kind),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            child: Row(
              children: [
                if (showLineNumbers)
                  SizedBox(
                    width: 64,
                    child: Text(
                      '${row.oldLine ?? ''}  ${row.newLine ?? ''}',
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 11),
                    ),
                  ),
                Text(
                  row.kind == _Kind.added
                      ? '+ '
                      : row.kind == _Kind.removed
                          ? '- '
                          : '  ',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                Expanded(
                  child: Text(
                    row.text,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SplitView extends StatelessWidget {
  const _SplitView({required this.rows, required this.showLineNumbers});

  final List<_Row> rows;
  final bool showLineNumbers;

  @override
  Widget build(BuildContext context) {
    Widget side(_Row row, bool left) {
      final show = row.kind == _Kind.same ||
          row.kind == _Kind.elision ||
          (left ? row.kind == _Kind.removed : row.kind == _Kind.added);
      return Container(
        color: show ? _background(context, row.kind) : null,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: Row(
          children: [
            if (showLineNumbers)
              SizedBox(
                width: 36,
                child: Text(
                  '${(left ? row.oldLine : row.newLine) ?? ''}',
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            Expanded(
              child: Text(
                show ? row.text : '',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in rows)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: side(row, true)),
                const VerticalDivider(width: 1),
                Expanded(child: side(row, false)),
              ],
            ),
          ),
      ],
    );
  }
}
