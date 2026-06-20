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
    final splashRadius = properties['splashRadius']?.toDouble();

    // Extract action handler
    final onChange = (properties['onChange'] ?? properties['change']) as Map<String, dynamic>?;

    Widget radio = Radio<dynamic>(
      value: value,
      groupValue: groupValue,
      onChanged: onChange != null
          ? (newValue) {
              // Spec §2.6.0: canonical `binding`; accept legacy `bindTo`.
              final path = (properties['binding'] as String?) ??
                  (properties['bindTo'] as String?);
              if (path != null) {
                context.setValue(path, newValue);
              }

              // Execute action
              final eventData = Map<String, dynamic>.from(onChange);
              if (eventData['value'] == '{{event.value}}') {
                eventData['value'] = newValue;
              }
              context.actionHandler.execute(eventData, context);
            }
          : null,
      activeColor: activeColor,
      fillColor: fillColor,
      focusColor: focusColor,
      hoverColor: hoverColor,
      splashRadius: splashRadius,
    );

    // Handle label
    final label = context.resolve<String?>(properties['label']);
    if (label != null && label.isNotEmpty) {
      radio = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          radio,
          GestureDetector(
            onTap: onChange != null
                ? () {
                    // Simulate radio tap when label is clicked
                    if (value != groupValue) {
                      // Update state if bindTo is specified
                      final path = properties['bindTo'] as String?;
                      if (path != null) {
                        context.setValue(path, value);
                      }

                      // Execute action
                      final eventData = Map<String, dynamic>.from(onChange);
                      if (eventData['value'] == '{{event.value}}') {
                        eventData['value'] = value;
                      }
                      context.actionHandler.execute(eventData, context);
                    }
                  }
                : null,
            child: Text(label),
          ),
        ],
      );
    }

    return applyCommonWrappers(radio, properties, context);
  }
}
