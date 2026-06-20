import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for DatePicker widgets (as a button that shows date picker)
class DatePickerWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final label = properties['label'] != null
        ? context.resolve<String>(properties['label'])
        : 'Select Date';
    final initialDate = properties['initialDate'] != null
        ? DateTime.parse(properties['initialDate'])
        : DateTime.now();
    final firstDate = properties['firstDate'] != null
        ? DateTime.parse(properties['firstDate'])
        : DateTime(1900);
    final lastDate = properties['lastDate'] != null
        ? DateTime.parse(properties['lastDate'])
        : DateTime(2100);
    final dateFormat = properties['dateFormat'] as String? ?? 'yyyy-MM-dd';
    final variant = properties['variant'] as String? ?? 'elevated';
    final icon = properties['icon'] as String? ?? 'calendar_today';

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

    Widget datePicker = StatefulBuilder(
      builder: (buildContext, setState) {
        DateTime? selectedDate;
        if (currentValue != null) {
          try {
            selectedDate = DateTime.parse(currentValue);
          } catch (e) {
            // Invalid date format
          }
        }

        return _buildButton(
          variant: variant,
          label: selectedDate != null
              ? _formatDate(selectedDate, dateFormat)
              : label,
          icon: _parseIcon(icon),
          onPressed: () async {
            final picked = await showDatePicker(
              context: buildContext,
              initialDate: selectedDate ?? initialDate,
              firstDate: firstDate,
              lastDate: lastDate,
            );

            if (picked != null) {
              final formattedDate = _formatDate(picked, dateFormat);

              if (binding != null) {
                context.setValue(binding, formattedDate);
              }

              // Execute onChange action
              if (onChange != null) {
                final eventData = Map<String, dynamic>.from(onChange);
                if (eventData['value'] == '{{event.value}}') {
                  eventData['value'] = formattedDate;
                }
                context.actionHandler.execute(eventData, context);
              }

              setState(() {
                selectedDate = picked;
              });
            }
          },
        );
      },
    );

    return applyCommonWrappers(datePicker, properties, context);
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

  String _formatDate(DateTime date, String format) {
    // Simple date formatting
    return format
        .replaceAll('yyyy', date.year.toString().padLeft(4, '0'))
        .replaceAll('MM', date.month.toString().padLeft(2, '0'))
        .replaceAll('dd', date.day.toString().padLeft(2, '0'));
  }

  IconData _parseIcon(String? icon) {
    switch (icon) {
      case 'calendar_today':
        return Icons.calendar_today;
      case 'event':
        return Icons.event;
      case 'date_range':
        return Icons.date_range;
      default:
        return Icons.calendar_today;
    }
  }
}
