import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for creating color picker widgets
class ColorPickerFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final label = properties['label'] as String?;
    final binding = properties['binding'] as String?;
    final enabled = context.resolve(properties['enabled'] ?? true) as bool;
    // Spec §2.6.18: picker configuration properties. Current implementation
    // uses a preset-palette picker; the configuration options below are
    // accepted so authors can declare intent even when the renderer has not
    // yet diverged (deferred implementation tracked separately).
    // ignore: unused_local_variable
    final showAlpha = properties['showAlpha'] as bool? ?? false;
    // ignore: unused_local_variable
    final showLabel = properties['showLabel'] as bool? ?? true;
    // ignore: unused_local_variable
    final pickerType = properties['pickerType'] as String? ?? 'palette';
    // ignore: unused_local_variable
    final enableHistory = properties['enableHistory'] as bool? ?? false;

    // Get current color value
    final currentValue =
        binding != null ? context.resolve("{{$binding}}") : properties['value'];

    // Parse current color — fall back to the active theme's primary so a
    // picker that hasn't been initialised still shows a meaningful colour
    // against either light or dark chrome.
    Color currentColor = parseColor(currentValue, context) ??
        context.themeManager.getColorValue('primary') ??
        Colors.blue;

    // Simple color picker implementation using preset colors
    final colors = [
      Colors.red,
      Colors.pink,
      Colors.purple,
      Colors.deepPurple,
      Colors.indigo,
      Colors.blue,
      Colors.lightBlue,
      Colors.cyan,
      Colors.teal,
      Colors.green,
      Colors.lightGreen,
      Colors.lime,
      Colors.yellow,
      Colors.amber,
      Colors.orange,
      Colors.deepOrange,
      Colors.brown,
      Colors.grey,
      Colors.blueGrey,
      Colors.black,
    ];

    Widget colorPicker = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: colors.map((color) {
        final isSelected = currentColor.toString() == color.toString();
        return InkWell(
          onTap: enabled
              ? () {
                  if (binding != null) {
                    // Convert color to hex string
                    final hexColor =
                        '#${(color.r * 255).round().toRadixString(16).padLeft(2, '0')}${(color.g * 255).round().toRadixString(16).padLeft(2, '0')}${(color.b * 255).round().toRadixString(16).padLeft(2, '0')}'
                            .toUpperCase();
                    context.setValue(binding, hexColor);
                  }
                }
              : null,
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color,
              border: Border.all(
                color: isSelected
                    ? (context.themeManager.getColorValue('onSurface') ??
                        Colors.black)
                    : (context.themeManager.getColorValue('outlineVariant') ??
                        Colors.grey[300]!),
                width: isSelected ? 3 : 1,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        );
      }).toList(),
    );

    // Add label if provided
    if (label != null) {
      colorPicker = Column(
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
          colorPicker,
        ],
      );
    }

    // Add opacity if disabled
    if (!enabled) {
      colorPicker = Opacity(
        opacity: 0.6,
        child: colorPicker,
      );
    }

    return applyCommonWrappers(colorPicker, properties, context);
  }
}
