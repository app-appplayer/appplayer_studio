/// `VbuPropertiesForm` — vertical scrollable form rendering layer-specific
/// property sections. Used in app_builder's [5] slot (Properties pane).
///
/// Structure:
/// - Header `PROPERTIES` (mono uppercase, labelSmall)
/// - Optional context line: 3px layer stripe + focused id (mono w500)
/// - Divider
/// - Body: scrollable list of sections; each section = title header + N
///   field rows; each row = label (96w) + editor matched to `field.kind`:
///   `text`, `number`, `bool`, `enum`, `color`, `widget`, `asset`.
///
/// Field changes fire `field.onChange` with the new value (string-typed
/// for text/number/color/enum, bool for bool, string id for widget /
/// asset selection in the read-only placeholder).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';

class VbuPropertiesSection {
  const VbuPropertiesSection({
    required this.title,
    this.fields = const <VbuPropertiesField>[],
  });

  final String title;
  final List<VbuPropertiesField> fields;
}

class VbuPropertiesField {
  const VbuPropertiesField({
    required this.label,
    this.kind = 'text',
    this.value,
    this.hint,
    this.enumValues = const <String>[],
    this.onChange,
  });

  final String label;

  /// One of `text` / `number` / `bool` / `enum` / `color` / `widget` /
  /// `asset`. Unknown values fall back to the read-only text row.
  final String kind;

  final String? value;
  final String? hint;

  /// Required for `kind: 'enum'` — list of dropdown options.
  final List<String> enumValues;

  /// Fires on edit completion. The factory wires this through the DSL
  /// action dispatcher (`{type: state, action: set, ...}`).
  final ValueChanged<String>? onChange;
}

class VbuPropertiesForm extends StatelessWidget {
  const VbuPropertiesForm({
    super.key,
    this.sections = const <VbuPropertiesSection>[],
    this.contextLabel,
    this.contextStripeColor,
    this.emptyText = 'No focused layer',
  });

  final List<VbuPropertiesSection> sections;

  /// Rendered between the `PROPERTIES` header and the divider when
  /// non-null. Use to show the current focus (e.g. `pages / home`).
  final String? contextLabel;

  /// Hex stripe color for the context line (typically the active
  /// layer's color).
  final String? contextStripeColor;

  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final stripeColor = _parseColor(contextStripeColor);
    return Container(
      color: c.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: VbuTokens.space3,
              vertical: VbuTokens.space3,
            ),
            child: Text(
              'PROPERTIES',
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
                color: c.textSecondary,
              ),
            ),
          ),
          if (contextLabel != null)
            SizedBox(
              height: 28,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(width: 3, color: stripeColor ?? c.textMuted),
                  const SizedBox(width: VbuTokens.space2),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        contextLabel!,
                        style: TextStyle(
                          fontFamily: VbuTokens.fontMono,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: c.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Container(height: 1, color: c.borderDefault),
          Expanded(
            child:
                sections.isEmpty
                    ? Center(
                      child: Text(
                        emptyText,
                        style: TextStyle(
                          fontFamily: VbuTokens.fontSans,
                          fontSize: 12,
                          color: c.textTertiary,
                        ),
                      ),
                    )
                    : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: VbuTokens.space4,
                        vertical: VbuTokens.space3,
                      ),
                      itemCount: sections.length,
                      itemBuilder:
                          (context, i) => _Section(section: sections[i]),
                    ),
          ),
        ],
      ),
    );
  }

  static Color? _parseColor(String? hex) {
    if (hex == null) return null;
    var s = hex.trim();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length == 6) s = 'ff$s';
    final v = int.tryParse(s, radix: 16);
    return v == null ? null : Color(v);
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.section});

  final VbuPropertiesSection section;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: VbuTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: VbuTokens.space2),
            child: Text(
              section.title.toUpperCase(),
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
                color: c.textTertiary,
              ),
            ),
          ),
          if (section.fields.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: VbuTokens.space2),
              child: Text(
                '— empty section —',
                style: TextStyle(
                  fontFamily: VbuTokens.fontMono,
                  fontSize: 11,
                  color: c.textMuted,
                ),
              ),
            )
          else
            for (final f in section.fields) _Row(field: f),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.field});

  final VbuPropertiesField field;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: VbuTokens.space2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                field.label,
                style: TextStyle(
                  fontFamily: VbuTokens.fontSans,
                  fontSize: 12,
                  color: c.textSecondary,
                ),
              ),
            ),
          ),
          const SizedBox(width: VbuTokens.space2),
          Expanded(child: _editor(field, c)),
        ],
      ),
    );
  }

  Widget _editor(VbuPropertiesField f, _VbuColor c) {
    switch (f.kind) {
      case 'bool':
        return _BoolEditor(field: f);
      case 'number':
        return _NumberEditor(field: f);
      case 'enum':
        return _EnumEditor(field: f);
      case 'color':
        return _ColorEditor(field: f);
      case 'widget':
        return _WidgetEditor(field: f);
      case 'asset':
        return _AssetEditor(field: f);
      case 'text':
      default:
        return _TextEditor(field: f);
    }
  }
}

typedef _VbuColor = dynamic;

Decoration _fieldDecoration(BuildContext context) {
  final c = VbuTokens.colorOf(context);
  return BoxDecoration(
    color: c.surface2,
    border: Border.all(color: c.borderSubtle, width: 1),
    borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
  );
}

/// Reactive text editor — uses a [TextEditingController] so external
/// state changes (after first render) are reflected in the field. We
/// sync `controller.text` from `widget.field.value` in
/// `didUpdateWidget`, but only when the field is NOT focused — that
/// way a user mid-edit isn't clobbered by the very binding update
/// their own keystrokes are about to produce.
class _TextEditor extends StatefulWidget {
  const _TextEditor({required this.field});
  final VbuPropertiesField field;

  @override
  State<_TextEditor> createState() => _TextEditorState();
}

class _TextEditorState extends State<_TextEditor> {
  late final TextEditingController _ctrl;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.field.value ?? '');
  }

  @override
  void didUpdateWidget(covariant _TextEditor old) {
    super.didUpdateWidget(old);
    final next = widget.field.value ?? '';
    if (!_focus.hasFocus && _ctrl.text != next) {
      _ctrl.text = next;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return TextFormField(
      controller: _ctrl,
      focusNode: _focus,
      onFieldSubmitted: widget.field.onChange,
      onEditingComplete: () {
        widget.field.onChange?.call(_ctrl.text);
      },
      style: TextStyle(
        fontFamily: VbuTokens.fontMono,
        fontSize: 11,
        color: c.textPrimary,
      ),
      decoration: InputDecoration(
        hintText: widget.field.hint ?? '',
        hintStyle: TextStyle(
          fontFamily: VbuTokens.fontMono,
          fontSize: 11,
          color: c.textMuted,
        ),
        filled: true,
        fillColor: c.surface2,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
          borderSide: BorderSide(color: c.borderSubtle, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
          borderSide: BorderSide(color: c.borderSubtle, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
          borderSide: BorderSide(color: c.mint, width: 1.5),
        ),
      ),
    );
  }
}

/// Reactive number editor — same controller-sync pattern as
/// [_TextEditor], with an extra digit/sign filter.
class _NumberEditor extends StatefulWidget {
  const _NumberEditor({required this.field});
  final VbuPropertiesField field;

  @override
  State<_NumberEditor> createState() => _NumberEditorState();
}

class _NumberEditorState extends State<_NumberEditor> {
  late final TextEditingController _ctrl;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.field.value ?? '');
  }

  @override
  void didUpdateWidget(covariant _NumberEditor old) {
    super.didUpdateWidget(old);
    final next = widget.field.value ?? '';
    if (!_focus.hasFocus && _ctrl.text != next) {
      _ctrl.text = next;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return TextFormField(
      controller: _ctrl,
      focusNode: _focus,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]'))],
      onFieldSubmitted: widget.field.onChange,
      onEditingComplete: () {
        widget.field.onChange?.call(_ctrl.text);
      },
      style: TextStyle(
        fontFamily: VbuTokens.fontMono,
        fontSize: 11,
        color: c.textPrimary,
      ),
      decoration: InputDecoration(
        hintText: widget.field.hint ?? '0',
        hintStyle: TextStyle(
          fontFamily: VbuTokens.fontMono,
          fontSize: 11,
          color: c.textMuted,
        ),
        filled: true,
        fillColor: c.surface2,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
          borderSide: BorderSide(color: c.borderSubtle, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
          borderSide: BorderSide(color: c.borderSubtle, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
          borderSide: BorderSide(color: c.mint, width: 1.5),
        ),
      ),
    );
  }
}

class _BoolEditor extends StatefulWidget {
  const _BoolEditor({required this.field});
  final VbuPropertiesField field;

  @override
  State<_BoolEditor> createState() => _BoolEditorState();
}

class _BoolEditorState extends State<_BoolEditor> {
  late bool _v;

  @override
  void initState() {
    super.initState();
    _v = widget.field.value == 'true';
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Switch(
        value: _v,
        activeThumbColor: c.mint,
        onChanged: (v) {
          setState(() => _v = v);
          widget.field.onChange?.call(v ? 'true' : 'false');
        },
      ),
    );
  }
}

class _EnumEditor extends StatefulWidget {
  const _EnumEditor({required this.field});
  final VbuPropertiesField field;

  @override
  State<_EnumEditor> createState() => _EnumEditorState();
}

class _EnumEditorState extends State<_EnumEditor> {
  String? _v;

  @override
  void initState() {
    super.initState();
    _v = widget.field.value;
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final opts = widget.field.enumValues;
    return Container(
      decoration: _fieldDecoration(context),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: opts.contains(_v) ? _v : null,
          hint: Text(
            widget.field.hint ?? '—',
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 11,
              color: c.textMuted,
            ),
          ),
          icon: Icon(Icons.expand_more, size: 16, color: c.textTertiary),
          dropdownColor: c.elevated,
          isDense: true,
          isExpanded: true,
          items: [
            for (final o in opts)
              DropdownMenuItem(
                value: o,
                child: Text(
                  o,
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 11,
                    color: c.textPrimary,
                  ),
                ),
              ),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _v = v);
            widget.field.onChange?.call(v);
          },
        ),
      ),
    );
  }
}

class _ColorEditor extends StatelessWidget {
  const _ColorEditor({required this.field});
  final VbuPropertiesField field;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final swatch = _swatchColor(field.value);
    return Row(
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: swatch ?? c.surface3,
            border: Border.all(color: c.borderDefault, width: 1),
            borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
          ),
        ),
        const SizedBox(width: VbuTokens.space2),
        Expanded(child: _TextEditor(field: field)),
      ],
    );
  }

  Color? _swatchColor(String? hex) {
    if (hex == null) return null;
    var s = hex.trim();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length == 6) s = 'ff$s';
    final v = int.tryParse(s, radix: 16);
    return v == null ? null : Color(v);
  }
}

class _WidgetEditor extends StatelessWidget {
  const _WidgetEditor({required this.field});
  final VbuPropertiesField field;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Container(
      decoration: _fieldDecoration(context),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.account_tree, size: 14, color: c.textTertiary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              field.value ?? field.hint ?? 'No widget tree',
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 11,
                color: field.value != null ? c.textPrimary : c.textMuted,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Icon(Icons.edit_outlined, size: 12, color: c.textTertiary),
        ],
      ),
    );
  }
}

class _AssetEditor extends StatelessWidget {
  const _AssetEditor({required this.field});
  final VbuPropertiesField field;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Container(
      decoration: _fieldDecoration(context),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.image, size: 14, color: c.textTertiary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              field.value ?? field.hint ?? 'No asset',
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 11,
                color: field.value != null ? c.textPrimary : c.textMuted,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Icon(Icons.folder_open, size: 12, color: c.textTertiary),
        ],
      ),
    );
  }
}
