import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for creating time field widgets
class TimeFieldFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final label = stringOf(properties['label'], context);
    final binding = stringOf(properties['binding'], context);
    final errorText = context.resolve(properties['errorText']) as String?;
    final enabled = context.resolve(properties['enabled'] ?? true) as bool;
    final use24HourFormat = boolOf(properties['use24HourFormat'], context) ?? false;
    // Spec §2.6.14: `format` controls displayed string (HH:mm default);
    // `mode` switches picker style.
    final formatStr = readEnum(properties['format'], context) ?? 'HH:mm';
    final modeStr = readEnum(properties['mode'], context) ?? 'spinner';

    // Get current value
    String? currentValue;
    if (binding != null) {
      final value = context.resolve("{{$binding}}");
      currentValue = value?.toString();
    }

    final controller = TextEditingController(text: currentValue ?? '');

    Widget timeField = GestureDetector(
      onTap: enabled
          ? () async {
              // Parse current time
              TimeOfDay? initialTime;
              if (currentValue != null && currentValue.isNotEmpty) {
                try {
                  final parts = currentValue.split(':');
                  if (parts.length >= 2) {
                    final hour = int.parse(parts[0]);
                    final minute = int.parse(parts[1]);
                    initialTime = TimeOfDay(hour: hour, minute: minute);
                  }
                } catch (e) {
                  // Invalid time
                }
              }
              initialTime ??= TimeOfDay.now();

              final pickedTime = await showTimePicker(
                context: context.buildContext!,
                initialTime: initialTime,
                // `spinner` and `dial` are the same Material surface (the
                // clock face); `input` is the keyboard entry form. Named
                // rather than left as an else-branch so the declared value
                // is visible in the implementation.
                initialEntryMode: switch (modeStr) {
                  'input' => TimePickerEntryMode.input,
                  'dial' => TimePickerEntryMode.dial,
                  _ => TimePickerEntryMode.dial,
                },
                builder: (context, child) {
                  if (!use24HourFormat) return child!;

                  return MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(alwaysUse24HourFormat: true),
                    child: child!,
                  );
                },
              );

              if (pickedTime != null && binding != null) {
                final formattedTime = _applyTimeFormat(formatStr, pickedTime);
                context.setValue(binding, formattedTime);
                controller.text = formattedTime;
              }
            }
          : null,
      child: AbsorbPointer(
        child: TextField(
          controller: controller,
          enabled: enabled,
          decoration: InputDecoration(
            labelText: label,
            errorText: errorText,
            suffixIcon: const Icon(Icons.access_time),
          ),
        ),
      ),
    );

    return applyCommonWrappers(timeField, properties, context);
  }

  /// Basic time-format subset: HH/H (24-h), hh/h (12-h), mm/m, a (AM/PM).
  static String _applyTimeFormat(String format, TimeOfDay t) {
    final hour24 = t.hour;
    final hour12 = (t.hour % 12 == 0) ? 12 : t.hour % 12;
    final period = t.period == DayPeriod.am ? 'AM' : 'PM';
    return format
        .replaceAll('HH', hour24.toString().padLeft(2, '0'))
        .replaceAll('hh', hour12.toString().padLeft(2, '0'))
        .replaceAll('mm', t.minute.toString().padLeft(2, '0'))
        .replaceAll('H', hour24.toString())
        .replaceAll('h', hour12.toString())
        .replaceAll('m', t.minute.toString())
        .replaceAll('a', period);
  }
}
