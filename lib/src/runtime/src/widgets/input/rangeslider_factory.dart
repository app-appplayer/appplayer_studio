import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for RangeSlider widgets
class RangeSliderWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Spec §2.6.0: binding shorthand — read from state path if set.
    final binding = (properties['binding'] as String?) ??
        (properties['bindTo'] as String?);
    final dynamic rawValue = binding != null
        ? context.getState(binding)
        : context.resolve(properties['value'] ?? properties['values']);
    final values = _parseRangeValues(rawValue) ?? const RangeValues(0.2, 0.8);
    final min = properties['min']?.toDouble() ?? 0.0;
    final max = properties['max']?.toDouble() ?? 1.0;
    final divisions = properties['divisions'] as int?;
    final labels = _parseRangeLabels(properties['labels'], context);
    final activeColor = parseColor(context.resolve(properties['activeColor']), context);
    final inactiveColor =
        parseColor(context.resolve(properties['inactiveColor']), context);

    // Extract action handlers
    final onChange = (properties['onChange'] ?? properties['change']) as Map<String, dynamic>?;
    final onChangeStart = properties['onChangeStart'] as Map<String, dynamic>?;
    final onChangeEnd = properties['onChangeEnd'] as Map<String, dynamic>?;

    Widget rangeSlider = RangeSlider(
      values: RangeValues(
        values.start.clamp(min, max).toDouble(),
        values.end.clamp(min, max).toDouble(),
      ),
      min: min,
      max: max,
      divisions: divisions,
      labels: labels,
      activeColor: activeColor,
      inactiveColor: inactiveColor,
      // Spec §2.6.0: when `binding` is set, the runtime performs two-way
      // binding (read + write) automatically. `onChange` is optional; the
      // handler must be wired when either `binding` or an explicit
      // `onChange` action is present so the RangeSlider is interactive.
      onChanged: (binding != null || onChange != null)
          ? (newValues) {
              final payload = {
                'start': newValues.start,
                'end': newValues.end,
              };
              // Persist to state when `binding` (canonical) or legacy
              // `bindTo` is provided.
              final path = binding ?? (properties['bindTo'] as String?);
              if (path != null) {
                context.setValue(path, payload);
              }
              if (onChange != null) {
                final eventData = Map<String, dynamic>.from(onChange);
                if (eventData['value'] == '{{event.value}}') {
                  eventData['value'] = payload;
                }
                context.actionHandler.execute(eventData, context);
              }
            }
          : null,
      onChangeStart: onChangeStart != null
          ? (values) {
              final eventData = Map<String, dynamic>.from(onChangeStart);
              if (eventData['value'] == '{{event.value}}') {
                eventData['value'] = {
                  'start': values.start,
                  'end': values.end,
                };
              }
              context.actionHandler.execute(eventData, context);
            }
          : null,
      onChangeEnd: onChangeEnd != null
          ? (values) {
              final eventData = Map<String, dynamic>.from(onChangeEnd);
              if (eventData['value'] == '{{event.value}}') {
                eventData['value'] = {
                  'start': values.start,
                  'end': values.end,
                };
              }
              context.actionHandler.execute(eventData, context);
            }
          : null,
    );

    return applyCommonWrappers(rangeSlider, properties, context);
  }

  RangeValues? _parseRangeValues(dynamic values) {
    if (values == null) return null;

    if (values is Map<String, dynamic>) {
      final start = values['start']?.toDouble() ?? 0.0;
      final end = values['end']?.toDouble() ?? 1.0;
      return RangeValues(start, end);
    }

    if (values is List && values.length >= 2) {
      return RangeValues(
        values[0].toDouble(),
        values[1].toDouble(),
      );
    }

    return null;
  }

  RangeLabels? _parseRangeLabels(dynamic labels, RenderContext context) {
    if (labels == null) return null;

    if (labels is Map<String, dynamic>) {
      final start = context.resolve<String?>(labels['start']);
      final end = context.resolve<String?>(labels['end']);
      if (start != null && end != null) {
        return RangeLabels(start, end);
      }
    }

    if (labels is List && labels.length >= 2) {
      final start = context.resolve<String?>(labels[0]);
      final end = context.resolve<String?>(labels[1]);
      if (start != null && end != null) {
        return RangeLabels(start, end);
      }
    }

    return null;
  }
}
