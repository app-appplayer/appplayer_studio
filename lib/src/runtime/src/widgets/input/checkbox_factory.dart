import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Checkbox widgets
class CheckboxWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Spec §2.6.0: binding shorthand — read from state path if set.
    final binding = (properties['binding'] as String?) ??
        (properties['bindTo'] as String?);
    final bool value = binding != null
        ? (context.getState(binding) as bool? ?? false)
        : context.resolve<bool>(properties['value'] ?? false);
    final label = properties['label'] as String?;
    final enabled = properties['enabled'] as bool? ?? true;
    final tristate = properties['tristate'] as bool? ?? false;
    final onChange =
        (properties['onChange'] ?? properties['change']) as Map<String, dynamic>?;

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
