import 'package:flutter/material.dart';

import '../../form_factor/app_tokens.dart';
import '../../renderer/render_context.dart';
import '../../utils/icon_resolver.dart';
import '../widget_factory.dart';

/// Factory for Icon widgets (spec §2.5).
///
/// Three supported input shapes for the `icon` property:
///
///   1. A string name resolved through [resolveIconData]
///      (e.g. `"home"`, `"folder_open"`). Uses the bundled Material Icons
///      font — offline, zero-latency, tintable.
///   2. A codepoint object `{codepoint, fontFamily?, fontPackage?}` for any
///      Material Icons codepoint that isn't in the resolver map.
///      `{"codepoint": 0xe88a}` renders the same glyph as `"home"`.
///   3. An `http://` / `https://` URL pointing at a raster icon. The
///      runtime fetches via [Image.network], caches, and tints when the
///      color channel allows. SVG is not rendered natively.
class IconWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final iconValue = context.resolve(properties['icon']);
    // `size` accepts a numeric / dimension form (legacy) AND a responsive
    // token shorthand string — `size: "md"` or new `sizeToken: "md"` —
    // which resolves through [AppIconSizes.of] so icons scale with the
    // active form factor.
    final rawSize = context.resolve(properties['size']);
    final rawSizeToken = context.resolve(properties['sizeToken']);
    final tokenName = rawSizeToken is String
        ? rawSizeToken
        : (rawSize is String ? rawSize : null);
    final double size = _resolveIconSize(tokenName, context) ??
        parseDimension(rawSize) ??
        24.0;
    final color = parseColor(context.resolve(properties['color']), context);

    final widget = _buildIconWidget(iconValue, size, color);
    return applyCommonWrappers(widget, properties, context);
  }

  /// Resolve an [AppIconSizes] token (`sm` / `md` / `lg` / `xl`) to its
  /// FormFactor-scaled dp value. Returns `null` for unknown tokens or
  /// when the input is a numeric dimension string.
  double? _resolveIconSize(String? token, RenderContext context) {
    if (token == null || token.isEmpty) return null;
    if (double.tryParse(token) != null) return null; // numeric, not a token
    final ctx = context.buildContext;
    if (ctx != null) {
      final scale = AppIconSizes.of(ctx);
      switch (token) {
        case 'sm':
          return scale.sm;
        case 'md':
          return scale.md;
        case 'lg':
          return scale.lg;
        case 'xl':
          return scale.xl;
      }
      return null;
    }
    // No build context — fall back to the compact / mobile baseline
    // declared on [AppIconSizes].
    switch (token) {
      case 'sm':
        return AppIconSizes.sm;
      case 'md':
        return AppIconSizes.md;
      case 'lg':
        return AppIconSizes.lg;
      case 'xl':
        return AppIconSizes.xl;
    }
    return null;
  }

  Widget _buildIconWidget(dynamic value, double size, Color? color) {
    if (value is String && _isHttpUrl(value)) {
      return SizedBox(
        width: size,
        height: size,
        child: Image.network(
          value,
          width: size,
          height: size,
          color: color,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => Icon(
            resolveIconData('broken_image'),
            size: size,
            color: color,
          ),
        ),
      );
    }

    return Icon(_resolveIconData(value), size: size, color: color);
  }

  IconData _resolveIconData(dynamic value) {
    if (value is String) return resolveIconData(value);
    if (value is Map<String, dynamic>) {
      final codepoint = value['codepoint'];
      if (codepoint is int) {
        return IconData(
          codepoint,
          fontFamily:
              (value['fontFamily'] as String?) ?? 'MaterialIcons',
          fontPackage: value['fontPackage'] as String?,
        );
      }
      final name = value['name'];
      if (name is String) return resolveIconData(name);
    }
    return resolveIconData('help_outline');
  }

  bool _isHttpUrl(String value) {
    return value.startsWith('http://') || value.startsWith('https://');
  }
}
