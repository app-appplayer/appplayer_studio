import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for creating checkbox group widgets
class CheckboxGroupFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final label = properties['label'] as String?;
    final options = properties['options'] as List<dynamic>? ?? [];
    final enabled = context.resolve(properties['enabled'] ?? true) as bool;
    final direction =
        (properties['direction'] ?? properties['orientation']) as String? ??
            'vertical';

    // Spec §2.6.0 / §2.6.7: top-level `binding` holds an array of selected values.
    // Legacy: per-option `binding` (boolean state per option) remains supported.
    final groupBinding = properties['binding'] as String?;
    final onChange =
        (properties['onChange'] ?? properties['change']) as Map<String, dynamic>?;

    List<dynamic> selectedValues = const [];
    if (groupBinding != null) {
      final resolved = context.getState(groupBinding);
      if (resolved is List) selectedValues = resolved;
    }

    // Build checkboxes
    final checkboxes = options.map((option) {
      String value;
      String label;
      String? perOptionBinding;

      if (option is Map<String, dynamic>) {
        value = option['value']?.toString() ?? '';
        label = option['label']?.toString() ?? value;
        perOptionBinding = option['binding'] as String?;
      } else {
        value = option.toString();
        label = value;
        perOptionBinding = null;
      }

      final bool isChecked;
      if (groupBinding != null) {
        isChecked = selectedValues.contains(value);
      } else if (perOptionBinding != null) {
        isChecked = context.resolve("{{$perOptionBinding}}") as bool? ?? false;
      } else {
        isChecked = false;
      }

      ValueChanged<bool?>? handler;
      if (enabled) {
        if (groupBinding != null) {
          handler = (newValue) {
            final updated = List<dynamic>.from(selectedValues);
            if (newValue == true) {
              if (!updated.contains(value)) updated.add(value);
            } else {
              updated.remove(value);
            }
            context.setValue(groupBinding, updated);
            if (onChange != null) {
              final eventContext = context.createChildContext(
                variables: {
                  'event': {'value': updated, 'type': 'change'},
                },
              );
              context.actionHandler.execute(onChange, eventContext);
            }
          };
        } else if (perOptionBinding != null) {
          handler = (newValue) {
            if (newValue != null) context.setValue(perOptionBinding!, newValue);
          };
        }
      }

      return CheckboxListTile(
        title: Text(label),
        value: isChecked,
        onChanged: handler,
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
      );
    }).toList();

    Widget checkboxGroup;
    if (direction == 'horizontal') {
      checkboxGroup = Row(
        mainAxisSize: MainAxisSize.min,
        children:
            checkboxes.map((checkbox) => Flexible(child: checkbox)).toList(),
      );
    } else {
      checkboxGroup = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: checkboxes,
      );
    }

    // Add label if provided
    if (label != null) {
      checkboxGroup = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          checkboxGroup,
        ],
      );
    }

    return applyCommonWrappers(checkboxGroup, properties, context);
  }
}
