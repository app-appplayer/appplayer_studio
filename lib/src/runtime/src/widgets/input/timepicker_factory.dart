import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for TimePicker widgets (as a button that shows time picker)
class TimePickerWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final label = properties['label'] != null
        ? context.resolve<String>(properties['label'])
        : 'Select Time';
    final initialTime = properties['initialTime'] != null
        ? (_parseTimeOfDay(properties['initialTime']) ?? TimeOfDay.now())
        : TimeOfDay.now();
    final timeFormat = properties['timeFormat'] as String? ?? 'HH:mm';
    final variant = properties['variant'] as String? ?? 'elevated';
    final icon = properties['icon'] as String? ?? 'access_time';
    final use24HourFormat = properties['use24HourFormat'] as bool? ?? true;

    // Spec §2.6.0: canonical `binding`; accept legacy `bindTo` alias.
    final binding = (properties['binding'] as String?) ??
        (properties['bindTo'] as String?);
    String? currentValue;
    if (binding != null) {
      currentValue = context.getValue(binding) as String?;
    } else if (properties['value'] != null) {
      currentValue = context.resolve<String?>(properties['value']);
    }

    // Extract action handler
    final onChange = (properties['onChange'] ?? properties['change']) as Map<String, dynamic>?;

    Widget timePicker = StatefulBuilder(
      builder: (buildContext, setState) {
        TimeOfDay? selectedTime;
        if (currentValue != null) {
          selectedTime = _parseTimeOfDay(currentValue);
        }

        return _buildButton(
          variant: variant,
          label: selectedTime != null
              ? _formatTime(selectedTime, timeFormat, use24HourFormat)
              : label,
          icon: _parseIcon(icon),
          onPressed: () async {
            final picked = await showTimePicker(
              context: buildContext,
              initialTime: initialTime,
              builder: (dialogContext, child) {
                if (!use24HourFormat) {
                  return child!;
                }
                return MediaQuery(
                  data: MediaQuery.of(dialogContext).copyWith(
                    alwaysUse24HourFormat: true,
                  ),
                  child: child!,
                );
              },
            );

            if (picked != null) {
              final formattedTime =
                  _formatTime(picked, timeFormat, use24HourFormat);

              if (binding != null) {
                context.setValue(binding, formattedTime);
              }

              // Execute onChange action
              if (onChange != null) {
                final eventData = Map<String, dynamic>.from(onChange);
                if (eventData['value'] == '{{event.value}}') {
                  eventData['value'] = formattedTime;
                }
                context.actionHandler.execute(eventData, context);
              }

              setState(() {
                selectedTime = picked;
              });
            }
          },
        );
      },
    );

    return applyCommonWrappers(timePicker, properties, context);
  }

  Widget _buildButton({
    required String variant,
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    switch (variant) {
      case 'elevated':
        return ElevatedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
        );
      case 'outlined':
        return OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
        );
      case 'text':
        return TextButton.icon(
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
        );
      default:
        return IconButton(
          onPressed: onPressed,
          icon: Icon(icon),
          tooltip: label,
        );
    }
  }

  TimeOfDay? _parseTimeOfDay(String time) {
    try {
      final parts = time.split(':');
      if (parts.length >= 2) {
        return TimeOfDay(
          hour: int.parse(parts[0]),
          minute: int.parse(parts[1]),
        );
      }
    } catch (e) {
      // Invalid time format
    }
    return null;
  }

  String _formatTime(TimeOfDay time, String format, bool use24Hour) {
    if (use24Hour) {
      return format
          .replaceAll('HH', time.hour.toString().padLeft(2, '0'))
          .replaceAll('mm', time.minute.toString().padLeft(2, '0'));
    } else {
      final hour = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
      final period = time.period == DayPeriod.am ? 'AM' : 'PM';
      return format
          .replaceAll('hh', hour.toString().padLeft(2, '0'))
          .replaceAll('mm', time.minute.toString().padLeft(2, '0'))
          .replaceAll('a', period);
    }
  }

  IconData _parseIcon(String? icon) {
    switch (icon) {
      case 'access_time':
        return Icons.access_time;
      case 'schedule':
        return Icons.schedule;
      case 'alarm':
        return Icons.alarm;
      default:
        return Icons.access_time;
    }
  }
}
