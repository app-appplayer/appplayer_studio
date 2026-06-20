/// Schema-driven settings form for `manifest.settings.sections[]`. Wired
/// composite (lives in base, not atoms) — internal type→atom dispatch
/// goes through [ManifestFieldRow] so new field types land in one place.
/// Reused by both chrome's Settings dialog Domain body and any DSL bundle
/// that registers settings sections directly.
import 'package:flutter/material.dart';
import 'package:appplayer_studio/ui.dart';

import 'manifest_field_row.dart';

/// One field inside a [VbuSettingsSection] — mirrors the shape
/// vibe_studio uses for `manifest.settings.sections[].fields[]`. Inert:
/// the composite consumes resolved values and emits `onChanged`; the host
/// owns persistence (typically a per-package overrides file).
class VbuSettingsField {
  const VbuSettingsField({
    required this.key,
    required this.label,
    this.type = 'text',
    this.value,
    this.options = const <String>[],
    this.hint,
    this.onChanged,
  });

  /// Stable id — manifest-declared `key`. The host uses this when
  /// writing the overrides file so values survive a manifest edit.
  final String key;

  /// Display label rendered to the left of the input.
  final String label;

  /// Control kind — recognized by [ManifestFieldRow]:
  /// `text` (default) · `toggle` · `menu` · `folder` · `number`.
  final String type;

  /// Current effective value — either the manifest-declared default
  /// or the host's per-package override (the host decides which to
  /// feed in).
  final Object? value;

  /// Menu options. Ignored unless [type] is `menu`.
  final List<String> options;

  /// Placeholder hint — applies to `text` / `folder`.
  final String? hint;

  /// Edit hook — emits the new value back to the host. The host is
  /// responsible for persistence + re-feeding [value] on the next
  /// build pass.
  final ValueChanged<Object?>? onChanged;
}

/// One section — header label + zero or more fields. Mirrors the shape
/// of `manifest.settings.sections[]` (key + label + fields[]).
class VbuSettingsSection {
  const VbuSettingsSection({
    required this.key,
    required this.label,
    this.fields = const <VbuSettingsField>[],
  });

  final String key;
  final String label;
  final List<VbuSettingsField> fields;
}

class VbuSettingsSectionsForm extends StatelessWidget {
  const VbuSettingsSectionsForm({super.key, required this.sections});

  final List<VbuSettingsSection> sections;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    if (sections.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          '(no sections)',
          style: TextStyle(
            fontFamily: VbuTokens.fontMono,
            fontSize: 11,
            color: c.textTertiary,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final s in sections)
          Padding(
            padding: const EdgeInsets.only(bottom: VbuTokens.space4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(bottom: VbuTokens.space2),
                  child: Text(
                    s.label.toUpperCase(),
                    style: TextStyle(
                      fontFamily: VbuTokens.fontMono,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.0,
                      color: c.textTertiary,
                    ),
                  ),
                ),
                for (final f in s.fields)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: ManifestFieldRow(
                      field: <String, dynamic>{
                        'key': f.key,
                        'label': f.label,
                        'type': f.type,
                        'options': f.options,
                        if (f.hint != null) 'hint': f.hint,
                      },
                      value: f.value,
                      onChanged: f.onChanged ?? (_) {},
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
