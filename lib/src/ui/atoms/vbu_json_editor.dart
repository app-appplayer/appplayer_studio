/// Monospace JSON text editor with live parse validation. Emits raw
/// text on every keystroke + a parsed value (or null on parse error)
/// so hosts can keep their state in sync without re-encoding. Used by
/// Scene Builder's scenario composer + Studio Builder's manifest patch
/// view + any future surface that lets the user touch raw JSON.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../tokens.dart';

class VbuJsonEditor extends StatefulWidget {
  const VbuJsonEditor({
    super.key,
    required this.initialText,
    this.onChanged,
    this.onParsed,
    this.readOnly = false,
    this.minLines = 10,
    this.maxLines,
    this.placeholder,
  });

  /// Initial text shown in the editor. Hosts that re-key (`key:
  /// ValueKey(scenarioId)`) get a fresh controller per id.
  final String initialText;

  /// Called on every keystroke with the raw text.
  final ValueChanged<String>? onChanged;

  /// Called when the text successfully parses as JSON. Receives the
  /// decoded value. NOT called on parse errors — the error indicator
  /// surfaces inline so the host stays out of the validation loop.
  final ValueChanged<Object?>? onParsed;

  final bool readOnly;
  final int minLines;
  final int? maxLines;

  /// Hint text when empty.
  final String? placeholder;

  @override
  State<VbuJsonEditor> createState() => _VbuJsonEditorState();
}

class _VbuJsonEditorState extends State<VbuJsonEditor> {
  late TextEditingController _ctl;
  String? _err;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: widget.initialText);
    _ctl.addListener(_onChange);
    _validate(widget.initialText, fireParsed: false);
    // Defer initial onParsed to the frame after mount so downstream
    // bindings (e.g. Scene Builder's compose page wiring `parsed`
    // to `studio.scenario.preview`) populate state on first paint
    // — without this the timeline only renders after the user
    // edits, which feels broken.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final src = widget.initialText;
      if (src.trim().isEmpty) return;
      try {
        final value = jsonDecode(src);
        widget.onParsed?.call(value);
      } catch (_) {
        /* validation error already surfaced */
      }
    });
  }

  @override
  void didUpdateWidget(covariant VbuJsonEditor old) {
    super.didUpdateWidget(old);
    if (old.initialText != widget.initialText &&
        widget.initialText != _ctl.text) {
      _ctl.text = widget.initialText;
      _validate(widget.initialText);
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _onChange() {
    widget.onChanged?.call(_ctl.text);
    _validate(_ctl.text);
  }

  void _validate(String src, {bool fireParsed = true}) {
    try {
      final value = src.trim().isEmpty ? null : jsonDecode(src);
      setState(() => _err = null);
      if (fireParsed) widget.onParsed?.call(value);
    } catch (e) {
      setState(() => _err = _shortenError(e.toString()));
    }
  }

  String _shortenError(String s) {
    if (s.startsWith('FormatException: ')) {
      return s.substring('FormatException: '.length);
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final ok = _err == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          decoration: BoxDecoration(
            color: c.surface2,
            border: Border.all(color: ok ? c.borderDefault : c.coral, width: 1),
            borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
          ),
          child: TextField(
            controller: _ctl,
            readOnly: widget.readOnly,
            minLines: widget.minLines,
            maxLines: widget.maxLines ?? widget.minLines * 4,
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 12,
              color: c.textPrimary,
              height: 1.5,
            ),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: VbuTokens.space3,
                vertical: VbuTokens.space2,
              ),
              hintText: widget.placeholder,
              hintStyle: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 12,
                color: c.textTertiary,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(
            top: VbuTokens.space1,
            left: VbuTokens.space2,
          ),
          child: Row(
            children: <Widget>[
              Icon(
                ok ? Icons.check_circle_outline : Icons.error_outline,
                size: 12,
                color: ok ? c.mint : c.coral,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  ok ? 'valid JSON' : (_err ?? 'parse error'),
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 10,
                    color: ok ? c.textTertiary : c.coral,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
