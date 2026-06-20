import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';
import '../../validation/validation_engine.dart';
import '../../validation/custom_validator.dart';

/// Factory for TextFormField widgets with advanced validation support
class TextFormFieldWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Check if async validation is enabled
    final asyncValidation = properties['asyncValidation'] as bool? ?? false;
    final customValidation = properties['customValidation'] as String?;

    if (asyncValidation || customValidation != null) {
      return _AsyncValidatedTextField(
        definition: definition,
        context: context,
        customValidation: customValidation,
      );
    }

    return _buildTextFormField(definition, context);
  }

  Widget _buildTextFormField(
      Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final hint = context.resolve<String?>(properties['hint']) ??
        context.resolve<String?>(properties['placeholder']) ??
        '';
    final label = properties['label'] as String?;
    final helperText = properties['helperText'] as String?;
    final prefixIcon = properties['prefixIcon'] as String?;
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

    // Parse validation rules
    final validationDef = properties['validation'];
    final validationRules = ValidationEngine.parseValidation(validationDef);

    // Check for custom validation expression
    final customValidation = properties['customValidation'] as String?;

    // Create controller if binding is specified
    final path = properties['binding'] as String?;
    TextEditingController? controller;
    if (path != null) {
      final initialValue = context.getValue<String?>(path) ??
          context.resolve<String?>(properties['value']) ??
          '';
      controller = TextEditingController(text: initialValue);
    }

    // Handle onChange action
    final changeAction = properties['onChange'] ?? properties['change'];
    final submitAction = properties['onSubmit'] ?? properties['submit'];

    // Build validator
    String? Function(String?)? validator;

    if (validationRules.isNotEmpty) {
      validator = ValidationEngine.createFlutterValidator(validationRules);
    }

    // Add custom validation if specified
    if (customValidation != null && validator != null) {
      final originalValidator = validator;
      validator = (value) {
        // First run standard validation
        final standardResult = originalValidator(value);
        if (standardResult != null) return standardResult;

        // Then run custom validation
        final customValidator = CustomValidator(
          expression: customValidation,
          bindingEngine: context.bindingEngine,
        );

        final result = customValidator.validate(value, context);
        return result.isValid ? null : result.message;
      };
    } else if (customValidation != null) {
      validator = (value) {
        final customValidator = CustomValidator(
          expression: customValidation,
          bindingEngine: context.bindingEngine,
        );

        final result = customValidator.validate(value, context);
        return result.isValid ? null : result.message;
      };
    }

    return TextFormField(
      controller: controller,
      decoration: InputDecoration(
        hintText: hint,
        labelText: label,
        helperText: helperText,
        prefixIcon: prefixIcon != null ? Icon(_parseIcon(prefixIcon)) : null,
        border: const OutlineInputBorder(),
      ),
      obscureText: obscureText,
      enabled: enabled,
      readOnly: readOnly,
      maxLines: maxLines,
      maxLength: maxLength,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      validator: validator,
      onChanged: (newValue) {
        // Update state if binding is specified
        if (path != null) {
          context.setValue(path, newValue);
        }

        // Execute action if change is specified
        if (changeAction != null) {
          context.actionHandler.execute(changeAction, context);
        }
      },
      onFieldSubmitted: submitAction != null
          ? (_) => context.actionHandler.execute(submitAction, context)
          : null,
    );
  }

  TextInputType _parseKeyboardType(dynamic type) {
    switch (type?.toString()) {
      case 'text':
        return TextInputType.text;
      case 'number':
        return TextInputType.number;
      case 'email':
        return TextInputType.emailAddress;
      case 'phone':
        return TextInputType.phone;
      case 'url':
        return TextInputType.url;
      case 'multiline':
        return TextInputType.multiline;
      default:
        return TextInputType.text;
    }
  }

  TextInputAction _parseTextInputAction(dynamic action) {
    switch (action?.toString()) {
      case 'done':
        return TextInputAction.done;
      case 'go':
        return TextInputAction.go;
      case 'next':
        return TextInputAction.next;
      case 'previous':
        return TextInputAction.previous;
      case 'search':
        return TextInputAction.search;
      case 'send':
        return TextInputAction.send;
      default:
        return TextInputAction.done;
    }
  }

  IconData _parseIcon(String iconName) {
    // Simple icon mapping - can be expanded
    switch (iconName) {
      case 'email':
        return Icons.email;
      case 'phone':
        return Icons.phone;
      case 'person':
        return Icons.person;
      case 'lock':
        return Icons.lock;
      case 'search':
        return Icons.search;
      default:
        return Icons.text_fields;
    }
  }
}

/// Async validated text field widget
class _AsyncValidatedTextField extends StatefulWidget {
  final Map<String, dynamic> definition;
  final RenderContext context;
  final String? customValidation;

  const _AsyncValidatedTextField({
    required this.definition,
    required this.context,
    this.customValidation,
  });

  @override
  State<_AsyncValidatedTextField> createState() =>
      _AsyncValidatedTextFieldState();
}

class _AsyncValidatedTextFieldState extends State<_AsyncValidatedTextField>
    with FormValidationMixin {
  late TextEditingController _controller;
  final GlobalKey<FormFieldState> _fieldKey = GlobalKey<FormFieldState>();
  RemoteValidator? _remoteValidator;

  @override
  void initState() {
    super.initState();

    final factory = TextFormFieldWidgetFactory();
    final properties = factory.extractProperties(widget.definition);
    final path = properties['binding'] as String?;
    final initialValue = path != null
        ? widget.context.getValue<String?>(path) ?? ''
        : widget.context.resolve<String?>(properties['value']) ?? '';

    _controller = TextEditingController(text: initialValue);

    // Setup remote validator if configured
    final remoteValidation =
        properties['remoteValidation'] as Map<String, dynamic>?;
    if (remoteValidation != null) {
      _remoteValidator = RemoteValidator(
        endpoint: remoteValidation['endpoint'] as String,
        headers: (remoteValidation['headers'] as Map?)?.cast<String, String>(),
        fieldName: remoteValidation['fieldName'] as String?,
        message: remoteValidation['message'] as String?,
        debounceMilliseconds: remoteValidation['debounce'] as int? ?? 500,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _remoteValidator?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final factory = TextFormFieldWidgetFactory();
    final properties = factory.extractProperties(widget.definition);

    // Extract properties
    final hint = widget.context.resolve<String?>(properties['hint']) ?? '';
    final label = properties['label'] as String?;
    final helperText = properties['helperText'] as String?;
    final prefixIcon = properties['prefixIcon'] as String?;
    final obscureText = properties['obscureText'] as bool? ?? false;
    final enabled = properties['enabled'] as bool? ?? true;

    // Handle onChange action
    final changeAction = properties['onChange'] ?? properties['change'];
    final path = properties['binding'] as String?;

    return AnimatedBuilder(
      animation: validationState,
      builder: (context, child) {
        final fieldError = validationState.getFieldError('field');
        final isPending = validationState.isFieldPending('field');

        return TextFormField(
          key: _fieldKey,
          controller: _controller,
          decoration: InputDecoration(
            hintText: hint,
            labelText: label,
            helperText: isPending ? 'Validating...' : helperText,
            errorText: fieldError,
            prefixIcon: prefixIcon != null
                ? Icon(TextFormFieldWidgetFactory()._parseIcon(prefixIcon))
                : null,
            suffixIcon: isPending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            border: const OutlineInputBorder(),
          ),
          obscureText: obscureText,
          enabled: enabled && !isPending,
          onChanged: (value) {
            // Update state if binding is specified
            if (path != null) {
              widget.context.setValue(path, value);
            }

            // Execute action if change is specified
            if (changeAction != null) {
              widget.context.actionHandler
                  .execute(changeAction, widget.context);
            }

            // Trigger async validation
            if (_remoteValidator != null) {
              validateField('field', value, _remoteValidator!, widget.context);
            }
          },
        );
      },
    );
  }
}
