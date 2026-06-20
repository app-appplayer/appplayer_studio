import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for creating number input fields
class NumberFieldFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final label = properties['label'] as String?;
    final hint = properties['hint'] as String?;
    final helperText = context.resolve(properties['helperText']) as String?;
    final suffix = properties['suffix'] as String?;
    final prefix = properties['prefix'] as String?;
    final min = properties['min'] as num?;
    final max = properties['max'] as num?;
    final step = properties['step'] as num? ?? 1;
    final decimals = properties['decimals'] as int? ?? 0;
    // Support 'decimalPlaces' as alias for 'decimals'
    final decimalPlaces = properties['decimalPlaces'] as int?;
    final effectiveDecimals = decimalPlaces ?? decimals;
    final format = properties['format'] as String?;
    final thousandSeparator =
        properties['thousandSeparator'] as String? ?? '';
    final enabled = context.resolve(properties['enabled'] ?? true) as bool;
    
    // Handle error property
    final errorValue = context.resolve(properties['error']);
    final String? errorText;
    if (errorValue is String && errorValue.isNotEmpty) {
      errorText = errorValue;
    } else if (errorValue == true) {
      errorText = 'Invalid value';
    } else {
      errorText = null;
    }

    // Spec §2.6.0: binding shorthand — read from state path if set.
    final binding = properties['binding'] as String?;
    final currentValue = binding != null
        ? context.getState(binding)
        : context.resolve(properties['value']);

    // Format the display value
    String displayValue = '';
    if (currentValue != null) {
      if (effectiveDecimals > 0) {
        final numVal = currentValue is num
            ? currentValue
            : num.tryParse(currentValue.toString());
        displayValue = numVal != null
            ? numVal.toStringAsFixed(effectiveDecimals)
            : currentValue.toString();
      } else {
        displayValue = currentValue.toString();
      }
      // Apply thousand separator
      if (thousandSeparator.isNotEmpty && displayValue.isNotEmpty) {
        displayValue = _applyThousandSeparator(
            displayValue, thousandSeparator);
      }
      // Apply format pattern if provided
      if (format != null) {
        displayValue = format.replaceAll('{value}', displayValue);
      }
    }

    // Create text controller with current value
    final controller = TextEditingController(
      text: displayValue,
    );

    // Build input formatters
    final inputFormatters = <TextInputFormatter>[];

    // Add numeric formatter
    if (effectiveDecimals > 0) {
      inputFormatters.add(
        FilteringTextInputFormatter.allow(RegExp(r'^\-?\d*\.?\d*$')),
      );
    } else {
      inputFormatters.add(
        FilteringTextInputFormatter.allow(RegExp(r'^\-?\d*$')),
      );
    }

    Widget textField = TextField(
      controller: controller,
      keyboardType: TextInputType.numberWithOptions(
        decimal: effectiveDecimals > 0,
        signed: min == null || min < 0,
      ),
      inputFormatters: inputFormatters,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helperText,
        errorText: errorText,
        suffixText: suffix,
        prefixText: prefix,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      enabled: enabled,
      onChanged: (value) {
        // Parse the number value
        num? numValue;
        // Strip thousand separators before parsing
        final cleanValue = thousandSeparator.isNotEmpty
            ? value.replaceAll(thousandSeparator, '')
            : value;
        if (cleanValue.isNotEmpty) {
          if (effectiveDecimals > 0) {
            numValue = double.tryParse(cleanValue);
          } else {
            numValue = int.tryParse(cleanValue);
          }
        }

        // Spec §2.6.0: write back to binding path.
        if (binding != null) {
          context.setValue(binding, numValue);
        }

        // Execute change action if defined
        final changeAction = properties['onChange'] ?? properties['change'];
        if (changeAction != null) {
          // Create modified action with event value
          final eventData = Map<String, dynamic>.from(changeAction);
          
          // Replace {{event.value}} placeholder in params
          if (eventData['params'] != null && eventData['params'] is Map<String, dynamic>) {
            final params = Map<String, dynamic>.from(eventData['params']);
            params.forEach((key, value) {
              if (value == '{{event.value}}') {
                params[key] = numValue;
              }
            });
            eventData['params'] = params;
          }
          
          context.actionHandler.execute(eventData, context);
        }
      },
    );

    // Add increment/decrement buttons if step is defined
    if (step > 0) {
      textField = Row(
        children: [
          IconButton(
            icon: const Icon(Icons.remove),
            onPressed: enabled
                ? () {
                    final current = num.tryParse(controller.text) ?? 0;
                    final newValue = current - step;

                    // Check bounds
                    if (min == null || newValue >= min) {
                      controller.text = effectiveDecimals > 0
                          ? newValue.toStringAsFixed(effectiveDecimals)
                          : newValue.toStringAsFixed(0);

                      if (binding != null) {
                        context.setValue(binding, newValue);
                      }

                      // Execute change action if defined
                      final changeAction = properties['onChange'] ?? properties['change'];
                      if (changeAction != null) {
                        final eventData = Map<String, dynamic>.from(changeAction);

                        // Replace {{event.value}} placeholder in params
                        if (eventData['params'] != null && eventData['params'] is Map<String, dynamic>) {
                          final params = Map<String, dynamic>.from(eventData['params']);
                          params.forEach((key, value) {
                            if (value == '{{event.value}}') {
                              params[key] = newValue;
                            }
                          });
                          eventData['params'] = params;
                        }

                        context.actionHandler.execute(eventData, context);
                      }
                    }
                  }
                : null,
          ),
          Expanded(child: textField),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: enabled
                ? () {
                    final current = num.tryParse(controller.text) ?? 0;
                    final newValue = current + step;

                    // Check bounds
                    if (max == null || newValue <= max) {
                      controller.text = effectiveDecimals > 0
                          ? newValue.toStringAsFixed(effectiveDecimals)
                          : newValue.toStringAsFixed(0);

                      if (binding != null) {
                        context.setValue(binding, newValue);
                      }

                      // Execute change action if defined
                      final changeAction = properties['onChange'] ?? properties['change'];
                      if (changeAction != null) {
                        final eventData = Map<String, dynamic>.from(changeAction);
                        
                        // Replace {{event.value}} placeholder in params
                        if (eventData['params'] != null && eventData['params'] is Map<String, dynamic>) {
                          final params = Map<String, dynamic>.from(eventData['params']);
                          params.forEach((key, value) {
                            if (value == '{{event.value}}') {
                              params[key] = newValue;
                            }
                          });
                          eventData['params'] = params;
                        }
                        
                        context.actionHandler.execute(eventData, context);
                      }
                    }
                  }
                : null,
          ),
        ],
      );
    }

    return applyCommonWrappers(textField, properties, context);
  }

  /// Apply thousand separator to a numeric string
  String _applyThousandSeparator(String value, String separator) {
    // Split into integer and decimal parts
    final parts = value.split('.');
    final integerPart = parts[0];
    final decimalPart = parts.length > 1 ? '.${parts[1]}' : '';

    // Determine if negative
    final isNegative = integerPart.startsWith('-');
    final digits = isNegative ? integerPart.substring(1) : integerPart;

    // Apply thousand separator from right to left
    final buffer = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) {
        buffer.write(separator);
      }
      buffer.write(digits[i]);
    }

    return '${isNegative ? '-' : ''}$buffer$decimalPart';
  }
}
