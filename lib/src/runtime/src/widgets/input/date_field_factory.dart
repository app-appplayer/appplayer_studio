import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for creating date field widgets
class DateFieldFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final label = properties['label'] as String?;
    final binding = properties['binding'] as String?;
    final errorText = context.resolve(properties['errorText']) as String?;
    final enabled = context.resolve(properties['enabled'] ?? true) as bool;
    // Spec §2.6.13: `format` controls displayed date string; `mode` chooses
    // between calendar dialog and input, `locale` for localization.
    final formatStr = (properties['format'] as String?) ?? 'yyyy-MM-dd';
    final modeStr = (properties['mode'] as String?) ?? 'calendar';
    final localeStr = properties['locale'] as String?;

    // Parse date constraints
    final firstDateStr = properties['firstDate'] as String?;
    final lastDateStr = properties['lastDate'] as String?;

    DateTime? firstDate;
    DateTime? lastDate;

    try {
      if (firstDateStr != null) {
        firstDate = DateTime.parse(firstDateStr);
      }
      if (lastDateStr != null) {
        lastDate = DateTime.parse(lastDateStr);
      }
    } catch (e) {
      // Use defaults if parsing fails
    }

    firstDate ??= DateTime(1900);
    lastDate ??= DateTime(2100);

    // Get current value
    String? currentValue;
    if (binding != null) {
      final value = context.resolve("{{$binding}}");
      currentValue = value?.toString();
    }

    final controller = TextEditingController(text: currentValue ?? '');

    Widget dateField = GestureDetector(
      onTap: enabled
          ? () async {
              // Parse current date
              DateTime? initialDate;
              if (currentValue != null && currentValue.isNotEmpty) {
                try {
                  initialDate = DateTime.parse(currentValue);
                } catch (e) {
                  // Invalid date
                }
              }
              initialDate ??= DateTime.now();

              // Ensure initial date is within range
              if (initialDate.isBefore(firstDate!)) {
                initialDate = firstDate;
              } else if (initialDate.isAfter(lastDate!)) {
                initialDate = lastDate;
              }

              final pickedDate = await showDatePicker(
                context: context.buildContext!,
                initialDate: initialDate,
                firstDate: firstDate,
                lastDate: lastDate!,
                initialEntryMode: modeStr == 'input'
                    ? DatePickerEntryMode.input
                    : DatePickerEntryMode.calendar,
                locale:
                    localeStr != null ? Locale(localeStr) : null,
              );

              if (pickedDate != null && binding != null) {
                final formattedDate = _applyDateFormat(formatStr, pickedDate);
                context.setValue(binding, formattedDate);
                controller.text = formattedDate;
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
            suffixIcon: const Icon(Icons.calendar_today),
          ),
        ),
      ),
    );

    return applyCommonWrappers(dateField, properties, context);
  }

  /// Applies a subset of the standard date-format tokens:
  ///   yyyy / yy  — 4/2-digit year
  ///   MM / M     — zero-padded / unpadded month
  ///   dd / d     — zero-padded / unpadded day
  /// Tokens outside this set are passed through verbatim so authors can
  /// include literal separators. Rich ICU patterns (day names, etc.) are
  /// not supported; spec §2.6.13 documents only the basic subset.
  static String _applyDateFormat(String format, DateTime d) {
    final y4 = d.year.toString().padLeft(4, '0');
    final y2 = y4.substring(2);
    final mm = d.month.toString().padLeft(2, '0');
    final m = d.month.toString();
    final dd = d.day.toString().padLeft(2, '0');
    final dayStr = d.day.toString();
    return format
        .replaceAll('yyyy', y4)
        .replaceAll('yy', y2)
        .replaceAll('MM', mm)
        .replaceAll('dd', dd)
        .replaceAll('M', m)
        .replaceAll('d', dayStr);
  }
}
