import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// `resolveIconData` mirrors the runtime's Material name → IconData
// map so the picker preview matches what the runtime actually
// renders. Not part of the package's public surface.
// ignore: implementation_imports
import 'package:flutter_mcp_ui_runtime/src/utils/icon_resolver.dart';

import 'package:appplayer_studio/base.dart';

/// Result type the host listens for to refresh state after a patch lands.
typedef PatchDispatcher =
    Future<bool> Function({
      required LayerId layer,
      required String path,
      required dynamic value,
    });

/// Color cell — swatch on the left, mono hex input on the right. Hex input
/// is debounced; once a valid #RRGGBB or #AARRGGBB string is entered the
/// dispatcher is called.
class VibeColorEditor extends StatefulWidget {
  const VibeColorEditor({
    super.key,
    required this.label,
    required this.value,
    required this.dispatch,
    required this.layer,
    required this.path,
  });

  final String label;
  final String? value;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String path;

  @override
  State<VibeColorEditor> createState() => _VibeColorEditorState();
}

class _VibeColorEditorState extends State<VibeColorEditor> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value ?? '');
    _focus = FocusNode()..addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant VibeColorEditor old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.value != _ctrl.text) {
      _ctrl.text = widget.value ?? '';
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _commit(_ctrl.text);
  }

  Future<void> _commit(String raw) async {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      if (widget.value != null) {
        await widget.dispatch(
          layer: widget.layer,
          path: widget.path,
          value: null,
        );
      }
      return;
    }
    if (_parse(trimmed) == null) return;
    if (trimmed == widget.value) return;
    await widget.dispatch(
      layer: widget.layer,
      path: widget.path,
      value: trimmed,
    );
  }

  static Color? _parse(String hex) {
    var h = hex.trim();
    if (h.startsWith('#')) h = h.substring(1);
    if (h.length == 6) h = 'FF$h';
    if (h.length != 8) return null;
    try {
      return Color(int.parse(h, radix: 16));
    } catch (_) {
      return null;
    }
  }

  Future<void> _openPicker(BuildContext context) async {
    final initial = _parse(_ctrl.text) ?? VibeTokens.color.surface3;
    final picked = await showDialog<Object?>(
      context: context,
      builder:
          (ctx) => _ColorPickerDialog(initial: initial, label: widget.label),
    );
    if (picked == null) return; // Cancel
    if (identical(picked, _kClearSentinel)) {
      _ctrl.text = '';
      await _commit('');
      return;
    }
    if (picked is Color) {
      final hex =
          '#${picked.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
      _ctrl.text = hex;
      await _commit(hex);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final swatch = _parse(_ctrl.text) ?? c.borderStrong;
    return SizedBox(
      height: 30,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                widget.label,
                style: vibeMono(size: 12, color: c.textSecondary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            InkWell(
              onTap: () => _openPicker(context),
              borderRadius: BorderRadius.circular(2),
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: swatch,
                  borderRadius: BorderRadius.circular(2),
                  border: Border.all(color: c.borderStrong, width: 0.5),
                ),
              ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 92,
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                style: vibeMono(size: 11, color: c.textPrimary),
                cursorColor: c.mint,
                decoration: InputDecoration(
                  hintText: '#RRGGBB',
                  hintStyle: vibeMono(size: 11, color: c.textTertiary),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 6,
                  ),
                ),
                onSubmitted: _commit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class VibeTextEditor extends StatefulWidget {
  const VibeTextEditor({
    super.key,
    required this.label,
    required this.value,
    required this.dispatch,
    required this.layer,
    required this.path,
    this.numeric = false,
  });

  final String label;
  final String? value;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String path;
  final bool numeric;

  @override
  State<VibeTextEditor> createState() => _VibeTextEditorState();
}

class _VibeTextEditorState extends State<VibeTextEditor> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value ?? '');
    _focus = FocusNode()..addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant VibeTextEditor old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.value != _ctrl.text) {
      _ctrl.text = widget.value ?? '';
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _commit(_ctrl.text);
  }

  Future<void> _commit(String raw) async {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      if (widget.value != null) {
        await widget.dispatch(
          layer: widget.layer,
          path: widget.path,
          value: null,
        );
      }
      return;
    }
    if (widget.numeric) {
      final n = num.tryParse(trimmed);
      if (n == null) return;
      if (n.toString() == widget.value) return;
      await widget.dispatch(layer: widget.layer, path: widget.path, value: n);
      return;
    }
    if (trimmed == widget.value) return;
    await widget.dispatch(
      layer: widget.layer,
      path: widget.path,
      value: trimmed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return SizedBox(
      height: 30,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                widget.label,
                style: vibeMono(size: 12, color: c.textSecondary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(
              width: 110,
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                style: vibeMono(size: 11, color: c.textPrimary),
                cursorColor: c.mint,
                keyboardType:
                    widget.numeric
                        ? const TextInputType.numberWithOptions(decimal: true)
                        : TextInputType.text,
                inputFormatters:
                    widget.numeric
                        ? <TextInputFormatter>[
                          FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9.\-]'),
                          ),
                        ]
                        : null,
                decoration: InputDecoration(
                  hintText: widget.numeric ? '0' : '—',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 6,
                  ),
                  hintStyle: vibeMono(size: 11, color: c.textTertiary),
                ),
                onSubmitted: _commit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Icon-typed property editor. Renders like [VibeTextEditor] (label +
/// 110px field) plus a left-side preview and a chevron that opens
/// [showVibeIconPicker]. Accepted values:
///   - bare Material name (`home`) — runtime expands.
///   - `material:<name>` — explicit Material ref.
///   - `bundle://<id>` — resolved through [registeredIcons] (the icon
///     subset of `manifest.assets`).
/// Author can still type any string directly into the field — the
/// picker is a shortcut, not a constraint.
class VibeIconEditor extends StatefulWidget {
  const VibeIconEditor({
    super.key,
    required this.label,
    required this.value,
    required this.dispatch,
    required this.layer,
    required this.path,
    this.registeredIcons = const <({String id, String? contentRef})>[],
  });

  final String label;
  final String? value;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String path;

  /// Subset of `manifest.assets` with `type == "icon"` — drives the
  /// picker's Assets tab and the bundle-id preview lookup.
  final List<({String id, String? contentRef})> registeredIcons;

  @override
  State<VibeIconEditor> createState() => _VibeIconEditorState();
}

class _VibeIconEditorState extends State<VibeIconEditor> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value ?? '');
    _focus = FocusNode()..addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant VibeIconEditor old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.value != _ctrl.text) {
      _ctrl.text = widget.value ?? '';
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _commit(_ctrl.text);
  }

  Future<void> _commit(String raw) async {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      if (widget.value != null) {
        await widget.dispatch(
          layer: widget.layer,
          path: widget.path,
          value: null,
        );
      }
      return;
    }
    if (trimmed == widget.value) return;
    await widget.dispatch(
      layer: widget.layer,
      path: widget.path,
      value: trimmed,
    );
  }

  Future<void> _openPicker() async {
    final picked = await showVibeIconPicker(
      context,
      registeredIcons: widget.registeredIcons,
      currentValue: _ctrl.text,
    );
    if (!mounted || picked == null) return;
    _ctrl.text = picked;
    await _commit(picked);
  }

  /// Resolve [_ctrl.text] to an IconData for the inline preview. Bundle
  /// refs walk through [widget.registeredIcons] to find a Material ref;
  /// anything we can't resolve falls through to a faint placeholder so
  /// the author sees the value didn't pin to a known icon.
  IconData? _previewMaterial() {
    final v = _ctrl.text.trim();
    if (v.isEmpty) return null;
    if (v.startsWith('bundle://')) {
      final id = v.substring('bundle://'.length);
      final hit = widget.registeredIcons
          .where((e) => e.id == id)
          .cast<({String id, String? contentRef})?>()
          .firstWhere((_) => true, orElse: () => null);
      final ref = hit?.contentRef ?? '';
      if (ref.startsWith('material:')) {
        return resolveIconData(ref.substring('material:'.length));
      }
      return null;
    }
    if (v.startsWith('material:')) {
      return resolveIconData(v.substring('material:'.length));
    }
    if (v.startsWith('http://') ||
        v.startsWith('https://') ||
        v.startsWith('data:')) {
      return null;
    }
    return resolveIconData(v);
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final mat = _previewMaterial();
    return SizedBox(
      height: 30,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                widget.label,
                style: vibeMono(size: 12, color: c.textSecondary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(
              width: 110,
              child: VibeCompactInputBox(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    const SizedBox(width: 4),
                    Icon(
                      mat ?? Icons.image_outlined,
                      size: 14,
                      color:
                          mat == null
                              ? c.textTertiary
                              : (mat == Icons.help_outline &&
                                      _ctrl.text.trim().toLowerCase() !=
                                          'help_outline'
                                  ? VibeTokens.color.coral
                                  : c.textSecondary),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: TextField(
                        controller: _ctrl,
                        focusNode: _focus,
                        style: vibeMono(size: 11, color: c.textPrimary),
                        cursorColor: c.mint,
                        decoration: InputDecoration(
                          isDense: true,
                          isCollapsed: true,
                          filled: false,
                          contentPadding: EdgeInsets.zero,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          focusedErrorBorder: InputBorder.none,
                          hintText: '—',
                          hintStyle: vibeMono(size: 11, color: c.textTertiary),
                        ),
                        onSubmitted: _commit,
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    InkWell(
                      onTap: _openPicker,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Icon(
                          Icons.arrow_drop_down,
                          size: 14,
                          color: c.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.initial, required this.label});
  final Color initial;
  final String label;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late HSLColor _hsl;
  late TextEditingController _hex;

  static const List<MaterialColor> _swatches = <MaterialColor>[
    Colors.red,
    Colors.pink,
    Colors.purple,
    Colors.deepPurple,
    Colors.indigo,
    Colors.blue,
    Colors.lightBlue,
    Colors.cyan,
    Colors.teal,
    Colors.green,
    Colors.lightGreen,
    Colors.lime,
    Colors.yellow,
    Colors.amber,
    Colors.orange,
    Colors.deepOrange,
    Colors.brown,
    Colors.blueGrey,
    Colors.grey,
  ];

  static const List<int> _shades = <int>[
    50,
    100,
    200,
    300,
    400,
    500,
    600,
    700,
    800,
    900,
  ];

  @override
  void initState() {
    super.initState();
    _hsl = _safeHsl(widget.initial);
    _hex = TextEditingController(text: _hexOf(widget.initial));
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  static HSLColor _safeHsl(Color c) {
    final hsl = HSLColor.fromColor(c);
    final hue = hsl.hue.isNaN ? 0.0 : hsl.hue;
    return HSLColor.fromAHSL(hsl.alpha, hue, hsl.saturation, hsl.lightness);
  }

  static String _hexOf(Color c) {
    final v = c.toARGB32();
    return '#${v.toRadixString(16).padLeft(8, '0').toUpperCase()}';
  }

  static Color? _parseHex(String raw) {
    var s = raw.trim();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length == 6) s = 'FF$s';
    if (s.length != 8) return null;
    final n = int.tryParse(s, radix: 16);
    return n == null ? null : Color(n);
  }

  void _setColor(Color c) {
    setState(() {
      _hsl = _safeHsl(c);
      _hex.text = _hexOf(c);
    });
  }

  void _setHsl(HSLColor next) {
    setState(() {
      _hsl = next;
      _hex.text = _hexOf(next.toColor());
    });
  }

  Color get _color => _hsl.toColor();

  /// Maps a vibe theme M3 role to its current resolved color from
  /// the host's ColorScheme.
  Color? _tokenColor(String name) {
    final s = Theme.of(context).colorScheme;
    switch (name) {
      case 'primary':
        return s.primary;
      case 'onPrimary':
        return s.onPrimary;
      case 'secondary':
        return s.secondary;
      case 'tertiary':
        return s.tertiary;
      case 'error':
        return s.error;
      case 'surface':
        return s.surface;
      case 'onSurface':
        return s.onSurface;
      case 'outline':
        return s.outline;
    }
    return null;
  }

  static const List<String> _tokens = <String>[
    'primary',
    'onPrimary',
    'secondary',
    'tertiary',
    'error',
    'surface',
    'onSurface',
    'outline',
  ];

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Dialog(
      backgroundColor: c.surface2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VibeTokens.radiusLg),
        side: BorderSide(color: c.borderStrong),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(VibeTokens.space4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(
                    'Color · ${widget.label}',
                    style: vibeMono(
                      size: 12,
                      weight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: _color,
                      borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
                      border: Border.all(color: c.borderStrong),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: VibeTokens.space3),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _section('Theme tokens'),
                      _tokenRow(),
                      const SizedBox(height: VibeTokens.space3),
                      _section('Material swatches'),
                      _swatchGrid(),
                      const SizedBox(height: VibeTokens.space3),
                      _section('Custom'),
                      _hslSliders(),
                      const SizedBox(height: VibeTokens.space2),
                      _hexRow(),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: VibeTokens.space3),
              Row(
                children: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(_kClearSentinel),
                    child: const Text('Clear (inherit)'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(_color),
                    child: const Text('Apply'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(String label) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 6),
    child: Text(
      label.toUpperCase(),
      style: vibeMono(
        size: 11,
        weight: FontWeight.w600,
        color: VibeTokens.color.textSecondary,
      ),
    ),
  );

  Widget _tokenRow() {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final t in _tokens)
          _Swatch(
            color: _tokenColor(t) ?? VibeTokens.color.borderStrong,
            tooltip: t,
            label: t,
            selected:
                _hexOf(_color).toUpperCase() ==
                _hexOf(_tokenColor(t) ?? Colors.transparent).toUpperCase(),
            onTap: () {
              final col = _tokenColor(t);
              if (col != null) _setColor(col);
            },
          ),
      ],
    );
  }

  Widget _swatchGrid() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final swatch in _swatches)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(
              children: <Widget>[
                for (final shade in _shades)
                  Expanded(
                    child: _ShadeCell(
                      color: swatch[shade] ?? swatch,
                      selected:
                          _hexOf(_color).toUpperCase() ==
                          _hexOf(swatch[shade] ?? swatch).toUpperCase(),
                      onTap: () => _setColor(swatch[shade] ?? swatch),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _hslSliders() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _slider(
          label: 'Hue',
          value: _hsl.hue,
          max: 360,
          onChanged: (v) => _setHsl(_hsl.withHue(v)),
          trackColors: const <Color>[
            Color(0xFFFF0000),
            Color(0xFFFFFF00),
            Color(0xFF00FF00),
            Color(0xFF00FFFF),
            Color(0xFF0000FF),
            Color(0xFFFF00FF),
            Color(0xFFFF0000),
          ],
        ),
        _slider(
          label: 'Saturation',
          value: _hsl.saturation,
          max: 1,
          onChanged: (v) => _setHsl(_hsl.withSaturation(v)),
          trackColors: <Color>[
            HSLColor.fromAHSL(1, _hsl.hue, 0, _hsl.lightness).toColor(),
            HSLColor.fromAHSL(1, _hsl.hue, 1, _hsl.lightness).toColor(),
          ],
        ),
        _slider(
          label: 'Lightness',
          value: _hsl.lightness,
          max: 1,
          onChanged: (v) => _setHsl(_hsl.withLightness(v)),
          trackColors: <Color>[
            Colors.black,
            HSLColor.fromAHSL(1, _hsl.hue, _hsl.saturation, 0.5).toColor(),
            Colors.white,
          ],
        ),
        _slider(
          label: 'Alpha',
          value: _hsl.alpha,
          max: 1,
          onChanged: (v) => _setHsl(_hsl.withAlpha(v)),
          trackColors: <Color>[
            _hsl.withAlpha(0).toColor(),
            _hsl.withAlpha(1).toColor(),
          ],
        ),
      ],
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required double max,
    required ValueChanged<double> onChanged,
    required List<Color> trackColors,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: vibeMono(size: 11, color: VibeTokens.color.textSecondary),
            ),
          ),
          Expanded(
            child: SizedBox(
              height: 24,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  Container(
                    height: 6,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      gradient: LinearGradient(colors: trackColors),
                    ),
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 0,
                      activeTrackColor: Colors.transparent,
                      inactiveTrackColor: Colors.transparent,
                      thumbColor: Colors.white,
                      overlayColor: VibeTokens.color.mint.withValues(
                        alpha: 0.18,
                      ),
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                    ),
                    child: Slider(
                      value: value.clamp(0, max),
                      max: max,
                      onChanged: onChanged,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              max == 1 ? value.toStringAsFixed(2) : value.toStringAsFixed(0),
              style: vibeMono(size: 11, color: VibeTokens.color.textPrimary),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _hexRow() {
    final c = VibeTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 76,
            child: Text(
              'Hex',
              style: vibeMono(size: 11, color: c.textSecondary),
            ),
          ),
          Expanded(
            child: TextField(
              controller: _hex,
              style: vibeMono(size: 12, color: c.textPrimary),
              cursorColor: c.mint,
              decoration: const InputDecoration(
                isDense: true,
                hintText: '#AARRGGBB',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
              ),
              onChanged: (s) {
                final col = _parseHex(s);
                if (col != null) {
                  setState(() {
                    _hsl = _safeHsl(col);
                    // Don't echo back to controller (would move caret).
                  });
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Sentinel passed back from the Color dialog when the user clears.
const Object _kClearSentinel = Object();

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.tooltip,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final Color color;
  final String tooltip;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark;
    return InkWell(
      onTap: onTap,
      child: Tooltip(
        message: tooltip,
        child: Container(
          width: 64,
          height: 28,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
            border: Border.all(
              color:
                  selected
                      ? VibeTokens.color.mint
                      : VibeTokens.color.borderStrong,
              width: selected ? 2 : 0.5,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: vibeMono(
              size: 10,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

class _ShadeCell extends StatelessWidget {
  const _ShadeCell({
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 22,
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
          border: Border.all(
            color:
                selected
                    ? VibeTokens.color.mint
                    : VibeTokens.color.borderSubtle,
            width: selected ? 2 : 0.5,
          ),
        ),
      ),
    );
  }
}

/// Icon-only "+" affordance for adding a new entry to a collection.
/// Right-aligned, flat (no box, no accent) so it reads as a quiet
/// trailing action consistent with the dark / mono theme.
class VibeAddRow extends StatelessWidget {
  const VibeAddRow({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VibeTokens.space4,
        2,
        VibeTokens.space4,
        2,
      ),
      child: Align(
        alignment: Alignment.centerRight,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(Icons.add, size: 14, color: c.textSecondary),
          ),
        ),
      ),
    );
  }
}

/// Multi-line JSON-shaped text editor for collection fields. Click to
/// expand into a dialog where the user can paste / edit raw JSON.
class VibeJsonEditor extends StatelessWidget {
  const VibeJsonEditor({
    super.key,
    required this.label,
    required this.value,
    required this.dispatch,
    required this.layer,
    required this.path,
  });

  final String label;
  final dynamic value;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String path;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return SizedBox(
      height: 30,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: vibeMono(size: 12, color: c.textSecondary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (value == null)
              InkWell(
                onTap: () => _openEditor(context),
                borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.add, size: 14, color: c.textSecondary),
                ),
              )
            else
              InkWell(
                onTap: () => _openEditor(context),
                borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: VibeTokens.space2,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        _summary(),
                        style: vibeMono(size: 11, color: c.textPrimary),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.edit, size: 12, color: c.textSecondary),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _summary() {
    if (value is List) return '${(value as List).length}';
    if (value is Map) return '${(value as Map).length}';
    final s = value is String ? value as String : value.toString();
    if (s.length > 12) return '${s.substring(0, 10)}…';
    return s;
  }

  Future<void> _openEditor(BuildContext context) async {
    final c = VibeTokens.colorOf(context);
    final ctrl = TextEditingController(
      text:
          value == null
              ? ''
              : value is String
              ? value as String
              : _pretty(value),
    );
    final result = await showDialog<String?>(
      context: context,
      builder:
          (ctx) => Dialog(
            backgroundColor: c.surface2,
            child: SizedBox(
              width: 520,
              child: Padding(
                padding: const EdgeInsets.all(VibeTokens.space4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      '$label (raw JSON)',
                      style: vibeMono(
                        size: 13,
                        weight: FontWeight.w600,
                        color: c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: VibeTokens.space3),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: TextField(
                        controller: ctrl,
                        maxLines: null,
                        style: vibeMono(size: 12, color: c.textPrimary),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.all(8),
                        ),
                      ),
                    ),
                    const SizedBox(height: VibeTokens.space3),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(null),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: VibeTokens.space2),
                        TextButton(
                          onPressed:
                              () => Navigator.of(ctx).pop('__VIBE_CLEAR__'),
                          child: const Text('Clear'),
                        ),
                        const SizedBox(width: VibeTokens.space2),
                        FilledButton(
                          onPressed: () => Navigator.of(ctx).pop(ctrl.text),
                          child: const Text('Apply'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
    );
    if (result == null) return;
    if (result == '__VIBE_CLEAR__') {
      await dispatch(layer: layer, path: path, value: null);
      return;
    }
    final trimmed = result.trim();
    if (trimmed.isEmpty) {
      await dispatch(layer: layer, path: path, value: null);
      return;
    }
    dynamic parsed = trimmed;
    try {
      parsed = const JsonDecoder().convert(trimmed);
    } catch (_) {
      // Fall back to plain string.
    }
    await dispatch(layer: layer, path: path, value: parsed);
  }

  static String _pretty(dynamic v) {
    return const JsonEncoder.withIndent('  ').convert(v);
  }
}

class VibeBoolEditor extends StatelessWidget {
  const VibeBoolEditor({
    super.key,
    required this.label,
    required this.value,
    required this.dispatch,
    required this.layer,
    required this.path,
    this.schemaDefault,
  });

  final String label;
  final bool? value;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String path;

  /// Spec-declared default. When [value] is null the toggle reflects
  /// this — matching the runtime's own default-resolution — so the
  /// editor never misleads about the rendered widget's effective state.
  final bool? schemaDefault;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return SizedBox(
      height: 30,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: vibeMono(size: 12, color: c.textSecondary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Three explicit options so "unset (using runtime default)"
            // is a real choice, not a guess. Each is a labelled radio.
            //   default → canonical key absent (runtime resolves the
            //             spec default).
            //   on      → explicit `true` written to canonical.
            //   off     → explicit `false` written to canonical.
            _BoolRadio(
              label: 'default',
              selected: value == null,
              tooltip:
                  schemaDefault == null
                      ? 'unset (use spec default)'
                      : 'unset (default: $schemaDefault)',
              onTap: () => dispatch(layer: layer, path: path, value: null),
            ),
            const SizedBox(width: VibeTokens.space2),
            _BoolRadio(
              label: 'on',
              selected: value == true,
              onTap: () => dispatch(layer: layer, path: path, value: true),
            ),
            const SizedBox(width: VibeTokens.space2),
            _BoolRadio(
              label: 'off',
              selected: value == false,
              onTap: () => dispatch(layer: layer, path: path, value: false),
            ),
          ],
        ),
      ),
    );
  }
}

class _BoolRadio extends StatelessWidget {
  const _BoolRadio({
    required this.label,
    required this.selected,
    required this.onTap,
    this.tooltip,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final widget = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 12,
              color: selected ? c.mint : c.textTertiary,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: vibeMono(
                size: 11,
                color: selected ? c.textPrimary : c.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
    if (tooltip == null) return widget;
    return Tooltip(message: tooltip!, child: widget);
  }
}

/// Compact dropdown that opens a [showMenu] popup with full control over
/// height / padding / shape, mirroring `app_builder`'s `CompactDropdown`.
/// Bypasses Material's `DropdownButton` (which forces a min interactive
/// dimension on items and ignores rounded outlines).
class VibeEnumEditor extends StatefulWidget {
  const VibeEnumEditor({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.dispatch,
    required this.layer,
    required this.path,
  });

  final String label;
  final String? value;
  final List<String> options;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String path;

  @override
  State<VibeEnumEditor> createState() => _VibeEnumEditorState();
}

class _VibeEnumEditorState extends State<VibeEnumEditor> {
  /// Re-entry guard. While the popup is open, a second tap on the
  /// trigger is ignored — otherwise the first popup's await unwinds
  /// with whatever the second tap registers, surfacing as a phantom
  /// selection of an adjacent option.
  bool _menuOpen = false;

  /// Latest tap timestamp on the trigger pill. Drives the same-frame
  /// "double tap closes the popup" guard — if the user re-taps the
  /// trigger to dismiss, we ignore any selection that lands within
  /// 80 ms of the second tap (Flutter's barrier dismiss can race
  /// the trigger's onTap so a click meant to close occasionally
  /// arrives after the popup has committed a hover-focused item).
  DateTime? _lastTriggerTap;

  Future<void> _open(BuildContext context) async {
    final now = DateTime.now();
    if (_menuOpen) {
      _lastTriggerTap = now;
      return;
    }
    _menuOpen = true;
    _lastTriggerTap = now;
    final c = VibeTokens.colorOf(context);
    final box = context.findRenderObject();
    if (box is! RenderBox) {
      _menuOpen = false;
      return;
    }
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final overlaySize = overlayBox.size;
    final offset = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final size = box.size;
    // Larger gap (8 px instead of 2 px) keeps the popup's first row
    // out of the trigger's accidental-tap halo when the panel is
    // tight on vertical space and the user double-taps to dismiss.
    final anchor = Rect.fromLTWH(
      offset.dx,
      offset.dy + size.height + 8,
      size.width,
      0,
    );
    String? selected;
    try {
      selected = await showMenu<String>(
        context: context,
        popUpAnimationStyle: AnimationStyle.noAnimation,
        useRootNavigator: true,
        menuPadding: EdgeInsets.zero,
        color: c.elevated,
        constraints: BoxConstraints(minWidth: 0, maxWidth: size.width),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
          side: BorderSide(color: c.borderStrong),
        ),
        position: RelativeRect.fromRect(anchor, Offset.zero & overlaySize),
        items: <PopupMenuEntry<String>>[
          for (final opt in widget.options)
            PopupMenuItem<String>(
              value: opt,
              height: 28,
              padding: EdgeInsets.zero,
              child: InkWell(
                // Explicit InkWell makes the only commit path an
                // intentional click on the row's text. PopupMenuItem's
                // built-in tap handler still pops with `value`, but
                // this child catches stray hover events that some
                // platforms turn into taps on dismissal.
                onTap: () => Navigator.of(context).pop(opt),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  alignment: Alignment.centerLeft,
                  height: 28,
                  child: Text(
                    opt,
                    style: vibeMono(
                      size: 11,
                      color: opt == widget.value ? c.mint : c.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    } finally {
      _menuOpen = false;
    }
    // Race guard — if a trigger re-tap arrived within 80 ms of the
    // dispatch, treat the close as user-initiated cancel rather than
    // a phantom selection from the popup's hover focus.
    final dispatchAt = DateTime.now();
    final lastTap = _lastTriggerTap;
    if (lastTap != null &&
        dispatchAt.difference(lastTap) < const Duration(milliseconds: 80)) {
      return;
    }
    if (selected != null && selected != widget.value) {
      await widget.dispatch(
        layer: widget.layer,
        path: widget.path,
        value: selected,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final showLabel =
        widget.options.contains(widget.value) ? widget.value! : null;
    return SizedBox(
      height: 30,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                widget.label,
                style: vibeMono(size: 12, color: c.textSecondary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(
              width: 110,
              child: InkWell(
                onTap: () => _open(context),
                borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: c.surface2,
                    borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
                    border: Border.all(color: c.borderDefault),
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          showLabel ?? '—',
                          style: vibeMono(
                            size: 11,
                            color:
                                showLabel == null
                                    ? c.textTertiary
                                    : c.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      Icon(
                        Icons.arrow_drop_down,
                        size: 14,
                        color: c.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 28-pixel-tall input box decoration — matches the surface / border /
/// radius of `VibeCompactDropdown` so plain text inputs sit alongside
/// dropdowns in row layouts without height drift. Use as the OUTER
/// wrapper around a borderless `TextField` (`InputBorder.none`,
/// `contentPadding: zero`) so the visible chrome lives on the
/// container, not the input.
class VibeCompactInputBox extends StatelessWidget {
  const VibeCompactInputBox({
    super.key,
    required this.child,
    this.warning = false,
  });
  final Widget child;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
        border: Border.all(
          color: warning ? VibeTokens.color.coral : c.borderDefault,
        ),
      ),
      child: Center(child: child),
    );
  }
}

/// Material Icon names known to the runtime's `resolveIconData` map.
/// Mirrors `flutter_mcp_ui_runtime/utils/icon_resolver.dart` 1:1 so
/// every name the picker offers definitely renders in the running
/// app. Authors can still type any name directly — anything outside
/// this list resolves to `help_outline` at runtime.
const List<String> kCommonMaterialIcons = <String>[
  'access_time',
  'account_box',
  'account_circle',
  'add',
  'add_circle',
  'add_circle_outline',
  'alarm',
  'analytics',
  'apps',
  'arrow_back',
  'arrow_downward',
  'arrow_drop_down',
  'arrow_drop_up',
  'arrow_forward',
  'arrow_left',
  'arrow_right',
  'arrow_upward',
  'article',
  'assignment',
  'attach_file',
  'attach_money',
  'attachment',
  'auto_awesome',
  'bar_chart',
  'battery_full',
  'bluetooth',
  'bookmark',
  'bookmark_border',
  'brush',
  'bubble_chart',
  'bug_report',
  'build',
  'calculate',
  'calendar_month',
  'calendar_today',
  'call',
  'camera',
  'camera_alt',
  'cancel',
  'chat',
  'chat_bubble',
  'chat_bubble_outline',
  'check',
  'check_box',
  'check_box_outline_blank',
  'check_circle',
  'check_circle_outline',
  'chevron_left',
  'chevron_right',
  'circle',
  'circle_outlined',
  'clear',
  'close',
  'cloud',
  'cloud_done',
  'cloud_download',
  'cloud_off',
  'cloud_upload',
  'code',
  'color_lens',
  'computer',
  'content_copy',
  'content_cut',
  'content_paste',
  'copy',
  'credit_card',
  'dark_mode',
  'dashboard',
  'dashboard_outlined',
  'date_range',
  'delete',
  'delete_forever',
  'delete_outline',
  'description',
  'design_services',
  'devices',
  'directions',
  'directions_bike',
  'directions_bus',
  'directions_car',
  'directions_walk',
  'done',
  'done_all',
  'download',
  'edit',
  'edit_outlined',
  'email',
  'email_outlined',
  'error',
  'error_outline',
  'event',
  'event_available',
  'event_note',
  'exit_to_app',
  'expand_less',
  'expand_more',
  'extension',
  'face',
  'fast_forward',
  'fast_rewind',
  'favorite',
  'favorite_border',
  'fiber_manual_record',
  'file_download',
  'file_upload',
  'filter_alt',
  'filter_list',
  'flag',
  'flight',
  'folder',
  'folder_open',
  'folder_outlined',
  'folder_special',
  'format_bold',
  'format_italic',
  'format_list_bulleted',
  'format_list_numbered',
  'format_underline',
  'fullscreen',
  'fullscreen_exit',
  'gavel',
  'gps_fixed',
  'gps_not_fixed',
  'gps_off',
  'grid_view',
  'group',
  'group_add',
  'headset',
  'help',
  'help_outline',
  'history',
  'home',
  'home_outlined',
  'hub',
  'image',
  'info',
  'info_outline',
  'insert_drive_file',
  'insights',
  'inventory',
  'inventory_2',
  'key',
  'keyboard',
  'label',
  'language',
  'laptop',
  'launch',
  'light_mode',
  'lightbulb',
  'lightbulb_outline',
  'link',
  'list',
  'local_mall',
  'local_offer',
  'local_shipping',
  'location',
  'location_city',
  'location_off',
  'location_on',
  'location_pin',
  'lock',
  'lock_open',
  'lock_outline',
  'login',
  'logout',
  'mail',
  'mail_outline',
  'map',
  'menu',
  'menu_open',
  'message',
  'mic',
  'mic_off',
  'more_horiz',
  'more_vert',
  'mouse',
  'movie',
  'music_note',
  'my_location',
  'navigation',
  'near_me',
  'notifications',
  'notifications_active',
  'notifications_off',
  'notifications_outlined',
  'open_in_new',
  'palette',
  'pan_tool',
  'pause',
  'pause_circle',
  'payment',
  'people',
  'person',
  'person_add',
  'person_outline',
  'phone',
  'phone_android',
  'phone_iphone',
  'photo',
  'photo_camera',
  'pie_chart',
  'pin_drop',
  'place',
  'play_arrow',
  'play_circle',
  'play_circle_outline',
  'power',
  'power_settings_new',
  'print',
  'profile',
  'public',
  'receipt',
  'redo',
  'refresh',
  'remove',
  'remove_circle',
  'remove_circle_outline',
  'report',
  'save',
  'save_alt',
  'schedule',
  'search',
  'security',
  'send',
  'sensors',
  'settings',
  'settings_outlined',
  'share',
  'shield',
  'shopping_bag',
  'shopping_cart',
  'show_chart',
  'skip_next',
  'skip_previous',
  'smartphone',
  'sort',
  'speed',
  'square',
  'star',
  'star_border',
  'star_half',
  'stop',
  'store',
  'storefront',
  'supervisor_account',
  'swap_horiz',
  'swap_vert',
  'sync',
  'table_chart',
  'tablet',
  'temperature',
  'terminal',
  'text_fields',
  'thermostat',
  'thumb_down',
  'thumb_up',
  'timer',
  'today',
  'touch_app',
  'translate',
  'trending_down',
  'trending_flat',
  'trending_up',
  'tune',
  'tv',
  'undo',
  'upload',
  'verified',
  'verified_user',
  'videocam',
  'view_list',
  'view_module',
  'visibility',
  'visibility_off',
  'volume_down',
  'volume_mute',
  'volume_off',
  'volume_up',
  'warning',
  'warning_amber',
  'watch',
  'widgets',
  'wifi',
  'zoom_in',
  'zoom_out',
];

/// Open a modal icon picker. Returns the chosen value or null on
/// cancel. Two sources:
///   - `assets`: registered Asset entries with type:icon — returned as
///     `bundle://<id>`. Empty when no assets registered.
///   - Material catalog (curated common icons + search) — returned as
///     the bare name (`home`, `menu`, …) which the runtime resolves
///     against its full Material map.
/// Author can still type any name into the TextField directly when
/// the picker doesn't surface what they want.
Future<String?> showVibeIconPicker(
  BuildContext context, {
  required List<({String id, String? contentRef})> registeredIcons,
  String? currentValue,
}) {
  return showDialog<String?>(
    context: context,
    barrierColor: Colors.black54,
    builder:
        (ctx) => _VibeIconPickerDialog(
          registeredIcons: registeredIcons,
          currentValue: currentValue,
        ),
  );
}

class _VibeIconPickerDialog extends StatefulWidget {
  const _VibeIconPickerDialog({
    required this.registeredIcons,
    required this.currentValue,
  });
  final List<({String id, String? contentRef})> registeredIcons;
  final String? currentValue;

  @override
  State<_VibeIconPickerDialog> createState() => _VibeIconPickerDialogState();
}

class _VibeIconPickerDialogState extends State<_VibeIconPickerDialog>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.registeredIcons.isEmpty ? 1 : 0,
    );
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final filtered = _filterMaterial();
    return Dialog(
      backgroundColor: c.surface2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VibeTokens.radiusLg),
        side: BorderSide(color: c.borderStrong),
      ),
      child: SizedBox(
        width: 480,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                VibeTokens.space4,
                VibeTokens.space3,
                VibeTokens.space4,
                VibeTokens.space2,
              ),
              child: Text(
                'PICK ICON',
                style: vibeMono(size: 11, color: c.textSecondary),
              ),
            ),
            TabBar(
              controller: _tabs,
              labelColor: c.textPrimary,
              unselectedLabelColor: c.textTertiary,
              indicatorColor: VibeTokens.color.mint,
              labelStyle: vibeMono(size: 11, color: c.textPrimary),
              tabs: <Widget>[
                Tab(text: 'Assets (${widget.registeredIcons.length})'),
                const Tab(text: 'Material'),
              ],
            ),
            Divider(height: 1, color: c.borderDefault),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: <Widget>[
                  _buildAssetsList(c),
                  _buildMaterialGrid(c, filtered),
                ],
              ),
            ),
            Divider(height: 1, color: c.borderDefault),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: VibeTokens.space3,
                vertical: VibeTokens.space2,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<String> _filterMaterial() {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return kCommonMaterialIcons;
    return kCommonMaterialIcons.where((n) => n.contains(q)).toList();
  }

  Widget _buildAssetsList(dynamic c) {
    if (widget.registeredIcons.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(VibeTokens.space4),
          child: Text(
            'No assets with type "icon" registered.\n'
            'Open the Assets card to register one — Material refs '
            '(`material:home`), URLs, or imported files.',
            style: vibeMono(size: 11, color: c.textTertiary),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: widget.registeredIcons.length,
      separatorBuilder: (_, __) => Divider(height: 1, color: c.borderSubtle),
      itemBuilder: (_, i) {
        final entry = widget.registeredIcons[i];
        final ref = entry.contentRef ?? '';
        final materialName =
            ref.startsWith('material:')
                ? ref.substring('material:'.length)
                : null;
        return InkWell(
          onTap: () {
            // Map the registry entry to a value the icon widget can
            // actually consume (per widgets/display/icon.yaml — five
            // forms: bare name / codepoint / URL / `assets/...` SVG
            // / data URI). The runtime does not unwrap `bundle://`
            // for icon, so we return the resolvable shape directly.
            //   - `material:<name>`  → bare name (legacy / wrong-
            //     spec entry; still tolerated for old projects)
            //   - `https?://...`     → URL as-is
            //   - `data:...`         → data URI as-is
            //   - `assets/<path>`    → path as-is (SVG form #4)
            //   - anything else      → return contentRef as-is
            String value = ref;
            if (materialName != null) {
              value = materialName;
            } else if (ref.isEmpty) {
              // No contentRef — we can't synthesize a usable form.
              // Fall back to the (broken) bundle:// pointer so the
              // user notices and re-registers the asset properly.
              value = 'bundle://${entry.id}';
            }
            Navigator.of(context).pop(value);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: VibeTokens.space3,
              vertical: VibeTokens.space2,
            ),
            child: Row(
              children: <Widget>[
                if (materialName != null)
                  Icon(
                    resolveIconData(materialName),
                    size: 20,
                    color: c.textPrimary,
                  )
                else
                  Icon(Icons.image_outlined, size: 20, color: c.textSecondary),
                const SizedBox(width: VibeTokens.space3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        entry.id,
                        style: vibeMono(size: 12, color: c.textPrimary),
                      ),
                      Text(
                        ref.isEmpty ? '— file —' : ref,
                        style: vibeMono(size: 10, color: c.textTertiary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Text(
                  'bundle://${entry.id}',
                  style: vibeMono(size: 10, color: c.textTertiary),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMaterialGrid(dynamic c, List<String> names) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space3,
            vertical: VibeTokens.space2,
          ),
          child: TextField(
            controller: _search,
            style: vibeMono(size: 11, color: c.textPrimary),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'search icon name…',
              hintStyle: vibeMono(size: 11, color: c.textTertiary),
              prefixIcon: Icon(Icons.search, size: 16, color: c.textTertiary),
              prefixIconConstraints: const BoxConstraints.tightFor(
                width: 28,
                height: 28,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 6,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
                borderSide: BorderSide(color: c.borderDefault),
              ),
            ),
          ),
        ),
        Expanded(
          child: Scrollbar(
            thumbVisibility: true,
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(
                VibeTokens.space3,
                VibeTokens.space1,
                VibeTokens.space3,
                VibeTokens.space3,
              ),
              physics: const AlwaysScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 44,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
                childAspectRatio: 1,
              ),
              itemCount: names.length,
              itemBuilder: (_, i) {
                final name = names[i];
                return InkWell(
                  onTap: () => Navigator.of(context).pop(name),
                  borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
                  child: Tooltip(
                    message: name,
                    waitDuration: const Duration(milliseconds: 300),
                    child: Container(
                      decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(
                          VibeTokens.radiusSm,
                        ),
                        border: Border.all(color: c.borderSubtle),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        resolveIconData(name),
                        size: 16,
                        color: c.textPrimary,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// Bare compact dropdown — same showMenu styling as `VibeEnumEditor`
/// but returns the chosen value via [onChanged] instead of
/// dispatching a patch directly. Use when the host needs to apply
/// the value through a different path (e.g. a row in a list editor)
/// or run validation before dispatch.
class VibeCompactDropdown<T> extends StatelessWidget {
  const VibeCompactDropdown({
    super.key,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
    this.placeholder,
    this.warning = false,
  });

  final T? value;
  final List<T> options;
  final String Function(T) labelOf;
  final ValueChanged<T?> onChanged;

  /// Shown when [value] is null. Defaults to `—`.
  final String? placeholder;

  /// When true, the field renders with a coral border to flag a
  /// missing / dangling value (e.g. a route pointing at a deleted
  /// page). Visual only; doesn't block selection.
  final bool warning;

  Future<void> _open(BuildContext context) async {
    final c = VibeTokens.colorOf(context);
    final box = context.findRenderObject();
    if (box is! RenderBox) return;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final overlaySize = overlayBox.size;
    final offset = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final size = box.size;
    final anchor = Rect.fromLTWH(
      offset.dx,
      offset.dy + size.height + 2,
      size.width,
      0,
    );
    final selected = await showMenu<T>(
      context: context,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      menuPadding: EdgeInsets.zero,
      color: c.elevated,
      constraints: BoxConstraints(minWidth: 0, maxWidth: size.width),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
        side: BorderSide(color: c.borderStrong),
      ),
      position: RelativeRect.fromRect(anchor, Offset.zero & overlaySize),
      items: <PopupMenuEntry<T>>[
        for (final opt in options)
          PopupMenuItem<T>(
            value: opt,
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              labelOf(opt),
              style: vibeMono(
                size: 11,
                color: opt == value ? c.mint : c.textPrimary,
              ),
            ),
          ),
      ],
    );
    if (selected != null && selected != value) {
      onChanged(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final v = value;
    final shown = v != null && options.contains(v) ? labelOf(v) : null;
    // Match the surrounding `TextField(OutlineInputBorder, isDense:
    // true, contentPadding: vertical 6)` exactly — same height, same
    // radius, same vertical padding. Without this, dropdowns next to
    // text inputs in row layouts look oversized and break alignment.
    return InkWell(
      onTap: options.isEmpty ? null : () => _open(context),
      borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
      child: Container(
        height: 28,
        // Horizontal padding only — drop the vertical padding and let
        // the inner Row's `center` cross-axis alignment + the
        // Container height drive vertical positioning. With explicit
        // vertical padding the asymmetry between border + padding +
        // text baseline pushes the rendered text a few pixels below
        // the bare-text rows next to it.
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
          border: Border.all(
            color: warning ? VibeTokens.color.coral : c.borderDefault,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: Text(
                shown ?? (placeholder ?? '—'),
                style: vibeMono(
                  size: 11,
                  color: shown == null ? c.textTertiary : c.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 14, color: c.textSecondary),
          ],
        ),
      ),
    );
  }
}
