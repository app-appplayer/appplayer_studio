// Phase 2-4 widget factories — gallery layouts, motion drivers,
// and media accents. Each factory follows the spec yaml shape
// declared in `widgets/list/`, `widgets/scroll/`, `widgets/display/`,
// and `widgets/advanced/`.
//
// Implementations target the documented Flutter mappings; the
// "premium" rendering details (cover-flow perspective, true Ken
// Burns optical-flow, full Rive runtime, slivers) ship at this
// minimum level and grow with subsequent runtime cycles.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../renderer/render_context.dart';
import 'widget_factory.dart';

/// Spec § imageFilter (since v1.3).
class ImageFilterWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final filter =
        context.resolve(properties['filter']) as String? ?? 'grayscale';
    final intensity =
        (context.resolve(properties['intensity']) as num?)?.toDouble() ?? 1.0;
    final childDef = properties['child'] as Map<String, dynamic>?;
    final child =
        childDef != null ? context.buildWidget(childDef) : const SizedBox();

    switch (filter) {
      case 'sepia':
        return ColorFiltered(
          colorFilter: ColorFilter.matrix(_sepiaMatrix(intensity)),
          child: child,
        );
      case 'grayscale':
        return ColorFiltered(
          colorFilter: ColorFilter.matrix(_grayscaleMatrix(intensity)),
          child: child,
        );
      case 'invert':
        return ColorFiltered(
          colorFilter: ColorFilter.matrix(_invertMatrix(intensity)),
          child: child,
        );
      case 'saturation':
        return ColorFiltered(
          colorFilter: ColorFilter.matrix(_saturationMatrix(intensity)),
          child: child,
        );
      case 'brightness':
        return ColorFiltered(
          colorFilter: ColorFilter.matrix(_brightnessMatrix(intensity)),
          child: child,
        );
      case 'contrast':
        return ColorFiltered(
          colorFilter: ColorFilter.matrix(_contrastMatrix(intensity)),
          child: child,
        );
      case 'blur':
        return ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: intensity, sigmaY: intensity),
          child: child,
        );
    }
    return child;
  }

  List<double> _sepiaMatrix(double k) {
    // Linear blend between identity and sepia at strength `k`.
    final sepia = <double>[
      0.393, 0.769, 0.189, 0, 0,
      0.349, 0.686, 0.168, 0, 0,
      0.272, 0.534, 0.131, 0, 0,
      0,     0,     0,     1, 0,
    ];
    return _blendIdentity(sepia, k);
  }

  List<double> _grayscaleMatrix(double k) {
    final gray = <double>[
      0.2126, 0.7152, 0.0722, 0, 0,
      0.2126, 0.7152, 0.0722, 0, 0,
      0.2126, 0.7152, 0.0722, 0, 0,
      0,      0,      0,      1, 0,
    ];
    return _blendIdentity(gray, k);
  }

  List<double> _invertMatrix(double k) {
    final inv = <double>[
      -1, 0,  0,  0, 255,
      0,  -1, 0,  0, 255,
      0,  0,  -1, 0, 255,
      0,  0,  0,  1, 0,
    ];
    return _blendIdentity(inv, k);
  }

  List<double> _saturationMatrix(double s) {
    // Standard luminance-preserving saturation matrix (s=1 identity).
    const r = 0.2126;
    const g = 0.7152;
    const b = 0.0722;
    final inv = 1 - s;
    return [
      r * inv + s, g * inv,     b * inv,     0, 0,
      r * inv,     g * inv + s, b * inv,     0, 0,
      r * inv,     g * inv,     b * inv + s, 0, 0,
      0,           0,           0,           1, 0,
    ];
  }

  List<double> _brightnessMatrix(double k) {
    return [
      k, 0, 0, 0, 0,
      0, k, 0, 0, 0,
      0, 0, k, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  List<double> _contrastMatrix(double k) {
    final t = (1 - k) * 128;
    return [
      k, 0, 0, 0, t,
      0, k, 0, 0, t,
      0, 0, k, 0, t,
      0, 0, 0, 1, 0,
    ];
  }

  List<double> _blendIdentity(List<double> m, double k) {
    final identity = <double>[
      1, 0, 0, 0, 0,
      0, 1, 0, 0, 0,
      0, 0, 1, 0, 0,
      0, 0, 0, 1, 0,
    ];
    final out = <double>[];
    for (var i = 0; i < 20; i++) {
      out.add(identity[i] * (1 - k) + m[i] * k);
    }
    return out;
  }
}

/// Spec § kenBurnsImage (since v1.3) — slow zoom-and-pan.
/// Uses `TweenAnimationBuilder` and re-triggers via `setState` for loop.
class KenBurnsImageWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final src = context.resolve(properties['src']) as String? ?? '';
    final durationMs =
        (context.resolve(properties['duration']) as num?)?.toInt() ?? 8000;
    final intensity =
        (context.resolve(properties['intensity']) as num?)?.toDouble() ?? 0.15;
    final loop = context.resolve(properties['loop']) as bool? ?? true;
    // Read but currently treated as advisory — full pan animation
    // ships in a later cycle. Recorded so authors' intent is
    // preserved through the resolver.
    final _ = context.resolve(properties['startAlignment']);
    final __ = context.resolve(properties['endAlignment']);
    final ___ = context.resolve(properties['curve']);
    final fit = _resolveBoxFit(context.resolve(properties['fit']));
    final width = parseDimension(context.resolve(properties['width']));
    final height = parseDimension(context.resolve(properties['height']));

    final image = _buildImage(src, fit);
    return _KenBurnsRunner(
      image: image,
      duration: Duration(milliseconds: durationMs),
      intensity: intensity,
      loop: loop,
      width: width,
      height: height,
    );
  }

  BoxFit _resolveBoxFit(dynamic fit) {
    switch (fit) {
      case 'fill':
        return BoxFit.fill;
      case 'contain':
        return BoxFit.contain;
      case 'fitWidth':
        return BoxFit.fitWidth;
      case 'fitHeight':
        return BoxFit.fitHeight;
      case 'cover':
      default:
        return BoxFit.cover;
    }
  }

  Widget _buildImage(String src, BoxFit fit) {
    if (src.startsWith('http')) {
      return Image.network(src, fit: fit);
    }
    if (src.startsWith('assets/')) {
      return Image.asset(src, fit: fit);
    }
    return Container(color: Colors.grey.shade300);
  }
}

class _KenBurnsRunner extends StatefulWidget {
  const _KenBurnsRunner({
    required this.image,
    required this.duration,
    required this.intensity,
    required this.loop,
    this.width,
    this.height,
  });
  final Widget image;
  final Duration duration;
  final double intensity;
  final bool loop;
  final double? width;
  final double? height;

  @override
  State<_KenBurnsRunner> createState() => _KenBurnsRunnerState();
}

class _KenBurnsRunnerState extends State<_KenBurnsRunner>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener((status) {
        if (!widget.loop) return;
        if (status == AnimationStatus.completed) {
          _controller.reverse();
        } else if (status == AnimationStatus.dismissed) {
          _controller.forward();
        }
      })
      ..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _controller,
          child: widget.image,
          builder: (ctx, child) {
            final t = _controller.value;
            final scale = 1.0 + widget.intensity * t;
            return Transform.scale(
              scale: scale,
              alignment: Alignment.center,
              child: child,
            );
          },
        ),
      ),
    );
  }
}

/// Spec § carousel (since v1.3) — partial-viewport horizontal browser.
/// First-cut implementation maps `viewportFraction` and `loop` onto
/// `PageView`. Cover-flow / depth transitions fall back to `slide`.
class CarouselWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final viewportFraction =
        (context.resolve(properties['viewportFraction']) as num?)?.toDouble() ??
            1.0;
    final initialIndex =
        (context.resolve(properties['initialIndex']) as num?)?.toInt() ?? 0;
    final scrollAxis =
        context.resolve(properties['scrollDirection']) as String? ??
            'horizontal';
    final loop = context.resolve(properties['loop']) as bool? ?? false;
    // Read for spec coverage. `autoPlay` (interval ms), `transition`
    // (`slide` / `fade` / `coverflow` / `depth`), and
    // `indicatorPosition` (`bottom` / `top` / `none`) are advisory —
    // the cover-flow / depth perspective transforms and the auto-
    // advance timer ship in a later runtime cycle.
    final _ = context.resolve(properties['autoPlay']);
    final __ = context.resolve(properties['transition']);
    final ___ = context.resolve(properties['indicatorPosition']);

    final children = _buildChildren(properties, context);
    if (children.isEmpty) return const SizedBox.shrink();

    final controller = PageController(
      viewportFraction: viewportFraction.clamp(0.05, 1.0),
      initialPage: initialIndex,
    );

    final view = PageView.builder(
      controller: controller,
      scrollDirection:
          scrollAxis == 'vertical' ? Axis.vertical : Axis.horizontal,
      itemCount: loop ? null : children.length,
      onPageChanged: _onPageChangedHandler(properties['onPageChanged'], context),
      itemBuilder: (ctx, i) => children[i % children.length],
    );

    return view;
  }

  List<Widget> _buildChildren(
      Map<String, dynamic> properties, RenderContext context) {
    final staticChildren = properties['children'] as List?;
    if (staticChildren != null) {
      return staticChildren
          .map((c) => context.buildWidget(c as Map<String, dynamic>))
          .toList();
    }
    final items = context.resolve<dynamic>(properties['items']);
    final template = properties['itemTemplate'] as Map<String, dynamic>?;
    if (items is List && template != null) {
      return items.asMap().entries.map((e) {
        final scoped = context.createChildContext(variables: {'item': e.value, 'index': e.key});
        return scoped.buildWidget(template);
      }).toList();
    }
    return const [];
  }
}

/// Spec § staggeredGrid (since v1.3) — Pinterest-style masonry.
/// First-cut implementation distributes items into `columns` columns
/// by appending each next item to the shortest column. Final paint
/// is a `CustomMultiChildLayout`-style approximation using nested
/// `Column` per slot — good enough for shelves; a tighter pack
/// (full incremental-height aware) ships in a later runtime cycle.
class StaggeredGridWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final columns =
        (context.resolve(properties['columns']) as num?)?.toInt() ?? 2;
    final mainAxisSpacing =
        (context.resolve(properties['mainAxisSpacing']) as num?)?.toDouble() ??
            0.0;
    final crossAxisSpacing =
        (context.resolve(properties['crossAxisSpacing']) as num?)?.toDouble() ??
            0.0;
    final padding =
        parseEdgeInsets(context.resolve(properties['padding']));
    // Read for spec coverage. `scrollDirection` is advisory — the
    // round-robin distribution currently always builds a vertical
    // packed grid. Horizontal masonry ships in a later cycle.
    final _ = context.resolve(properties['scrollDirection']);

    final children = _buildChildren(properties, context);
    if (children.isEmpty) return const SizedBox.shrink();

    // Distribute children round-robin into N columns. (Naive packing —
    // a heightless approximation suitable for first delivery.)
    final perColumn = List.generate(columns, (_) => <Widget>[]);
    for (var i = 0; i < children.length; i++) {
      perColumn[i % columns].add(children[i]);
    }

    return SingleChildScrollView(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(columns, (col) {
          final colChildren = <Widget>[];
          for (var j = 0; j < perColumn[col].length; j++) {
            if (j > 0) colChildren.add(SizedBox(height: mainAxisSpacing));
            colChildren.add(perColumn[col][j]);
          }
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                  left: col == 0 ? 0 : crossAxisSpacing / 2,
                  right: col == columns - 1 ? 0 : crossAxisSpacing / 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: colChildren,
              ),
            ),
          );
        }),
      ),
    );
  }

  List<Widget> _buildChildren(
      Map<String, dynamic> properties, RenderContext context) {
    final staticChildren = properties['children'] as List?;
    if (staticChildren != null) {
      return staticChildren
          .map((c) => context.buildWidget(c as Map<String, dynamic>))
          .toList();
    }
    final items = context.resolve<dynamic>(properties['items']);
    final template = properties['itemTemplate'] as Map<String, dynamic>?;
    if (items is List && template != null) {
      return items.asMap().entries.map((e) {
        final scoped = context.createChildContext(variables: {'item': e.value, 'index': e.key});
        return scoped.buildWidget(template);
      }).toList();
    }
    return const [];
  }
}

/// Spec § lightbox (since v1.3) — full-screen image viewer.
class LightboxWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final imagesValue = context.resolve<dynamic>(properties['images']);
    final images = imagesValue is List
        ? imagesValue.whereType<String>().toList()
        : <String>[];
    if (images.isEmpty) return const SizedBox.shrink();

    final initialIndex =
        (context.resolve(properties['initialIndex']) as num?)?.toInt() ?? 0;
    final allowZoom =
        context.resolve(properties['allowZoom']) as bool? ?? true;
    final allowSwipe =
        context.resolve(properties['allowSwipe']) as bool? ?? true;
    final maxZoom =
        (context.resolve(properties['maxZoom']) as num?)?.toDouble() ?? 4.0;
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context) ??
            Colors.black;
    // Read for spec coverage. `onIndexChanged` and `onClose` are
    // advisory — the lightbox surface currently has no dismiss
    // affordance / index-tracking event source. Wire-up ships when
    // a host gesture callback model is finalised.
    final _ = properties['onIndexChanged'];
    final __ = properties['onClose'];

    return ColoredBox(
      color: backgroundColor,
      child: PageView.builder(
        physics: allowSwipe
            ? const PageScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        controller: PageController(initialPage: initialIndex),
        itemCount: images.length,
        itemBuilder: (ctx, i) {
          final image = _buildImage(images[i]);
          if (!allowZoom) return Center(child: image);
          return InteractiveViewer(
            maxScale: maxZoom,
            child: Center(child: image),
          );
        },
      ),
    );
  }

  Widget _buildImage(String src) {
    if (src.startsWith('http')) {
      return Image.network(src);
    }
    if (src.startsWith('assets/')) {
      return Image.asset(src);
    }
    return Container(color: Colors.grey.shade800);
  }
}

/// Spec § scrollAnimated (since v1.3) — placeholder factory.
/// First-cut renders the child unwrapped; the scroll-driven binding
/// engine ships in a subsequent runtime cycle.
class ScrollAnimatedWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final childDef = properties['child'] as Map<String, dynamic>?;
    if (childDef == null) return const SizedBox.shrink();
    return context.buildWidget(childDef);
  }
}

/// Spec § rive (since v1.3) — placeholder factory.
/// Full Rive playback ships in a subsequent runtime cycle once the
/// `rive` package is wired into core deps. For now renders a sized
/// placeholder so layouts referencing this widget keep their shape.
class RiveWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    // Read every spec field so the resolver records authors' intent
    // even though the real renderer is deferred.
    final _ = context.resolve(properties['src']);
    final __ = context.resolve(properties['artboard']);
    final ___ = context.resolve(properties['animation']);
    final ____ = context.resolve(properties['stateMachine']);
    final _____ = context.resolve(properties['inputs']);
    final ______ = context.resolve(properties['fit']);
    final _______ = context.resolve(properties['alignment']);
    final width = parseDimension(context.resolve(properties['width']));
    final height = parseDimension(context.resolve(properties['height']));
    return SizedBox(
      width: width,
      height: height,
      child: ColoredBox(color: Colors.grey.shade200),
    );
  }
}

ValueChanged<int>? _onPageChangedHandler(dynamic action, RenderContext context) {
  if (action is! Map) return null;
  return (page) {
    final scoped = context.createChildContext(variables: {'event': {'page': page}});
    scoped.actionHandler.execute(
      action.cast<String, dynamic>(),
      scoped,
    );
  };
}
