import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for `otpInput` (spec §2.6.27).
///
/// Exists because the composed version is reliably broken. A row of
/// `textInput`s loses paste distribution (a pasted code lands entirely in the
/// first cell), focus movement on entry and delete, and the platform's
/// one-time-code autofill — which needs a single field declaring that intent.
/// None of the three can be recovered by the author.
class OtpInputFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final binding = properties['binding'] as String?;
    final length = context.resolve<num?>(properties['length'])?.toInt() ?? 6;
    final inputType =
        context.resolve<String?>(properties['inputType']) ?? 'numeric';
    final masked = context.resolve<bool?>(properties['masked']) ?? false;
    final enabled = context.resolve<bool?>(properties['enabled']) ?? true;
    final autofill = context.resolve<bool?>(properties['autofill']) ?? true;
    final autoSubmit = properties['autoSubmit'] as Map<String, dynamic>?;
    final onChange = properties['onChange'] as Map<String, dynamic>?;

    final current = binding != null
        ? (context.getState(binding)?.toString() ?? '')
        : (context.resolve<String?>(properties['value']) ?? '');

    void emit(Map<String, dynamic>? action, String value) {
      if (action == null) return;
      context.actionHandler.execute(
        action,
        context.createChildContext(
          variables: {
            'event': {'value': value, 'type': 'change'},
          },
        ),
      );
    }

    return _OtpField(
      length: length,
      value: current,
      masked: masked,
      enabled: enabled,
      autofill: autofill,
      numeric: inputType != 'alphanumeric',
      onChanged: (value) {
        if (binding != null) context.setValue(binding, value);
        emit(onChange, value);
        // Fires once the last cell is filled, so the common case needs no
        // separate button.
        if (value.length == length) emit(autoSubmit, value);
      },
    );
  }
}

class _OtpField extends StatefulWidget {
  const _OtpField({
    required this.length,
    required this.value,
    required this.onChanged,
    required this.masked,
    required this.enabled,
    required this.numeric,
    required this.autofill,
  });

  final int length;
  final String value;
  final ValueChanged<String> onChanged;
  final bool masked;
  final bool enabled;
  final bool numeric;
  final bool autofill;

  @override
  State<_OtpField> createState() => _OtpFieldState();
}

class _OtpFieldState extends State<_OtpField> {
  late final List<FocusNode> _nodes =
      List.generate(widget.length, (_) => FocusNode());
  late final List<TextEditingController> _controllers = List.generate(
    widget.length,
    (i) => TextEditingController(
      text: i < widget.value.length ? widget.value[i] : '',
    ),
  );

  @override
  void dispose() {
    for (final n in _nodes) {
      n.dispose();
    }
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  String get _joined => _controllers.map((c) => c.text).join();

  /// Distributes a pasted or autofilled string across the cells.
  ///
  /// This is the behaviour a composed row cannot have: the platform delivers
  /// the whole code to whichever field has focus, and without redistribution
  /// it sits in that one cell.
  void _distribute(String raw, int from) {
    final chars = raw.split('');
    var i = from;
    for (final ch in chars) {
      if (i >= widget.length) break;
      _controllers[i].text = ch;
      i++;
    }
    final next = i.clamp(0, widget.length - 1);
    _nodes[next].requestFocus();
    setState(() {});
    widget.onChanged(_joined);
  }

  void _onCellChanged(int index, String value) {
    if (value.length > 1) {
      _distribute(value, index);
      return;
    }
    if (value.isNotEmpty && index < widget.length - 1) {
      _nodes[index + 1].requestFocus();
    }
    widget.onChanged(_joined);
  }

  KeyEventResult _onKey(int index, KeyEvent event) {
    // Backspace on an empty cell steps back, which is what makes correcting a
    // code feel like editing one field rather than six.
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.backspace &&
        _controllers[index].text.isEmpty &&
        index > 0) {
      _nodes[index - 1].requestFocus();
      _controllers[index - 1].clear();
      widget.onChanged(_joined);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final cells = <Widget>[
      for (var i = 0; i < widget.length; i++)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: SizedBox(
            width: 44,
            child: Focus(
              onKeyEvent: (_, event) => _onKey(i, event),
              child: TextField(
                controller: _controllers[i],
                focusNode: _nodes[i],
                enabled: widget.enabled,
                obscureText: widget.masked,
                textAlign: TextAlign.center,
                maxLength: 1,
                keyboardType: widget.numeric
                    ? TextInputType.number
                    : TextInputType.text,
                inputFormatters: widget.numeric
                    ? [FilteringTextInputFormatter.digitsOnly]
                    : null,
                decoration: const InputDecoration(
                  counterText: '',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => _onCellChanged(i, v),
              ),
            ),
          ),
        ),
    ];

    final row = Row(mainAxisSize: MainAxisSize.min, children: cells);

    // The platform needs one field declaring one-time-code intent; a runtime
    // without autofill support renders normally rather than failing.
    return widget.autofill
        ? AutofillGroup(child: row)
        : row;
  }
}
