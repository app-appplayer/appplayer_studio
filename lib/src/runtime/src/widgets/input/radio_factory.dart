import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Radio widgets
class RadioWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final value = context.resolve(properties['value']);
    final groupValue = context.resolve(properties['groupValue']);
    final activeColor = parseColor(context.resolve(properties['activeColor']), context);
    final fillColor = properties['fillColor'] != null
        ? WidgetStateProperty.all(
            parseColor(context.resolve(properties['fillColor']), context))
        : null;
    final focusColor = parseColor(context.resolve(properties['focusColor']), context);
    final hoverColor = parseColor(context.resolve(properties['hoverColor']), context);
    final splashRadius = numberOf(properties['splashRadius'], context);

    // Extract action handler
    final onChange = actionOf(properties['onChange'] ?? properties['change'], context);

    // Flutter moved selection + change onto a RadioGroup ancestor; a standalone
    // `radio` widget therefore carries its own single-item group so the DSL
    // keeps working unchanged.
    void handleChange(dynamic newValue) {
      // Canonical `binding`; accept legacy `bindTo`.
      final path = (stringOf(properties['binding'], context)) ??
          (stringOf(properties['bindTo'], context));
      if (path != null) {
        context.setValue(path, newValue);
      }
      if (onChange == null) return;
      final eventData = Map<String, dynamic>.from(onChange);
      if (eventData['value'] == '{{event.value}}') {
        eventData['value'] = newValue;
      }
      context.actionHandler.execute(eventData, context);
    }

    Widget radio = RadioGroup<dynamic>(
      groupValue: groupValue,
      // Always `handleChange`: it writes the binding first and only then
      // dispatches `onChange`. Gating the whole callback on `onChange` made a
      // radio declared with nothing but a `binding` — the shortest correct
      // form — inert.
      onChanged: handleChange,
      child: Radio<dynamic>(
        value: value,
        activeColor: activeColor,
        fillColor: fillColor,
        focusColor: focusColor,
        hoverColor: hoverColor,
        splashRadius: splashRadius,
      ),
    );

    // Handle label
    final label = context.resolve<String?>(properties['label']);
    if (label != null && label.isNotEmpty) {
      radio = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          radio,
          GestureDetector(
            // The label is part of the control — tapping it is tapping the
            // radio, through the same path, so `binding` works there too.
            onTap: () {
              if (value != groupValue) handleChange(value);
            },
            child: Text(label),
          ),
        ],
      );
    }

    return applyCommonWrappers(radio, properties, context);
  }
}
