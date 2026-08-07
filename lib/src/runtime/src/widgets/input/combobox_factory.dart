import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for `combobox` (spec §2.6.26).
///
/// The defining property is that a value outside `options` is legal — that is
/// what separates it from `select`, where the option list is the domain.
/// Composing it from a text field plus a list loses focus ownership: the list
/// must not steal focus, arrow keys must move a highlight without moving the
/// caret, and Escape must close the list without clearing the text.
class ComboboxFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final binding = stringOf(properties['binding'], context);
    final options = context.resolve<List<dynamic>?>(properties['options']) ?? const [];
    final allowCustom = context.resolve<bool?>(properties['allowCustom']) ?? true;
    final enabled = context.resolve<bool?>(properties['enabled']) ?? true;
    final label = context.resolve<String?>(properties['label']);
    final placeholder = context.resolve<String?>(properties['placeholder']);
    final minChars = context.resolve<num?>(properties['minChars'])?.toInt() ?? 1;
    final debounceMs =
        context.resolve<num?>(properties['debounceMs'])?.toInt() ?? 250;
    final onSearch = actionOf(properties['onSearch'], context);
    final onChange = actionOf(properties['onChange'], context);

    final current = binding != null
        ? (context.getState(binding)?.toString() ?? '')
        : (context.resolve<String?>(properties['value']) ?? '');

    final labels = <String>[
      for (final o in options)
        o is Map ? (o['label']?.toString() ?? o['value']?.toString() ?? '')
                 : o.toString(),
    ];

    void emit(Map<String, dynamic>? action, String value, String type) {
      if (action == null) return;
      context.actionHandler.execute(
        action,
        context.createChildContext(
          variables: {
            'event': {'value': value, 'query': value, 'type': type},
          },
        ),
      );
    }

    return _ComboboxField(
      value: current,
      suggestions: labels,
      allowCustom: allowCustom,
      enabled: enabled,
      label: label,
      placeholder: placeholder,
      minChars: minChars,
      debounce: Duration(milliseconds: debounceMs),
      onSearch: onSearch == null ? null : (q) => emit(onSearch, q, 'search'),
      onCommitted: (value) {
        if (binding != null) context.setValue(binding, value);
        emit(onChange, value, 'change');
      },
    );
  }
}

class _ComboboxField extends StatefulWidget {
  const _ComboboxField({
    required this.value,
    required this.suggestions,
    required this.allowCustom,
    required this.enabled,
    required this.minChars,
    required this.debounce,
    required this.onCommitted,
    this.onSearch,
    this.label,
    this.placeholder,
  });

  final String value;
  final List<String> suggestions;
  final bool allowCustom;
  final bool enabled;
  final int minChars;
  final Duration debounce;
  final ValueChanged<String> onCommitted;
  final ValueChanged<String>? onSearch;
  final String? label;
  final String? placeholder;

  @override
  State<_ComboboxField> createState() => _ComboboxFieldState();
}

class _ComboboxFieldState extends State<_ComboboxField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value);
  final FocusNode _focus = FocusNode();
  bool _open = false;
  int _highlight = -1;
  DateTime _lastSearch = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<String> get _matches {
    final q = _controller.text.toLowerCase();
    if (q.isEmpty) return widget.suggestions;
    return widget.suggestions
        .where((s) => s.toLowerCase().contains(q))
        .toList();
  }

  void _onChanged(String value) {
    setState(() {
      _open = value.length >= widget.minChars;
      _highlight = -1;
    });
    // A free value is legal, so the text is committed as typed — the list is
    // a suggestion surface, not the domain.
    if (widget.allowCustom) widget.onCommitted(value);
    final search = widget.onSearch;
    if (search != null && value.length >= widget.minChars) {
      final now = DateTime.now();
      if (now.difference(_lastSearch) >= widget.debounce) {
        _lastSearch = now;
        search(value);
      }
    }
  }

  void _select(String value) {
    _controller.text = value;
    setState(() {
      _open = false;
      _highlight = -1;
    });
    widget.onCommitted(value);
  }

  KeyEventResult _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final matches = _matches;
    switch (event.logicalKey.keyLabel) {
      case 'Arrow Down':
        if (matches.isEmpty) return KeyEventResult.ignored;
        // Moves the highlight without moving the caret — the part a composed
        // field and list gets wrong.
        setState(() {
          _open = true;
          _highlight = (_highlight + 1) % matches.length;
        });
        return KeyEventResult.handled;
      case 'Arrow Up':
        if (matches.isEmpty) return KeyEventResult.ignored;
        setState(() {
          _open = true;
          _highlight = (_highlight - 1 + matches.length) % matches.length;
        });
        return KeyEventResult.handled;
      case 'Enter':
        if (_open && _highlight >= 0 && _highlight < matches.length) {
          _select(matches[_highlight]);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      case 'Escape':
        if (_open) {
          // Closes the list and leaves the text alone.
          setState(() => _open = false);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Focus(
          onKeyEvent: (_, e) => _onKey(e),
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            enabled: widget.enabled,
            decoration: InputDecoration(
              labelText: widget.label,
              hintText: widget.placeholder,
              border: const OutlineInputBorder(),
            ),
            onChanged: _onChanged,
            onSubmitted: widget.allowCustom ? widget.onCommitted : null,
          ),
        ),
        if (_open && matches.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: Material(
              elevation: 2,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: matches.length,
                itemBuilder: (_, i) => ListTile(
                  dense: true,
                  selected: i == _highlight,
                  title: Text(matches[i]),
                  onTap: () => _select(matches[i]),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
