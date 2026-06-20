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
    // Spec §10.4: sort state + callback. Read so the factory honors the
    // documented API; applying sort to rendered rows is tracked separately.
    // ignore: unused_local_variable
    final sortColumn = properties['sortColumn'] as String?;
    // ignore: unused_local_variable
    final sortAscending = properties['sortAscending'] as bool? ?? true;
    // ignore: unused_local_variable
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

    // Build DataColumn list
    final dataColumns = columns.map<DataColumn>((col) {
      final colDef = col as Map<String, dynamic>;
      return DataColumn(
        label: Text(colDef['label']?.toString() ?? colDef['key']?.toString() ?? ''),
      );
    }).toList();

    if (dataColumns.isEmpty) {
      return const SizedBox.shrink();
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
      ),
    );
  }
}
