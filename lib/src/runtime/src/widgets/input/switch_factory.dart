import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Switch widgets
class SwitchWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Spec §2.6.0: binding shorthand — read from state path if set.
    final binding = stringOf(properties['binding'], context);
    final bool value = binding != null
        ? (context.getState(binding) as bool? ?? false)
        : context.resolve<bool>(properties['value'] ?? false);
    final label = stringOf(properties['label'], context);
    final enabled = boolOf(properties['enabled'], context) ?? true;
    final onChange =
        actionOf(properties['onChange'] ?? properties['change'], context);

    ValueChanged<bool>? handler;
    if (enabled && (binding != null || onChange != null)) {
      handler = (newValue) async {
        if (binding != null) {
          context.setValue(binding, newValue);
        }
        if (onChange != null) {
          final eventContext = context.createChildContext(
            variables: {
              'event': {'value': newValue, 'type': 'change'},
            },
          );
          await context.actionHandler.execute(onChange, eventContext);
        }
      };
    }

    Widget switchWidget = label != null
        ? SwitchListTile(
            value: value,
            title: Text(label),
            onChanged: handler,
          )
        : Switch(value: value, onChanged: handler);

    return applyCommonWrappers(switchWidget, properties, context);
  }
}
