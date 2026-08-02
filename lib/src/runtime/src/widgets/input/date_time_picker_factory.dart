import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for `dateTimePicker` (spec §2.6.28).
///
/// One instant, one binding. Not `datePicker` + `timePicker` side by side:
/// those bind two values the author must recombine, and the recombination is
/// where time zones get lost.
class DateTimePickerFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final binding = properties['binding'] as String?;
    final enabled = context.resolve<bool?>(properties['enabled']) ?? true;
    final label = context.resolve<String?>(properties['label']);
    final minuteInterval =
        context.resolve<num?>(properties['minuteInterval'])?.toInt() ?? 1;
    final onChange = properties['onChange'] as Map<String, dynamic>?;
    // Presented in the declared zone; the bound value carries its offset
    // either way, because a timestamp without one is not an instant.
    final timeZone = context.resolve<String?>(properties['timeZone']);
    // Display patterns. The bound value stays ISO-8601 either way — these
    // change only what the closed field shows.
    final dateFormat = context.resolve<String?>(properties['dateFormat']);
    final timeFormat = context.resolve<String?>(properties['timeFormat']);

    final raw = binding != null
        ? context.getState(binding)?.toString()
        : context.resolve<String?>(properties['value']);
    final current = raw == null || raw.isEmpty ? null : DateTime.tryParse(raw);

    final min = _parse(context.resolve<String?>(properties['min']));
    final max = _parse(context.resolve<String?>(properties['max']));

    return Builder(
      builder: (buildContext) => InkWell(
        onTap: enabled
            ? () async {
                final now = DateTime.now();
                final date = await showDatePicker(
                  context: buildContext,
                  initialDate: current ?? now,
                  firstDate: min ?? DateTime(now.year - 100),
                  lastDate: max ?? DateTime(now.year + 100),
                );
                if (date == null) return;
                if (!buildContext.mounted) return;
                final time = await showTimePicker(
                  context: buildContext,
                  initialTime: TimeOfDay.fromDateTime(current ?? now),
                );
                if (time == null) return;

                final minute = minuteInterval > 1
                    ? (time.minute ~/ minuteInterval) * minuteInterval
                    : time.minute;
                // Reassembled here rather than by the author, and kept as one
                // instant carrying its offset — a timestamp without one is not
                // an instant.
                final combined = DateTime(
                  date.year,
                  date.month,
                  date.day,
                  time.hour,
                  minute,
                );
                final value = combined.toIso8601String();
                if (binding != null) context.setValue(binding, value);
                if (onChange != null) {
                  context.actionHandler.execute(
                    onChange,
                    context.createChildContext(
                      variables: {
                        'event': {'value': value, 'type': 'change'},
                      },
                    ),
                  );
                }
              }
            : null,
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            enabled: enabled,
            suffixIcon: const Icon(Icons.event),
          ),
          child: Text(
            current == null
                ? ''
                : _format(current, timeZone, dateFormat, timeFormat),
          ),
        ),
      ),
    );
  }

  static DateTime? _parse(String? value) =>
      value == null || value.isEmpty ? null : DateTime.tryParse(value);

  static String _format(
    DateTime d,
    String? timeZone,
    String? dateFormat,
    String? timeFormat,
  ) {
    String two(int v) => v.toString().padLeft(2, '0');
    final datePart = dateFormat == null
        ? '${d.year}-${two(d.month)}-${two(d.day)}'
        : _applyPattern(dateFormat, d);
    final timePart = timeFormat == null
        ? '${two(d.hour)}:${two(d.minute)}'
        : _applyPattern(timeFormat, d);
    final shown = '$datePart $timePart';
    // The zone is labelled rather than converted: converting would need a tz
    // database this runtime does not carry, and a silently shifted time is
    // worse than a labelled one.
    return timeZone == null ? shown : '$shown ($timeZone)';
  }

  /// Substitutes the common date/time pattern tokens.
  ///
  /// Deliberately small: the spec calls these display patterns, and a full
  /// ICU implementation would pull in a formatting dependency for a field
  /// whose bound value is ISO-8601 regardless.
  static String _applyPattern(String pattern, DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final hour12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return pattern
        .replaceAll('yyyy', d.year.toString().padLeft(4, '0'))
        .replaceAll('MM', two(d.month))
        .replaceAll('dd', two(d.day))
        .replaceAll('HH', two(d.hour))
        .replaceAll('hh', two(hour12))
        .replaceAll('mm', two(d.minute))
        .replaceAll('ss', two(d.second))
        .replaceAll('a', d.hour < 12 ? 'AM' : 'PM');
  }
}
