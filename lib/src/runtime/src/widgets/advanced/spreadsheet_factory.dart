import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for `spreadsheet` (spec §10.32).
///
/// Distinct from `dataTable`, which presents records: a table's unit is a row
/// with typed fields, a spreadsheet's unit is a **cell with a coordinate**.
/// Selection, editing and paste all address different things, which is why one
/// cannot be a mode of the other.
///
/// Formulas evaluate through the runtime's own binding engine — the §7.1
/// sandbox — or not at all. A cell that runs arbitrary text is the one place
/// this widget could become an injection surface, so `formulas` is off by
/// default and an unevaluable formula renders its last value rather than being
/// interpreted loosely.
class SpreadsheetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final rows = context.resolve<List<dynamic>?>(properties['data']) ?? const [];
    final columnDefs =
        context.resolve<List<dynamic>?>(properties['columns']) ?? const [];
    final editable = context.resolve<bool?>(properties['editable']) ?? true;
    final formulas = context.resolve<bool?>(properties['formulas']) ?? false;
    final rowHeaders = context.resolve<bool?>(properties['rowHeaders']) ?? true;
    final columnHeaders =
        context.resolve<bool?>(properties['columnHeaders']) ?? true;
    final frozenRows = context.resolve<num?>(properties['frozenRows'])?.toInt() ?? 0;
    final frozenColumns =
        context.resolve<num?>(properties['frozenColumns'])?.toInt() ?? 0;
    final onChange = actionOf(properties['onChange'], context);
    final onCellSelect = actionOf(properties['onCellSelect'], context);

    final grid = [
      for (final r in rows)
        if (r is List) List<dynamic>.from(r),
    ];
    if (grid.isEmpty) return const SizedBox.shrink();

    final columnCount = columnDefs.isNotEmpty
        ? columnDefs.length
        : grid.map((r) => r.length).reduce((a, b) => a > b ? a : b);

    return _Sheet(
      grid: grid,
      columnCount: columnCount,
      columnLabels: [
        for (var c = 0; c < columnCount; c++)
          c < columnDefs.length && columnDefs[c] is Map
              ? (columnDefs[c] as Map)['label']?.toString() ?? _columnName(c)
              : _columnName(c),
      ],
      columnReadOnly: [
        for (var c = 0; c < columnCount; c++)
          c < columnDefs.length &&
              columnDefs[c] is Map &&
              (columnDefs[c] as Map)['readOnly'] == true,
      ],
      editable: editable,
      formulas: formulas,
      rowHeaders: rowHeaders,
      columnHeaders: columnHeaders,
      frozenRows: frozenRows,
      frozenColumns: frozenColumns,
      evaluate: (formula) {
        // Through the binding engine, so the sandbox that governs every other
        // expression governs this one too.
        try {
          return context.resolve<dynamic>('{{$formula}}');
        } catch (_) {
          return null;
        }
      },
      onChange: (row, column, value, previous) {
        if (onChange == null) return;
        context.actionHandler.execute(
          onChange,
          context.createChildContext(
            variables: {
              'event': {
                'row': row,
                'column': column,
                'value': value,
                'previous': previous,
                'type': 'change',
              },
            },
          ),
        );
      },
      onSelect: (row, column) {
        if (onCellSelect == null) return;
        context.actionHandler.execute(
          onCellSelect,
          context.createChildContext(
            variables: {
              'event': {'row': row, 'column': column, 'type': 'cellSelect'},
            },
          ),
        );
      },
    );
  }

  /// A, B, … Z, AA, AB … — the spreadsheet convention rather than an index.
  static String _columnName(int index) {
    var i = index;
    final buffer = StringBuffer();
    do {
      buffer.write(String.fromCharCode(65 + i % 26));
      i = i ~/ 26 - 1;
    } while (i >= 0);
    return buffer.toString().split('').reversed.join();
  }
}

class _Sheet extends StatefulWidget {
  const _Sheet({
    required this.grid,
    required this.columnCount,
    required this.columnLabels,
    required this.columnReadOnly,
    required this.editable,
    required this.formulas,
    required this.rowHeaders,
    required this.columnHeaders,
    required this.frozenRows,
    required this.frozenColumns,
    required this.evaluate,
    required this.onChange,
    required this.onSelect,
  });

  final List<List<dynamic>> grid;
  final int columnCount;
  final List<String> columnLabels;
  final List<bool> columnReadOnly;
  final bool editable;
  final bool formulas;
  final bool rowHeaders;
  final bool columnHeaders;
  final int frozenRows;
  final int frozenColumns;
  final dynamic Function(String formula) evaluate;
  final void Function(int row, int column, dynamic value, dynamic previous)
      onChange;
  final void Function(int row, int column) onSelect;

  @override
  State<_Sheet> createState() => _SheetState();
}

class _SheetState extends State<_Sheet> {
  int? _editingRow;
  int? _editingColumn;
  int? _selectedRow;
  int? _selectedColumn;
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  ({dynamic value, String? formula}) _cell(int row, int column) {
    final r = widget.grid[row];
    final raw = column < r.length ? r[column] : null;
    if (raw is Map) {
      return (value: raw['value'], formula: raw['formula']?.toString());
    }
    return (value: raw, formula: null);
  }

  String _display(int row, int column) {
    final cell = _cell(row, column);
    if (cell.formula != null) {
      if (!widget.formulas) {
        // Off by default: render the last computed value rather than
        // interpreting the formula loosely.
        return cell.value?.toString() ?? '';
      }
      final computed = widget.evaluate(cell.formula!);
      return (computed ?? cell.value)?.toString() ?? '';
    }
    return cell.value?.toString() ?? '';
  }

  bool _readOnly(int column) =>
      !widget.editable ||
      (column < widget.columnReadOnly.length && widget.columnReadOnly[column]);

  void _commit(int row, int column) {
    final previous = _cell(row, column).value;
    final text = _controller.text;
    setState(() {
      _editingRow = null;
      _editingColumn = null;
    });
    if (text == previous?.toString()) return;
    widget.onChange(row, column, text, previous);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const cellWidth = 110.0;
    const cellHeight = 30.0;

    Widget cell(int row, int column) {
      final editing = _editingRow == row && _editingColumn == column;
      final selected = _selectedRow == row && _selectedColumn == column;
      final frozen = row < widget.frozenRows || column < widget.frozenColumns;

      return GestureDetector(
        onTap: () {
          setState(() {
            _selectedRow = row;
            _selectedColumn = column;
          });
          widget.onSelect(row, column);
        },
        onDoubleTap: _readOnly(column)
            ? null
            : () {
                _controller.text = _display(row, column);
                setState(() {
                  _editingRow = row;
                  _editingColumn = column;
                });
              },
        child: Container(
          width: cellWidth,
          height: cellHeight,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: frozen ? scheme.surfaceContainerHighest : null,
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 2 : 0.5,
            ),
          ),
          child: editing
              ? TextField(
                  controller: _controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                  ),
                  onSubmitted: (_) => _commit(row, column),
                  onTapOutside: (_) => _commit(row, column),
                )
              : Text(
                  _display(row, column),
                  overflow: TextOverflow.ellipsis,
                ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.columnHeaders)
              Row(
                children: [
                  if (widget.rowHeaders)
                    const SizedBox(width: 44, height: cellHeight),
                  for (var c = 0; c < widget.columnCount; c++)
                    Container(
                      width: cellWidth,
                      height: cellHeight,
                      alignment: Alignment.center,
                      color: scheme.surfaceContainerHighest,
                      child: Text(widget.columnLabels[c]),
                    ),
                ],
              ),
            for (var r = 0; r < widget.grid.length; r++)
              Row(
                children: [
                  if (widget.rowHeaders)
                    Container(
                      width: 44,
                      height: cellHeight,
                      alignment: Alignment.center,
                      color: scheme.surfaceContainerHighest,
                      child: Text('${r + 1}'),
                    ),
                  for (var c = 0; c < widget.columnCount; c++) cell(r, c),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
