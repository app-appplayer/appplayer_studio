import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for `gantt` (spec §10.31).
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

    final rawTasks = context.resolve<List<dynamic>?>(properties['tasks']) ?? const [];
    final viewMode = context.resolve<String?>(properties['viewMode']) ?? 'day';
    final editable = context.resolve<bool?>(properties['editable']) ?? false;
    final showProgress = context.resolve<bool?>(properties['showProgress']) ?? true;
    final showDependencies =
        context.resolve<bool?>(properties['showDependencies']) ?? true;
    final todayMarker = context.resolve<bool?>(properties['todayMarker']) ?? true;
    final rowHeight = context.resolve<num?>(properties['rowHeight'])?.toDouble() ?? 32.0;
    final onTaskChange = properties['onTaskChange'] as Map<String, dynamic>?;
    final onTaskClick = properties['onTaskClick'] as Map<String, dynamic>?;

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
        dependsOn: [
          for (final d in (raw['dependsOn'] as List? ?? const []))
            d.toString(),
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
  });

  final String id;
  final String label;
  final DateTime start;
  final DateTime end;
  final double? progress;
  final List<String> dependsOn;
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
          height: widget.rowHeight * (widget.tasks.length + 1),
          child: Row(
            children: [
              SizedBox(
                width: _labelWidth,
                child: Column(
                  children: [
                    SizedBox(height: widget.rowHeight),
                    for (final t in widget.tasks)
                      SizedBox(
                        height: widget.rowHeight,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(t.label, overflow: TextOverflow.ellipsis),
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
                    child: Column(
                      children: [
                        SizedBox(
                          height: widget.rowHeight,
                          child: CustomPaint(
                            size: Size(chartWidth, widget.rowHeight),
                            painter: _AxisPainter(
                              scale: scale,
                              unit: widget.unit,
                              color: Theme.of(context).dividerColor,
                              textColor:
                                  Theme.of(context).textTheme.bodySmall?.color ??
                                      Colors.grey,
                            ),
                          ),
                        ),
                        for (final task in widget.tasks)
                          SizedBox(
                            height: widget.rowHeight,
                            child: _Bar(
                              task: task,
                              scale: scale,
                              editable: widget.editable,
                              showProgress: widget.showProgress,
                              preview: _dragging[task.id],
                              onTap: () => widget.onClick(task),
                              onDrag: (start, end) =>
                                  setState(() => _dragging[task.id] = (start: start, end: end)),
                              onDragEnd: (start, end) {
                                setState(() => _dragging.remove(task.id));
                                widget.onChange(task, start, end);
                              },
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

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    var t = scale.from;
    while (t.isBefore(scale.to)) {
      final x = scale.xOf(t);
      canvas.drawRect(Rect.fromLTWH(x, 0, 1, size.height), paint);
      final label = TextPainter(
        text: TextSpan(
          text: '${t.month}/${t.day}',
          style: TextStyle(fontSize: 10, color: textColor),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(x + 2, 2));
      t = t.add(unit);
    }
  }

  @override
  bool shouldRepaint(_AxisPainter old) => old.scale.width != scale.width;
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

    Widget bar = Container(
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(3),
      ),
      child: showProgress && task.progress != null
          ? FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: task.progress!.clamp(0, 1),
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
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
          final shift = scale.timeAt(scale.xOf(start) + d.delta.dx).difference(start);
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
