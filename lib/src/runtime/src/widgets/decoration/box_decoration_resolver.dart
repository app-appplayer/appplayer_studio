import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Shared resolver for the spec § 1.3 `BoxDecoration` primitive
/// declared in `configs/widget/BoxDecoration.yaml`. Both the `box`
/// widget (`container_factory.dart`) and the `decoration` widget
/// (`decoration_factory.dart`) build their `BoxDecoration` through
/// this single path so the two stay in lockstep with the schema.
///
/// The companion [wrapWithBackdrop] helper handles `backdropBlur` —
/// which is not part of `BoxDecoration` itself but is declared on
/// the same primitive in spec — by wrapping the rendered widget in
/// a `BackdropFilter` clipped by the same border radius.
class BoxDecorationResolver {
  /// Build a Flutter [BoxDecoration] from the merged spec property bag.
  ///
  /// `properties` is the flattened widget property map. The resolver
  /// reads two equivalent shapes:
  ///
  /// 1. Single `decoration: { color, gradient, image, ... }` map.
  /// 2. Flat top-level keys (`color`, `gradient`, `image`, `border`,
  ///    `borderRadius`, `boxShadow`, `shape`).
  ///
  /// Flat keys override matching `decoration.<field>` entries when
  /// both forms are present (spec § decoration widget docs).
  static BoxDecoration? resolve(
    Map<String, dynamic> properties,
    RenderContext context, {
    required WidgetFactory host,
  }) {
    final flat = <String, dynamic>{};
    final inner = properties['decoration'];
    if (inner is Map) {
      flat.addAll(inner.cast<String, dynamic>());
    } else if (inner is String) {
      // Allow `decoration: "{{theme.surface}}"` binding form. If it
      // resolves to a map, treat as the inner shape; non-maps fall
      // through to the flat-keys path below.
      final resolved = context.resolve<dynamic>(inner);
      if (resolved is Map) {
        flat.addAll(resolved.cast<String, dynamic>());
      }
    }
    // Flat top-level overrides — same key set the schema documents.
    // Treat null values as "not provided" so an absent top-level field
    // can never erase a value the caller declared inside `decoration:`.
    // The schema has no use case for an explicit-null override.
    for (final key in const [
      'color',
      'gradient',
      'image',
      'border',
      'borderRadius',
      'boxShadow',
      'shadow', // legacy alias for boxShadow per pre-1.3.4 bundles
      'shape',
      'backdropBlur',
    ]) {
      final v = properties[key];
      if (v != null) flat[key] = v;
    }

    final hasAny = flat.keys.any((k) => k != 'backdropBlur');
    if (!hasAny) return null;

    final gradient = _resolveGradient(flat['gradient'], context, host);
    final color = gradient != null
        ? null
        : _resolveColor(flat['color'], context, host);

    return BoxDecoration(
      color: color,
      gradient: gradient,
      image: _resolveDecorationImage(flat['image'], context, host),
      border: _resolveBorder(flat['border'], context, host),
      borderRadius: _resolveBorderRadius(flat['borderRadius']),
      boxShadow: _resolveBoxShadow(
          flat['boxShadow'] ?? flat['shadow'], context, host),
      shape: _resolveBoxShape(flat['shape']),
    );
  }

  /// `backdropBlur` sigma if declared, else null. Lives outside
  /// [BoxDecoration] because Flutter implements it via
  /// [BackdropFilter] not as part of [BoxDecoration].
  static double? backdropBlurSigma(Map<String, dynamic> properties) {
    final inner = properties['decoration'];
    final candidates = <dynamic>[
      properties['backdropBlur'],
      if (inner is Map) inner['backdropBlur'],
    ];
    for (final c in candidates) {
      if (c is num && c > 0) return c.toDouble();
    }
    return null;
  }

  /// Wrap [child] with a Gaussian backdrop blur clipped by [radius]
  /// (or no radius when null) when [sigma] is non-null.
  static Widget wrapWithBackdrop(
    Widget child, {
    required double? sigma,
    BorderRadius? radius,
  }) {
    if (sigma == null || sigma <= 0) return child;
    final blurred = BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: child,
    );
    if (radius != null) {
      return ClipRRect(borderRadius: radius, child: blurred);
    }
    return ClipRect(child: blurred);
  }

  // ---- Sub-resolvers ----------------------------------------------------

  static Color? _resolveColor(
    dynamic value,
    RenderContext context,
    WidgetFactory host,
  ) {
    if (value == null) return null;
    final resolved = context.resolve<dynamic>(value);
    return host.parseColor(resolved, context);
  }

  /// Resolve a spec [Gradient] map to a Flutter [Gradient]. Public
  /// surface so other widgets (text shader fill, icon shader fill,
  /// gallery hero overlay, …) can reuse the same primitive without
  /// reaching into [resolve].
  static Gradient? resolveGradient(
    dynamic value,
    RenderContext context,
    WidgetFactory host,
  ) =>
      _resolveGradient(value, context, host);

  static Gradient? _resolveGradient(
    dynamic value,
    RenderContext context,
    WidgetFactory host,
  ) {
    if (value is! Map) return null;
    final colorsRaw = value['colors'];
    if (colorsRaw is! List || colorsRaw.length < 2) return null;
    final colors = <Color>[];
    for (final c in colorsRaw) {
      final parsed = _resolveColor(c, context, host);
      if (parsed == null) return null;
      colors.add(parsed);
    }
    final stops = (value['stops'] is List)
        ? (value['stops'] as List)
            .map((e) => (e as num).toDouble())
            .toList(growable: false)
        : null;

    final type = (value['type'] as String?) ?? 'linear';
    final tile = _resolveTileMode(value['tileMode']);
    switch (type) {
      case 'linear':
        return LinearGradient(
          colors: colors,
          stops: stops,
          begin: _resolveAlignment(value['begin']) ?? Alignment.centerLeft,
          end: _resolveAlignment(value['end']) ?? Alignment.centerRight,
          tileMode: tile,
        );
      case 'radial':
        return RadialGradient(
          colors: colors,
          stops: stops,
          center: _resolveAlignment(value['center']) ?? Alignment.center,
          radius: (value['radius'] as num?)?.toDouble() ?? 0.5,
          tileMode: tile,
        );
      case 'sweep':
        return SweepGradient(
          colors: colors,
          stops: stops,
          center: _resolveAlignment(value['center']) ?? Alignment.center,
          startAngle: (value['startAngle'] as num?)?.toDouble() ?? 0.0,
          endAngle: (value['endAngle'] as num?)?.toDouble() ?? (2 * 3.141592653589793),
          tileMode: tile,
        );
    }
    return null;
  }

  static TileMode _resolveTileMode(dynamic v) {
    switch (v) {
      case 'repeated':
        return TileMode.repeated;
      case 'mirror':
        return TileMode.mirror;
      case 'clamp':
      default:
        return TileMode.clamp;
    }
  }

  /// Spec [Alignment] primitive: nine M3 directional tokens (canonical)
  /// or visual tokens (legacy alias accepted for runtime compat) or
  /// `{x, y}` numeric pair in `[-1, 1]` range. Maps every form to a
  /// Flutter [Alignment] in visual coords; RTL handling is the
  /// caller's concern via `Directionality`.
  static Alignment? _resolveAlignment(dynamic value) {
    if (value is String) {
      switch (value) {
        case 'topStart':
        case 'topLeft':
          return Alignment.topLeft;
        case 'topCenter':
          return Alignment.topCenter;
        case 'topEnd':
        case 'topRight':
          return Alignment.topRight;
        case 'centerStart':
        case 'centerLeft':
          return Alignment.centerLeft;
        case 'center':
          return Alignment.center;
        case 'centerEnd':
        case 'centerRight':
          return Alignment.centerRight;
        case 'bottomStart':
        case 'bottomLeft':
          return Alignment.bottomLeft;
        case 'bottomCenter':
          return Alignment.bottomCenter;
        case 'bottomEnd':
        case 'bottomRight':
          return Alignment.bottomRight;
      }
    }
    if (value is Map) {
      final x = (value['x'] as num?)?.toDouble();
      final y = (value['y'] as num?)?.toDouble();
      if (x != null && y != null) return Alignment(x, y);
    }
    return null;
  }

  /// Spec [BackgroundImage] primitive. `image` is the AssetRef-shaped
  /// source string (`https?://`, `assets/`, `data:image/...;base64,`).
  /// Other schemes (`bundle://`, `client://`) are not yet wired
  /// through to an `ImageProvider` here and resolve to null.
  static DecorationImage? _resolveDecorationImage(
    dynamic value,
    RenderContext context,
    WidgetFactory host,
  ) {
    if (value is! Map) return null;
    final src = value['image'] ?? value['src'];
    if (src is! String || src.isEmpty) return null;
    final provider = _resolveImageProvider(src);
    if (provider == null) return null;

    final filter = value['colorFilter'];
    final colorFilter = filter is Map
        ? _resolveColorFilter(filter, context, host)
        : null;

    return DecorationImage(
      image: provider,
      fit: _resolveBoxFit(value['fit']),
      alignment: _resolveAlignment(value['alignment']) ?? Alignment.center,
      repeat: _resolveImageRepeat(value['repeat']),
      opacity: (value['opacity'] as num?)?.toDouble() ?? 1.0,
      colorFilter: colorFilter,
    );
  }

  static ImageProvider? _resolveImageProvider(String src) {
    if (src.startsWith('http://') || src.startsWith('https://')) {
      return NetworkImage(src);
    }
    if (src.startsWith('assets/')) {
      return AssetImage(src);
    }
    if (src.startsWith('data:image')) {
      final commaIdx = src.indexOf(',');
      if (commaIdx == -1) return null;
      final isBase64 = src.substring(0, commaIdx).contains(';base64');
      final payload = src.substring(commaIdx + 1);
      try {
        final bytes = isBase64
            ? base64Decode(payload)
            : Uint8List.fromList(utf8.encode(Uri.decodeComponent(payload)));
        return MemoryImage(bytes);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static ColorFilter? _resolveColorFilter(
    Map filter,
    RenderContext context,
    WidgetFactory host,
  ) {
    final color = _resolveColor(filter['color'], context, host);
    if (color == null) return null;
    final mode = _resolveBlendMode(filter['blendMode']) ?? BlendMode.srcIn;
    return ColorFilter.mode(color, mode);
  }

  /// Spec curated blend-mode subset for `BackgroundImage.colorFilter`:
  /// `srcIn` (solid tint), `color` (hue swap), and `screen`/`overlay`/
  /// `multiply` (atmosphere). Matches the enum declared in
  /// `configs/widget/BackgroundImage.yaml`.
  static BlendMode? _resolveBlendMode(dynamic mode) {
    switch (mode) {
      case 'srcIn':
        return BlendMode.srcIn;
      case 'color':
        return BlendMode.color;
      case 'screen':
        return BlendMode.screen;
      case 'overlay':
        return BlendMode.overlay;
      case 'multiply':
        return BlendMode.multiply;
    }
    return null;
  }

  static BoxFit _resolveBoxFit(dynamic fit) {
    switch (fit) {
      case 'fill':
        return BoxFit.fill;
      case 'contain':
        return BoxFit.contain;
      case 'cover':
        return BoxFit.cover;
      case 'fitWidth':
        return BoxFit.fitWidth;
      case 'fitHeight':
        return BoxFit.fitHeight;
      case 'none':
        return BoxFit.none;
      case 'scaleDown':
        return BoxFit.scaleDown;
      default:
        return BoxFit.cover;
    }
  }

  static ImageRepeat _resolveImageRepeat(dynamic repeat) {
    switch (repeat) {
      case 'repeat':
        return ImageRepeat.repeat;
      case 'repeatX':
        return ImageRepeat.repeatX;
      case 'repeatY':
        return ImageRepeat.repeatY;
      case 'noRepeat':
      default:
        return ImageRepeat.noRepeat;
    }
  }

  /// Spec [BoxBorder] primitive: uniform side OR per-side overrides.
  static Border? _resolveBorder(
    dynamic border,
    RenderContext context,
    WidgetFactory host,
  ) {
    if (border is! Map) return null;

    // Detect uniform-side shorthand: any key from BorderSide
    // (`color`/`width`/`style`) at the top level means the whole map
    // is a single BorderSide applied to all four edges.
    final isUniform = border.containsKey('color') ||
        border.containsKey('width') ||
        border.containsKey('style');
    if (isUniform && !border.containsKey('top') &&
        !border.containsKey('bottom') &&
        !border.containsKey('left') &&
        !border.containsKey('right') &&
        !border.containsKey('all')) {
      final side = _resolveBorderSide(border, context, host);
      return Border.fromBorderSide(side);
    }

    if (border.containsKey('all')) {
      final side = _resolveBorderSide(border['all'], context, host);
      return Border.fromBorderSide(side);
    }

    return Border(
      top: _resolveBorderSide(border['top'], context, host),
      right: _resolveBorderSide(border['right'], context, host),
      bottom: _resolveBorderSide(border['bottom'], context, host),
      left: _resolveBorderSide(border['left'], context, host),
    );
  }

  static BorderSide _resolveBorderSide(
    dynamic side,
    RenderContext context,
    WidgetFactory host,
  ) {
    if (side is! Map) return BorderSide.none;
    final color = _resolveColor(side['color'], context, host) ??
        Colors.black;
    final width = (side['width'] as num?)?.toDouble() ?? 1.0;
    final style =
        side['style'] == 'none' ? BorderStyle.none : BorderStyle.solid;
    return BorderSide(color: color, width: width, style: style);
  }

  /// Spec [BorderRadius] primitive: number or per-corner object.
  /// Directional canonical (topStart / topEnd / bottomStart /
  /// bottomEnd, RTL-aware per Material 3); visual aliases
  /// (topLeft / topRight / bottomLeft / bottomRight) accepted at
  /// runtime for backward compat.
  static BorderRadius? _resolveBorderRadius(dynamic radius) {
    if (radius is num) return BorderRadius.circular(radius.toDouble());
    if (radius is Map) {
      if (radius.containsKey('all')) {
        return BorderRadius.circular((radius['all'] as num).toDouble());
      }
      final tl = (radius['topStart'] ?? radius['topLeft']) as num?;
      final tr = (radius['topEnd'] ?? radius['topRight']) as num?;
      final bl = (radius['bottomStart'] ?? radius['bottomLeft']) as num?;
      final br = (radius['bottomEnd'] ?? radius['bottomRight']) as num?;
      return BorderRadius.only(
        topLeft: Radius.circular(tl?.toDouble() ?? 0),
        topRight: Radius.circular(tr?.toDouble() ?? 0),
        bottomLeft: Radius.circular(bl?.toDouble() ?? 0),
        bottomRight: Radius.circular(br?.toDouble() ?? 0),
      );
    }
    return null;
  }

  /// Spec [BoxShadow] primitive — single object or array of objects.
  static List<BoxShadow>? _resolveBoxShadow(
    dynamic shadow,
    RenderContext context,
    WidgetFactory host,
  ) {
    BoxShadow? one(Map m) {
      final color =
          _resolveColor(m['color'], context, host) ?? Colors.black26;
      final offsetRaw = m['offset'];
      final offset = offsetRaw is Map
          ? Offset(
              (offsetRaw['dx'] as num?)?.toDouble() ?? 0.0,
              (offsetRaw['dy'] as num?)?.toDouble() ?? 0.0,
            )
          : Offset(
              (m['offsetX'] as num?)?.toDouble() ?? 0.0,
              (m['offsetY'] as num?)?.toDouble() ?? 0.0,
            );
      return BoxShadow(
        color: color,
        offset: offset,
        blurRadius:
            (m['blurRadius'] as num?)?.toDouble() ?? (m['blur'] as num?)?.toDouble() ?? 0.0,
        spreadRadius:
            (m['spreadRadius'] as num?)?.toDouble() ?? (m['spread'] as num?)?.toDouble() ?? 0.0,
      );
    }

    if (shadow is Map) {
      final s = one(shadow);
      return s != null ? [s] : null;
    }
    if (shadow is List) {
      return shadow.whereType<Map>().map(one).whereType<BoxShadow>().toList();
    }
    return null;
  }

  /// Spec [BoxDecoration.shape] enum: `rectangle` (default) or `circle`.
  static BoxShape _resolveBoxShape(dynamic shape) {
    switch (shape) {
      case 'circle':
        return BoxShape.circle;
      case 'rectangle':
      default:
        return BoxShape.rectangle;
    }
  }
}
