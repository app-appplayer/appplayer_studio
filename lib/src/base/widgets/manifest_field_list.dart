/// Renderer for a manifest-supplied settings section. Loads any prior
/// overrides from disk on mount, autosaves each edit. Per-field widgets
/// pick a control type from `field.type` (text · toggle); unknown
/// types fall back to read-only display.
///
/// Lifted from the universal-host so future studios share one
/// implementation. The list is intentionally schema-driven: a manifest
/// section's `fields[]` array drives the row layout, and the public
/// [ManifestFieldRow] atom handles the per-row control choice. Edits
/// autosave to the per-package overrides JSON file passed in via
/// [overridesFile].
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:appplayer_studio/ui.dart';

import 'manifest_field_row.dart';

/// Renders `manifest.settings.sections[].fields[]` for a single section,
/// with autosave to an overrides JSON file.
///
/// Supports a simple `dependsOn` / `dependsOnValue` schema: a field that
/// declares both is rendered only when the referenced sibling field's
/// effective value `==` the expected value. Used by the auto-prepended
/// "Domain MCP" base section so URL / transport rows hide when
/// `inheritFromSystem` is on.
class ManifestFieldList extends StatefulWidget {
  const ManifestFieldList({
    super.key,
    required this.fields,
    required this.overridesFile,
    this.onFieldChanged,
  });

  /// The section's raw field maps (already inheritance-baked when the
  /// host wants studio-wide defaults applied).
  final List<Map<String, dynamic>> fields;

  /// Per-package overrides JSON file. Reads on mount, autosaves on edit.
  final String overridesFile;

  /// Optional notify hook fired after every persisted edit. Hosts wire
  /// this to ChromeBridge to surface "Restart required" toasts when
  /// the user mutates server-affecting fields (URL / transport /
  /// inherit toggle).
  final void Function(String key, Object? value)? onFieldChanged;

  @override
  State<ManifestFieldList> createState() => _ManifestFieldListState();
}

class _ManifestFieldListState extends State<ManifestFieldList> {
  Map<String, dynamic> _overrides = <String, dynamic>{};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadOverrides();
  }

  Future<void> _loadOverrides() async {
    try {
      final f = File(widget.overridesFile);
      if (await f.exists()) {
        final raw = await f.readAsString();
        final json = jsonDecode(raw);
        if (json is Map<String, dynamic>) {
          if (mounted) {
            setState(() {
              _overrides = json;
              _loaded = true;
            });
          }
          return;
        }
      }
    } catch (_) {
      /* fall through to defaults */
    }
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _persist() async {
    try {
      final f = File(widget.overridesFile);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(_overrides));
    } catch (_) {
      /* best-effort */
    }
  }

  void _setOverride(String key, Object? value) {
    setState(() {
      if (value == null || (value is String && value.isEmpty)) {
        _overrides.remove(key);
      } else {
        _overrides[key] = value;
      }
    });
    // ignore: unawaited_futures
    _persist();
    widget.onFieldChanged?.call(key, value);
  }

  Object? _effectiveValue(Map<String, dynamic> field) {
    final key = field['key'] as String?;
    if (key != null && _overrides.containsKey(key)) {
      final v = _overrides[key];
      if (v != null && !(v is String && v.isEmpty)) return v;
    }
    return field['value'];
  }

  @override
  Widget build(BuildContext context) {
    if (widget.fields.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Text(
          '(no fields)',
          style: TextStyle(fontSize: 11, color: Color(0xFF6E7681)),
        ),
      );
    }
    if (!_loaded) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Text(
          'Loading…',
          style: TextStyle(fontSize: 11, color: Color(0xFF6E7681)),
        ),
      );
    }
    // Match VbuFormSection's per-row bottom gap so manifest-driven
    // domain sections render with the same rhythm as the hand-rolled
    // system Settings sections (Workspace / MCP server / Autosave /
    // LLM). VbuFormSection wraps each `children[]` entry with the
    // same gap; this list is rendered as that section's single child,
    // so the row gap has to live here instead.
    final visible = <Widget>[
      for (final f in widget.fields)
        if (_dependencyMet(f))
          _disabledWhenMet(f)
              ? IgnorePointer(
                ignoring: true,
                child: Opacity(opacity: 0.5, child: _fieldRow(f)),
              )
              : _fieldRow(f),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < visible.length; i++)
          Padding(
            padding: EdgeInsets.only(
              bottom: i == visible.length - 1 ? 0 : VbuTokens.space2,
            ),
            child: visible[i],
          ),
      ],
    );
  }

  /// `dependsOn` resolves against the sibling field's effective value
  /// (override > inheritance-baked default). Missing referenced field
  /// = treat as no dependency (field shows).
  bool _dependencyMet(Map<String, dynamic> field) {
    final depKey = field['dependsOn'] as String?;
    if (depKey == null || depKey.isEmpty) return true;
    final expected = field['dependsOnValue'];
    for (final sibling in widget.fields) {
      if (sibling['key'] == depKey) {
        return _effectiveValue(sibling) == expected;
      }
    }
    return true;
  }

  /// `disabledWhen` is the visual-but-locked counterpart to `dependsOn`:
  /// when the sibling field's effective value equals `disabledWhenValue`
  /// the row renders, but is non-interactive (greyed). Used for
  /// inherited fields that the user should be able to *see* (current
  /// inherited URL / transport / etc.) without being able to override
  /// them. Missing referenced field = treat as no constraint (field
  /// stays enabled).
  bool _disabledWhenMet(Map<String, dynamic> field) {
    final depKey = field['disabledWhen'] as String?;
    if (depKey == null || depKey.isEmpty) return false;
    final expected = field['disabledWhenValue'];
    for (final sibling in widget.fields) {
      if (sibling['key'] == depKey) {
        return _effectiveValue(sibling) == expected;
      }
    }
    return false;
  }

  Widget _fieldRow(Map<String, dynamic> field) {
    final key = field['key'] as String?;
    if (key == null) {
      final label = (field['label'] as String?) ?? '?';
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          const SizedBox(width: 92),
          Expanded(
            child: Text(
              '(missing key) — $label',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: Color(0xFF6E7681),
              ),
            ),
          ),
        ],
      );
    }
    return ManifestFieldRow(
      field: field,
      value: _effectiveValue(field),
      onChanged: (v) => _setOverride(key, v),
    );
  }
}
