/// Stateful dispatcher for a single manifest settings field. Single
/// source of truth for `manifest.settings.sections[].fields[].type` →
/// atom mapping. Both the chrome host (Settings dialog Domain body) and
/// the registered composite (`VbuSettingsSectionsForm`) consume this so
/// new field types land in exactly one place.
///
/// Field types:
///   - `toggle` → [VbuLabelledToggle]
///   - `menu`   → [VbuLabelledMenu]
///   - `folder` → [VbuLabelledFolder] (FilePicker · pick + clear)
///   - `text` / `number` / default → [VbuLabelledField]
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:appplayer_studio/ui.dart';

class ManifestFieldRow extends StatefulWidget {
  const ManifestFieldRow({
    super.key,
    required this.field,
    required this.value,
    required this.onChanged,
  });

  /// Raw field map — `{key, label, type, value?, options?, hint?}`.
  final Map<String, dynamic> field;

  /// Effective value — host's override or manifest default.
  final Object? value;

  /// Edit hook — emits the new value (null = cleared).
  final void Function(Object? newValue) onChanged;

  @override
  State<ManifestFieldRow> createState() => _ManifestFieldRowState();
}

class _ManifestFieldRowState extends State<ManifestFieldRow> {
  TextEditingController? _textCtrl;

  @override
  void dispose() {
    _textCtrl?.dispose();
    super.dispose();
  }

  TextEditingController _ensureTextController(String initial) {
    final existing = _textCtrl;
    if (existing != null) return existing;
    final c = TextEditingController(text: initial);
    c.addListener(() => widget.onChanged(c.text));
    _textCtrl = c;
    return c;
  }

  Future<void> _pickFolder() async {
    final picked = await FilePicker.platform.getDirectoryPath(
      initialDirectory: widget.value?.toString(),
    );
    if (picked == null) return;
    widget.onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    final type = (field['type'] as String?) ?? 'text';
    final label =
        (field['label'] as String?) ?? (field['key'] as String?) ?? '?';
    final value = widget.value;
    switch (type) {
      case 'toggle':
        return VbuLabelledToggle(
          label: label,
          value: value == true,
          onChanged: (v) => widget.onChanged(v),
        );
      case 'menu':
        final options =
            (field['options'] as List<dynamic>? ?? const <dynamic>[])
                .map((e) => '$e')
                .toList();
        final rawLabels = field['optionLabels'] as Map<dynamic, dynamic>?;
        final labels = <String, String>{
          if (rawLabels != null)
            for (final e in rawLabels.entries) '${e.key}': '${e.value}',
        };
        return VbuLabelledMenu<String>(
          label: label,
          value: value?.toString() ?? (options.isNotEmpty ? options.first : ''),
          options: options,
          labels: labels,
          onChanged: (v) => widget.onChanged(v),
        );
      case 'folder':
        final hint = (field['hint'] as String?) ?? '';
        final hasValue = value != null && value.toString().isNotEmpty;
        return VbuLabelledFolder(
          label: label,
          value: hasValue ? value.toString() : null,
          hint: hint,
          onPick: _pickFolder,
          onClear: hasValue ? () => widget.onChanged(null) : null,
        );
      case 'text':
      case 'number':
      default:
        final ctrl = _ensureTextController(value?.toString() ?? '');
        return VbuLabelledField(
          label: label,
          controller: ctrl,
          hint: (field['hint'] as String?) ?? '',
        );
    }
  }
}
