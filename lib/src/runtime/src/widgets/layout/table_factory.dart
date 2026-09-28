import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for table widget
class TableWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final declaredRows = definition['rows'] as List<dynamic>? ?? [];

    // `Table` throws when a row carries no children. Rows that cannot be laid
    // out — `{}`, or the column-keyed shape that belongs to `dataTable` — are
    // dropped here rather than refused in the schema.
    final rows = <Map<String, dynamic>>[
      for (final row in declaredRows)
        if (row is Map<String, dynamic> &&
            (row['cells'] as List<dynamic>?)?.isNotEmpty == true)
          row,
    ];
    if (rows.isEmpty) return const SizedBox.shrink();

    return Table(
      border: _resolveTableBorder(properties['border'], context),
      // `columnWidths`: index → width. Declared and never read, so a
      // table that sized its first column watched every column come out the
      // same width.
      columnWidths: _resolveColumnWidths(properties['columnWidths'], context),
      defaultColumnWidth: _resolveColumnWidth(properties['defaultColumnWidth']),
      textDirection: _resolveTextDirection(properties['textDirection']),
      textBaseline: _resolveTextBaseline(properties['textBaseline']),
      defaultVerticalAlignment: _resolveTableCellVerticalAlignment(
          readEnum(properties['defaultVerticalAlignment'], context)),
      children: rows.map((rowData) {
        final cells = rowData['cells'] as List<dynamic>? ?? [];

        return TableRow(
          decoration: _resolveBoxDecoration(rowData['decoration'], context),
          children: cells.map((cell) {
            if (cell is Map<String, dynamic>) {
              return context.buildWidget(cell);
            } else {
              return Text(cell.toString());
            }
          }).toList(),
        );
      }).toList(),
    );
  }

  TableBorder? _resolveTableBorder(dynamic border, RenderContext context) {
    if (border == null) return null;
    if (border is Map<String, dynamic>) {
      return TableBorder.all(
        color: parseColor(border['color'], context) ??
            context.themeManager.colorOr('outlineVariant', Colors.grey),
        width: border['width']?.toDouble() ?? 1.0,
      );
    }
    return null;
  }

  /// `{"0": 120, "1": "flex"}` → the per-column widths `Table` takes. Keys
  /// are column indices; anything that is not an index is skipped rather than
  /// throwing, because one bad key must not cost the whole table.
  Map<int, TableColumnWidth>? _resolveColumnWidths(
      dynamic raw, RenderContext context) {
    final resolved = context.resolve<Object?>(raw);
    if (resolved is! Map) return null;
    final out = <int, TableColumnWidth>{};
    resolved.forEach((key, value) {
      final index = int.tryParse(key.toString());
      if (index == null) return;
      out[index] = _resolveColumnWidth(value);
    });
    return out.isEmpty ? null : out;
  }

  TableColumnWidth _resolveColumnWidth(dynamic width) {
    // A bare number is the obvious spelling — `columnWidths: {"0": 200}` is
    // what the documented "map columnIndex → width override" reads as, and it fell
    // through to `flex`, so a table that sized a column got the default.
    if (width is num) return FixedColumnWidth(width.toDouble());
    if (width is String) {
      final parsed = double.tryParse(width);
      if (parsed != null) return FixedColumnWidth(parsed);
      switch (width) {
        case 'intrinsic':
          return const IntrinsicColumnWidth();
        case 'flex':
          return const FlexColumnWidth();
        case 'fixed':
          return const FixedColumnWidth(100);
        default:
          return const FlexColumnWidth();
      }
    }
    if (width is Map<String, dynamic>) {
      final type = width['type'] as String?;
      switch (type) {
        case 'fixed':
          return FixedColumnWidth(width['value']?.toDouble() ?? 100);
        case 'flex':
          return FlexColumnWidth(width['value']?.toDouble() ?? 1.0);
        case 'fraction':
          return FractionColumnWidth(width['value']?.toDouble() ?? 0.5);
        case 'intrinsic':
          return const IntrinsicColumnWidth();
        default:
          return const FlexColumnWidth();
      }
    }
    return const FlexColumnWidth();
  }

  TextDirection? _resolveTextDirection(String? direction) {
    switch (direction) {
      case 'ltr':
        return TextDirection.ltr;
      case 'rtl':
        return TextDirection.rtl;
      default:
        return null;
    }
  }

  TextBaseline? _resolveTextBaseline(String? baseline) {
    switch (baseline) {
      case 'alphabetic':
        return TextBaseline.alphabetic;
      case 'ideographic':
        return TextBaseline.ideographic;
      default:
        return null;
    }
  }

  TableCellVerticalAlignment _resolveTableCellVerticalAlignment(
      String? alignment) {
    switch (alignment) {
      case 'top':
        return TableCellVerticalAlignment.top;
      case 'middle':
        return TableCellVerticalAlignment.middle;
      case 'bottom':
        return TableCellVerticalAlignment.bottom;
      case 'baseline':
        return TableCellVerticalAlignment.baseline;
      case 'fill':
        return TableCellVerticalAlignment.fill;
      default:
        return TableCellVerticalAlignment.top;
    }
  }

  BoxDecoration? _resolveBoxDecoration(dynamic decoration, RenderContext context) {
    if (decoration == null) return null;
    if (decoration is Map<String, dynamic>) {
      return BoxDecoration(
        color: parseColor(decoration['color'], context),
        border: decoration['border'] != null
            ? Border.all(
                color: parseColor(decoration['border']['color'], context) ??
                    context.themeManager.colorOr('outlineVariant', Colors.grey),
                width: decoration['border']['width']?.toDouble() ?? 1.0,
              )
            : null,
      );
    }
    return null;
  }
}
