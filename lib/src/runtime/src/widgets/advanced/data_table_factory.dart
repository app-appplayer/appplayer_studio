import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for dataTable widget — data-bound table with column definitions,
/// sorting, selection, and row actions.
class DataTableWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final columns = properties['columns'] as List<dynamic>? ?? [];
    final rowsBinding = properties['rows'];
    final selectable = properties['selectable'] == true;
    // Spec §10.4 canonical `onRowTap`; `rowClick` kept as legacy alias.
    final rowClickAction =
        (properties['onRowTap'] ?? properties['rowClick']) as Map<String, dynamic>?;
    // Spec §10.4: `sortColumn` and `sortAscending` are declared `binding`, so
    // the documented form of both is a `{{...}}` string — reading them without
    // resolving threw on every document that used them as written.
    final sortColumn = context.resolve<String?>(properties['sortColumn']);
    final sortAscending =
        context.resolve<bool?>(properties['sortAscending']) ?? true;
    final onSort = properties['onSort'] as Map<String, dynamic>?;

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
    // dispatches `onSort` with `event.column` — the shape §10.4's example
    // writes back into `sortColumn` / `sortAscending`.
    final dataColumns = columns.map<DataColumn>((col) {
      final colDef = col as Map<String, dynamic>;
      final key = colDef['key']?.toString() ?? '';
      final sortable = colDef['sortable'] == true;
      return DataColumn(
        label:
            Text(colDef['label']?.toString() ?? colDef['key']?.toString() ?? ''),
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
        : columns.indexWhere(
            (col) => (col as Map<String, dynamic>)['key']?.toString() ==
                sortColumn);
    if (sortIndex != null && sortIndex >= 0) {
      rows = List<dynamic>.from(rows)
        ..sort((a, b) {
          final av = (a as Map<String, dynamic>)[sortColumn];
          final bv = (b as Map<String, dynamic>)[sortColumn];
          if (av == null && bv == null) return 0;
          if (av == null) return sortAscending ? -1 : 1;
          if (bv == null) return sortAscending ? 1 : -1;
          final cmp = (av is Comparable && bv is Comparable && av.runtimeType == bv.runtimeType)
              ? av.compareTo(bv)
              : av.toString().compareTo(bv.toString());
          return sortAscending ? cmp : -cmp;
        });
    }

    // Build DataRow list
    final dataRows = rows.map<DataRow>((row) {
      final rowData = row as Map<String, dynamic>;
      return DataRow(
        onSelectChanged: selectable
            ? (_) {
                if (rowClickAction != null) {
                  context.handleAction(rowClickAction);
                }
              }
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
                ? () => context.handleAction(rowClickAction)
                : null,
          );
        }).toList(),
      );
    }).toList();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: dataColumns,
        rows: dataRows,
        showCheckboxColumn: selectable,
        sortColumnIndex:
            (sortIndex != null && sortIndex >= 0) ? sortIndex : null,
        sortAscending: sortAscending,
      ),
    );
  }
}
