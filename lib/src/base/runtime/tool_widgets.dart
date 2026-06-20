/// Custom mcp_ui_runtime widgets for tool↔UI auto-wiring. Hosts call
/// [registerToolWidgets] on a freshly-constructed `MCPUIRuntime` to
/// expose three widgets to bundle UI authors:
///
///   * `<ToolForm>`   — form generator from `inputSchema`
///   * `<ToolResult>` — typed result display from `outputSchema` / state
///   * `<ToolPicker>` — drop-down chooser over a tool list
///
/// All three are sugar on top of mcp_ui_runtime's existing
/// `action: tool` + spec §3.10 auto-merge contract — they don't need
/// any spec change. The host registers them once after the runtime is
/// constructed; bundle UIs reference them like any built-in widget
/// (`{"type": "ToolForm", ...}`).
library;

import 'package:flutter/material.dart';
// Use the namespace-forked runtime — the workspace-side MCPUIRuntime
// callers (DslWorkspaceView) want their own process-global singletons
// kept separate from the host preview path that lives on
// `flutter_mcp_ui_runtime`. See `project_vibe_studio_runtime_fork`.
import 'package:appplayer_studio/runtime.dart';

/// Register all three tool-wiring widgets on [runtime]. Idempotent —
/// re-registering overwrites the previous factory (mcp_ui_runtime's
/// registry behaviour).
void registerToolWidgets(MCPUIRuntime runtime) {
  runtime.registerWidget('ToolForm', _ToolFormFactory());
  runtime.registerWidget('ToolResult', _ToolResultFactory());
  runtime.registerWidget('ToolPicker', _ToolPickerFactory());
}

// ---------------------------------------------------------------------------
// ToolForm — auto-generates form fields from a JSON Schema, dispatches
// the tool action with the collected values on submit.
//
// Definition:
//   {
//     "type": "ToolForm",
//     "tool": "<bundleShortId>.<verb>",       // required
//     "inputSchema": { ... },                  // required (JSON Schema)
//     "submitLabel": "Run",                    // optional, default "Submit"
//     "bindResult": "lastResult",              // optional, override merge
//     "loadingBinding": "submitting"           // optional, loading flag
//   }
//
// Object-typed properties at the top level of the schema become form
// fields. Type → widget mapping:
//   string  → TextFormField
//   number  → TextFormField (numeric keyboard, parsed as double)
//   integer → TextFormField (numeric keyboard, parsed as int)
//   boolean → SwitchListTile
//   string + enum → DropdownButtonFormField
// Anything else falls through to a plain TextFormField (string).
// ---------------------------------------------------------------------------

class _ToolFormFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final tool = context.resolve<String?>(props['tool']);
    final schema =
        context.resolve<Object?>(props['inputSchema']) as Map<String, dynamic>?;
    if (tool == null || tool.isEmpty || schema == null) {
      return _ErrorBanner(
        message: 'ToolForm requires `tool` and `inputSchema`.',
      );
    }
    final widget = _ToolFormWidget(
      tool: tool,
      schema: schema,
      submitLabel: context.resolve<String?>(props['submitLabel']) ?? 'Submit',
      bindResult: context.resolve<String?>(props['bindResult']),
      loadingBinding: context.resolve<String?>(props['loadingBinding']),
      context: context,
    );
    return applyCommonWrappers(widget, props, context);
  }
}

class _ToolFormWidget extends StatefulWidget {
  const _ToolFormWidget({
    required this.tool,
    required this.schema,
    required this.submitLabel,
    required this.bindResult,
    required this.loadingBinding,
    required this.context,
  });

  final String tool;
  final Map<String, dynamic> schema;
  final String submitLabel;
  final String? bindResult;
  final String? loadingBinding;
  final RenderContext context;

  @override
  State<_ToolFormWidget> createState() => _ToolFormWidgetState();
}

class _ToolFormWidgetState extends State<_ToolFormWidget> {
  final _values = <String, Object?>{};
  bool _submitting = false;

  @override
  Widget build(BuildContext context) {
    final props =
        (widget.schema['properties'] as Map<String, dynamic>?) ??
        const <String, dynamic>{};
    final required =
        (widget.schema['required'] as List?)?.whereType<String>().toSet() ??
        const <String>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final entry in props.entries)
          _buildField(entry.key, entry.value, required.contains(entry.key)),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: Text(_submitting ? 'Working…' : widget.submitLabel),
        ),
      ],
    );
  }

  Widget _buildField(String name, dynamic spec, bool isRequired) {
    if (spec is! Map<String, dynamic>) return const SizedBox.shrink();
    final type = spec['type']?.toString() ?? 'string';
    final title = spec['title']?.toString() ?? name;
    final description = spec['description']?.toString();
    final enumValues = (spec['enum'] as List?)?.cast<Object?>();
    final label = isRequired ? '$title *' : title;

    if (type == 'boolean') {
      return SwitchListTile(
        title: Text(title),
        subtitle: description != null ? Text(description) : null,
        value: (_values[name] as bool?) ?? false,
        onChanged: (v) => setState(() => _values[name] = v),
      );
    }
    if (type == 'string' && enumValues != null && enumValues.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: DropdownButtonFormField<String>(
          decoration: InputDecoration(
            labelText: label,
            helperText: description,
          ),
          initialValue: _values[name] as String?,
          items: <DropdownMenuItem<String>>[
            for (final v in enumValues)
              DropdownMenuItem(value: v?.toString(), child: Text('$v')),
          ],
          onChanged: (v) => setState(() => _values[name] = v),
        ),
      );
    }
    final keyboard =
        (type == 'number' || type == 'integer')
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextFormField(
        decoration: InputDecoration(labelText: label, helperText: description),
        keyboardType: keyboard,
        onChanged: (v) {
          setState(() {
            if (type == 'integer') {
              _values[name] = int.tryParse(v);
            } else if (type == 'number') {
              _values[name] = double.tryParse(v);
            } else {
              _values[name] = v;
            }
          });
        },
      ),
    );
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      // Reuse mcp_ui_runtime's standard tool action — args are taken
      // verbatim from our local field state. The runtime applies its
      // standard auto-merge / bindResult / loadingBinding semantics,
      // so the surrounding UI sees the same state shape regardless
      // of whether the form lives in a ToolForm or hand-rolled
      // widgets.
      await widget.context.handleAction(<String, dynamic>{
        'type': 'tool',
        'tool': widget.tool,
        'args': Map<String, dynamic>.from(_values),
        if (widget.bindResult != null) 'bindResult': widget.bindResult,
        if (widget.loadingBinding != null)
          'loadingBinding': widget.loadingBinding,
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

// ---------------------------------------------------------------------------
// ToolResult — render the latest result a tool produced. Reads from
// either an explicit `binding` (state path the bundle author chose
// via `bindResult`) or the legacy `tools.<name>.result` mirror that
// mcp_ui_runtime maintains automatically.
//
// Definition:
//   {
//     "type": "ToolResult",
//     "tool": "<bundleShortId>.<verb>",       // optional — uses tools.<tool>.result
//     "binding": "lastResult",                  // optional — explicit state path
//     "outputSchema": { ... }                   // optional — used for typed render
//   }
// ---------------------------------------------------------------------------

class _ToolResultFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final tool = context.resolve<String?>(props['tool']);
    final binding = context.resolve<String?>(props['binding']);
    final schema =
        context.resolve<Object?>(props['outputSchema'])
            as Map<String, dynamic>?;
    Object? value;
    if (binding != null) {
      value = context.getValue(binding);
    } else if (tool != null) {
      value = context.getValue('tools.$tool.result');
    }
    final widget = _ToolResultRender(value: value, schema: schema);
    return applyCommonWrappers(widget, props, context);
  }
}

class _ToolResultRender extends StatelessWidget {
  const _ToolResultRender({required this.value, required this.schema});

  final Object? value;
  final Map<String, dynamic>? schema;

  @override
  Widget build(BuildContext context) {
    if (value == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'No result yet.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    if (value is Map) {
      final m = (value as Map).cast<String, dynamic>();
      final props = (schema?['properties'] as Map?)?.cast<String, dynamic>();
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final entry in m.entries)
                _kv(
                  context,
                  entry.key,
                  entry.value,
                  props?[entry.key] as Map<String, dynamic>?,
                ),
            ],
          ),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SelectableText('$value'),
      ),
    );
  }

  Widget _kv(
    BuildContext context,
    String key,
    Object? value,
    Map<String, dynamic>? propSpec,
  ) {
    final label = propSpec?['title']?.toString() ?? key;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: SelectableText('$value')),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ToolPicker — dropdown over a list of tool ids. Stores the chosen
// id in the configured state binding so other widgets (e.g. a
// ToolForm bound to that variable) can react.
//
// Definition:
//   {
//     "type": "ToolPicker",
//     "tools": ["wire_demo.shout", "wire_demo.echo"],
//     "binding": "selectedTool",
//     "label": "Tool"
//   }
// ---------------------------------------------------------------------------

class _ToolPickerFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final rawTools = context.resolve<Object?>(props['tools']);
    final tools =
        rawTools is List
            ? rawTools.whereType<String>().toList()
            : const <String>[];
    final binding = context.resolve<String?>(props['binding']);
    final label = context.resolve<String?>(props['label']) ?? 'Tool';
    final current =
        binding == null ? null : context.getValue(binding) as String?;
    final widget = DropdownButtonFormField<String>(
      decoration: InputDecoration(labelText: label),
      initialValue: current,
      items: <DropdownMenuItem<String>>[
        for (final t in tools) DropdownMenuItem(value: t, child: Text(t)),
      ],
      onChanged: (v) {
        if (binding != null && v != null) context.setValue(binding, v);
      },
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// Shared error rendering for malformed widget specs.
// ---------------------------------------------------------------------------

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Text(
        message,
        style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
      ),
    );
  }
}
