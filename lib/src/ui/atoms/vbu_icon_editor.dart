import 'package:flutter/material.dart';

import '../tokens.dart';

/// Property-row icon editor — label + 14px icon preview + 110px name
/// field + picker chevron. Catalog Part E.R.23 spec.
///
/// Accepts:
///   - bare name      ("home")     → Material icon if registered
///   - explicit       ("material:home")
///   - bundle ref     ("bundle://asset_id")
///
/// `iconResolver` lets the host map a name to an [IconData] (Material
/// catalog lookup). Returns null → coral broken-link icon.
class VbuIconEditor extends StatefulWidget {
  const VbuIconEditor({
    super.key,
    required this.label,
    this.value,
    this.onChange,
    this.onPickerOpen,
    this.iconResolver,
    this.labelWidth = 90,
    this.fieldWidth = 110,
  });

  final String label;
  final String? value;
  final ValueChanged<String?>? onChange;
  final VoidCallback? onPickerOpen;
  final IconData? Function(String name)? iconResolver;
  final double labelWidth;
  final double fieldWidth;

  @override
  State<VbuIconEditor> createState() => _VbuIconEditorState();
}

class _VbuIconEditorState extends State<VbuIconEditor> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.value ?? '',
  );

  @override
  void didUpdateWidget(covariant VbuIconEditor old) {
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

  void _commit() {
    final v = _ctrl.text.trim();
    widget.onChange?.call(v.isEmpty ? null : v);
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final raw = _ctrl.text.trim();
    final name =
        raw.startsWith('material:')
            ? raw.substring(9)
            : raw.startsWith('bundle://')
            ? raw.substring(9)
            : raw;
    final IconData? icon = widget.iconResolver?.call(name);
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
          Icon(
            icon ?? Icons.broken_image_outlined,
            size: 14,
            color: icon == null ? c.coral : c.textSecondary,
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: widget.fieldWidth,
            child: TextField(
              controller: _ctrl,
              onSubmitted: (_) => _commit(),
              onEditingComplete: _commit,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 11,
                color: c.textPrimary,
              ),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'icon name',
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
          if (widget.onPickerOpen != null)
            IconButton(
              onPressed: widget.onPickerOpen,
              icon: const Icon(Icons.expand_more, size: 12),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
              color: c.textSecondary,
            ),
        ],
      ),
    );
  }
}
