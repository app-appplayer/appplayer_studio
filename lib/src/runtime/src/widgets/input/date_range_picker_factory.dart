import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for creating date range picker widgets
class DateRangePickerFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final label = properties['label'] as String?;
    // Spec §2.6.17: canonical `startDate` / `endDate` are state paths.
    // Legacy `startBinding` / `endBinding` accepted as aliases.
    final startPath = (properties['startDate'] as String?) ??
        (properties['startBinding'] as String?);
    final endPath = (properties['endDate'] as String?) ??
        (properties['endBinding'] as String?);
    final firstDateStr = properties['firstDate'] as String?;
    final lastDateStr = properties['lastDate'] as String?;
    final errorText = context.resolve(properties['errorText']) as String?;
    final enabled = context.resolve(properties['enabled'] ?? true) as bool;
    final onChange =
        (properties['onChange'] ?? properties['change']) as Map<String, dynamic>?;
    // Spec §2.6.17: `format` and `locale`. format uses the same token
    // subset as dateField (`yyyy`, `MM`, `dd`, etc.).
    final formatStr = (properties['format'] as String?) ?? 'yyyy-MM-dd';
    final localeStr = properties['locale'] as String?;

    // Get current values
    final startDate = startPath != null
        ? context.getState(startPath)?.toString()
        : null;
    final endDate = endPath != null
        ? context.getState(endPath)?.toString()
        : null;

    final displayText = (startDate != null && endDate != null)
        ? "$startDate - $endDate"
        : "Select date range";

    Widget rangePicker = InkWell(
      onTap: enabled
          ? () async {
              // Parse current dates
              DateTime? initialStart;
              DateTime? initialEnd;

              try {
                if (startDate != null && startDate.isNotEmpty) {
                  initialStart = DateTime.parse(startDate);
                }
                if (endDate != null && endDate.isNotEmpty) {
                  initialEnd = DateTime.parse(endDate);
                }
              } catch (e) {
                // Invalid dates
              }

              final now = DateTime.now();
              initialStart ??= now;
              initialEnd ??= now.add(const Duration(days: 7));

              DateTime firstDate = DateTime(1900);
              DateTime lastDate = DateTime(2100);
              try {
                if (firstDateStr != null) firstDate = DateTime.parse(firstDateStr);
                if (lastDateStr != null) lastDate = DateTime.parse(lastDateStr);
              } catch (_) {/* keep defaults */}

              final pickedRange = await showDateRangePicker(
                context: context.buildContext!,
                firstDate: firstDate,
                lastDate: lastDate,
                locale: localeStr != null ? Locale(localeStr) : null,
                initialDateRange: DateTimeRange(
                  start: initialStart,
                  end: initialEnd,
                ),
              );

              if (pickedRange != null) {
                final formattedStart =
                    _applyDateFormat(formatStr, pickedRange.start);
                final formattedEnd =
                    _applyDateFormat(formatStr, pickedRange.end);

                if (startPath != null) {
                  context.setValue(startPath, formattedStart);
                }
                if (endPath != null) {
                  context.setValue(endPath, formattedEnd);
                }
                if (onChange != null) {
                  final eventContext = context.createChildContext(
                    variables: {
                      'event': {
                        'value': {'start': formattedStart, 'end': formattedEnd},
                        'type': 'change',
                      },
                    },
                  );
                  context.actionHandler.execute(onChange, eventContext);
                }
              }
            }
          : null,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          errorText: errorText,
          suffixIcon: const Icon(Icons.date_range),
          enabled: enabled,
        ),
        child: Text(displayText),
      ),
    );

    return applyCommonWrappers(rangePicker, properties, context);
  }

  /// Token subset identical to `dateField._applyDateFormat`.
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
