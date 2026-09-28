import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for `gantt`.
///
/// What makes this a widget rather than a composition is the **axis**. Bars are
/// positioned by time, not by index, so row and header must share one scale and
/// stay aligned through scroll. Composing it from `grid` gives rows that drift
/// from the header as soon as either scrolls — here both are laid out from the
/// same `_Scale`.
///
/// Dependencies are drawn, not enforced: the widget reports an edit and whether
/// a move is legal is the server's answer.
class GanttFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final rawTasks = listOf(properties['tasks'], context) ?? const [];
    final viewMode = context.resolve<String?>(properties['viewMode']) ?? 'day';
    final editable = context.resolve<bool?>(properties['editable']) ?? false;
    final showProgress =
        context.resolve<bool?>(properties['showProgress']) ?? true;
    final showDependencies =
        context.resolve<bool?>(properties['showDependencies']) ?? true;
    final todayMarker =
        context.resolve<bool?>(properties['todayMarker']) ?? true;
    final rowHeight =
        context.resolve<num?>(properties['rowHeight'])?.toDouble() ?? 32.0;
    final onTaskChange = actionOf(properties['onTaskChange'], context);
    final onTaskClick = actionOf(properties['onTaskClick'], context);

    final tasks = <_Task>[];
    for (final raw in rawTasks) {
      if (raw is! Map) continue;
      final start = DateTime.tryParse(raw['start']?.toString() ?? '');
      final end = DateTime.tryParse(raw['end']?.toString() ?? '');
      if (start == null || end == null) continue;
      tasks.add(_Task(
        id: raw['id']?.toString() ?? '',
        label: raw['label']?.toString() ?? '',
        start: start,
        end: end,
        progress: (raw['progress'] as num?)?.toDouble(),
        // A task declares `color?` and `group?`. Both were dropped:
        // every bar came out in the scheme primary, and a chart of two teams
        // showed one undivided list.
        color: parseColor(raw['color'], context),
        group: raw['group']?.toString(),
        dependsOn: [
          for (final d in (raw['dependsOn'] as List? ?? const [])) d.toString(),
        ],
      ));
    }
    if (tasks.isEmpty) return const SizedBox.shrink();

    final range = context.resolve<Map<String, dynamic>?>(properties['range']);
    final from = DateTime.tryParse(range?['start']?.toString() ?? '') ??
        tasks.map((t) => t.start).reduce((a, b) => a.isBefore(b) ? a : b);
    final to = DateTime.tryParse(range?['end']?.toString() ?? '') ??
        tasks.map((t) => t.end).reduce((a, b) => a.isAfter(b) ? a : b);

    return _Gantt(
      tasks: tasks,
      from: from,
      to: to,
      unit: _unitFor(viewMode),
      rowHeight: rowHeight,
      editable: editable,
      showProgress: showProgress,
      showDependencies: showDependencies,
      todayMarker: todayMarker,
      onChange: (task, start, end) {
        if (onTaskChange == null) return;
        context.actionHandler.execute(
          onTaskChange,
          context.createChildContext(
            variables: {
              // The proposed schedule, not an applied one.
              'event': {
                'id': task.id,
                'start': start.toIso8601String(),
                'end': end.toIso8601String(),
                'type': 'taskChange',
              },
            },
          ),
        );
      },
      onClick: (task) {
        if (onTaskClick == null) return;
        context.actionHandler.execute(
          onTaskClick,
          context.createChildContext(
            variables: {
              'event': {'id': task.id, 'type': 'taskClick'},
            },
          ),
        );
      },
    );
  }

  static Duration _unitFor(String viewMode) {
    switch (viewMode) {
      case 'hour':
        return const Duration(hours: 1);
      case 'week':
        return const Duration(days: 7);
      case 'month':
        return const Duration(days: 30);
      case 'quarter':
        return const Duration(days: 90);
      case 'year':
        return const Duration(days: 365);
      default:
        return const Duration(days: 1);
    }
  }
}

@immutable
class _Task {
  const _Task({
    required this.id,
    required this.label,
    required this.start,
    required this.end,
    required this.dependsOn,
    this.progress,
    this.color,
    this.group,
  });

  final String id;
  final String label;
  final DateTime start;
  final DateTime end;
  final double? progress;
  final List<String> dependsOn;

  /// The bar's own colour, when the task named one.
  final Color? color;

  /// The band this task belongs to. Tasks are drawn grouped, with the name
  /// above the first row of each band.
  final String? group;
}

/// A row in the chart: either a band header or a task.
class _Row {
  const _Row._(this.group, this.task);

  factory _Row.header(String group) => _Row._(group, null);
  factory _Row.task(_Task task) => _Row._(null, task);

  final String? group;
  final _Task? task;
}

/// The single mapping from time to pixels. Header and rows both read it, which
/// is what keeps them aligned.
class _Scale {
  const _Scale(this.from, this.to, this.width);

  final DateTime from;
  final DateTime to;
  final double width;

  double xOf(DateTime t) {
    final span = to.difference(from).inMilliseconds;
    if (span <= 0) return 0;
    return width * (t.difference(from).inMilliseconds / span);
  }

  DateTime timeAt(double x) => from.add(Duration(
      milliseconds:
          (to.difference(from).inMilliseconds * (x / width)).round()));
}

class _Gantt extends StatefulWidget {
  const _Gantt({
    required this.tasks,
    required this.from,
    required this.to,
    required this.unit,
    required this.rowHeight,
    required this.editable,
    required this.showProgress,
    required this.showDependencies,
    required this.todayMarker,
    required this.onChange,
    required this.onClick,
  });

  final List<_Task> tasks;
  final DateTime from;
  final DateTime to;
  final Duration unit;
  final double rowHeight;
  final bool editable;
  final bool showProgress;
  final bool showDependencies;
  final bool todayMarker;
  final void Function(_Task, DateTime, DateTime) onChange;
  final void Function(_Task) onClick;

  @override
  State<_Gantt> createState() => _GanttState();
}

class _GanttState extends State<_Gantt> {
  final ScrollController _horizontal = ScrollController();
  final Map<String, ({DateTime start, DateTime end})> _dragging = {};

  @override
  void dispose() {
    _horizontal.dispose();
    super.dispose();
  }

  static const double _labelWidth = 160;

  @override
  Widget build(BuildContext context) {
    final span = widget.to.difference(widget.from);
    final units = (span.inMilliseconds / widget.unit.inMilliseconds).ceil();
    final chartWidth = (units.clamp(1, 2000)) * 40.0;
    final scale = _Scale(widget.from, widget.to, chartWidth);
    // One row plan for both columns. Labels and bars are drawn by different
    // widgets, and any difference between their row lists shows up as bars
    // sliding away from their names.
    final rows = _rows(widget.tasks);
    final headerHeight = widget.rowHeight * 0.75;
    final bodyHeight = rows.fold<double>(
        widget.rowHeight,
        (total, row) =>
            total + (row.task == null ? headerHeight : widget.rowHeight));

    // The chart is as tall as it has rows, which is unbounded: a plan with two
    // hundred tasks is a normal plan, and it overflowed by three thousand
    // pixels rather than scrolling. The height stays as the *content* height
    // and a vertical scroll view carries it, so the timeline keeps its
    // one-row-per-task geometry and the viewport decides how much is on
    // screen.
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: bodyHeight,
            child: Row(
              children: [
                SizedBox(
                  width: _labelWidth,
                  child: Column(
                    children: [
                      SizedBox(height: widget.rowHeight),
                      for (final row in rows)
                        if (row.task == null)
                          SizedBox(
                            height: headerHeight,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                row.group!,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.color ??
                                      Colors.grey,
                                ),
                              ),
                            ),
                          )
                        else
                          SizedBox(
                            height: widget.rowHeight,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(row.task!.label,
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ),
                    ],
                  ),
                ),
                Expanded(
                  // One scroll view for header and rows together — separate
                  // controllers are exactly how a composed version drifts.
                  child: SingleChildScrollView(
                    controller: _horizontal,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: chartWidth,
                      child: Stack(
                        children: [
                          Column(
                            children: [
                              SizedBox(
                                height: widget.rowHeight,
                                child: CustomPaint(
                                  size: Size(chartWidth, widget.rowHeight),
                                  painter: _AxisPainter(
                                    scale: scale,
                                    unit: widget.unit,
                                    color: Theme.of(context).dividerColor,
                                    textColor: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.color ??
                                        Colors.grey,
                                  ),
                                ),
                              ),
                              for (final row in rows)
                                if (row.task == null)
                                  SizedBox(height: headerHeight)
                                else
                                  SizedBox(
                                    height: widget.rowHeight,
                                    child: _Bar(
                                      task: row.task!,
                                      scale: scale,
                                      editable: widget.editable,
                                      showProgress: widget.showProgress,
                                      preview: _dragging[row.task!.id],
                                      onTap: () => widget.onClick(row.task!),
                                      onDrag: (start, end) => setState(() =>
                                          _dragging[row.task!.id] =
                                              (start: start, end: end)),
                                      onDragEnd: (start, end) {
                                        // The live range, not the arguments: the
                                        // bar's callbacks close over the dates from
                                        // its last BUILD, and the frame after the
                                        // final drag update has not been built when
                                        // the gesture ends. Reporting the arguments
                                        // therefore lost the tail of every drag —
                                        // and all of a quick one, which reported the
                                        // task as unmoved.
                                        final live = _dragging[row.task!.id];
                                        setState(() =>
                                            _dragging.remove(row.task!.id));
                                        widget.onChange(
                                          row.task!,
                                          live?.start ?? start,
                                          live?.end ?? end,
                                        );
                                      },
                                    ),
                                  ),
                            ],
                          ),
                          // Dependency arrows, over the bars. `dependsOn` was
                          // parsed and `showDependencies` passed down, and nothing
                          // drew them: the only painter was the axis. The overlay
                          // ignores pointers so a bar under an arrow still drags.
                          if (widget.showDependencies)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _DependencyPainter(
                                    rows: rows,
                                    scale: scale,
                                    rowHeight: widget.rowHeight,
                                    headerHeight: headerHeight,
                                    preview: _dragging,
                                    color: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.color ??
                                        Colors.grey,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The rows to draw: a header for each band that has a name, then its
  /// tasks. Bands keep the order they first appear in, and tasks keep the
  /// document's order inside a band; a plan with no groups produces exactly
  /// the rows it did before.
  List<_Row> _rows(List<_Task> tasks) {
    final bands = <String?, List<_Task>>{};
    for (final task in tasks) {
      bands.putIfAbsent(task.group, () => <_Task>[]).add(task);
    }
    final out = <_Row>[];
    bands.forEach((group, band) {
      if (group != null) out.add(_Row.header(group));
      out.addAll(band.map(_Row.task));
    });
    return out;
  }
}

/// Draws an arrow from the end of each task a row depends on to the start
/// of that row's task: out of the predecessor, down (or up) in the gap, into
/// the successor. Uses the same row plan the bars use, so an arrow lands on
/// the bar it names; a drag preview moves the arrow with the bar.
class _DependencyPainter extends CustomPainter {
  const _DependencyPainter({
    required this.rows,
    required this.scale,
    required this.rowHeight,
    required this.headerHeight,
    required this.preview,
    required this.color,
  });

  final List<_Row> rows;
  final _Scale scale;
  final double rowHeight;
  final double headerHeight;
  final Map<String, ({DateTime start, DateTime end})> preview;
  final Color color;

  static const double _stub = 8;
  static const double _head = 5;

  @override
  void paint(Canvas canvas, Size size) {
    // Row centres, keyed by task id, from the row plan.
    final centers = <String, double>{};
    final tasks = <String, _Task>{};
    var y = rowHeight; // the axis row
    for (final row in rows) {
      if (row.task == null) {
        y += headerHeight;
        continue;
      }
      centers[row.task!.id] = y + rowHeight / 2;
      tasks[row.task!.id] = row.task!;
      y += rowHeight;
    }

    final line = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final head = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    for (final task in tasks.values) {
      final toY = centers[task.id]!;
      final toX = scale.xOf(preview[task.id]?.start ?? task.start);
      for (final depId in task.dependsOn) {
        final dep = tasks[depId];
        final fromY = centers[depId];
        if (dep == null || fromY == null) continue;
        final fromX = scale.xOf(preview[depId]?.end ?? dep.end);

        final path = Path()..moveTo(fromX, fromY);
        if (toX - _stub * 2 >= fromX) {
          // Successor starts after the predecessor ends: one elbow.
          final midX = toX - _stub;
          path
            ..lineTo(midX, fromY)
            ..lineTo(midX, toY)
            ..lineTo(toX, toY);
        } else {
          // Successor starts before the predecessor ends: route around,
          // dropping into the gap between the rows.
          final gapY =
              fromY < toY ? fromY + rowHeight / 2 : fromY - rowHeight / 2;
          path
            ..lineTo(fromX + _stub, fromY)
            ..lineTo(fromX + _stub, gapY)
            ..lineTo(toX - _stub, gapY)
            ..lineTo(toX - _stub, toY)
            ..lineTo(toX, toY);
        }
        canvas.drawPath(path, line);
        canvas.drawPath(
          Path()
            ..moveTo(toX, toY)
            ..lineTo(toX - _head, toY - _head * 0.7)
            ..lineTo(toX - _head, toY + _head * 0.7)
            ..close(),
          head,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_DependencyPainter old) =>
      old.rows != rows ||
      old.scale.width != scale.width ||
      old.preview != preview ||
      old.color != color;
}

class _AxisPainter extends CustomPainter {
  const _AxisPainter({
    required this.scale,
    required this.unit,
    required this.color,
    required this.textColor,
  });

  final _Scale scale;
  final Duration unit;
  final Color color;
  final Color textColor;

  /// A unit shorter than a day names a point in time; a day or longer
  /// names a span. The label goes where the thing it names is: beside the
  /// tick for a point, centred in the cell for a span — over the bar it
  /// dates, the way every calendar and gantt reads.
  bool get _spans => unit >= const Duration(days: 1);

  String _labelFor(DateTime t) {
    if (_spans) return '${t.month}/${t.day}';
    // A point scale reads the hour, and the date where the day turns.
    final hour = '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
    return t.hour == 0 && t.minute == 0 ? '${t.month}/${t.day} $hour' : hour;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    var t = scale.from;
    double? lastLabelRight;
    while (t.isBefore(scale.to)) {
      final x = scale.xOf(t);
      final next = t.add(unit);
      canvas.drawRect(Rect.fromLTWH(x, 0, 1, size.height), paint);
      final label = TextPainter(
        text: TextSpan(
          text: _labelFor(t),
          style: TextStyle(fontSize: 10, color: textColor),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final cellWidth = scale.xOf(next) - x;
      final left = _spans ? x + (cellWidth - label.width) / 2 : x + 2;
      // A label that would sit on the previous one is dropped, not drawn
      // over it: a dense scale shows fewer dates rather than unreadable ones.
      if (lastLabelRight == null || left > lastLabelRight + 4) {
        label.paint(canvas, Offset(left, 2));
        lastLabelRight = left + label.width;
      }
      t = next;
    }
    // Ticks sit on cell boundaries, the last one included.
    canvas.drawRect(
        Rect.fromLTWH(scale.xOf(scale.to), 0, 1, size.height), paint);
  }

  @override
  bool shouldRepaint(_AxisPainter old) =>
      old.scale.width != scale.width || old.unit != unit;
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.task,
    required this.scale,
    required this.editable,
    required this.showProgress,
    required this.onTap,
    required this.onDrag,
    required this.onDragEnd,
    this.preview,
  });

  final _Task task;
  final _Scale scale;
  final bool editable;
  final bool showProgress;

  /// Local schedule shown while a drag is in flight; the task's own dates
  /// remain the truth until the author's action applies a change.
  final ({DateTime start, DateTime end})? preview;
  final VoidCallback onTap;
  final void Function(DateTime, DateTime) onDrag;
  final void Function(DateTime, DateTime) onDragEnd;

  @override
  Widget build(BuildContext context) {
    final start = preview?.start ?? task.start;
    final end = preview?.end ?? task.end;
    final left = scale.xOf(start);
    // A task shorter than a pixel still renders — dropping it would hide work
    // that exists.
    final width = (scale.xOf(end) - left).clamp(2.0, scale.width);
    final scheme = Theme.of(context).colorScheme;

    // The task's own colour when it named one; the scheme otherwise. The
    // completed fraction is the bar's colour and the remainder its lighter
    // tint — the reading every gantt tool trains: dark is done. It was the
    // other way round, and a 30 % task read as 70 % complete.
    final barColor = task.color ?? scheme.primary;
    final remainingColor = task.color == null
        ? scheme.primaryContainer
        : Color.lerp(barColor, Colors.white, 0.55) ?? barColor;
    final showFill = showProgress && task.progress != null;

    Widget bar = Container(
      decoration: BoxDecoration(
        color: showFill ? remainingColor : barColor,
        borderRadius: BorderRadius.circular(3),
      ),
      child: showFill
          ? FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: task.progress!.clamp(0, 1),
              child: Container(
                decoration: BoxDecoration(
                  color: barColor,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            )
          : null,
    );

    if (editable) {
      bar = GestureDetector(
        onTap: onTap,
        onHorizontalDragUpdate: (d) {
          final shift =
              scale.timeAt(scale.xOf(start) + d.delta.dx).difference(start);
          onDrag(start.add(shift), end.add(shift));
        },
        onHorizontalDragEnd: (_) => onDragEnd(start, end),
        child: bar,
      );
    } else {
      bar = GestureDetector(onTap: onTap, child: bar);
    }

    return Stack(
      children: [
        Positioned(left: left, width: width, top: 6, bottom: 6, child: bar),
      ],
    );
  }
}
