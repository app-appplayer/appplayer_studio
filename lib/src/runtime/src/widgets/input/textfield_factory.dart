import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';
import '../../validation/validation_engine.dart';
import '../../utils/debounce.dart';
import '../../utils/icon_resolver.dart';

/// Factory for TextField widgets
class TextFieldWidgetFactory extends WidgetFactory {
  /// Controllers whose obscured field is currently revealed. Keyed by
  /// controller so two password fields on a page toggle independently, and
  /// held here rather than in a local so the flag survives the rebuild the
  /// toggle itself triggers.
  static final Set<Object> _revealed = <Object>{};

  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Check if debouncing is enabled
    final debounceDelay = readInt(properties['debounce'], context);

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

  /// Builds the field.
  ///
  /// [controllerOverride] / [onChangedOverride] are for the debounced wrapper,
  /// which owns both. It used to take the finished widget apart and rebuild a
  /// `TextField` around its own handler — which worked only while the result
  /// WAS a `TextField` or a `Focus` around one. A document that also declared
  /// `visible`, `tooltip` or `click` got a wrapper back, the rebuild did not
  /// recognise it, and the field was returned untouched: the debounce was
  /// silently gone and the field was driven by a different controller than the
  /// one holding the debounced value.
  Widget _buildTextField(
    Map<String, dynamic> definition,
    RenderContext context, {
    required TextEditingController controller,
    required void Function(String) onChanged,
  }) {
    final properties = extractProperties(definition);

    // Extract properties
    final hint = context.resolve<String?>(properties['hint']) ??
        context.resolve<String?>(properties['placeholder']) ??
        '';
    final label = readString(properties['label'], context);
    final helperText = readString(properties['helperText'], context);
    final prefixIcon = readString(properties['prefixIcon'], context);
    final suffixIcon = readString(properties['suffixIcon'], context);
    final obscureText = readBool(properties['obscureText'], context) ?? false;
    final enabled = readBool(properties['enabled'], context) ?? true;
    final readOnly = readBool(properties['readOnly'], context) ?? false;
    final maxLines = dimensionOf(properties['maxLines'], context)?.toInt() ?? 1;
    final maxLength = dimensionOf(properties['maxLength'], context)?.toInt();
    // spec v1.0: 'inputType', legacy: 'keyboardType'
    final keyboardType = _parseKeyboardType(
        readEnum(properties['inputType'] ?? properties['keyboardType'], context));
    final textInputAction =
        _parseTextInputAction(properties['textInputAction']);

    // Parse validation rules if provided
    final validationDef = properties['validation'];
    // Parsed for the decoration below; the debounced path validates through
    // its own handler.
    ValidationEngine.parseValidation(validationDef);

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

    // Get event handlers - MCP UI DSL v1.0 spec.
    // `onChange` is the debouncer's, injected above.
    final submitAction = actionOf(properties['onSubmit'] ?? properties['submit'], context);
    final blurAction = actionOf(properties['onBlur'] ?? properties['blur'], context);
    final focusAction = actionOf(properties['onFocus'] ?? properties['focus'], context);

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
        height: readLineHeight(styleDef, context),
      );
    }

    final showToggle =
        (readBool(properties['showToggle'], context) ?? false) && obscureText;

    // `defaultCountry` (ISO 3166-1 alpha-2) seeds the dialling code on a phone
    // field. Declared in 1.4 and never read, so a document naming a country
    // got an empty field and no prefix.
    final inputTypeName =
        readEnum(properties['inputType'] ?? properties['keyboardType'], context);
    final defaultCountry = inputTypeName == 'phone'
        ? readEnum(properties['defaultCountry'], context)
        : null;
    final diallingPrefix = _diallingCodes[defaultCountry?.toUpperCase()];
    // The prefix is DECORATION, not content: it is drawn by `prefixText`
    // below. Seeding the controller with it as well put the code on screen
    // twice ("+82+82…" as soon as anything was typed) and wrote into the
    // field without writing to the binding, so what was displayed and what
    // the document held disagreed from the first frame. Only the debounced
    // path ever showed it, because that path threw this controller away.

    Widget buildField({required bool obscure, Widget? extraSuffix}) => TextField(
      controller: controller,
      style: style,
      decoration: InputDecoration(
        hintText: hint,
        labelText: label,
        helperText: helperText,
        prefixIcon: prefixIcon != null ? Icon(_parseIcon(prefixIcon)) : null,
        prefixText: diallingPrefix,
        suffixIcon: extraSuffix ??
            (suffixIcon != null ? Icon(_parseIcon(suffixIcon)) : null),
        border: const OutlineInputBorder(),
        counterText: maxLength != null ? null : '',
        errorText: errorText,
      ),
      obscureText: obscure,
      enabled: enabled,
      readOnly: readOnly,
      maxLines: maxLines,
      maxLength: maxLength,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onChanged: onChanged,
      onSubmitted: (newValue) {
        // Update state if binding is specified
        final path = readString(properties['binding'], context);
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

    Widget textField = showToggle
        ? StatefulBuilder(
            builder: (_, setLocal) {
              return buildField(
                obscure: !_revealed.contains(controller),
                extraSuffix: IconButton(
                  icon: Icon(_revealed.contains(controller)
                      ? Icons.visibility_off
                      : Icons.visibility),
                  onPressed: () => setLocal(() {
                    if (!_revealed.remove(controller)) _revealed.add(controller);
                  }),
                ),
              );
            },
          )
        : buildField(obscure: obscureText);

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
    Function(String) onValueChanged, {
    String? validationMessage,
    void Function(String? message)? onValidated,
  }) {
    final properties = extractProperties(definition);

    // Extract properties
    final hint = context.resolve<String?>(properties['hint']) ??
        context.resolve<String?>(properties['placeholder']) ??
        '';
    final label = readString(properties['label'], context);
    final helperText = readString(properties['helperText'], context);
    final prefixIcon = readString(properties['prefixIcon'], context);
    final suffixIcon = readString(properties['suffixIcon'], context);
    final obscureText = readBool(properties['obscureText'], context) ?? false;
    final enabled = readBool(properties['enabled'], context) ?? true;
    final readOnly = readBool(properties['readOnly'], context) ?? false;
    final maxLines = dimensionOf(properties['maxLines'], context)?.toInt() ?? 1;
    final maxLength = dimensionOf(properties['maxLength'], context)?.toInt();
    // spec v1.0: 'inputType', legacy: 'keyboardType'
    final keyboardType = _parseKeyboardType(
        readEnum(properties['inputType'] ?? properties['keyboardType'], context));
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
    final changeAction = actionOf(properties['onChange'] ?? properties['change'], context);
    final submitAction = actionOf(properties['onSubmit'] ?? properties['submit'], context);
    final blurAction = actionOf(properties['onBlur'] ?? properties['blur'], context);
    // Read and dropped: a field declaring `onFocus` never fired it, while
    // `onBlur` beside it worked.
    final focusAction = actionOf(properties['onFocus'] ?? properties['focus'], context);

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
        height: readLineHeight(styleDef, context),
      );
    }

    // `showToggle` and `defaultCountry` (1.4) are computed here as
    // well as in `_buildTextField`. There are two builders in this file — this
    // one runs for an ordinary field, the other for a debounced one — and both
    // slots were implemented only in the other. A document declaring either
    // got nothing, on the path almost every document takes.
    final showToggle =
        (readBool(properties['showToggle'], context) ?? false) && obscureText;
    final inputTypeName =
        readEnum(properties['inputType'] ?? properties['keyboardType'], context);
    final diallingPrefix = inputTypeName == 'phone'
        ? _diallingCodes[
            readEnum(properties['defaultCountry'], context)?.toUpperCase()]
        : null;
    // The prefix is DECORATION, not content: it is drawn by `prefixText`
    // below. Seeding the controller with it as well put the code on screen
    // twice ("+82+82…" as soon as anything was typed) and wrote into the
    // field without writing to the binding, so what was displayed and what
    // the document held disagreed from the first frame. Only the debounced
    // path ever showed it, because that path threw this controller away.

    // Build text field with provided controller
    Widget buildField({required bool obscure, Widget? extraSuffix}) => TextField(
      controller: controller,
      style: style,
      decoration: InputDecoration(
        hintText: hint,
        labelText: label,
        helperText: helperText,
        prefixIcon: prefixIcon != null ? Icon(_parseIcon(prefixIcon)) : null,
        prefixText: diallingPrefix,
        suffixIcon: extraSuffix ??
            (suffixIcon != null ? Icon(_parseIcon(suffixIcon)) : null),
        border: const OutlineInputBorder(),
        counterText: maxLength != null ? null : '',
        // An explicit `error` wins; otherwise the field shows what its own
        // validation rules said about the current value.
        errorText: errorText ?? validationMessage,
      ),
      obscureText: obscure,
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
          final result = ValidationEngine.validate(newValue, validationRules);
          onValidated?.call(result.isValid ? null : result.message);
        }

        // Update state if binding is specified
        final path = readString(properties['binding'], context);
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
        final path = readString(properties['binding'], context);
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

    Widget textField = showToggle
        ? StatefulBuilder(
            builder: (_, setLocal) => buildField(
              obscure: !_revealed.contains(controller),
              extraSuffix: IconButton(
                icon: Icon(_revealed.contains(controller)
                    ? Icons.visibility_off
                    : Icons.visibility),
                onPressed: () => setLocal(() {
                  if (!_revealed.remove(controller)) _revealed.add(controller);
                }),
              ),
            ),
          )
        : buildField(obscure: obscureText);

    // Wrap in Focus when either focus action is specified
    if (blurAction != null || focusAction != null) {
      textField = Focus(
        onFocusChange: (hasFocus) {
          final action = hasFocus ? focusAction : blurAction;
          if (action == null) return;
          final eventContext = context.createChildContext(
            variables: {
              'event': {
                'value': controller.text,
                'type': hasFocus ? 'focus' : 'blur',
              },
            },
          );
          eventContext.handleAction(action);
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

    // The registry key is `textInput` (the canonical widget name); asking for
    // `TextField` returned null and the `!` threw, so *any* field declaring
    // `debounce` took the page down with a null-check error the author could
    // not connect to the property they had just added.
    final properties = widget.context.renderer.widgetRegistry
        .get('textInput')!
        .extractProperties(widget.definition);

    // Get initial value
    final bindingPath = readString(properties['binding'], widget.context);
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
    // The registry key is `textInput` (the canonical widget name); asking for
    // `TextField` returned null and the `!` threw, so *any* field declaring
    // `debounce` took the page down with a null-check error the author could
    // not connect to the property they had just added.
    final properties = widget.context.renderer.widgetRegistry
        .get('textInput')!
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
      final path = readString(properties['binding'], widget.context);
      if (path != null) {
        widget.context.setValue(path, newValue);
      }

      // Execute action if change is specified
      final changeAction = readAction(
          properties['onChange'] ?? properties['change'], widget.context);
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
    // Same registry key as initState — `textInput`.
    final factory = widget.context.renderer.widgetRegistry.get('textInput')
        as TextFieldWidgetFactory;
    final properties = factory.extractProperties(widget.definition);

    // Create a modified definition without change action (handled by debouncer)
    final modifiedDefinition = Map<String, dynamic>.from(widget.definition);
    final modifiedProperties = Map<String, dynamic>.from(properties);
    modifiedProperties.remove('change'); // Remove change action as we handle it
    modifiedProperties['value'] = _lastValue; // Use current value

    // The debouncer owns the controller and the change handler; everything
    // else — including whatever wrappers the document declared — comes back
    // from the builder untouched.
    return factory._buildTextField(
      modifiedDefinition,
      widget.context,
      controller: _controller,
      onChanged: _handleChange,
    );
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
  String? _validationMessage;
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
    final bindingPath = readString(properties['binding'], widget.context);
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
    final bindingPath = readString(properties['binding'], widget.context);
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
      },
      validationMessage: _validationMessage,
      onValidated: (message) {
        if (message == _validationMessage) return;
        // Validation used to run and its result was dropped on the floor —
        // `ValidationEngine.validate(...)` was called and the answer thrown
        // away under a comment saying it would be used "later if needed". A
        // declared `validation` block therefore did nothing at all, which
        // reads as input that was always valid.
        setState(() => _validationMessage = message);
      },
    );
  }
}

/// Dialling codes for the countries a `phone` field can seed from
/// `defaultCountry`. Kept to the ISO alpha-2 codes the spec names; an
/// unlisted country simply seeds nothing rather than guessing a prefix.
const Map<String, String> _diallingCodes = <String, String>{
  'KR': '+82', 'US': '+1', 'CA': '+1', 'JP': '+81', 'CN': '+86',
  'GB': '+44', 'DE': '+49', 'FR': '+33', 'IT': '+39', 'ES': '+34',
  'NL': '+31', 'SE': '+46', 'NO': '+47', 'DK': '+45', 'FI': '+358',
  'AU': '+61', 'NZ': '+64', 'IN': '+91', 'SG': '+65', 'HK': '+852',
  'TW': '+886', 'BR': '+55', 'MX': '+52', 'AR': '+54', 'ZA': '+27',
  'AE': '+971', 'SA': '+966', 'RU': '+7', 'PL': '+48', 'CH': '+41',
};
