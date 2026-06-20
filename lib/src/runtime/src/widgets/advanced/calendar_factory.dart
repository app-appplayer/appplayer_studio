import 'package:flutter/material.dart';
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Calendar widgets (Advanced conformance level)
/// Implements month, week, and day views using GridView
class CalendarWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract calendar properties
    final view = context.resolve<String>(properties['view'] ?? 'month');
    final selectedDateStr = context.resolve<String?>(properties['selectedDate']);
    final events = context.resolve<List<dynamic>>(properties['events'] ?? [])
            as List<dynamic>? ??
        [];
    final showHeader = context.resolve<bool>(properties['showHeader'] ?? true);
    final showWeekNumbers =
        context.resolve<bool>(properties['showWeekNumbers'] ?? false);
    final firstDayOfWeek =
        context.resolve<int>(properties['firstDayOfWeek'] ?? 0);
    final width = context.resolve<double?>(properties['width']);
    final height = context.resolve<double?>(properties['height']) ?? 400.0;

    // Extract colors — theme-adaptive defaults. Today/selected/event
    // previously pinned to hardcoded Material-2 blues / red which clashed
    // with dark surfaces and non-blue brand palettes.
    final primaryColor =
        parseColor(context.resolve(properties['primaryColor']), context) ??
            context.themeManager.getColorValue('primary') ??
            Colors.blue;
    final todayColor =
        parseColor(context.resolve(properties['todayColor']), context) ??
            (context.themeManager
                .getColorValue('primary')
                ?.withValues(alpha: 0.15)) ??
            Colors.blue.shade100;
    final selectedColor =
        parseColor(context.resolve(properties['selectedColor']), context) ??
            context.themeManager.getColorValue('primary') ??
            Colors.blue.shade700;
    final eventColor =
        parseColor(context.resolve(properties['eventColor']), context) ??
            context.themeManager.getColorValue('error') ??
            Colors.red;
    // Default to the theme's surface slot so an unset backgroundColor
    // adapts to dark mode. Previously this was a hardcoded
    // `Colors.white` which made the calendar a bright white block on
    // dark scaffolds.
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context) ??
            context.themeManager.getColorValue('surface') ??
            Colors.white;

    // Extract date range constraints
    final firstDateStr =
        context.resolve<String?>(properties['firstDate']);
    final lastDateStr =
        context.resolve<String?>(properties['lastDate']);
    DateTime? firstDate;
    DateTime? lastDate;
    if (firstDateStr != null) {
      try {
        firstDate = DateTime.parse(firstDateStr);
      } catch (_) {
        // Ignore invalid date
      }
    }
    if (lastDateStr != null) {
      try {
        lastDate = DateTime.parse(lastDateStr);
      } catch (_) {
        // Ignore invalid date
      }
    }

    // on + PascalCase optimal, legacy short names as fallback
    final onDateSelect = (properties['onDateSelect'] ??
        properties['onChange'] ?? properties['change']) as Map<String, dynamic>?;
    final onMonthChange = properties['onMonthChange'] as Map<String, dynamic>?;

    // Parse selected date
    DateTime selectedDate;
    if (selectedDateStr != null) {
      try {
        selectedDate = DateTime.parse(selectedDateStr);
      } catch (_) {
        selectedDate = DateTime.now();
      }
    } else {
      selectedDate = DateTime.now();
    }

    // Parse events
    final parsedEvents = _parseEvents(events);

    // Build calendar widget
    Widget calendar = _CalendarWidget(
      view: view,
      selectedDate: selectedDate,
      events: parsedEvents,
      showHeader: showHeader,
      showWeekNumbers: showWeekNumbers,
      firstDayOfWeek: firstDayOfWeek,
      primaryColor: primaryColor,
      todayColor: todayColor,
      selectedColor: selectedColor,
      eventColor: eventColor,
      backgroundColor: backgroundColor,
      firstDate: firstDate,
      lastDate: lastDate,
      onDateSelect: onDateSelect,
      onMonthChange: onMonthChange,
      context: context,
    );

    calendar = SizedBox(
      width: width,
      height: height,
      child: calendar,
    );

    return applyCommonWrappers(calendar, properties, context);
  }

  List<CalendarEvent> _parseEvents(List<dynamic> events) {
    final List<CalendarEvent> parsed = [];

    for (var event in events) {
      if (event is Map) {
        final dateStr = event['date']?.toString();
        if (dateStr != null) {
          try {
            final date = DateTime.parse(dateStr);
            parsed.add(CalendarEvent(
              date: date,
              title: event['title']?.toString() ?? '',
              color: event['color']?.toString(),
            ));
          } catch (_) {
            // Skip invalid dates
          }
        }
      }
    }

    return parsed;
  }
}

/// Calendar event data
class CalendarEvent {
  final DateTime date;
  final String title;
  final String? color;

  CalendarEvent({
    required this.date,
    required this.title,
    this.color,
  });
}

/// Stateful calendar widget
class _CalendarWidget extends StatefulWidget {
  final String view;
  final DateTime selectedDate;
  final List<CalendarEvent> events;
  final bool showHeader;
  final bool showWeekNumbers;
  final int firstDayOfWeek;
  final Color primaryColor;
  final Color todayColor;
  final Color selectedColor;
  final Color eventColor;
  final Color backgroundColor;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final Map<String, dynamic>? onDateSelect;
  final Map<String, dynamic>? onMonthChange;
  final RenderContext context;

  const _CalendarWidget({
    required this.view,
    required this.selectedDate,
    required this.events,
    required this.showHeader,
    required this.showWeekNumbers,
    required this.firstDayOfWeek,
    required this.primaryColor,
    required this.todayColor,
    required this.selectedColor,
    required this.eventColor,
    required this.backgroundColor,
    this.firstDate,
    this.lastDate,
    this.onDateSelect,
    this.onMonthChange,
    required this.context,
  });

  @override
  State<_CalendarWidget> createState() => _CalendarWidgetState();
}

class _CalendarWidgetState extends State<_CalendarWidget> {
  late DateTime _currentMonth;
  late DateTime _selectedDate;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.selectedDate;
    _currentMonth = DateTime(_selectedDate.year, _selectedDate.month, 1);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: widget.backgroundColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        children: [
          if (widget.showHeader) _buildHeader(),
          _buildWeekDays(),
          Expanded(
            child: _buildCalendarBody(),
          ),
        ],
      ),
    );
  }

  /// Foreground text/icon color that reads against the calendar's
  /// `backgroundColor`. In-month day numbers, weekday labels and
  /// heading text all adapt to light/dark automatically — previously
  /// these were hardcoded to `Colors.black87` which vanished when the
  /// DSL author set `backgroundColor: surface` in dark mode.
  Color _onSurface(BuildContext context) =>
      Theme.of(context).colorScheme.onSurface;

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: widget.primaryColor.withValues(alpha: 0.1),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(7),
          topRight: Radius.circular(7),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: _previousMonth,
            color: widget.primaryColor,
          ),
          Text(
            _formatMonth(_currentMonth),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: widget.primaryColor,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: _nextMonth,
            color: widget.primaryColor,
          ),
        ],
      ),
    );
  }

  Widget _buildWeekDays() {
    final weekDays = _getWeekDayNames();
    final muted = _onSurface(context).withValues(alpha: 0.6);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          if (widget.showWeekNumbers)
            SizedBox(
              width: 32,
              child: Text(
                '#',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: muted,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ...weekDays.map((day) => Expanded(
                child: Text(
                  day,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildCalendarBody() {
    switch (widget.view.toLowerCase()) {
      case 'week':
        return _buildWeekView();
      case 'day':
        return _buildDayView();
      case 'month':
      default:
        return _buildMonthView();
    }
  }

  Widget _buildMonthView() {
    final days = _getDaysInMonth();
    final today = DateTime.now();

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        childAspectRatio: 1.0,
        crossAxisSpacing: 2,
        mainAxisSpacing: 2,
      ),
      itemCount: days.length,
      itemBuilder: (context, index) {
        final day = days[index];
        if (day == null) {
          return const SizedBox();
        }

        final isToday = _isSameDay(day, today);
        final isSelected = _isSameDay(day, _selectedDate);
        final isCurrentMonth = day.month == _currentMonth.month;
        final hasEvents = _hasEvents(day);

        return InkWell(
          onTap: () => _selectDate(day),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              color: isSelected
                  ? widget.selectedColor
                  : isToday
                      ? widget.todayColor
                      : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Text(
                  '${day.day}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: isToday || isSelected ? FontWeight.bold : null,
                    color: isSelected
                        ? Colors.white
                        : isCurrentMonth
                            ? _onSurface(context)
                            : _onSurface(context).withValues(alpha: 0.4),
                  ),
                ),
                if (hasEvents)
                  Positioned(
                    bottom: 4,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: isSelected ? Colors.white : widget.eventColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildWeekView() {
    final weekStart = _getWeekStart(_selectedDate);
    final days = List.generate(7, (i) => weekStart.add(Duration(days: i)));
    final today = DateTime.now();

    return Column(
      children: [
        // Week day headers with dates
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: days.map((day) {
              final isToday = _isSameDay(day, today);
              final isSelected = _isSameDay(day, _selectedDate);

              return Expanded(
                child: InkWell(
                  onTap: () => _selectDate(day),
                  child: Column(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? widget.selectedColor
                              : isToday
                                  ? widget.todayColor
                                  : null,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text(
                            '${day.day}',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight:
                                  isToday || isSelected ? FontWeight.bold : null,
                              color: isSelected
                                  ? Colors.white
                                  : _onSurface(context),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const Divider(height: 1),
        // Events for the week
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(8),
            children: days.expand((day) {
              final dayEvents = _getEventsForDay(day);
              return dayEvents.map((event) => _buildEventCard(event, day));
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildDayView() {
    final events = _getEventsForDay(_selectedDate);
    final today = DateTime.now();
    final isToday = _isSameDay(_selectedDate, today);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Selected date header
        Container(
          padding: const EdgeInsets.all(16),
          color: widget.primaryColor.withValues(alpha: 0.05),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: isToday ? widget.todayColor : widget.primaryColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Text(
                    '${_selectedDate.day}',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: isToday ? widget.primaryColor : Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _getWeekDayName(_selectedDate.weekday),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: _onSurface(context),
                    ),
                  ),
                  Text(
                    _formatFullDate(_selectedDate),
                    style: TextStyle(
                      fontSize: 14,
                      color: _onSurface(context).withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Events list
        Expanded(
          child: events.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.event_available,
                        size: 48,
                        color: _onSurface(context).withValues(alpha: 0.3),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'No events',
                        style: TextStyle(
                          color: _onSurface(context).withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: events.length,
                  itemBuilder: (context, index) =>
                      _buildEventCard(events[index], _selectedDate),
                ),
        ),
      ],
    );
  }

  Widget _buildEventCard(CalendarEvent event, DateTime day) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Container(
          width: 4,
          height: 40,
          decoration: BoxDecoration(
            color: widget.eventColor,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        title: Text(event.title),
        subtitle: Text(_formatFullDate(day)),
      ),
    );
  }

  List<DateTime?> _getDaysInMonth() {
    final firstDay = DateTime(_currentMonth.year, _currentMonth.month, 1);
    final lastDay = DateTime(_currentMonth.year, _currentMonth.month + 1, 0);

    // Adjust for first day of week
    int startWeekday = firstDay.weekday - widget.firstDayOfWeek;
    if (startWeekday < 0) startWeekday += 7;

    final List<DateTime?> days = [];

    // Add padding for days before the first of the month
    for (int i = 0; i < startWeekday; i++) {
      final prevDay = firstDay.subtract(Duration(days: startWeekday - i));
      days.add(prevDay);
    }

    // Add all days of the current month
    for (int i = 0; i < lastDay.day; i++) {
      days.add(DateTime(_currentMonth.year, _currentMonth.month, i + 1));
    }

    // Add padding for days after the last of the month
    final remainingDays = (7 - (days.length % 7)) % 7;
    for (int i = 0; i < remainingDays; i++) {
      days.add(lastDay.add(Duration(days: i + 1)));
    }

    return days;
  }

  DateTime _getWeekStart(DateTime date) {
    int daysFromStart = date.weekday - widget.firstDayOfWeek;
    if (daysFromStart < 0) daysFromStart += 7;
    return DateTime(date.year, date.month, date.day - daysFromStart);
  }

  List<String> _getWeekDayNames() {
    const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    final result = <String>[];
    for (int i = 0; i < 7; i++) {
      result.add(days[(widget.firstDayOfWeek + i) % 7]);
    }
    return result;
  }

  String _getWeekDayName(int weekday) {
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday'
    ];
    return days[weekday - 1];
  }

  String _formatMonth(DateTime date) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December'
    ];
    return '${months[date.month - 1]} ${date.year}';
  }

  String _formatFullDate(DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  bool _hasEvents(DateTime day) {
    return widget.events.any((event) => _isSameDay(event.date, day));
  }

  List<CalendarEvent> _getEventsForDay(DateTime day) {
    return widget.events.where((event) => _isSameDay(event.date, day)).toList();
  }

  void _selectDate(DateTime date) {
    // Enforce firstDate/lastDate constraints
    if (widget.firstDate != null && date.isBefore(widget.firstDate!)) return;
    if (widget.lastDate != null && date.isAfter(widget.lastDate!)) return;

    setState(() {
      _selectedDate = date;
      if (date.month != _currentMonth.month) {
        _currentMonth = DateTime(date.year, date.month, 1);
      }
    });

    if (widget.onDateSelect != null) {
      final eventContext = widget.context.createChildContext(
        variables: {
          'event': {
            'date': date.toIso8601String(),
            'year': date.year,
            'month': date.month,
            'day': date.day,
          },
        },
      );
      widget.context.actionHandler.execute(widget.onDateSelect!, eventContext);
    }
  }

  void _previousMonth() {
    final newMonth =
        DateTime(_currentMonth.year, _currentMonth.month - 1, 1);
    // Enforce firstDate constraint on month navigation
    if (widget.firstDate != null) {
      final firstMonthStart =
          DateTime(widget.firstDate!.year, widget.firstDate!.month, 1);
      if (newMonth.isBefore(firstMonthStart)) return;
    }
    setState(() {
      _currentMonth = newMonth;
    });
    _notifyMonthChange();
  }

  void _nextMonth() {
    final newMonth =
        DateTime(_currentMonth.year, _currentMonth.month + 1, 1);
    // Enforce lastDate constraint on month navigation
    if (widget.lastDate != null) {
      final lastMonthStart =
          DateTime(widget.lastDate!.year, widget.lastDate!.month, 1);
      if (newMonth.isAfter(lastMonthStart)) return;
    }
    setState(() {
      _currentMonth = newMonth;
    });
    _notifyMonthChange();
  }

  void _notifyMonthChange() {
    if (widget.onMonthChange != null) {
      final eventContext = widget.context.createChildContext(
        variables: {
          'event': {
            'year': _currentMonth.year,
            'month': _currentMonth.month,
          },
        },
      );
      widget.context.actionHandler.execute(widget.onMonthChange!, eventContext);
    }
  }
}
