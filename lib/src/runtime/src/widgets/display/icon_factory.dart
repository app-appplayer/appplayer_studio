import 'package:flutter/material.dart';

import '../../form_factor/app_tokens.dart';
import '../../assets/asset_ref.dart';
import '../../assets/asset_resolver.dart';
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
///   3. Any `AssetRef` — a network URL, `bundle://`, `assets/`, an inline
///      `data:` payload, or a host resource. Raster payloads go through
///      [Image]; vector payloads (`.svg`, `data:image/svg+xml`) are drawn as
///      pictures and tinted through a colour filter, so `color` applies to
///      every form alike.
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

    final widget = _buildIconWidget(iconValue, size, color, context);
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

  Widget _buildIconWidget(
    dynamic value,
    double size,
    Color? color,
    RenderContext context,
  ) {
    // §2.5.4 / IconRef — a bare string carrying no known scheme is a *name*,
    // which keeps the named form the zero-ceremony default. Anything that
    // parses as a real asset form goes through the one resolver (§6.12), so
    // an icon may now be a bundle SVG, an inline data URI, or a host resource
    // rather than only an http(s) URL.
    final ref = value is String ? AssetRef.parse(value) : null;
    if (ref != null && !ref.looksLikeIconName) {
      // A vector icon is the form the spec's own example uses
      // (`assets/icons/heart.svg`), and `data:image/svg+xml` is named in
      // `IconRef` itself. It is drawn by a picture widget and tinted through
      // a colour filter, which is what makes `color` apply to it the way
      // §2.5 says it does for the named and codepoint forms.
      if (AssetResolver.isVector(ref)) {
        final vector = context.assetResolver.vectorWidgetFor(
          ref,
          width: size,
          height: size,
          color: color,
        );
        if (vector != null) {
          return SizedBox(width: size, height: size, child: vector);
        }
      }
      final provider = context.assetResolver.imageProviderFor(ref);
      if (provider != null) {
        return SizedBox(
          width: size,
          height: size,
          child: Image(
            image: provider,
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
    }

    return Icon(_resolveIconData(value), size: size, color: color);
  }

  IconData _resolveIconData(dynamic value) {
    if (value is String) return resolveIconData(value);
    if (value is Map<String, dynamic>) {
      final codepoint = value['codepoint'];
      if (codepoint is int) {
        // Runtime codepoint: the const-inferring context cannot apply here.
        // ignore: prefer_const_constructors
        return IconData(
          // ignore: non_const_argument_for_const_parameter
          codepoint,
          // ignore: non_const_argument_for_const_parameter
          fontFamily:
              (value['fontFamily'] as String?) ?? 'MaterialIcons',
          // ignore: non_const_argument_for_const_parameter
          fontPackage: value['fontPackage'] as String?,
        );
      }
      final name = value['name'];
      if (name is String) return resolveIconData(name);
    }
    return resolveIconData('help_outline');
  }

}
