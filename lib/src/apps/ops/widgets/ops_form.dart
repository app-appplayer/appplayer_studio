// Ops form system — declare a per-page schema → auto-render Material
// widgets. Toggles between YAML editing and form editing.
//
// Field types
//   text       — single-line text
//   multiline  — multi-line text (lines = row count)
//   number     — int / double
//   bool       — switch
//   select     — dropdown (options static or callback)
//   array      — string[] when itemSchema is null, object[] otherwise
//   keyValue   — Map<String, dynamic> (free-form key/value)
//
// Render result forwards [OpsForm.value] changes via [onChanged].

import 'package:flutter/material.dart';
import 'package:yaml/yaml.dart' as yaml_pkg;

import '../theme/tokens.dart';

enum OpsFieldType { text, multiline, number, boolean, select, array, keyValue }

class OpsFieldOption {
  const OpsFieldOption({required this.value, required this.label});
  final String value;
  final String label;
}

class OpsField {
  const OpsField({
    required this.name,
    required this.type,
    this.label,
    this.required = false,
    this.placeholder,
    this.description,
    this.lines = 1,
    this.options,
    this.optionsBuilder,
    this.itemSchema,
  });

  final String name;
  final OpsFieldType type;
  final String? label;
  final bool required;
  final String? placeholder;
  final String? description;
  final int lines;
  final List<OpsFieldOption>? options;
  final List<OpsFieldOption> Function()? optionsBuilder;
  final List<OpsField>? itemSchema;
}

class OpsForm extends StatelessWidget {
  const OpsForm({
    super.key,
    required this.schema,
    required this.value,
    required this.onChanged,
  });

  final List<OpsField> schema;
  final Map<String, dynamic> value;
  final ValueChanged<Map<String, dynamic>> onChanged;

  void _set(String key, dynamic v) {
    final next = Map<String, dynamic>.from(value);
    if (v == null) {
      next.remove(key);
    } else {
      next[key] = v;
    }
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final f in schema) ...[
          _Row(
            field: f,
            value: value[f.name],
            onChanged: (v) => _set(f.name, v),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.field,
    required this.value,
    required this.onChanged,
  });
  final OpsField field;
  final dynamic value;
  final ValueChanged<dynamic> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            '${field.label ?? field.name}${field.required ? " *" : ""}',
            style: TextStyle(
              fontFamily: OpsType.mono,
              fontSize: 11,
              fontWeight: OpsType.semibold,
              color: OpsColors.text2,
              letterSpacing: 0.4,
            ),
          ),
        ),
        _editor(),
        if (field.description != null && field.description!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              field.description!,
              style: TextStyle(
                fontFamily: OpsType.mono,
                fontSize: 10,
                color: OpsColors.text3,
              ),
            ),
          ),
      ],
    );
  }

  Widget _editor() {
    switch (field.type) {
      case OpsFieldType.text:
      case OpsFieldType.multiline:
        return _TextInput(field: field, value: value, onChanged: onChanged);
      case OpsFieldType.number:
        return _NumberInput(field: field, value: value, onChanged: onChanged);
      case OpsFieldType.boolean:
        return _BoolInput(value: value as bool? ?? false, onChanged: onChanged);
      case OpsFieldType.select:
        return _SelectInput(
          field: field,
          value: value as String?,
          onChanged: onChanged,
        );
      case OpsFieldType.array:
        return _ArrayInput(
          field: field,
          items: (value as List?)?.cast<dynamic>() ?? const [],
          onChanged: onChanged,
        );
      case OpsFieldType.keyValue:
        return _KeyValueInput(
          value: (value as Map?)?.cast<String, dynamic>() ?? const {},
          onChanged: onChanged,
        );
    }
  }
}

class _TextInput extends StatefulWidget {
  const _TextInput({
    required this.field,
    required this.value,
    required this.onChanged,
  });
  final OpsField field;
  final dynamic value;
  final ValueChanged<String?> onChanged;
  @override
  State<_TextInput> createState() => _TextInputState();
}

class _TextInputState extends State<_TextInput> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.value?.toString() ?? '',
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lines =
        widget.field.type == OpsFieldType.multiline
            ? (widget.field.lines == 1 ? 3 : widget.field.lines)
            : 1;
    return TextField(
      controller: _ctrl,
      maxLines: lines,
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.field.placeholder,
      ),
      onChanged: (v) => widget.onChanged(v.isEmpty ? null : v),
    );
  }
}

class _NumberInput extends StatefulWidget {
  const _NumberInput({
    required this.field,
    required this.value,
    required this.onChanged,
  });
  final OpsField field;
  final dynamic value;
  final ValueChanged<num?> onChanged;
  @override
  State<_NumberInput> createState() => _NumberInputState();
}

class _NumberInputState extends State<_NumberInput> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.value?.toString() ?? '',
  );
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.field.placeholder,
      ),
      onChanged: (v) => widget.onChanged(v.isEmpty ? null : num.tryParse(v)),
    );
  }
}

class _BoolInput extends StatelessWidget {
  const _BoolInput({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) =>
      Switch(value: value, onChanged: onChanged);
}

class _SelectInput extends StatelessWidget {
  const _SelectInput({
    required this.field,
    required this.value,
    required this.onChanged,
  });
  final OpsField field;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = field.optionsBuilder?.call() ?? field.options ?? const [];
    final exists = value != null && options.any((o) => o.value == value);
    return DropdownButtonFormField<String>(
      initialValue: exists ? value : null,
      isDense: true,
      decoration: InputDecoration(
        isDense: true,
        hintText: field.placeholder ?? 'Select…',
      ),
      items: [
        for (final o in options)
          DropdownMenuItem(value: o.value, child: Text(o.label)),
      ],
      onChanged: onChanged,
    );
  }
}

class _ArrayInput extends StatelessWidget {
  const _ArrayInput({
    required this.field,
    required this.items,
    required this.onChanged,
  });
  final OpsField field;
  final List<dynamic> items;
  final ValueChanged<List<dynamic>> onChanged;

  @override
  Widget build(BuildContext context) {
    final inner = field.itemSchema;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: OpsColors.border),
        borderRadius: OpsRadius.all_sm,
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 8),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontFamily: OpsType.mono,
                      fontSize: 10,
                      color: OpsColors.text3,
                    ),
                  ),
                ),
                Expanded(
                  child:
                      inner == null
                          ? TextField(
                            controller: TextEditingController(
                              text: items[i]?.toString() ?? '',
                            ),
                            decoration: const InputDecoration(isDense: true),
                            onSubmitted: (v) {
                              final next = List<dynamic>.from(items);
                              next[i] = v;
                              onChanged(next);
                            },
                          )
                          : OpsForm(
                            schema: inner,
                            value:
                                (items[i] as Map?)?.cast<String, dynamic>() ??
                                {},
                            onChanged: (v) {
                              final next = List<dynamic>.from(items);
                              next[i] = v;
                              onChanged(next);
                            },
                          ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 14),
                  tooltip: 'Remove',
                  onPressed: () {
                    final next = List<dynamic>.from(items);
                    next.removeAt(i);
                    onChanged(next);
                  },
                ),
              ],
            ),
            if (i < items.length - 1)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Divider(height: 1),
              ),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.add, size: 14),
              label: const Text('Add item'),
              onPressed: () {
                final next = List<dynamic>.from(items);
                next.add(inner == null ? '' : <String, dynamic>{});
                onChanged(next);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyValueInput extends StatefulWidget {
  const _KeyValueInput({required this.value, required this.onChanged});
  final Map<String, dynamic> value;
  final ValueChanged<Map<String, dynamic>> onChanged;
  @override
  State<_KeyValueInput> createState() => _KeyValueInputState();
}

class _KeyValueInputState extends State<_KeyValueInput> {
  late List<MapEntry<String, dynamic>> _entries = widget.value.entries.toList();

  void _emit() {
    widget.onChanged({for (final e in _entries) e.key: e.value});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: OpsColors.border),
        borderRadius: OpsRadius.all_sm,
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < _entries.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 140,
                    child: TextField(
                      controller: TextEditingController(text: _entries[i].key),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'key',
                      ),
                      onSubmitted: (k) {
                        setState(() {
                          _entries[i] = MapEntry(k, _entries[i].value);
                        });
                        _emit();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: TextEditingController(
                        text: _entries[i].value?.toString() ?? '',
                      ),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'value',
                      ),
                      onSubmitted: (v) {
                        setState(() {
                          _entries[i] = MapEntry(_entries[i].key, v);
                        });
                        _emit();
                      },
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 14),
                    tooltip: 'Remove',
                    onPressed: () {
                      setState(() => _entries.removeAt(i));
                      _emit();
                    },
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.add, size: 14),
              label: const Text('Add key'),
              onPressed: () {
                setState(() {
                  _entries.add(MapEntry('key${_entries.length + 1}', ''));
                });
                _emit();
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ----- Dynamic / schema-less editor -------------------------------------
//
// [OpsYamlEditor] is a dynamic form — edits any Map<String, dynamic>
// tree without a declared schema. Widget is picked by each entry's
// runtime type:
//   String   → text input
//   num      → number input
//   bool     → switch
//   List     → recurse (each item is dynamic)
//   Map      → recurse (key + value both editable)
//   null     → empty text (treated as String on edit)
//
// When `partialSchema` carries a subset of fields, those keys pick up
// select / hint / required from the schema; the rest fall through to
// generic rendering.

class OpsYamlEditor extends StatefulWidget {
  const OpsYamlEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.partialSchema,
  });

  final Map<String, dynamic> value;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final List<OpsField>? partialSchema;

  @override
  State<OpsYamlEditor> createState() => _OpsYamlEditorState();
}

class _OpsYamlEditorState extends State<OpsYamlEditor> {
  @override
  Widget build(BuildContext context) {
    return _DynamicMap(
      value: widget.value,
      onChanged: widget.onChanged,
      schema: widget.partialSchema,
    );
  }
}

class _DynamicMap extends StatefulWidget {
  const _DynamicMap({
    required this.value,
    required this.onChanged,
    this.schema,
  });
  final Map<String, dynamic> value;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final List<OpsField>? schema;

  @override
  State<_DynamicMap> createState() => _DynamicMapState();
}

class _DynamicMapState extends State<_DynamicMap> {
  late final List<MapEntry<String, dynamic>> _keys = _orderEntries(
    widget.value,
    widget.schema,
  );

  static List<MapEntry<String, dynamic>> _orderEntries(
    Map<String, dynamic> v,
    List<OpsField>? schema,
  ) {
    if (schema == null) return v.entries.toList();
    final ordered = <MapEntry<String, dynamic>>[];
    final seen = <String>{};
    for (final f in schema) {
      seen.add(f.name);
      ordered.add(MapEntry(f.name, v[f.name]));
    }
    for (final e in v.entries) {
      if (!seen.contains(e.key)) ordered.add(e);
    }
    return ordered;
  }

  void _emit() {
    widget.onChanged({for (final e in _keys) e.key: e.value});
  }

  OpsField? _schemaFor(String key) {
    if (widget.schema == null) return null;
    for (final f in widget.schema!) {
      if (f.name == key) return f;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _keys.length; i++) ...[
          _DynamicEntry(
            schemaField: _schemaFor(_keys[i].key),
            keyName: _keys[i].key,
            value: _keys[i].value,
            onKeyChanged: (k) {
              setState(() => _keys[i] = MapEntry(k, _keys[i].value));
              _emit();
            },
            onValueChanged: (v) {
              setState(() => _keys[i] = MapEntry(_keys[i].key, v));
              _emit();
            },
            onRemove:
                _schemaFor(_keys[i].key) != null
                    ? null
                    : () {
                      setState(() => _keys.removeAt(i));
                      _emit();
                    },
          ),
          const SizedBox(height: 10),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.add, size: 14),
            label: const Text('Add field'),
            onPressed: () {
              setState(
                () => _keys.add(MapEntry('field${_keys.length + 1}', '')),
              );
              _emit();
            },
          ),
        ),
      ],
    );
  }
}

class _DynamicEntry extends StatelessWidget {
  const _DynamicEntry({
    required this.schemaField,
    required this.keyName,
    required this.value,
    required this.onKeyChanged,
    required this.onValueChanged,
    required this.onRemove,
  });

  final OpsField? schemaField;
  final String keyName;
  final dynamic value;
  final ValueChanged<String> onKeyChanged;
  final ValueChanged<dynamic> onValueChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final label = schemaField?.label ?? keyName;
    final required = schemaField?.required == true ? ' *' : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child:
                  schemaField != null
                      ? Text(
                        '$label$required',
                        style: TextStyle(
                          fontFamily: OpsType.mono,
                          fontSize: 11,
                          fontWeight: OpsType.semibold,
                          color: OpsColors.text2,
                          letterSpacing: 0.4,
                        ),
                      )
                      : SizedBox(
                        child: TextField(
                          controller: TextEditingController(text: keyName),
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: 'key',
                          ),
                          style: TextStyle(
                            fontFamily: OpsType.mono,
                            fontSize: 11,
                            color: OpsColors.text2,
                          ),
                          onSubmitted: onKeyChanged,
                        ),
                      ),
            ),
            if (onRemove != null)
              IconButton(
                icon: const Icon(Icons.close, size: 14),
                tooltip: 'Remove',
                onPressed: onRemove,
              ),
          ],
        ),
        const SizedBox(height: 4),
        _DynamicValue(
          schemaField: schemaField,
          value: value,
          onChanged: onValueChanged,
        ),
        if (schemaField?.description != null &&
            schemaField!.description!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              schemaField!.description!,
              style: TextStyle(
                fontFamily: OpsType.mono,
                fontSize: 10,
                color: OpsColors.text3,
              ),
            ),
          ),
      ],
    );
  }
}

class _DynamicValue extends StatelessWidget {
  const _DynamicValue({
    required this.schemaField,
    required this.value,
    required this.onChanged,
  });
  final OpsField? schemaField;
  final dynamic value;
  final ValueChanged<dynamic> onChanged;

  @override
  Widget build(BuildContext context) {
    // Schema-driven path: render via [OpsForm] field types when present.
    if (schemaField != null) {
      return _Row(
        field: OpsField(
          name: schemaField!.name,
          type: schemaField!.type,
          label: '', // shown by the parent already
          required: schemaField!.required,
          placeholder: schemaField!.placeholder,
          lines: schemaField!.lines,
          options: schemaField!.options,
          optionsBuilder: schemaField!.optionsBuilder,
          itemSchema: schemaField!.itemSchema,
        ),
        value: value,
        onChanged: onChanged,
      )._editor();
    }

    // Schema-less: infer from runtime type.
    if (value is bool) {
      return _BoolInput(value: value as bool, onChanged: onChanged);
    }
    if (value is num) {
      return _NumberInput(
        field: const OpsField(name: '', type: OpsFieldType.number),
        value: value,
        onChanged: onChanged,
      );
    }
    if (value is List) {
      return _DynamicArray(items: value.cast<dynamic>(), onChanged: onChanged);
    }
    if (value is Map) {
      return Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: OpsColors.border),
          borderRadius: OpsRadius.all_sm,
        ),
        padding: const EdgeInsets.all(8),
        child: _DynamicMap(
          value: value.cast<String, dynamic>(),
          onChanged: onChanged,
        ),
      );
    }
    return _TextInput(
      field: OpsField(name: '', type: OpsFieldType.text, placeholder: 'value'),
      value: value,
      onChanged: onChanged,
    );
  }
}

class _DynamicArray extends StatefulWidget {
  const _DynamicArray({required this.items, required this.onChanged});
  final List<dynamic> items;
  final ValueChanged<List<dynamic>> onChanged;
  @override
  State<_DynamicArray> createState() => _DynamicArrayState();
}

class _DynamicArrayState extends State<_DynamicArray> {
  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: OpsColors.border),
        borderRadius: OpsRadius.all_sm,
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 8),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontFamily: OpsType.mono,
                      fontSize: 10,
                      color: OpsColors.text3,
                    ),
                  ),
                ),
                Expanded(
                  child: _DynamicValue(
                    schemaField: null,
                    value: items[i],
                    onChanged: (v) {
                      final next = List<dynamic>.from(items);
                      next[i] = v;
                      widget.onChanged(next);
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 14),
                  tooltip: 'Remove',
                  onPressed: () {
                    final next = List<dynamic>.from(items);
                    next.removeAt(i);
                    widget.onChanged(next);
                  },
                ),
              ],
            ),
            if (i < items.length - 1)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Divider(height: 1),
              ),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: PopupMenuButton<String>(
              tooltip: 'Add item',
              onSelected: (kind) {
                final next = List<dynamic>.from(items);
                next.add(switch (kind) {
                  'string' => '',
                  'number' => 0,
                  'bool' => false,
                  'object' => <String, dynamic>{},
                  'array' => <dynamic>[],
                  _ => '',
                });
                widget.onChanged(next);
              },
              itemBuilder:
                  (_) => const [
                    PopupMenuItem(
                      height: 32,
                      value: 'string',
                      child: Text('+ string'),
                    ),
                    PopupMenuItem(
                      height: 32,
                      value: 'number',
                      child: Text('+ number'),
                    ),
                    PopupMenuItem(
                      height: 32,
                      value: 'bool',
                      child: Text('+ bool'),
                    ),
                    PopupMenuItem(
                      height: 32,
                      value: 'object',
                      child: Text('+ object'),
                    ),
                    PopupMenuItem(
                      height: 32,
                      value: 'array',
                      child: Text('+ array'),
                    ),
                  ],
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 14),
                    SizedBox(width: 4),
                    Text('Add item'),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ----- YAML round-trip helpers ------------------------------------------

dynamic _yamlToPlain(dynamic node) {
  if (node is yaml_pkg.YamlMap) {
    return node.map((k, v) => MapEntry(k.toString(), _yamlToPlain(v)));
  }
  if (node is yaml_pkg.YamlList) {
    return node.map(_yamlToPlain).toList();
  }
  return node;
}

Map<String, dynamic> parseYamlToMap(String text) {
  try {
    final parsed = yaml_pkg.loadYaml(text);
    final plain = _yamlToPlain(parsed);
    return plain is Map<String, dynamic> ? plain : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

String mapToYaml(Map<String, dynamic> map) {
  final buf = StringBuffer();
  void writeNode(dynamic node, int indent) {
    final pad = '  ' * indent;
    if (node is Map) {
      node.forEach((k, v) {
        if (v is Map && v.isEmpty) {
          buf.writeln('$pad$k: {}');
        } else if (v is List && v.isEmpty) {
          buf.writeln('$pad$k: []');
        } else if (v is Map || v is List) {
          buf.writeln('$pad$k:');
          writeNode(v, indent + 1);
        } else {
          buf.writeln('$pad$k: ${_yamlScalar(v)}');
        }
      });
    } else if (node is List) {
      for (final item in node) {
        if (item is Map || item is List) {
          buf.writeln('$pad-');
          writeNode(item, indent + 1);
        } else {
          buf.writeln('$pad- ${_yamlScalar(item)}');
        }
      }
    } else {
      buf.writeln('$pad${_yamlScalar(node)}');
    }
  }

  writeNode(map, 0);
  return buf.toString();
}

String _yamlScalar(dynamic v) {
  if (v == null) return 'null';
  if (v is bool || v is num) return v.toString();
  final s = v.toString();
  if (s.isEmpty ||
      s.contains(':') ||
      s.contains('#') ||
      s.contains('\n') ||
      s.startsWith(' ') ||
      s.endsWith(' ') ||
      RegExp(r'^[\[\]\{\},&*?|>!%@`]').hasMatch(s)) {
    return '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }
  return s;
}
