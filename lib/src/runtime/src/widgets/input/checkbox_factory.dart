import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Checkbox widgets
class CheckboxWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Spec §2.6.0: binding shorthand — read from state path if set.
    final binding = (stringOf(properties['binding'], context)) ??
        (stringOf(properties['bindTo'], context));
    final bool value = binding != null
        ? (context.getState(binding) as bool? ?? false)
        : context.resolve<bool>(properties['value'] ?? false);
    final label = stringOf(properties['label'], context);
    final enabled = boolOf(properties['enabled'], context) ?? true;
    final tristate = boolOf(properties['tristate'], context) ?? false;
    final onChange =
        actionOf(properties['onChange'] ?? properties['change'], context);

    ValueChanged<bool?>? handler;
    if (enabled && (binding != null || onChange != null)) {
      handler = (newValue) {
        if (binding != null) {
          context.setValue(binding, newValue);
        }
        if (onChange != null) {
          final eventContext = context.createChildContext(
            variables: {
              'event': {'value': newValue, 'type': 'change'},
            },
          );
          context.actionHandler.execute(onChange, eventContext);
        }
      };
    }

    Widget checkbox = label != null
        ? CheckboxListTile(
            value: value,
            title: Text(label),
            tristate: tristate,
            onChanged: handler,
          )
        : Checkbox(value: value, tristate: tristate, onChanged: handler);

    return applyCommonWrappers(checkbox, properties, context);
  }
}
