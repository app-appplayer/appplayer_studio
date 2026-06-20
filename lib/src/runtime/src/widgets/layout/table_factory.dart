import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for table widget
class TableWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final rows = definition['rows'] as List<dynamic>? ?? [];

    return Table(
      border: _resolveTableBorder(properties['border'], context),
      defaultColumnWidth: _resolveColumnWidth(properties['defaultColumnWidth']),
      textDirection: _resolveTextDirection(properties['textDirection']),
      textBaseline: _resolveTextBaseline(properties['textBaseline']),
      defaultVerticalAlignment: _resolveTableCellVerticalAlignment(
          properties['defaultVerticalAlignment']),
      children: rows.map((row) {
        final rowData = row as Map<String, dynamic>;
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
            context.themeManager.getColorValue('outlineVariant') ??
            Colors.grey,
        width: border['width']?.toDouble() ?? 1.0,
      );
    }
    return null;
  }

  TableColumnWidth _resolveColumnWidth(dynamic width) {
    if (width is String) {
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
                    context.themeManager.getColorValue('outlineVariant') ??
                    Colors.grey,
                width: decoration['border']['width']?.toDouble() ?? 1.0,
              )
            : null,
      );
    }
    return null;
  }
}
