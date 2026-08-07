import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Slider widgets
class SliderWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Canonical `value`; §17.3.2 legacy alias `values` (single-value case).
    final resolvedValue = context
        .resolve<num?>(properties['value'] ?? properties['values']);

    // §2.6.0 — `binding` is two-way: the runtime READS the current value from
    // the path as well as writing input back to it. Only the write half was
    // wired, so a slider declared with the shorthand sat at its minimum while
    // the state it was bound to held something else, in every release since
    // 0.5.1. Precedence per §2.6.0: an explicit `value` + `onChange` pair wins,
    // which is how an author opts out for debounced or side-effecting flows.
    final bindingPath = stringOf(properties['binding'], context);
    final hasExplicitPair =
        properties['value'] != null && properties['onChange'] != null;
    final num? boundValue = (bindingPath != null && !hasExplicitPair)
        ? context.getState<dynamic>(bindingPath) as num?
        : null;

    final value = (boundValue ?? resolvedValue ?? 0.0).toDouble();
    final min = numberOf(properties['min'], context) ?? 0.0;
    final max = numberOf(properties['max'], context) ?? 1.0;
    final divisions = dimensionOf(properties['divisions'], context)?.toInt();
    final label = context.resolve<String?>(properties['label']);
    final activeColor = parseColor(context.resolve(properties['activeColor']), context);
    final inactiveColor =
        parseColor(context.resolve(properties['inactiveColor']), context);
    final thumbColor = parseColor(context.resolve(properties['thumbColor']), context);

    // Extract action handlers - A2 naming: on + PascalCase as primary key
    // Legacy kebab-case and camelCase kept as fallbacks
    final changeAction = actionOf(properties['onChange'] ?? properties['change'], context);
    final changeStartAction = actionOf(properties['onChangeStart'] ?? properties['change-start'] ?? properties['changeStart'], context);
    final changeEndAction = actionOf(properties['onChangeEnd'] ?? properties['change-end'] ?? properties['changeEnd'], context);

    Widget slider = Slider(
      value: value.clamp(min, max).toDouble(),
      min: min,
      max: max,
      divisions: divisions,
      label: label,
      activeColor: activeColor,
      inactiveColor: inactiveColor,
      thumbColor: thumbColor,
      onChanged: (changeAction != null || properties['binding'] != null)
          ? (newValue) {
              // Update state if binding is specified
              final path = stringOf(properties['binding'], context);
              if (path != null) {
                context.setValue(path, newValue);
              }
              // Execute action if change is specified
              if (changeAction != null) {
                // Create a child context with event data
                final eventContext = context.createChildContext(
                  variables: {
                    'event': {
                      'value': newValue,
                      'type': 'change',
                    },
                  },
                );
                eventContext.handleAction(changeAction);
              }
            }
          : null,
      onChangeStart: changeStartAction != null
          ? (value) {
              // Create a child context with event data
              final eventContext = context.createChildContext(
                variables: {
                  'event': {
                    'value': value,
                    'type': 'changeStart',
                  },
                },
              );
              eventContext.handleAction(changeStartAction);
            }
          : null,
      onChangeEnd: changeEndAction != null
          ? (value) {
              // Create a child context with event data
              final eventContext = context.createChildContext(
                variables: {
                  'event': {
                    'value': value,
                    'type': 'changeEnd',
                  },
                },
              );
              eventContext.handleAction(changeEndAction);
            }
          : null,
    );

    return applyCommonWrappers(slider, properties, context);
  }
}
