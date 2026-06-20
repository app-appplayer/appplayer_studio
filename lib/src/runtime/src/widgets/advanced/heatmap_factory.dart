import 'package:flutter/material.dart';
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Heatmap widgets
class HeatmapWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties. Use nullable resolve for Lists — non-nullable
    // generic `resolve<List<dynamic>>(null)` throws on absent properties.
    final data = (context.resolve<List<dynamic>?>(properties['data'])) ?? [];
    final columns = properties['columns'] as int?;
    final cellSize = properties['cellSize']?.toDouble() ?? 40.0;
    final cellGap = properties['cellGap']?.toDouble() ?? 2.0;
    final minValue = properties['minValue']?.toDouble() ?? 0.0;
    final maxValue = properties['maxValue']?.toDouble() ?? 1.0;
    final showLabels = properties['showLabels'] as bool? ?? false;
    final rowLabels =
        (context.resolve<List<dynamic>?>(properties['rowLabels'])) ?? [];
    final columnLabels =
        (context.resolve<List<dynamic>?>(properties['columnLabels'])) ?? [];
    final colorScheme = properties['colorScheme'] as String? ?? 'blue';
    // Spec §10.10: `colorRange: {low, high}`, `showValues`, `onCellTap`.
    // ignore: unused_local_variable
    final colorRange = properties['colorRange'] as Map<String, dynamic>?;
    // ignore: unused_local_variable
    final showValues = properties['showValues'] as bool? ?? false;
    // ignore: unused_local_variable
    final onCellTap = properties['onCellTap'] as Map<String, dynamic>?;

    // Parse data into 2D array
    List<List<double>> heatmapData = [];
    if (data.isNotEmpty && data.first is List) {
      // Data is already 2D
      for (var row in data) {
        if (row is List) {
          heatmapData.add(row.map((e) => (e as num).toDouble()).toList());
        }
      }
    } else if (columns != null && columns > 0) {
      // Convert 1D array to 2D based on columns
      for (int i = 0; i < data.length; i += columns) {
        final row = <double>[];
        for (int j = 0; j < columns && i + j < data.length; j++) {
          row.add((data[i + j] as num).toDouble());
        }
        heatmapData.add(row);
      }
    }

    if (heatmapData.isEmpty) {
      return const SizedBox();
    }

    final actualColumns = heatmapData.first.length;

    // Build heatmap
    final List<Widget> heatmapRows = [];

    // Add column labels if specified
    if (showLabels && columnLabels.isNotEmpty) {
      final List<Widget> labelRow = [
        if (showLabels && rowLabels.isNotEmpty)
          SizedBox(width: cellSize + cellGap),
      ];
      for (int i = 0; i < actualColumns && i < columnLabels.length; i++) {
        labelRow.add(
          SizedBox(
            width: cellSize,
            height: cellSize * 0.5,
            child: Center(
              child: Text(
                columnLabels[i].toString(),
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
        if (i < actualColumns - 1) {
          labelRow.add(SizedBox(width: cellGap));
        }
      }
      heatmapRows.add(Row(children: labelRow));
      heatmapRows.add(SizedBox(height: cellGap));
    }

    // Add data rows
    for (int i = 0; i < heatmapData.length; i++) {
      final List<Widget> rowWidgets = [];

      // Add row label if specified
      if (showLabels && i < rowLabels.length) {
        rowWidgets.add(
          SizedBox(
            width: cellSize,
            height: cellSize,
            child: Center(
              child: Text(
                rowLabels[i].toString(),
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
        rowWidgets.add(SizedBox(width: cellGap));
      }

      // Add cells. Cell colors blend the host theme's surfaceContainer
      // (low value end) into the scheme accent (high value end) so the
      // heatmap reads correctly in both light and dark modes — the
      // legacy fixed `Colors.<scheme>[50]` low end is too bright for
      // dark scaffolds.
      final lowEnd =
          context.themeManager.getColorValue('surfaceContainer') ??
              context.themeManager.getColorValue('surface') ??
              Colors.grey.shade100;
      for (int j = 0; j < heatmapData[i].length; j++) {
        final value = heatmapData[i][j];
        final normalizedValue =
            ((value - minValue) / (maxValue - minValue)).clamp(0.0, 1.0);
        final color =
            _getColorForValue(normalizedValue, colorScheme, lowEnd);

        rowWidgets.add(
          Container(
            width: cellSize,
            height: cellSize,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Center(
              child: Text(
                value.toStringAsFixed(0),
                style: TextStyle(
                  color: normalizedValue > 0.5 ? Colors.white : Colors.black,
                  fontSize: 10,
                ),
              ),
            ),
          ),
        );

        if (j < heatmapData[i].length - 1) {
          rowWidgets.add(SizedBox(width: cellGap));
        }
      }

      heatmapRows.add(Row(children: rowWidgets));
      if (i < heatmapData.length - 1) {
        heatmapRows.add(SizedBox(height: cellGap));
      }
    }

    Widget heatmap = Column(
      mainAxisSize: MainAxisSize.min,
      children: heatmapRows,
    );

    return applyCommonWrappers(heatmap, properties, context);
  }

  /// Lerps from [lowEnd] (theme surfaceContainer) at value 0 to a
  /// scheme-specific saturated accent at value 1. Cell text color
  /// (chosen at the call site) flips to white once the value crosses
  /// the midpoint and the cell becomes dark enough to need contrast.
  Color _getColorForValue(double value, String colorScheme, Color lowEnd) {
    final highEnd = switch (colorScheme) {
      'red' => Colors.red.shade700,
      'green' => Colors.green.shade700,
      'blue' => Colors.blue.shade700,
      'purple' => Colors.purple.shade700,
      'orange' => Colors.orange.shade700,
      'grayscale' => Colors.grey.shade800,
      _ => Colors.blue.shade700,
    };
    return Color.lerp(lowEnd, highEnd, value) ?? highEnd;
  }
}
