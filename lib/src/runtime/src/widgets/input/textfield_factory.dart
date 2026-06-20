import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';
import '../../validation/validation_engine.dart';
import '../../utils/debounce.dart';
import '../../utils/icon_resolver.dart';

/// Factory for TextField widgets
class TextFieldWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Check if debouncing is enabled
    final debounceDelay = properties['debounce'] as int?;

    if (debounceDelay != null && debounceDelay > 0) {
      return _DebouncedTextField(
        definition: definition,
        context: context,
        debounceDelay: debounceDelay,
      );
    }

    // Use stateful wrapper for proper controller management
    return _StatefulTextField(
      definition: definition,
      context: context,
    );
  }

  Widget _buildTextField(
      Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final hint = context.resolve<String?>(properties['hint']) ??
        context.resolve<String?>(properties['placeholder']) ??
        '';
    final label = properties['label'] as String?;
    final helperText = properties['helperText'] as String?;
    final prefixIcon = properties['prefixIcon'] as String?;
    final suffixIcon = properties['suffixIcon'] as String?;
    final obscureText = properties['obscureText'] as bool? ?? false;
    final enabled = properties['enabled'] as bool? ?? true;
    final readOnly = properties['readOnly'] as bool? ?? false;
    final maxLines = properties['maxLines'] as int? ?? 1;
    final maxLength = properties['maxLength'] as int?;
    // spec v1.0: 'inputType', legacy: 'keyboardType'
    final keyboardType = _parseKeyboardType(
        properties['inputType'] ?? properties['keyboardType']);
    final textInputAction =
        _parseTextInputAction(properties['textInputAction']);

    // Parse validation rules if provided
    final validationDef = properties['validation'];
    final validationRules = ValidationEngine.parseValidation(validationDef);
    final hasValidation = validationRules.isNotEmpty;

    // Handle error state
    // The 'error' property can be either a boolean (to show error state) or a string (the error message)
    final errorValue = context.resolve<dynamic>(properties['error']);
    final String? errorText;
    if (errorValue is String && errorValue.isNotEmpty) {
      errorText = errorValue;
    } else if (errorValue is bool && errorValue) {
      errorText = context.resolve<String?>(properties['errorText']);
    } else {
      errorText = null;
    }

    // Get event handlers - MCP UI DSL v1.0 spec
    final changeAction = (properties['onChange'] ?? properties['change']) as Map<String, dynamic>?;
    final submitAction = (properties['onSubmit'] ?? properties['submit']) as Map<String, dynamic>?;
    final blurAction = (properties['onBlur'] ?? properties['blur']) as Map<String, dynamic>?;
    final focusAction = (properties['onFocus'] ?? properties['focus']) as Map<String, dynamic>?;

    // Get initial value from binding or value property
    final bindingPath = properties['binding'] as String?;
    String initialValue = '';
    if (bindingPath != null) {
      initialValue = context.getState(bindingPath)?.toString() ?? '';
    } else {
      initialValue = context.resolve<String>(properties['value'] ?? '');
    }

    // Create text editing controller with initial value
    final controller = TextEditingController(text: initialValue);

    // Parse style
    TextStyle? style;
    final styleDef = properties['style'];
    if (styleDef is Map<String, dynamic>) {
      style = TextStyle(
        fontSize: context.resolve<num?>(styleDef['fontSize'])?.toDouble(),
        fontWeight: _parseFontWeight(styleDef['fontWeight']),
        fontStyle: styleDef['fontStyle'] == 'italic' ? FontStyle.italic : null,
        color: parseColor(context.resolve(styleDef['color']), context),
        letterSpacing:
            context.resolve<num?>(styleDef['letterSpacing'])?.toDouble(),
        wordSpacing: context.resolve<num?>(styleDef['wordSpacing'])?.toDouble(),
        height: context.resolve<num?>(styleDef['height'])?.toDouble(),
      );
    }

    // Build text field - always use TextField for consistency with tests
    Widget textField = TextField(
      controller: controller,
      style: style,
      decoration: InputDecoration(
        hintText: hint,
        labelText: label,
        helperText: helperText,
        prefixIcon: prefixIcon != null ? Icon(_parseIcon(prefixIcon)) : null,
        suffixIcon: suffixIcon != null ? Icon(_parseIcon(suffixIcon)) : null,
        border: const OutlineInputBorder(),
        counterText: maxLength != null ? null : '',
        errorText: errorText,
      ),
      obscureText: obscureText,
      enabled: enabled,
      readOnly: readOnly,
      maxLines: maxLines,
      maxLength: maxLength,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onChanged: (newValue) {
        // Validate if rules are defined
        if (hasValidation) {
          ValidationEngine.validate(newValue, validationRules);
          // Validation result will be used later if needed
        }

        // Update state if binding is specified
        final path = properties['binding'] as String?;
        if (path != null) {
          context.setValue(path, newValue);
        }

        // Execute action if change is specified
        if (changeAction != null) {
          // Create a child context with event data
          final eventContext = context.createChildContext(
            variables: {
              'event': {
                'value': newValue,
                'type': 'change',
              },
            },
          );
          eventContext.handleAction(changeAction);
        }
      },
      onSubmitted: (newValue) {
        // Update state if binding is specified
        final path = properties['binding'] as String?;
        if (path != null) {
          context.setValue(path, newValue);
        }

        // Execute action if submit is specified
        if (submitAction != null) {
          // Create a child context with event data
          final eventContext = context.createChildContext(
            variables: {
              'event': {
                'value': newValue,
                'type': 'submit',
              },
            },
          );
          eventContext.handleAction(submitAction);
        }
      },
    );

    // Wrap in Focus widget if blur or focus action is needed.
    if (blurAction != null || focusAction != null) {
      textField = Focus(
        onFocusChange: (hasFocus) {
          final eventContext = context.createChildContext(
            variables: {
              'event': {
                'value': controller.text,
                'type': hasFocus ? 'focus' : 'blur',
              },
            },
          );
          if (hasFocus && focusAction != null) {
            eventContext.handleAction(focusAction);
          } else if (!hasFocus && blurAction != null) {
            eventContext.handleAction(blurAction);
          }
        },
        child: textField,
      );
    }

    return applyCommonWrappers(textField, properties, context);
  }

  Widget _buildTextFieldWithController(
    Map<String, dynamic> definition,
    RenderContext context,
    TextEditingController controller,
    Function(String) onValueChanged,
  ) {
    final properties = extractProperties(definition);

    // Extract properties
    final hint = context.resolve<String?>(properties['hint']) ??
        context.resolve<String?>(properties['placeholder']) ??
        '';
    final label = properties['label'] as String?;
    final helperText = properties['helperText'] as String?;
    final prefixIcon = properties['prefixIcon'] as String?;
    final suffixIcon = properties['suffixIcon'] as String?;
    final obscureText = properties['obscureText'] as bool? ?? false;
    final enabled = properties['enabled'] as bool? ?? true;
    final readOnly = properties['readOnly'] as bool? ?? false;
    final maxLines = properties['maxLines'] as int? ?? 1;
    final maxLength = properties['maxLength'] as int?;
    // spec v1.0: 'inputType', legacy: 'keyboardType'
    final keyboardType = _parseKeyboardType(
        properties['inputType'] ?? properties['keyboardType']);
    final textInputAction =
        _parseTextInputAction(properties['textInputAction']);

    // Parse validation rules if provided
    final validationDef = properties['validation'];
    final validationRules = ValidationEngine.parseValidation(validationDef);
    final hasValidation = validationRules.isNotEmpty;

    // Handle error state
    final errorValue = context.resolve<dynamic>(properties['error']);
    final String? errorText;
    if (errorValue is String && errorValue.isNotEmpty) {
      errorText = errorValue;
    } else if (errorValue is bool && errorValue) {
      errorText = context.resolve<String?>(properties['errorText']);
    } else {
      errorText = null;
    }

    // Get event handlers
    final changeAction = (properties['onChange'] ?? properties['change']) as Map<String, dynamic>?;
    final submitAction = (properties['onSubmit'] ?? properties['submit']) as Map<String, dynamic>?;
    final blurAction = (properties['onBlur'] ?? properties['blur']) as Map<String, dynamic>?;
    // ignore: unused_local_variable
    final focusAction = (properties['onFocus'] ?? properties['focus']) as Map<String, dynamic>?;

    // Parse style
    TextStyle? style;
    final styleDef = properties['style'];
    if (styleDef is Map<String, dynamic>) {
      style = TextStyle(
        fontSize: context.resolve<num?>(styleDef['fontSize'])?.toDouble(),
        fontWeight: _parseFontWeight(styleDef['fontWeight']),
        fontStyle: styleDef['fontStyle'] == 'italic' ? FontStyle.italic : null,
        color: parseColor(context.resolve(styleDef['color']), context),
        letterSpacing:
            context.resolve<num?>(styleDef['letterSpacing'])?.toDouble(),
        wordSpacing: context.resolve<num?>(styleDef['wordSpacing'])?.toDouble(),
        height: context.resolve<num?>(styleDef['height'])?.toDouble(),
      );
    }

    // Build text field with provided controller
    Widget textField = TextField(
      controller: controller,
      style: style,
      decoration: InputDecoration(
        hintText: hint,
        labelText: label,
        helperText: helperText,
        prefixIcon: prefixIcon != null ? Icon(_parseIcon(prefixIcon)) : null,
        suffixIcon: suffixIcon != null ? Icon(_parseIcon(suffixIcon)) : null,
        border: const OutlineInputBorder(),
        counterText: maxLength != null ? null : '',
        errorText: errorText,
      ),
      obscureText: obscureText,
      enabled: enabled,
      readOnly: readOnly,
      maxLines: maxLines,
      maxLength: maxLength,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onChanged: (newValue) {
        // Notify parent of value change
        onValueChanged(newValue);

        // Validate if rules are defined
        if (hasValidation) {
          ValidationEngine.validate(newValue, validationRules);
        }

        // Update state if binding is specified
        final path = properties['binding'] as String?;
        if (path != null) {
          context.setValue(path, newValue);
        }

        // Execute action if change is specified
        if (changeAction != null) {
          final eventContext = context.createChildContext(
            variables: {
              'event': {
                'value': newValue,
                'type': 'change',
              },
            },
          );
          eventContext.handleAction(changeAction);
        }
      },
      onSubmitted: (newValue) {
        // Update state if binding is specified
        final path = properties['binding'] as String?;
        if (path != null) {
          context.setValue(path, newValue);
        }

        // Execute action if submit is specified
        if (submitAction != null) {
          final eventContext = context.createChildContext(
            variables: {
              'event': {
                'value': newValue,
                'type': 'submit',
              },
            },
          );
          eventContext.handleAction(submitAction);
        }
      },
    );

    // Wrap in Focus if blur action is specified
    if (blurAction != null) {
      textField = Focus(
        onFocusChange: (hasFocus) {
          if (!hasFocus) {
            final eventContext = context.createChildContext(
              variables: {
                'event': {
                  'value': controller.text,
                  'type': 'blur',
                },
              },
            );
            eventContext.handleAction(blurAction);
          }
        },
        child: textField,
      );
    }

    return applyCommonWrappers(textField, properties, context);
  }

  TextInputType _parseKeyboardType(String? value) {
    switch (value) {
      case 'text':
        return TextInputType.text;
      case 'number':
        return TextInputType.number;
      case 'phone':
        return TextInputType.phone;
      case 'email':
      case 'emailAddress':
        return TextInputType.emailAddress;
      case 'url':
        return TextInputType.url;
      case 'multiline':
        return TextInputType.multiline;
      case 'datetime':
        return TextInputType.datetime;
      default:
        return TextInputType.text;
    }
  }

  TextInputAction _parseTextInputAction(String? value) {
    switch (value) {
      case 'done':
        return TextInputAction.done;
      case 'go':
        return TextInputAction.go;
      case 'next':
        return TextInputAction.next;
      case 'search':
        return TextInputAction.search;
      case 'send':
        return TextInputAction.send;
      default:
        return TextInputAction.done;
    }
  }

  IconData _parseIcon(String iconName) => resolveIconData(iconName);

  FontWeight? _parseFontWeight(String? weight) {
    switch (weight) {
      case 'bold':
        return FontWeight.bold;
      case 'w100':
        return FontWeight.w100;
      case 'w200':
        return FontWeight.w200;
      case 'w300':
        return FontWeight.w300;
      case 'w400':
      case 'normal':
        return FontWeight.w400;
      case 'w500':
        return FontWeight.w500;
      case 'w600':
        return FontWeight.w600;
      case 'w700':
        return FontWeight.w700;
      case 'w800':
        return FontWeight.w800;
      case 'w900':
        return FontWeight.w900;
      default:
        return null;
    }
  }
}

/// Debounced text field widget for performance optimization
class _DebouncedTextField extends StatefulWidget {
  final Map<String, dynamic> definition;
  final RenderContext context;
  final int debounceDelay;

  const _DebouncedTextField({
    required this.definition,
    required this.context,
    required this.debounceDelay,
  });

  @override
  State<_DebouncedTextField> createState() => _DebouncedTextFieldState();
}

class _DebouncedTextFieldState extends State<_DebouncedTextField> {
  late TextEditingController _controller;
  late Debouncer _debouncer;
  String? _lastValue;

  @override
  void initState() {
    super.initState();

    final properties = widget.context.renderer.widgetRegistry
        .get('TextField')!
        .extractProperties(widget.definition);

    // Get initial value
    final bindingPath = properties['binding'] as String?;
    String initialValue = '';
    if (bindingPath != null) {
      initialValue = widget.context.getState(bindingPath)?.toString() ?? '';
    } else {
      initialValue = widget.context.resolve<String>(properties['value'] ?? '');
    }

    _controller = TextEditingController(text: initialValue);
    _lastValue = initialValue;
    _debouncer = Debouncer(milliseconds: widget.debounceDelay);
  }

  @override
  void dispose() {
    _controller.dispose();
    _debouncer.dispose();
    super.dispose();
  }

  void _handleChange(String newValue) {
    final properties = widget.context.renderer.widgetRegistry
        .get('TextField')!
        .extractProperties(widget.definition);

    // Update local value immediately for responsive UI
    setState(() {
      _lastValue = newValue;
    });

    // Debounce the actual state update and action execution
    _debouncer.run(() {
      // Parse validation rules if provided
      final validationDef = properties['validation'];
      final validationRules = ValidationEngine.parseValidation(validationDef);
      if (validationRules.isNotEmpty) {
        ValidationEngine.validate(newValue, validationRules);
      }

      // Update state if binding is specified
      final path = properties['binding'] as String?;
      if (path != null) {
        widget.context.setValue(path, newValue);
      }

      // Execute action if change is specified
      final changeAction = (properties['onChange'] ?? properties['change']) as Map<String, dynamic>?;
      if (changeAction != null) {
        final eventContext = widget.context.createChildContext(
          variables: {
            'event': {
              'value': newValue,
              'type': 'change',
            },
          },
        );
        eventContext.handleAction(changeAction);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final factory = widget.context.renderer.widgetRegistry.get('TextField')
        as TextFieldWidgetFactory;
    final properties = factory.extractProperties(widget.definition);

    // Create a modified definition without change action (handled by debouncer)
    final modifiedDefinition = Map<String, dynamic>.from(widget.definition);
    final modifiedProperties = Map<String, dynamic>.from(properties);
    modifiedProperties.remove('change'); // Remove change action as we handle it
    modifiedProperties['value'] = _lastValue; // Use current value

    // Build text field without debouncing
    final textField =
        factory._buildTextField(modifiedDefinition, widget.context);

    // If it's wrapped in Focus, we need to intercept the TextField
    if (textField is Focus) {
      final focusChild = (textField).child;
      if (focusChild is TextField) {
        return Focus(
          onFocusChange: (textField).onFocusChange,
          child: TextField(
            controller: _controller,
            onChanged: _handleChange,
            style: focusChild.style,
            decoration: focusChild.decoration,
            obscureText: focusChild.obscureText,
            enabled: focusChild.enabled,
            readOnly: focusChild.readOnly,
            maxLines: focusChild.maxLines,
            maxLength: focusChild.maxLength,
            keyboardType: focusChild.keyboardType,
            textInputAction: focusChild.textInputAction,
            onSubmitted: focusChild.onSubmitted,
          ),
        );
      }
    }

    // If it's a direct TextField, replace onChanged
    if (textField is TextField) {
      return TextField(
        controller: _controller,
        onChanged: _handleChange,
        style: textField.style,
        decoration: textField.decoration,
        obscureText: textField.obscureText,
        enabled: textField.enabled,
        readOnly: textField.readOnly,
        maxLines: textField.maxLines,
        maxLength: textField.maxLength,
        keyboardType: textField.keyboardType,
        textInputAction: textField.textInputAction,
        onSubmitted: textField.onSubmitted,
      );
    }

    return textField;
  }
}

/// Stateful wrapper for TextField to properly manage TextEditingController
class _StatefulTextField extends StatefulWidget {
  final Map<String, dynamic> definition;
  final RenderContext context;

  const _StatefulTextField({
    required this.definition,
    required this.context,
  });

  @override
  State<_StatefulTextField> createState() => _StatefulTextFieldState();
}

class _StatefulTextFieldState extends State<_StatefulTextField> {
  late TextEditingController _controller;
  late String _currentValue;

  @override
  void initState() {
    super.initState();
    _initializeController();
  }

  void _initializeController() {
    final factory = widget.context.renderer.widgetRegistry.get('textInput')
        as TextFieldWidgetFactory;
    final properties = factory.extractProperties(widget.definition);

    // Get initial value from binding or value property
    final bindingPath = properties['binding'] as String?;
    String initialValue = '';
    if (bindingPath != null) {
      initialValue = widget.context.getState(bindingPath)?.toString() ?? '';
    } else {
      initialValue = widget.context.resolve<String>(properties['value'] ?? '');
    }

    _currentValue = initialValue;
    _controller = TextEditingController(text: initialValue);
  }

  @override
  void didUpdateWidget(covariant _StatefulTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    final factory = widget.context.renderer.widgetRegistry.get('textInput')
        as TextFieldWidgetFactory;
    final properties = factory.extractProperties(widget.definition);

    // Check if value from state has changed
    final bindingPath = properties['binding'] as String?;
    String newValue = '';
    if (bindingPath != null) {
      newValue = widget.context.getState(bindingPath)?.toString() ?? '';
    } else {
      newValue = widget.context.resolve<String>(properties['value'] ?? '');
    }

    // Only update controller if value actually changed from external source
    if (newValue != _currentValue && newValue != _controller.text) {
      _currentValue = newValue;
      // Preserve cursor position
      final selection = _controller.selection;
      _controller.text = newValue;
      // Restore cursor position if valid
      if (selection.baseOffset <= newValue.length) {
        _controller.selection = selection;
      } else {
        // Place cursor at end if previous position is invalid
        _controller.selection = TextSelection.fromPosition(
          TextPosition(offset: newValue.length),
        );
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final factory = widget.context.renderer.widgetRegistry.get('textInput')
        as TextFieldWidgetFactory;
    
    // Build the text field with our controller
    return factory._buildTextFieldWithController(
      widget.definition, 
      widget.context, 
      _controller,
      (value) {
        // Update our internal state
        _currentValue = value;
      }
    );
  }
}
