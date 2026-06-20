import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for creating radio button group widgets
class RadioGroupFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final label = properties['label'] as String?;
    final binding = properties['binding'] as String?;
    final options = properties['options'] as List<dynamic>? ?? [];
    final enabled = context.resolve(properties['enabled'] ?? true) as bool;
    // Spec §2.6.9 canonical `orientation`; `direction` kept as legacy alias.
    final direction = (properties['orientation'] ?? properties['direction'])
            as String? ??
        'vertical';

    // Get current value
    final currentValue =
        binding != null ? context.resolve("{{$binding}}") : properties['value'];

    // Build radio buttons
    final radioButtons = options.map((option) {
      String value;
      String label;

      if (option is Map<String, dynamic>) {
        value = option['value']?.toString() ?? '';
        label = option['label']?.toString() ?? value;
      } else {
        value = option.toString();
        label = value;
      }

      return RadioListTile<String>(
        title: Text(label),
        value: value,
        groupValue: currentValue?.toString(),
        onChanged: enabled
            ? (newValue) {
                if (binding != null && newValue != null) {
                  context.setValue(binding, newValue);
                }
              }
            : null,
        dense: true,
        contentPadding: EdgeInsets.zero,
      );
    }).toList();

    Widget radioGroup;
    if (direction == 'horizontal') {
      radioGroup = Row(
        mainAxisSize: MainAxisSize.min,
        children: radioButtons.map((radio) => Flexible(child: radio)).toList(),
      );
    } else {
      radioGroup = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: radioButtons,
      );
    }

    // Add label if provided
    if (label != null) {
      radioGroup = Column(
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
          radioGroup,
        ],
      );
    }

    return applyCommonWrappers(radioGroup, properties, context);
  }
}
