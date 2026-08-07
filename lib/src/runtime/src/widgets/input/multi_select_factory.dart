import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for `multiSelect` (spec §2.6.25).
///
/// Kept separate from `select` rather than a `multiple` flag on it: the bound
/// value changes shape — scalar to array — and a flag that silently changes
/// the type of what lands in state is something an author discovers at
/// runtime.
class MultiSelectFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final binding = stringOf(properties['binding'], context);
    final options = context.resolve<List<dynamic>?>(properties['options']) ?? const [];
    final placeholder = context.resolve<String?>(properties['placeholder']);
    final label = context.resolve<String?>(properties['label']);
    final enabled = context.resolve<bool?>(properties['enabled']) ?? true;
    final showChips = context.resolve<bool?>(properties['showChips']) ?? true;
    final selectAll = context.resolve<bool?>(properties['selectAll']) ?? false;
    final maxSelections = context.resolve<num?>(properties['maxSelections'])?.toInt();
    final onChange = actionOf(properties['onChange'], context);

    final selected = _selectedValues(binding, properties, context);

    void commit(List<dynamic> next) {
      if (binding != null) context.setValue(binding, next);
      if (onChange != null) {
        context.actionHandler.execute(
          onChange,
          context.createChildContext(
            variables: {
              'event': {'value': next, 'type': 'change'},
            },
          ),
        );
      }
    }

    final entries = options.map(_MultiSelectOption.from).toList();

    return _MultiSelectField(
      label: label,
      placeholder: placeholder,
      enabled: enabled,
      showChips: showChips,
      selectAll: selectAll,
      maxSelections: maxSelections,
      options: entries,
      selected: selected,
      onChanged: commit,
      searchable: context.resolve<bool?>(properties['searchable']) ?? false,
    );
  }

  List<dynamic> _selectedValues(
    String? binding,
    Map<String, dynamic> properties,
    RenderContext context,
  ) {
    final raw = binding != null
        ? context.getState(binding)
        : context.resolve<dynamic>(properties['value']);
    return raw is List ? List<dynamic>.from(raw) : const [];
  }
}

@immutable
class _MultiSelectOption {
  const _MultiSelectOption(this.value, this.label);

  factory _MultiSelectOption.from(dynamic option) {
    if (option is Map) {
      final value = option['value'];
      return _MultiSelectOption(
        value,
        option['label']?.toString() ?? value?.toString() ?? '',
      );
    }
    return _MultiSelectOption(option, option.toString());
  }

  final dynamic value;
  final String label;
}

class _MultiSelectField extends StatefulWidget {
  const _MultiSelectField({
    required this.options,
    required this.selected,
    required this.onChanged,
    required this.enabled,
    required this.showChips,
    required this.selectAll,
    required this.searchable,
    this.label,
    this.placeholder,
    this.maxSelections,
  });

  final List<_MultiSelectOption> options;
  final List<dynamic> selected;
  final ValueChanged<List<dynamic>> onChanged;
  final bool enabled;
  final bool showChips;
  final bool selectAll;
  final bool searchable;
  final String? label;
  final String? placeholder;
  final int? maxSelections;

  @override
  State<_MultiSelectField> createState() => _MultiSelectFieldState();
}

class _MultiSelectFieldState extends State<_MultiSelectField> {
  bool _open = false;
  String _query = '';

  bool get _atCeiling =>
      widget.maxSelections != null &&
      widget.selected.length >= widget.maxSelections!;

  void _toggle(_MultiSelectOption option) {
    final next = List<dynamic>.from(widget.selected);
    if (next.contains(option.value)) {
      next.remove(option.value);
    } else {
      // Reaching the ceiling disables unselected rows rather than dropping a
      // pick the user made (spec §2.6.25).
      if (_atCeiling) return;
      next.add(option.value);
    }
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final visible = _query.isEmpty
        ? widget.options
        : widget.options
            .where((o) => o.label.toLowerCase().contains(_query.toLowerCase()))
            .toList();

    final summary = widget.selected.isEmpty
        ? Text(
            widget.placeholder ?? '',
            style: TextStyle(color: Theme.of(context).hintColor),
          )
        : widget.showChips
            ? Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final v in widget.selected)
                    Chip(
                      label: Text(_labelFor(v)),
                      onDeleted: widget.enabled
                          ? () => _toggle(_MultiSelectOption(v, _labelFor(v)))
                          : null,
                    ),
                ],
              )
            : Text('${widget.selected.length} selected');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label != null) ...[
          Text(widget.label!, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
        ],
        InkWell(
          onTap: widget.enabled ? () => setState(() => _open = !_open) : null,
          child: InputDecorator(
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              enabled: widget.enabled,
              suffixIcon: Icon(_open ? Icons.arrow_drop_up : Icons.arrow_drop_down),
            ),
            child: summary,
          ),
        ),
        if (_open) ...[
          if (widget.searchable)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: TextField(
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          if (widget.selectAll)
            Row(
              children: [
                TextButton(
                  onPressed: widget.enabled
                      ? () => widget.onChanged(
                            widget.options.map((o) => o.value).toList(),
                          )
                      : null,
                  child: const Text('Select all'),
                ),
                TextButton(
                  onPressed:
                      widget.enabled ? () => widget.onChanged(const []) : null,
                  child: const Text('Clear'),
                ),
              ],
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final option in visible)
                  CheckboxListTile(
                    dense: true,
                    value: widget.selected.contains(option.value),
                    title: Text(option.label),
                    // Disabled at the ceiling, not silently ignored.
                    onChanged: widget.enabled &&
                            (!_atCeiling ||
                                widget.selected.contains(option.value))
                        ? (_) => _toggle(option)
                        : null,
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  String _labelFor(dynamic value) => widget.options
      .firstWhere(
        (o) => o.value == value,
        orElse: () => _MultiSelectOption(value, value.toString()),
      )
      .label;
}
