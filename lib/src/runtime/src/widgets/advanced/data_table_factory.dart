import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for dataTable widget — data-bound table with column definitions,
/// sorting, selection, and row actions.
class DataTableWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    // Tolerant read — see `tabBar`. `columns` is declared literal, but a
    // document that binds it anyway must render an empty table rather than
    // covering the page area with a cast error.
    final columns = listOf(properties['columns'], context) ?? const [];
    final rowsBinding = properties['rows'];
    final selectable = properties['selectable'] == true;
    // Canonical `onRowTap`; `rowClick` kept as legacy alias.
    final rowClickAction =
        actionOf(properties['onRowTap'] ?? properties['rowClick'], context);
    // `sortColumn` and `sortAscending` are declared `binding`, so
    // the documented form of both is a `{{...}}` string — reading them without
    // resolving threw on every document that used them as written.
    final sortColumn = stringOf(properties['sortColumn'], context);
    final sortAscending = boolOf(properties['sortAscending'], context) ?? true;
    final onSort = actionOf(properties['onSort'], context);
    // `editable`: in-place cell editing, reported through `onCellEdit`.
    // Both were declared and neither was read — a table marked editable had
    // no editable cell, and the action its own description names did not
    // exist in the registry.
    final editable = boolOf(properties['editable'], context) ?? false;
    final onCellEdit = actionOf(properties['onCellEdit'], context);
    // 1.4 additions that were declared and never wired.
    final filterable = boolOf(properties['filterable'], context) ?? false;
    final resizableColumns =
        boolOf(properties['resizableColumns'], context) ?? false;
    final virtualScroll = boolOf(properties['virtualScroll'], context) ?? false;
    final rowHeight = dimensionOf(properties['rowHeight'], context);

    // Resolve rows from binding or direct data
    List<dynamic> rows = [];
    if (rowsBinding is String) {
      final resolved = context.resolve<dynamic>(rowsBinding);
      if (resolved is List) {
        rows = resolved;
      }
    } else if (rowsBinding is List) {
      rows = rowsBinding;
    }

    // Build DataColumn list. A column marked `sortable` gets a header that
    // dispatches `onSort` with `event.column` — the shape the documented example
    // writes back into `sortColumn` / `sortAscending`.
    final dataColumns = columns.map<DataColumn>((col) {
      final colDef = col as Map<String, dynamic>;
      final key = colDef['key']?.toString() ?? '';
      final sortable = colDef['sortable'] == true;
      return DataColumn(
        label: Text(
            colDef['label']?.toString() ?? colDef['key']?.toString() ?? ''),
        onSort: sortable && onSort != null
            ? (columnIndex, ascending) {
                final eventContext = context.createChildContext(
                  variables: {
                    'event': {
                      'column': key,
                      'ascending': ascending,
                      'index': columnIndex,
                      'type': 'sort',
                    },
                  },
                );
                eventContext.handleAction(onSort);
              }
            : null,
      );
    }).toList();

    if (dataColumns.isEmpty) {
      return const SizedBox.shrink();
    }

    // Apply the declared sort. Without this the widget accepts `sortColumn`
    // and draws the rows in source order, which is indistinguishable from a
    // document whose sort state never took.
    final sortIndex = sortColumn == null
        ? null
        : columns.indexWhere((col) =>
            (col as Map<String, dynamic>)['key']?.toString() == sortColumn);
    if (sortIndex != null && sortIndex >= 0) {
      rows = List<dynamic>.from(rows)
        ..sort((a, b) {
          final av = (a as Map<String, dynamic>)[sortColumn];
          final bv = (b as Map<String, dynamic>)[sortColumn];
          if (av == null && bv == null) return 0;
          if (av == null) return sortAscending ? -1 : 1;
          if (bv == null) return sortAscending ? 1 : -1;
          // Two numbers compare as numbers whatever their subtype: an `int`
          // and a `double` in one column are one kind of value, and the
          // same-runtimeType test sent that pair to string comparison, where
          // "617.5" sorts after "2160".
          final cmp = (av is num && bv is num)
              ? av.compareTo(bv)
              : (av is Comparable &&
                      bv is Comparable &&
                      av.runtimeType == bv.runtimeType)
                  ? av.compareTo(bv)
                  : av.toString().compareTo(bv.toString());
          return sortAscending ? cmp : -cmp;
        });
    }

    // Build DataRow list
    final dataRows = rows.map<DataRow>((row) {
      final rowData = row as Map<String, dynamic>;
      return DataRow(
        // A declared `onRowTap` fires whether or not the table is selectable —
        // gating it on `selectable` left a table whose taps went nowhere — and
        // it fires through `_tapRow`, which is the only place that knows to
        // put the row in the event. Three call sites fired the same action
        // with three different contexts, and two of them carried no row: a
        // document reading `{{event.row.id}}`, which is the spec's own
        // example, got null from whichever one happened to win the gesture.
        onSelectChanged: (selectable || rowClickAction != null)
            ? (_) => tapRow(context, rowClickAction, rowData)
            : null,
        cells: columns.map<DataCell>((col) {
          final colDef = col as Map<String, dynamic>;
          final key = colDef['key']?.toString() ?? '';
          final cellValue = rowData[key]?.toString() ?? '';
          final align = colDef['align']?.toString();
          return DataCell(
            align == 'center'
                ? Center(child: Text(cellValue))
                : Text(cellValue),
            onTap: rowClickAction != null
                ? () => tapRow(context, rowClickAction, rowData)
                : null,
          );
        }).toList(),
      );
    }).toList();

    return _DataTableView(
      columns: columns,
      rows: rows,
      dataColumns: dataColumns,
      dataRows: dataRows,
      selectable: selectable,
      sortColumnIndex: (sortIndex != null && sortIndex >= 0) ? sortIndex : null,
      sortAscending: sortAscending,
      filterable: filterable,
      resizableColumns: resizableColumns,
      virtualScroll: virtualScroll,
      rowHeight: rowHeight,
      rowClickAction: rowClickAction,
      editable: editable,
      onCellEdit: onCellEdit,
      onSort: onSort,
      context: context,
    );
  }
}

/// The rendered table.
///
/// `filterable`, `resizableColumns` and `virtualScroll` all need state that
/// outlives one build — the per-column filter text, the dragged widths, and
/// the scroll position — so the table itself is stateful rather than each of
/// the three being approximated statelessly.
/// Fires a row tap with the row in the event (`event.row` is the row
/// object). Shared so every path that can start a row tap reports the same
/// thing.
void tapRow(
  RenderContext context,
  Map<String, dynamic>? action,
  Map<String, dynamic> row,
) {
  if (action == null) return;
  context.createChildContext(variables: {
    'event': {'row': row},
  }).handleAction(action);
}

class _DataTableView extends StatefulWidget {
  final List<dynamic> columns;
  final List<dynamic> rows;
  final List<DataColumn> dataColumns;
  final List<DataRow> dataRows;
  final bool selectable;
  final int? sortColumnIndex;
  final bool sortAscending;
  final bool filterable;
  final bool resizableColumns;
  final bool virtualScroll;
  final double? rowHeight;
  final Map<String, dynamic>? rowClickAction;
  final bool editable;
  final Map<String, dynamic>? onCellEdit;
  final Map<String, dynamic>? onSort;
  final RenderContext context;

  const _DataTableView({
    required this.columns,
    required this.rows,
    required this.dataColumns,
    required this.dataRows,
    required this.selectable,
    required this.sortColumnIndex,
    required this.sortAscending,
    required this.filterable,
    required this.resizableColumns,
    required this.virtualScroll,
    required this.rowHeight,
    required this.rowClickAction,
    this.editable = false,
    this.onCellEdit,
    this.onSort,
    required this.context,
  });

  @override
  State<_DataTableView> createState() => _DataTableViewState();
}

class _DataTableViewState extends State<_DataTableView> {
  final Map<String, String> _filters = <String, String>{};
  final Map<String, double> _widths = <String, double>{};

  String _key(dynamic col) =>
      (col as Map<String, dynamic>)['key']?.toString() ?? '';

  /// Reports an edit. The widget never rewrites `rows` itself — the DSL says
  /// the document decides what an edit means.
  void _commitEdit(
    Map<String, dynamic> row,
    String column,
    String value,
    String previous,
  ) {
    final action = widget.onCellEdit;
    if (action == null || value == previous) return;
    widget.context.createChildContext(variables: {
      'event': {
        'row': row,
        'column': column,
        'value': value,
        'previous': previous,
      },
    }).handleAction(action);
  }

  List<dynamic> get _visibleRows {
    if (!widget.filterable || _filters.values.every((v) => v.isEmpty)) {
      return widget.rows;
    }
    return widget.rows.where((row) {
      final data = row as Map<String, dynamic>;
      for (final entry in _filters.entries) {
        if (entry.value.isEmpty) continue;
        final cell = data[entry.key]?.toString().toLowerCase() ?? '';
        if (!cell.contains(entry.value.toLowerCase())) return false;
      }
      return true;
    }).toList();
  }

  double _widthFor(dynamic col) =>
      _widths[_key(col)] ??
      ((col as Map<String, dynamic>)['width'] as num?)?.toDouble() ??
      140.0;

  @override
  Widget build(BuildContext buildContext) {
    final rows = _visibleRows;

    Widget table;
    // The hand-laid grid is the only path that can honour `virtualScroll`
    // (a DataTable materialises every row), per-column widths (resizing
    // edits them) and `editable` (a DataTable's cells are its own, and an
    // editable cell is a field). `editable: true` on its own used to render
    // the Material table, whose cells were plain text — a table marked
    // editable with no editable cell and an `onCellEdit` that never fired.
    if (widget.virtualScroll || widget.resizableColumns || widget.editable) {
      table = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: widget.columns.map(_headerCell).toList()),
          if (widget.filterable)
            Row(children: widget.columns.map(_filterCell).toList()),
          if (widget.virtualScroll)
            SizedBox(
              height: widget.rowHeight != null
                  ? (widget.rowHeight! * (rows.length.clamp(0, 12)))
                  : 320,
              // The whole table sits in a horizontal scroll view, so the row
              // list has no width to expand into and threw "vertical viewport
              // was given unbounded width" — `virtualScroll: true` did not
              // scroll, it crashed the page. The rows are as wide as the
              // columns, which is the width the header already uses.
              width: _tableWidth,
              child: ListView.builder(
                itemCount: rows.length,
                itemExtent: widget.rowHeight,
                itemBuilder: (_, i) => _bodyRow(rows[i]),
              ),
            )
          else
            // Not virtual: every row is laid out, the way a DataTable would,
            // so an editable or resizable table is as tall as its rows
            // rather than clipped to a fixed viewport with its own scroll.
            for (final row in rows)
              SizedBox(
                width: _tableWidth,
                height: widget.rowHeight,
                child: _bodyRow(row),
              ),
        ],
      );
    } else {
      final visible = widget.filterable ? _rowsFor(rows) : widget.dataRows;
      table = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DataTable(
            columns: widget.dataColumns,
            rows: visible,
            showCheckboxColumn: widget.selectable,
            sortColumnIndex: widget.sortColumnIndex,
            sortAscending: widget.sortAscending,
            dataRowMinHeight: widget.rowHeight,
            dataRowMaxHeight: widget.rowHeight,
          ),
          if (widget.filterable)
            Row(children: widget.columns.map(_filterCell).toList()),
        ],
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: table,
    );
  }

  /// The width the columns add up to, including the resize handles.
  double get _tableWidth => widget.columns.fold<double>(
        0,
        (total, col) =>
            total + _widthFor(col) + (widget.resizableColumns ? 8 : 0),
      );

  /// The pre-built rows restricted to what the filters leave visible. Index
  /// alignment holds because `_visibleRows` preserves source order.
  List<DataRow> _rowsFor(List<dynamic> visible) {
    final keep = <DataRow>[];
    for (var i = 0; i < widget.rows.length && i < widget.dataRows.length; i++) {
      if (visible.contains(widget.rows[i])) keep.add(widget.dataRows[i]);
    }
    return keep;
  }

  Widget _headerCell(dynamic col) {
    final colDef = col as Map<String, dynamic>;
    final label = colDef['label']?.toString() ?? _key(col);
    final index = widget.columns.indexOf(col);
    final sortable = colDef['sortable'] == true;
    final isSortColumn = widget.sortColumnIndex == index;
    Widget cell = SizedBox(
      width: _widthFor(col),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis),
            ),
            if (sortable && isSortColumn)
              Icon(
                widget.sortAscending
                    ? Icons.arrow_upward
                    : Icons.arrow_downward,
                size: 14,
              ),
          ],
        ),
      ),
    );
    // The same header tap the Material path has: a sortable column's header
    // dispatches `onSort` with `event.column`, toggling direction when the
    // column is already the sort column, as `DataTable` does. Without it the
    // hand-laid grid applied the declared sort and ignored the tap.
    if (sortable && widget.onSort != null) {
      final ascending = isSortColumn ? !widget.sortAscending : true;
      cell = InkWell(
        onTap: () => widget.context.createChildContext(variables: {
          'event': {
            'column': _key(col),
            'ascending': ascending,
            'index': index,
            'type': 'sort',
          },
        }).handleAction(widget.onSort),
        child: cell,
      );
    }
    if (!widget.resizableColumns) return cell;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      cell,
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => setState(() {
          _widths[_key(col)] = (_widthFor(col) + d.delta.dx).clamp(48.0, 720.0);
        }),
        child: const MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          child:
              SizedBox(width: 8, height: 32, child: VerticalDivider(width: 8)),
        ),
      ),
    ]);
  }

  Widget _filterCell(dynamic col) {
    final key = _key(col);
    return SizedBox(
      width: _widthFor(col) + (widget.resizableColumns ? 8 : 0),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: TextField(
          decoration: const InputDecoration(
            isDense: true,
            hintText: 'Filter',
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => setState(() => _filters[key] = v),
        ),
      ),
    );
  }

  /// `columns[].align` as the grid reads it. The Material path honours it
  /// through `DataCell`; the hand-laid grid ignored it, so every cell of an
  /// editable table started at the left whatever the column said.
  static ({Alignment box, TextAlign text}) _alignOf(Map<String, dynamic> col) {
    switch (col['align']?.toString()) {
      case 'center':
        return (box: Alignment.center, text: TextAlign.center);
      case 'end':
      case 'right':
        return (box: Alignment.centerRight, text: TextAlign.end);
      default:
        return (box: Alignment.centerLeft, text: TextAlign.start);
    }
  }

  Widget _bodyRow(dynamic row) {
    final data = row as Map<String, dynamic>;
    final cells = widget.columns.map<Widget>((col) {
      final key = _key(col);
      final value = data[key]?.toString() ?? '';
      final align = _alignOf(col as Map<String, dynamic>);
      return SizedBox(
        width: _widthFor(col) + (widget.resizableColumns ? 8 : 0),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: widget.editable
              ? _EditableCell(
                  // Keyed by the row *object*, not its index. A sort moves
                  // rows and keeps their objects, so the field moves with
                  // its row; keyed by index, the field at position 7 stayed
                  // where it was with the text it was built with, and the
                  // event named the row now at 7 — the number typed landed
                  // visually in one line and reported another.
                  key: ValueKey(_CellId(data, key)),
                  value: value,
                  textAlign: align.text,
                  onCommit: (edited) => _commitEdit(data, key, edited, value),
                )
              : Align(
                  alignment: align.box,
                  child: Text(value,
                      textAlign: align.text, overflow: TextOverflow.ellipsis),
                ),
        ),
      );
    }).toList();
    final content = Row(key: ObjectKey(data), children: cells);
    if (widget.rowClickAction == null) return content;
    return InkWell(
      onTap: () => tapRow(widget.context, widget.rowClickAction, data),
      child: content,
    );
  }
}

/// Row identity plus column, for a cell's key. The row is compared by
/// identity: the same map object is the same row wherever a sort put it.
@immutable
class _CellId {
  const _CellId(this.row, this.column);
  final Map<String, dynamic> row;
  final String column;

  @override
  bool operator ==(Object other) =>
      other is _CellId && identical(other.row, row) && other.column == column;

  @override
  int get hashCode => Object.hash(identityHashCode(row), column);
}

/// One editable cell. Owns its controller so that a value that changes
/// under it — a re-sort, a binding update — reaches the screen, unless the
/// author is mid-edit in that very field.
class _EditableCell extends StatefulWidget {
  const _EditableCell({
    super.key,
    required this.value,
    required this.textAlign,
    required this.onCommit,
  });

  final String value;
  final TextAlign textAlign;
  final ValueChanged<String> onCommit;

  @override
  State<_EditableCell> createState() => _EditableCellState();
}

class _EditableCellState extends State<_EditableCell> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value);
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(_EditableCell old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !_focus.hasFocus) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: _controller,
        focusNode: _focus,
        textAlign: widget.textAlign,
        style: Theme.of(context).textTheme.bodyMedium,
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
        // On commit, not per keystroke: an edit is a decision, and a
        // document that writes every character to a tool would fire once
        // per letter.
        onFieldSubmitted: widget.onCommit,
        onTapOutside: (_) {},
      );
}
