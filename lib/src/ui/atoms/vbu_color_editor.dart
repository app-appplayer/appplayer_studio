import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';

/// Property-row color editor — label + 14×14 swatch + 92px hex field.
/// Catalog Part E.R.20 spec — hex format #RRGGBB / #AARRGGBB, click on
/// swatch opens a color picker dialog (host wires onPickerOpen).
///
/// Commit pattern: blur or Enter triggers onChange with the validated
/// hex string. Empty input → null callback (clears the field).
class VbuColorEditor extends StatefulWidget {
  const VbuColorEditor({
    super.key,
    required this.label,
    this.value,
    this.onChange,
    this.onSwatchTap,
    this.labelWidth = 90,
    this.fieldWidth = 92,
  });

  final String label;
  final String? value;
  final ValueChanged<String?>? onChange;
  final VoidCallback? onSwatchTap;
  final double labelWidth;
  final double fieldWidth;

  @override
  State<VbuColorEditor> createState() => _VbuColorEditorState();
}

class _VbuColorEditorState extends State<VbuColorEditor> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.value ?? '',
  );

  @override
  void didUpdateWidget(covariant VbuColorEditor old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && (widget.value ?? '') != _ctrl.text) {
      _ctrl.text = widget.value ?? '';
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Color? _parse(String s) {
    var t = s.trim().toUpperCase();
    if (t.startsWith('#')) t = t.substring(1);
    if (t.length == 6) t = 'FF$t';
    if (t.length != 8) return null;
    final v = int.tryParse(t, radix: 16);
    return v == null ? null : Color(v);
  }

  void _commit() {
    final v = _ctrl.text.trim();
    if (v.isEmpty) {
      widget.onChange?.call(null);
    } else {
      final parsed = _parse(v);
      widget.onChange?.call(parsed == null ? v : v.toUpperCase());
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final swatchColor = _parse(_ctrl.text) ?? c.surface3;
    return SizedBox(
      height: 28,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: widget.labelWidth,
            child: Text(
              widget.label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: c.textSecondary),
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: widget.onSwatchTap,
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: swatchColor,
                borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
                border: Border.all(color: c.borderStrong, width: 1),
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: widget.fieldWidth,
            child: TextField(
              controller: _ctrl,
              onSubmitted: (_) => _commit(),
              onEditingComplete: _commit,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Fa-f#]')),
                LengthLimitingTextInputFormatter(9),
              ],
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 11,
                color: c.textPrimary,
              ),
              decoration: InputDecoration(
                isDense: true,
                hintText: '#______',
                hintStyle: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 11,
                  color: c.textTertiary,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 4,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
