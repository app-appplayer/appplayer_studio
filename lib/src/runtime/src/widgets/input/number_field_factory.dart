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
    final label = stringOf(properties['label'], context);
    final hint = stringOf(properties['hint'], context);
    final helperText = context.resolve(properties['helperText']) as String?;
    final suffix = stringOf(properties['suffix'], context);
    final prefix = stringOf(properties['prefix'], context);
    final min = dimensionOf(properties['min'], context);
    final max = dimensionOf(properties['max'], context);
    final step = dimensionOf(properties['step'], context) ?? 1;
    final decimals = intOf(properties['decimals'], context) ?? 0;
    // Support 'decimalPlaces' as alias for 'decimals'
    final decimalPlaces = dimensionOf(properties['decimalPlaces'], context)?.toInt();
    final effectiveDecimals = decimalPlaces ?? decimals;
    final format = readEnum(properties['format'], context);
    final thousandSeparator =
        stringOf(properties['thousandSeparator'], context) ?? '';
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

    // Binding shorthand — read from state path if set.
    final binding = stringOf(properties['binding'], context);
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

    // `FilteringTextInputFormatter.allow` takes a pattern matching ALLOWED
    // CHARACTERS. These were anchored whole-string patterns (`^\-?\d*$`), and
    // a string that does not match in full produces NO matches at all — so
    // the filter kept nothing. One stray keystroke, a letter or the thousand
    // separator the field itself displays, EMPTIED the whole field instead of
    // being dropped: a quantity the user had typed vanished as they kept
    // typing, and the binding went null with it.
    final separator =
        thousandSeparator.isEmpty ? '' : RegExp.escape(thousandSeparator);
    inputFormatters.add(
      FilteringTextInputFormatter.allow(
        RegExp(effectiveDecimals > 0
            ? '[0-9.\\-$separator]'
            : '[0-9\\-$separator]'),
      ),
    );

    /// The number behind what is displayed.
    ///
    /// The field's text is presentation: it may carry a thousand separator and
    /// a `format` wrapper ("$1,234 kg"). `num.tryParse` answers null for all
    /// of those, and the stepper below used to treat that as zero — so
    /// stepping a formatted 1,000 landed on 1. Everything that is not part of
    /// a number is dropped before parsing.
    num? parseDisplayed(String text) {
      final stripped = text.replaceAll(RegExp(r'[^0-9.\-]'), '');
      if (stripped.isEmpty) return null;
      return effectiveDecimals > 0
          ? double.tryParse(stripped)
          : int.tryParse(stripped) ?? double.tryParse(stripped)?.toInt();
    }

    /// Runs the document's `onChange` with the new value visible as
    /// `{{event.value}}`.
    ///
    /// The substitution used to be hand-rolled and only reached keys inside
    /// `params`, so the ordinary spelling — a `state` action whose `value` is
    /// `{{event.value}}` — received the literal string and wrote nothing
    /// usable. Every other input widget publishes the event through a child
    /// context; this one now does too, and the params substitution is kept for
    /// documents already written against it.
    void fireChange(num? value) {
      final changeAction = properties['onChange'] ?? properties['change'];
      if (changeAction is! Map<String, dynamic>) return;
      final eventData = Map<String, dynamic>.from(changeAction);
      if (eventData['params'] is Map<String, dynamic>) {
        final params = Map<String, dynamic>.from(
            eventData['params'] as Map<String, dynamic>);
        params.forEach((key, raw) {
          if (raw == '{{event.value}}') params[key] = value;
        });
        eventData['params'] = params;
      }
      context.actionHandler.execute(
        eventData,
        context.createChildContext(
          variables: {
            'event': {'value': value, 'type': 'change'},
          },
        ),
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

        // Write back to binding path.
        if (binding != null) {
          context.setValue(binding, numValue);
        }

        fireChange(numValue);
      },
    );

    // Add increment/decrement buttons if step is defined.
    // `showStepper: false` leaves keyboard entry only — the document says the
    // field takes numbers, not that it must offer buttons for them.
    final showStepper = context.resolve<bool>(properties['showStepper'] ?? true);
    if (step > 0 && showStepper) {
      textField = Row(
        children: [
          IconButton(
            icon: const Icon(Icons.remove),
            onPressed: enabled
                ? () {
                    final current = parseDisplayed(controller.text) ?? 0;
                    final newValue = current - step;

                    // Check bounds
                    if (min == null || newValue >= min) {
                      controller.text = effectiveDecimals > 0
                          ? newValue.toStringAsFixed(effectiveDecimals)
                          : newValue.toStringAsFixed(0);

                      if (binding != null) {
                        context.setValue(binding, newValue);
                      }

                      fireChange(newValue);
                    }
                  }
                : null,
          ),
          Expanded(child: textField),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: enabled
                ? () {
                    final current = parseDisplayed(controller.text) ?? 0;
                    final newValue = current + step;

                    // Check bounds
                    if (max == null || newValue <= max) {
                      controller.text = effectiveDecimals > 0
                          ? newValue.toStringAsFixed(effectiveDecimals)
                          : newValue.toStringAsFixed(0);

                      if (binding != null) {
                        context.setValue(binding, newValue);
                      }

                      fireChange(newValue);
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
