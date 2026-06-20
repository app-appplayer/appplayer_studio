import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Chart widgets (Advanced conformance level)
/// Supports line, bar, pie, scatter, area, and radar charts
/// with single data and multi-dataset structures
class ChartWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract chart properties
    final chartType =
        context.resolve<String>(properties['chartType'] ?? 'line');
    final rawData = properties['data'];
    final title = context.resolve<String?>(properties['title']);
    final width = context.resolve<double?>(properties['width']);
    final height = context.resolve<double?>(properties['height']) ?? 300.0;

    // Extract visual properties
    final showGrid = context.resolve<bool>(properties['showGrid'] ?? true);
    final showLabels = context.resolve<bool>(properties['showLabels'] ?? true);
    final showLegend = context.resolve<bool>(properties['showLegend'] ?? false);

    // Extract colors — theme-adaptive defaults. `gridColor` and
    // `labelColor` fall back to the active theme so gridlines and axis
    // labels stay visible in dark mode without the author setting them
    // explicitly.
    final primaryColor =
        parseColor(context.resolve(properties['primaryColor']), context) ??
            context.themeManager.getColorValue('primary') ??
            Colors.blue;
    final colors = _parseColors(properties['colors'], context);
    final gridColor =
        parseColor(context.resolve(properties['gridColor']), context) ??
            context.themeManager.getColorValue('outlineVariant') ??
            Colors.grey.shade300;
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context);
    final labelColor =
        parseColor(context.resolve(properties['labelColor']), context) ??
            context.themeManager.getColorValue('onSurface') ??
            Colors.black87;

    // Determine if multi-dataset or single data
    final bool isMultiDataset = rawData is Map && rawData.containsKey('datasets');
    final List<ChartDataset> datasets;
    final List<ChartDataPoint> chartData;
    final List<String> dataLabels;

    if (isMultiDataset) {
      datasets = _parseDatasets(rawData, context);
      dataLabels = _parseLabels(rawData);
      // Convert first dataset to ChartDataPoint for backward compat
      chartData = _datasetToPoints(datasets.isNotEmpty ? datasets.first : null, dataLabels);
    } else {
      final data = context.resolve<List<dynamic>>(rawData ?? [])
              as List<dynamic>? ??
          [];
      chartData = _parseChartData(data, chartType);
      datasets = [];
      dataLabels = chartData.map((p) => p.label).toList();
    }

    // M3 — chart container is an elevated panel; `surface` collapses
    // into the scaffold tone, so prefer `surfaceContainer` for visible
    // separation. Falls back through surface → white for legacy themes.
    final effectiveBackground = backgroundColor ??
        context.themeManager.getColorValue('surfaceContainer') ??
        context.themeManager.getColorValue('surface') ??
        Colors.white;
    final effectiveBorder = context.themeManager.getColorValue('outlineVariant') ??
        Colors.grey.shade200;

    if (chartData.isEmpty && datasets.isEmpty) {
      return applyCommonWrappers(
        Container(
          width: width,
          height: height,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: effectiveBorder),
            borderRadius: BorderRadius.circular(8),
            color: effectiveBackground,
          ),
          child: Text(
            'No chart data',
            style: TextStyle(color: labelColor.withValues(alpha: 0.6)),
          ),
        ),
        properties,
        context,
      );
    }

    // Build chart widget
    Widget chart = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        border: Border.all(color: effectiveBorder),
        borderRadius: BorderRadius.circular(8),
        color: effectiveBackground,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: labelColor,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: CustomPaint(
                painter: _ChartPainter(
                  chartType: chartType,
                  data: chartData,
                  datasets: datasets,
                  dataLabels: dataLabels,
                  showGrid: showGrid,
                  showLabels: showLabels,
                  primaryColor: primaryColor,
                  colors: colors,
                  gridColor: gridColor,
                  labelColor: labelColor,
                  backgroundColor: effectiveBackground,
                ),
                size: Size.infinite,
              ),
            ),
          ),
          if (showLegend)
            _buildLegend(chartData, datasets, colors, primaryColor, labelColor),
        ],
      ),
    );

    return applyCommonWrappers(chart, properties, context);
  }

  List<Color> _parseColors(dynamic colorsData, RenderContext context) {
    if (colorsData == null) return _defaultColors;
    if (colorsData is! List) return _defaultColors;

    final List<Color> colors = [];
    for (var colorData in colorsData) {
      final color = parseColor(context.resolve(colorData), context);
      if (color != null) {
        colors.add(color);
      }
    }
    return colors.isEmpty ? _defaultColors : colors;
  }

  static const List<Color> _defaultColors = [
    Colors.blue,
    Colors.red,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.teal,
    Colors.pink,
    Colors.indigo,
  ];

  List<String> _parseLabels(dynamic rawData) {
    if (rawData is! Map) return [];
    return (rawData['labels'] as List<dynamic>?)
            ?.map((l) => l.toString())
            .toList() ??
        [];
  }

  List<ChartDataset> _parseDatasets(dynamic rawData, RenderContext context) {
    if (rawData is! Map) return [];
    final datasets = rawData['datasets'] as List<dynamic>?;
    if (datasets == null || datasets.isEmpty) return [];

    return datasets.map((ds) {
      final dsMap = ds as Map<String, dynamic>;
      final values = (dsMap['data'] as List<dynamic>?)
              ?.map((v) => (v as num).toDouble())
              .toList() ??
          [];
      return ChartDataset(
        label: dsMap['label']?.toString() ?? '',
        data: values,
        color: parseColor(context.resolve(dsMap['color']), context),
        borderColor: parseColor(context.resolve(dsMap['borderColor']), context),
        fill: dsMap['fill'] as bool? ?? false,
      );
    }).toList();
  }

  List<ChartDataPoint> _datasetToPoints(
      ChartDataset? dataset, List<String> labels) {
    if (dataset == null) return [];
    return List.generate(dataset.data.length, (i) {
      return ChartDataPoint(
        value: dataset.data[i],
        label: i < labels.length ? labels[i] : '${i + 1}',
      );
    });
  }

  List<ChartDataPoint> _parseChartData(List<dynamic> data, String chartType) {
    final List<ChartDataPoint> points = [];

    for (int i = 0; i < data.length; i++) {
      final item = data[i];

      if (item is num) {
        points.add(ChartDataPoint(
          value: item.toDouble(),
          label: '${i + 1}',
        ));
      } else if (item is Map) {
        points.add(ChartDataPoint(
          value: (item['value'] as num?)?.toDouble() ?? 0.0,
          label: item['label']?.toString() ?? '${i + 1}',
          x: (item['x'] as num?)?.toDouble(),
          y: (item['y'] as num?)?.toDouble(),
        ));
      }
    }

    return points;
  }

  Widget _buildLegend(List<ChartDataPoint> data, List<ChartDataset> datasets,
      List<Color> colors, Color primaryColor, Color labelColor) {
    // Use dataset labels if multi-dataset, otherwise point labels
    final legendItems = datasets.isNotEmpty
        ? datasets.asMap().entries.map((entry) {
            final ds = entry.value;
            final color =
                ds.color ?? colors[entry.key % colors.length];
            return _LegendItem(label: ds.label, color: color);
          }).toList()
        : data.asMap().entries.map((entry) {
            final color = colors[entry.key % colors.length];
            return _LegendItem(label: entry.value.label, color: color);
          }).toList();

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: legendItems.map((item) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: item.color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                item.label,
                style: TextStyle(
                  fontSize: 12,
                  color: labelColor,
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}

class _LegendItem {
  final String label;
  final Color color;
  _LegendItem({required this.label, required this.color});
}

/// Data point for charts
class ChartDataPoint {
  final double value;
  final String label;
  final double? x;
  final double? y;

  ChartDataPoint({
    required this.value,
    required this.label,
    this.x,
    this.y,
  });
}

/// Dataset for multi-series charts
class ChartDataset {
  final String label;
  final List<double> data;
  final Color? color;
  final Color? borderColor;
  final bool fill;

  ChartDataset({
    required this.label,
    required this.data,
    this.color,
    this.borderColor,
    this.fill = false,
  });
}

/// Custom painter for rendering charts
class _ChartPainter extends CustomPainter {
  final String chartType;
  final List<ChartDataPoint> data;
  final List<ChartDataset> datasets;
  final List<String> dataLabels;
  final bool showGrid;
  final bool showLabels;
  final Color primaryColor;
  final List<Color> colors;
  final Color gridColor;
  final Color labelColor;

  /// Surface tone of the chart's outer container — used for visual
  /// "cuts" between pie slices so slice boundaries read as gaps in the
  /// background rather than a hardcoded white line. In M3 this is
  /// typically `surfaceContainer`.
  final Color backgroundColor;

  _ChartPainter({
    required this.chartType,
    required this.data,
    required this.datasets,
    required this.dataLabels,
    required this.showGrid,
    required this.showLabels,
    required this.primaryColor,
    required this.colors,
    required this.gridColor,
    required this.labelColor,
    required this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty && datasets.isEmpty) return;

    switch (chartType.toLowerCase()) {
      case 'bar':
        _paintBarChart(canvas, size);
        break;
      case 'pie':
        _paintPieChart(canvas, size);
        break;
      case 'donut':
        // Donut = pie with a central hole. Render the pie body, then
        // mask out the inner radius so the donut ring remains.
        _paintPieChart(canvas, size);
        _paintDonutHole(canvas, size);
        break;
      case 'polar':
        // Polar area — each category occupies an equal sweep but the
        // radius is proportional to the value. Reuses the pie palette.
        _paintPolarChart(canvas, size);
        break;
      case 'scatter':
        _paintScatterChart(canvas, size);
        break;
      case 'bubble':
        // Bubble = scatter with point radius proportional to value.
        _paintBubbleChart(canvas, size);
        break;
      case 'area':
        _paintAreaChart(canvas, size);
        break;
      case 'radar':
        _paintRadarChart(canvas, size);
        break;
      case 'line':
      default:
        if (datasets.isNotEmpty) {
          _paintMultiLineChart(canvas, size);
        } else {
          _paintLineChart(canvas, size);
        }
        break;
    }
  }

  void _paintLineChart(Canvas canvas, Size size) {
    final padding = showLabels ? 40.0 : 20.0;
    final graphWidth = size.width - padding * 2;
    final graphHeight = size.height - padding * 2;

    if (graphWidth <= 0 || graphHeight <= 0) return;

    final values = data.map((p) => p.value).toList();
    final minValue = values.reduce(math.min);
    final maxValue = values.reduce(math.max);
    final valueRange = maxValue - minValue;
    final adjustedMin = valueRange > 0 ? minValue : minValue - 1;
    final adjustedMax = valueRange > 0 ? maxValue : maxValue + 1;
    final adjustedRange = adjustedMax - adjustedMin;

    if (showGrid) {
      _drawGrid(canvas, size, padding, graphWidth, graphHeight);
    }

    final points = <Offset>[];
    final spacing = data.length > 1 ? graphWidth / (data.length - 1) : 0.0;

    for (int i = 0; i < data.length; i++) {
      final normalizedValue =
          adjustedRange > 0
              ? (data[i].value - adjustedMin) / adjustedRange
              : 0.5;
      final x = padding + (data.length > 1 ? i * spacing : graphWidth / 2);
      final y = padding + graphHeight - (normalizedValue * graphHeight);
      points.add(Offset(x, y));
    }

    // Draw filled area under line
    if (points.isNotEmpty) {
      final fillPath = Path();
      fillPath.moveTo(points.first.dx, padding + graphHeight);
      for (final point in points) {
        fillPath.lineTo(point.dx, point.dy);
      }
      fillPath.lineTo(points.last.dx, padding + graphHeight);
      fillPath.close();

      final fillPaint = Paint()
        ..color = primaryColor.withValues(alpha: 0.2)
        ..style = PaintingStyle.fill;
      canvas.drawPath(fillPath, fillPaint);
    }

    // Draw line
    if (points.length > 1) {
      final linePaint = Paint()
        ..color = primaryColor
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      final linePath = Path();
      linePath.moveTo(points.first.dx, points.first.dy);
      for (int i = 1; i < points.length; i++) {
        linePath.lineTo(points[i].dx, points[i].dy);
      }
      canvas.drawPath(linePath, linePaint);
    }

    // Draw data points
    final pointPaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.fill;

    for (final point in points) {
      canvas.drawCircle(point, 4, pointPaint);
    }

    if (showLabels) {
      _drawAxisLabels(canvas, size, padding, graphWidth, graphHeight,
          adjustedMin, adjustedMax, points);
    }
  }

  /// Paint multi-dataset line chart
  void _paintMultiLineChart(Canvas canvas, Size size) {
    final padding = showLabels ? 40.0 : 20.0;
    final graphWidth = size.width - padding * 2;
    final graphHeight = size.height - padding * 2;

    if (graphWidth <= 0 || graphHeight <= 0) return;

    // Find global min/max across all datasets
    double globalMin = double.infinity;
    double globalMax = double.negativeInfinity;
    for (final ds in datasets) {
      for (final v in ds.data) {
        if (v < globalMin) globalMin = v;
        if (v > globalMax) globalMax = v;
      }
    }
    if (globalMin == double.infinity) return;

    final valueRange = globalMax - globalMin;
    final adjustedMin = valueRange > 0 ? globalMin : globalMin - 1;
    final adjustedMax = valueRange > 0 ? globalMax : globalMax + 1;
    final adjustedRange = adjustedMax - adjustedMin;

    if (showGrid) {
      _drawGrid(canvas, size, padding, graphWidth, graphHeight);
    }

    // Draw each dataset as a separate line
    for (int dsIdx = 0; dsIdx < datasets.length; dsIdx++) {
      final ds = datasets[dsIdx];
      final color = ds.color ?? colors[dsIdx % colors.length];
      final points = <Offset>[];
      final spacing =
          ds.data.length > 1 ? graphWidth / (ds.data.length - 1) : 0.0;

      for (int i = 0; i < ds.data.length; i++) {
        final normalizedValue = adjustedRange > 0
            ? (ds.data[i] - adjustedMin) / adjustedRange
            : 0.5;
        final x = padding + (ds.data.length > 1 ? i * spacing : graphWidth / 2);
        final y = padding + graphHeight - (normalizedValue * graphHeight);
        points.add(Offset(x, y));
      }

      // Fill area if requested
      if (ds.fill && points.isNotEmpty) {
        final fillPath = Path();
        fillPath.moveTo(points.first.dx, padding + graphHeight);
        for (final point in points) {
          fillPath.lineTo(point.dx, point.dy);
        }
        fillPath.lineTo(points.last.dx, padding + graphHeight);
        fillPath.close();

        final fillPaint = Paint()
          ..color = color.withValues(alpha: 0.15)
          ..style = PaintingStyle.fill;
        canvas.drawPath(fillPath, fillPaint);
      }

      // Draw line
      if (points.length > 1) {
        final linePaint = Paint()
          ..color = ds.borderColor ?? color
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;

        final linePath = Path();
        linePath.moveTo(points.first.dx, points.first.dy);
        for (int i = 1; i < points.length; i++) {
          linePath.lineTo(points[i].dx, points[i].dy);
        }
        canvas.drawPath(linePath, linePaint);
      }

      // Draw data points
      final pointPaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;
      for (final point in points) {
        canvas.drawCircle(point, 3, pointPaint);
      }
    }

    // Draw labels from first dataset
    if (showLabels && datasets.isNotEmpty) {
      final ds = datasets.first;
      final spacing =
          ds.data.length > 1 ? graphWidth / (ds.data.length - 1) : 0.0;
      final points = <Offset>[];
      for (int i = 0; i < ds.data.length; i++) {
        final x = padding + (ds.data.length > 1 ? i * spacing : graphWidth / 2);
        points.add(Offset(x, 0));
      }
      _drawMultiDatasetLabels(
          canvas, size, padding, graphWidth, graphHeight, adjustedMin, adjustedMax, points);
    }
  }

  /// Paint area chart (line chart with filled area, no data points)
  void _paintAreaChart(Canvas canvas, Size size) {
    final padding = showLabels ? 40.0 : 20.0;
    final graphWidth = size.width - padding * 2;
    final graphHeight = size.height - padding * 2;

    if (graphWidth <= 0 || graphHeight <= 0) return;

    if (showGrid) {
      _drawGrid(canvas, size, padding, graphWidth, graphHeight);
    }

    if (datasets.isNotEmpty) {
      // Multi-dataset area chart
      double globalMin = double.infinity;
      double globalMax = double.negativeInfinity;
      for (final ds in datasets) {
        for (final v in ds.data) {
          if (v < globalMin) globalMin = v;
          if (v > globalMax) globalMax = v;
        }
      }
      if (globalMin == double.infinity) return;

      final valueRange = globalMax - globalMin;
      final adjustedMin = valueRange > 0 ? globalMin : globalMin - 1;
      final adjustedMax = valueRange > 0 ? globalMax : globalMax + 1;
      final adjustedRange = adjustedMax - adjustedMin;

      for (int dsIdx = datasets.length - 1; dsIdx >= 0; dsIdx--) {
        final ds = datasets[dsIdx];
        final color = ds.color ?? colors[dsIdx % colors.length];
        final points = <Offset>[];
        final spacing =
            ds.data.length > 1 ? graphWidth / (ds.data.length - 1) : 0.0;

        for (int i = 0; i < ds.data.length; i++) {
          final normalizedValue = adjustedRange > 0
              ? (ds.data[i] - adjustedMin) / adjustedRange
              : 0.5;
          final x = padding + (ds.data.length > 1 ? i * spacing : graphWidth / 2);
          final y = padding + graphHeight - (normalizedValue * graphHeight);
          points.add(Offset(x, y));
        }

        // Fill area
        if (points.isNotEmpty) {
          final fillPath = Path();
          fillPath.moveTo(points.first.dx, padding + graphHeight);
          for (final point in points) {
            fillPath.lineTo(point.dx, point.dy);
          }
          fillPath.lineTo(points.last.dx, padding + graphHeight);
          fillPath.close();

          final fillPaint = Paint()
            ..color = color.withValues(alpha: 0.4)
            ..style = PaintingStyle.fill;
          canvas.drawPath(fillPath, fillPaint);

          // Draw border line
          final linePaint = Paint()
            ..color = ds.borderColor ?? color
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke;
          final linePath = Path();
          linePath.moveTo(points.first.dx, points.first.dy);
          for (int i = 1; i < points.length; i++) {
            linePath.lineTo(points[i].dx, points[i].dy);
          }
          canvas.drawPath(linePath, linePaint);
        }
      }

      if (showLabels && datasets.isNotEmpty) {
        final ds = datasets.first;
        final spacing =
            ds.data.length > 1 ? graphWidth / (ds.data.length - 1) : 0.0;
        final pts = <Offset>[];
        for (int i = 0; i < ds.data.length; i++) {
          pts.add(Offset(padding + (ds.data.length > 1 ? i * spacing : graphWidth / 2), 0));
        }
        _drawMultiDatasetLabels(
            canvas, size, padding, graphWidth, graphHeight, adjustedMin, adjustedMax, pts);
      }
    } else {
      // Single data area chart
      final values = data.map((p) => p.value).toList();
      final minValue = values.reduce(math.min);
      final maxValue = values.reduce(math.max);
      final valueRange = maxValue - minValue;
      final adjustedMin = valueRange > 0 ? minValue : minValue - 1;
      final adjustedMax = valueRange > 0 ? maxValue : maxValue + 1;
      final adjustedRange = adjustedMax - adjustedMin;

      final points = <Offset>[];
      final spacing = data.length > 1 ? graphWidth / (data.length - 1) : 0.0;

      for (int i = 0; i < data.length; i++) {
        final normalizedValue = adjustedRange > 0
            ? (data[i].value - adjustedMin) / adjustedRange
            : 0.5;
        final x = padding + (data.length > 1 ? i * spacing : graphWidth / 2);
        final y = padding + graphHeight - (normalizedValue * graphHeight);
        points.add(Offset(x, y));
      }

      // Fill area
      if (points.isNotEmpty) {
        final fillPath = Path();
        fillPath.moveTo(points.first.dx, padding + graphHeight);
        for (final point in points) {
          fillPath.lineTo(point.dx, point.dy);
        }
        fillPath.lineTo(points.last.dx, padding + graphHeight);
        fillPath.close();

        final fillPaint = Paint()
          ..color = primaryColor.withValues(alpha: 0.4)
          ..style = PaintingStyle.fill;
        canvas.drawPath(fillPath, fillPaint);

        // Draw border line
        final linePaint = Paint()
          ..color = primaryColor
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke;
        final linePath = Path();
        linePath.moveTo(points.first.dx, points.first.dy);
        for (int i = 1; i < points.length; i++) {
          linePath.lineTo(points[i].dx, points[i].dy);
        }
        canvas.drawPath(linePath, linePaint);
      }

      if (showLabels) {
        _drawAxisLabels(canvas, size, padding, graphWidth, graphHeight,
            adjustedMin, adjustedMax, points);
      }
    }
  }

  /// Paint radar (spider) chart
  void _paintRadarChart(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius =
        math.min(size.width, size.height) / 2 - (showLabels ? 50 : 20);

    if (radius <= 0) return;

    // Determine axes count from data or datasets
    final int axisCount;
    final List<String> axisLabels;

    if (datasets.isNotEmpty) {
      axisCount = datasets.map((ds) => ds.data.length).reduce(math.max);
      axisLabels = dataLabels.isNotEmpty
          ? dataLabels
          : List.generate(axisCount, (i) => '${i + 1}');
    } else {
      axisCount = data.length;
      axisLabels = data.map((p) => p.label).toList();
    }

    if (axisCount < 3) return; // Radar needs at least 3 axes

    final angleStep = 2 * math.pi / axisCount;

    // Draw grid rings
    if (showGrid) {
      for (int ring = 1; ring <= 5; ring++) {
        final ringRadius = radius * ring / 5;
        final ringPath = Path();
        for (int i = 0; i <= axisCount; i++) {
          final angle = -math.pi / 2 + i * angleStep;
          final x = center.dx + ringRadius * math.cos(angle);
          final y = center.dy + ringRadius * math.sin(angle);
          if (i == 0) {
            ringPath.moveTo(x, y);
          } else {
            ringPath.lineTo(x, y);
          }
        }

        final ringPaint = Paint()
          ..color = gridColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1;
        canvas.drawPath(ringPath, ringPaint);
      }

      // Draw axis lines
      final axisPaint = Paint()
        ..color = gridColor
        ..strokeWidth = 1;
      for (int i = 0; i < axisCount; i++) {
        final angle = -math.pi / 2 + i * angleStep;
        final x = center.dx + radius * math.cos(angle);
        final y = center.dy + radius * math.sin(angle);
        canvas.drawLine(center, Offset(x, y), axisPaint);
      }
    }

    // Find global max for normalization
    double globalMax = 0;
    if (datasets.isNotEmpty) {
      for (final ds in datasets) {
        for (final v in ds.data) {
          if (v.abs() > globalMax) globalMax = v.abs();
        }
      }
    } else {
      for (final point in data) {
        if (point.value.abs() > globalMax) globalMax = point.value.abs();
      }
    }
    if (globalMax == 0) globalMax = 1;

    if (datasets.isNotEmpty) {
      // Draw each dataset polygon
      for (int dsIdx = 0; dsIdx < datasets.length; dsIdx++) {
        final ds = datasets[dsIdx];
        final color = ds.color ?? colors[dsIdx % colors.length];
        _drawRadarPolygon(
            canvas, center, radius, ds.data, globalMax, angleStep, color, ds.fill);
      }
    } else {
      // Draw single data polygon
      final values = data.map((p) => p.value).toList();
      _drawRadarPolygon(
          canvas, center, radius, values, globalMax, angleStep, primaryColor, true);
    }

    // Draw axis labels
    if (showLabels) {
      final textPainter = TextPainter(textDirection: TextDirection.ltr);
      for (int i = 0; i < axisCount && i < axisLabels.length; i++) {
        final angle = -math.pi / 2 + i * angleStep;
        final labelRadius = radius + 16;
        final lx = center.dx + labelRadius * math.cos(angle);
        final ly = center.dy + labelRadius * math.sin(angle);

        textPainter.text = TextSpan(
          text: axisLabels[i],
          style: TextStyle(color: labelColor.withValues(alpha: 0.6), fontSize: 10),
        );
        textPainter.layout();
        textPainter.paint(
          canvas,
          Offset(lx - textPainter.width / 2, ly - textPainter.height / 2),
        );
      }
    }
  }

  void _drawRadarPolygon(Canvas canvas, Offset center, double radius,
      List<double> values, double maxValue, double angleStep, Color color, bool fill) {
    final path = Path();
    final points = <Offset>[];

    for (int i = 0; i < values.length; i++) {
      final normalized = (values[i].abs() / maxValue).clamp(0.0, 1.0);
      final angle = -math.pi / 2 + i * angleStep;
      final x = center.dx + radius * normalized * math.cos(angle);
      final y = center.dy + radius * normalized * math.sin(angle);
      points.add(Offset(x, y));
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();

    // Fill
    if (fill) {
      final fillPaint = Paint()
        ..color = color.withValues(alpha: 0.25)
        ..style = PaintingStyle.fill;
      canvas.drawPath(path, fillPaint);
    }

    // Stroke
    final strokePaint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, strokePaint);

    // Draw dots at vertices
    final dotPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    for (final point in points) {
      canvas.drawCircle(point, 3, dotPaint);
    }
  }

  void _paintBarChart(Canvas canvas, Size size) {
    final padding = showLabels ? 40.0 : 20.0;
    final graphWidth = size.width - padding * 2;
    final graphHeight = size.height - padding * 2;

    if (graphWidth <= 0 || graphHeight <= 0) return;

    final values = data.map((p) => p.value).toList();
    final minValue = math.min(0.0, values.reduce(math.min));
    final maxValue = values.reduce(math.max);
    final valueRange = maxValue - minValue;
    final adjustedRange = valueRange > 0 ? valueRange : 1.0;

    if (showGrid) {
      _drawGrid(canvas, size, padding, graphWidth, graphHeight);
    }

    final barSpacing = graphWidth / data.length;
    final barWidth = (barSpacing * 0.7).clamp(10.0, 50.0);
    final zeroY =
        padding + graphHeight - (-minValue / adjustedRange * graphHeight);

    for (int i = 0; i < data.length; i++) {
      final color = colors[i % colors.length];
      final barPaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;

      final normalizedValue = (data[i].value - minValue) / adjustedRange;
      final barHeight = normalizedValue * graphHeight;
      final x = padding + barSpacing * i + (barSpacing - barWidth) / 2;
      final y = zeroY - barHeight;

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, barWidth, barHeight),
        const Radius.circular(4),
      );
      canvas.drawRRect(rect, barPaint);

      if (showLabels) {
        final textPainter = TextPainter(
          text: TextSpan(
            text: data[i].value.toStringAsFixed(0),
            style: TextStyle(
              color: labelColor,
              fontSize: 10,
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();
        textPainter.paint(
          canvas,
          Offset(x + (barWidth - textPainter.width) / 2,
              y - textPainter.height - 4),
        );
      }
    }

    if (showLabels) {
      final textPainter = TextPainter(textDirection: TextDirection.ltr);
      for (int i = 0; i < data.length; i++) {
        textPainter.text = TextSpan(
          text: data[i].label,
          style: TextStyle(color: labelColor.withValues(alpha: 0.6), fontSize: 10),
        );
        textPainter.layout(maxWidth: barSpacing);
        final x = padding +
            barSpacing * i +
            (barSpacing - textPainter.width) / 2;
        textPainter.paint(canvas, Offset(x, padding + graphHeight + 8));
      }
    }
  }

  void _paintPieChart(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius =
        math.min(size.width, size.height) / 2 - (showLabels ? 40 : 20);

    if (radius <= 0) return;

    final total = data.fold<double>(0, (sum, p) => sum + p.value.abs());
    if (total == 0) return;

    double startAngle = -math.pi / 2;

    for (int i = 0; i < data.length; i++) {
      final sweepAngle = (data[i].value.abs() / total) * 2 * math.pi;
      final color = colors[i % colors.length];

      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        true,
        paint,
      );

      // Slice border = chart background color so adjacent slices read
      // as separated by the surface tone, not a hardcoded white line
      // that disappears against light surfaces / glares against dark.
      final borderPaint = Paint()
        ..color = backgroundColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        true,
        borderPaint,
      );

      if (showLabels && sweepAngle > 0.2) {
        final labelAngle = startAngle + sweepAngle / 2;
        final labelRadius = radius * 0.65;
        final labelX = center.dx + labelRadius * math.cos(labelAngle);
        final labelY = center.dy + labelRadius * math.sin(labelAngle);

        final percentage =
            (data[i].value.abs() / total * 100).toStringAsFixed(0);
        final textPainter = TextPainter(
          text: TextSpan(
            text: '$percentage%',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();
        textPainter.paint(
          canvas,
          Offset(labelX - textPainter.width / 2,
              labelY - textPainter.height / 2),
        );
      }

      startAngle += sweepAngle;
    }
  }

  void _paintScatterChart(Canvas canvas, Size size) {
    final padding = showLabels ? 40.0 : 20.0;
    final graphWidth = size.width - padding * 2;
    final graphHeight = size.height - padding * 2;

    if (graphWidth <= 0 || graphHeight <= 0) return;

    final xValues =
        data.map((p) => p.x ?? data.indexOf(p).toDouble()).toList();
    final yValues = data.map((p) => p.y ?? p.value).toList();

    final minX = xValues.reduce(math.min);
    final maxX = xValues.reduce(math.max);
    final minY = yValues.reduce(math.min);
    final maxY = yValues.reduce(math.max);

    final xRange = maxX - minX > 0 ? maxX - minX : 1.0;
    final yRange = maxY - minY > 0 ? maxY - minY : 1.0;

    if (showGrid) {
      _drawGrid(canvas, size, padding, graphWidth, graphHeight);
    }

    for (int i = 0; i < data.length; i++) {
      final xVal = data[i].x ?? i.toDouble();
      final yVal = data[i].y ?? data[i].value;

      final x = padding + ((xVal - minX) / xRange) * graphWidth;
      final y = padding + graphHeight - ((yVal - minY) / yRange) * graphHeight;

      final color = colors[i % colors.length];

      final pointPaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;

      canvas.drawCircle(Offset(x, y), 6, pointPaint);

      final borderPaint = Paint()
        ..color = color.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;

      canvas.drawCircle(Offset(x, y), 8, borderPaint);
    }

    if (showLabels) {
      final textPainter = TextPainter(textDirection: TextDirection.ltr);

      for (int i = 0; i <= 5; i++) {
        final value = minY + (yRange * (5 - i) / 5);
        textPainter.text = TextSpan(
          text: value.toStringAsFixed(0),
          style: TextStyle(color: labelColor.withValues(alpha: 0.6), fontSize: 10),
        );
        textPainter.layout();
        final y = padding + (graphHeight * i / 5) - textPainter.height / 2;
        textPainter.paint(
            canvas, Offset(padding - textPainter.width - 5, y));
      }

      for (int i = 0; i <= 5; i++) {
        final value = minX + (xRange * i / 5);
        textPainter.text = TextSpan(
          text: value.toStringAsFixed(0),
          style: TextStyle(color: labelColor.withValues(alpha: 0.6), fontSize: 10),
        );
        textPainter.layout();
        final x = padding + (graphWidth * i / 5) - textPainter.width / 2;
        textPainter.paint(canvas, Offset(x, padding + graphHeight + 5));
      }
    }
  }

  /// Donut chart — paints over the rendered pie with a hole in the
  /// centre. Hole radius is 50 % of the pie radius.
  void _paintDonutHole(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outer = math.min(size.width, size.height) / 2 - (showLabels ? 40 : 20);
    if (outer <= 0) return;
    final paint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, outer * 0.5, paint);
  }

  /// Polar area — equal angular sweeps; per-slice radius scales with
  /// the data value.
  void _paintPolarChart(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outer = math.min(size.width, size.height) / 2 - (showLabels ? 40 : 20);
    if (outer <= 0 || data.isEmpty) return;
    final maxV = data.map((p) => p.value.abs()).fold<double>(0, math.max);
    if (maxV == 0) return;
    final sweep = (2 * math.pi) / data.length;
    var start = -math.pi / 2;
    for (var i = 0; i < data.length; i++) {
      final r = outer * (data[i].value.abs() / maxV);
      final color = colors[i % colors.length];
      final paint = Paint()
        ..color = color.withValues(alpha: 0.8)
        ..style = PaintingStyle.fill;
      canvas.drawArc(
          Rect.fromCircle(center: center, radius: r), start, sweep, true, paint);
      final border = Paint()
        ..color = backgroundColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawArc(
          Rect.fromCircle(center: center, radius: r), start, sweep, true, border);
      start += sweep;
    }
  }

  /// Bubble — scatter where each marker's radius is proportional to
  /// the data value (relative to the maximum value in the dataset).
  void _paintBubbleChart(Canvas canvas, Size size) {
    final padding = showLabels ? 40.0 : 20.0;
    final w = size.width - padding * 2;
    final h = size.height - padding * 2;
    if (w <= 0 || h <= 0 || data.isEmpty) return;
    final xs = data.map((p) => p.x ?? data.indexOf(p).toDouble()).toList();
    final ys = data.map((p) => p.y ?? p.value).toList();
    final values = data.map((p) => p.value.abs()).toList();
    final minX = xs.reduce(math.min);
    final maxX = xs.reduce(math.max);
    final minY = ys.reduce(math.min);
    final maxY = ys.reduce(math.max);
    final maxV = values.fold<double>(0, math.max);
    final xR = maxX - minX > 0 ? maxX - minX : 1.0;
    final yR = maxY - minY > 0 ? maxY - minY : 1.0;
    if (showGrid) _drawGrid(canvas, size, padding, w, h);
    final maxRadius = math.min(w, h) / 12;
    for (var i = 0; i < data.length; i++) {
      final xV = xs[i];
      final yV = ys[i];
      final r = maxV > 0
          ? math.max(4.0, maxRadius * (values[i] / maxV))
          : 6.0;
      final cx = padding + ((xV - minX) / xR) * w;
      final cy = padding + h - ((yV - minY) / yR) * h;
      final fill = Paint()
        ..color = colors[i % colors.length].withValues(alpha: 0.6)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cx, cy), r, fill);
      final stroke = Paint()
        ..color = colors[i % colors.length]
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawCircle(Offset(cx, cy), r, stroke);
    }
  }

  void _drawGrid(Canvas canvas, Size size, double padding, double graphWidth,
      double graphHeight) {
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;

    for (int i = 0; i <= 5; i++) {
      final y = padding + (graphHeight * i / 5);
      canvas.drawLine(
        Offset(padding, y),
        Offset(padding + graphWidth, y),
        gridPaint,
      );
    }

    for (int i = 0; i <= 5; i++) {
      final x = padding + (graphWidth * i / 5);
      canvas.drawLine(
        Offset(x, padding),
        Offset(x, padding + graphHeight),
        gridPaint,
      );
    }
  }

  void _drawAxisLabels(
      Canvas canvas,
      Size size,
      double padding,
      double graphWidth,
      double graphHeight,
      double minValue,
      double maxValue,
      List<Offset> points) {
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    final valueRange = maxValue - minValue;

    for (int i = 0; i <= 5; i++) {
      final value = minValue + (valueRange * (5 - i) / 5);
      textPainter.text = TextSpan(
        text: value.toStringAsFixed(0),
        style: TextStyle(color: labelColor.withValues(alpha: 0.6), fontSize: 10),
      );
      textPainter.layout();
      final y = padding + (graphHeight * i / 5) - textPainter.height / 2;
      textPainter.paint(
          canvas, Offset(padding - textPainter.width - 5, y));
    }

    for (int i = 0; i < data.length && i < points.length; i++) {
      textPainter.text = TextSpan(
        text: data[i].label,
        style: TextStyle(color: labelColor.withValues(alpha: 0.6), fontSize: 10),
      );
      textPainter.layout();
      final x = points[i].dx - textPainter.width / 2;
      textPainter.paint(canvas, Offset(x, padding + graphHeight + 5));
    }
  }

  void _drawMultiDatasetLabels(
      Canvas canvas,
      Size size,
      double padding,
      double graphWidth,
      double graphHeight,
      double minValue,
      double maxValue,
      List<Offset> points) {
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    final valueRange = maxValue - minValue;

    // Y-axis labels
    for (int i = 0; i <= 5; i++) {
      final value = minValue + (valueRange * (5 - i) / 5);
      textPainter.text = TextSpan(
        text: value.toStringAsFixed(0),
        style: TextStyle(color: labelColor.withValues(alpha: 0.6), fontSize: 10),
      );
      textPainter.layout();
      final y = padding + (graphHeight * i / 5) - textPainter.height / 2;
      textPainter.paint(
          canvas, Offset(padding - textPainter.width - 5, y));
    }

    // X-axis labels from dataLabels
    for (int i = 0; i < dataLabels.length && i < points.length; i++) {
      textPainter.text = TextSpan(
        text: dataLabels[i],
        style: TextStyle(color: labelColor.withValues(alpha: 0.6), fontSize: 10),
      );
      textPainter.layout();
      final x = points[i].dx - textPainter.width / 2;
      textPainter.paint(canvas, Offset(x, padding + graphHeight + 5));
    }
  }

  @override
  bool shouldRepaint(_ChartPainter oldDelegate) {
    return chartType != oldDelegate.chartType ||
        data.length != oldDelegate.data.length ||
        datasets.length != oldDelegate.datasets.length ||
        showGrid != oldDelegate.showGrid ||
        showLabels != oldDelegate.showLabels ||
        primaryColor != oldDelegate.primaryColor;
  }
}
