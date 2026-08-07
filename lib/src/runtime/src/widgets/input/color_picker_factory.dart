import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// `colorPicker` (spec §2.6.18).
///
/// Four of its properties — `showAlpha`, `showLabel`, `pickerType`,
/// `enableHistory` — used to be read into variables and dropped behind an
/// `unused_local_variable` ignore, with a comment saying the renderer had not
/// diverged yet. A document could declare any of them and get the same palette
/// either way, with nothing reported. They decide the picker now.
class ColorPickerFactory extends WidgetFactory {
  /// Recent values, per binding path. A picker asked for history has to
  /// remember something, and the binding is what identifies "this picker"
  /// across rebuilds.
  static final Map<String, List<Color>> _history = <String, List<Color>>{};

  static const _presets = <Color>[
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
    Colors.grey,
    Colors.blueGrey,
    Colors.black,
  ];

  static String hexOf(Color color, {required bool withAlpha}) {
    String two(double channel) =>
        (channel * 255).round().toRadixString(16).padLeft(2, '0');
    final rgb = '${two(color.r)}${two(color.g)}${two(color.b)}';
    return withAlpha
        ? '#${two(color.a)}$rgb'.toUpperCase()
        : '#$rgb'.toUpperCase();
  }

  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final label = stringOf(properties['label'], context);
    final binding = stringOf(properties['binding'], context);
    final enabled = boolOf(properties['enabled'], context) ?? true;
    final showAlpha = boolOf(properties['showAlpha'], context) ?? false;
    final showLabel = boolOf(properties['showLabel'], context) ?? true;
    // Default `palette` — exactly what every picker drew before this property
    // was read. The registry said `wheel`, but no implementation ever did
    // that, and defaulting to anything else changes what documents that never
    // mentioned `pickerType` put on screen. `wheel` and `both` are one word
    // away for anyone who wants them.
    final pickerType = readEnum(properties['pickerType'], context) ?? 'palette';
    final enableHistory = boolOf(properties['enableHistory'], context) ?? false;

    final currentValue =
        binding != null ? context.resolve("{{$binding}}") : properties['value'];
    final currentColor = parseColor(currentValue, context) ??
        context.themeManager.getColorValue('primary') ??
        Colors.blue;

    final historyKey = binding ?? '#anonymous';

    void pick(Color color, {double? alpha}) {
      final chosen =
          alpha != null ? color.withValues(alpha: alpha) : color;
      if (enableHistory) {
        final seen = _history.putIfAbsent(historyKey, () => <Color>[]);
        seen.removeWhere((c) => c.toARGB32() == chosen.toARGB32());
        seen.insert(0, chosen);
        if (seen.length > 8) seen.removeRange(8, seen.length);
      }
      if (binding != null) {
        context.setValue(binding, hexOf(chosen, withAlpha: showAlpha));
      }
    }

    Widget swatch(Color color, {double size = 32, VoidCallback? onTap}) {
      final selected = color.toARGB32() == currentColor.toARGB32();
      return InkWell(
        onTap: enabled ? onTap : null,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: color,
            border: Border.all(
              color: selected
                  ? (context.themeManager.getColorValue('onSurface') ??
                      Colors.black)
                  : (context.themeManager.getColorValue('outlineVariant') ??
                      Colors.grey[300]!),
              width: selected ? 3 : 1,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      );
    }

    // `wheel` is a continuous hue strip — the shades between the presets that
    // a palette cannot offer. `palette` is the preset swatches. `both` shows
    // the strip above the swatches, which is what the word says.
    Widget hueStrip() {
      const hues = <Color>[
        Color(0xFFFF0000),
        Color(0xFFFFFF00),
        Color(0xFF00FF00),
        Color(0xFF00FFFF),
        Color(0xFF0000FF),
        Color(0xFFFF00FF),
        Color(0xFFFF0000),
      ];
      return LayoutBuilder(
        builder: (context2, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : 240.0;
          return GestureDetector(
            onTapDown: enabled
                ? (details) {
                    final t = (details.localPosition.dx / width).clamp(0.0, 1.0);
                    pick(HSVColor.fromAHSV(
                      showAlpha ? currentColor.a : 1.0,
                      t * 359.999,
                      1,
                      1,
                    ).toColor());
                  }
                : null,
            child: Container(
              width: width,
              height: 24,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                gradient: const LinearGradient(colors: hues),
              ),
            ),
          );
        },
      );
    }

    final parts = <Widget>[];

    if (label != null) {
      parts.add(Text(
        label,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ));
      parts.add(const SizedBox(height: 8));
    }

    if (pickerType == 'wheel' || pickerType == 'both') {
      parts.add(hueStrip());
      parts.add(const SizedBox(height: 8));
    }
    if (pickerType != 'wheel') {
      parts.add(Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final color in _presets)
            swatch(color,
                onTap: () => pick(color,
                    alpha: showAlpha ? currentColor.a : null)),
        ],
      ));
    }

    if (showAlpha) {
      parts.add(const SizedBox(height: 8));
      parts.add(Row(
        children: [
          const Text('Alpha', style: TextStyle(fontSize: 12)),
          Expanded(
            child: Slider(
              value: currentColor.a,
              onChanged:
                  enabled ? (value) => pick(currentColor, alpha: value) : null,
            ),
          ),
        ],
      ));
    }

    if (showLabel) {
      parts.add(const SizedBox(height: 4));
      parts.add(Text(
        hexOf(currentColor, withAlpha: showAlpha),
        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
      ));
    }

    final recent = _history[historyKey];
    if (enableHistory && recent != null && recent.isNotEmpty) {
      parts.add(const SizedBox(height: 8));
      parts.add(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final color in recent)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: swatch(color, size: 20, onTap: () => pick(color)),
            ),
        ],
      ));
    }

    Widget colorPicker = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: parts,
    );

    if (!enabled) {
      colorPicker = Opacity(opacity: 0.6, child: colorPicker);
    }

    return applyCommonWrappers(colorPicker, properties, context);
  }
}
