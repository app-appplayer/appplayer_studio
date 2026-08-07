import 'package:flutter/material.dart';

import '../../assets/asset_ref.dart';
import '../../assets/asset_resolver.dart';
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Image widgets
class ImageWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Canonical `src`; §17.3.2 legacy aliases `source`, `backgroundImage`.
    final src = context.resolve<String>(properties['src'] ??
        properties['source'] ??
        properties['backgroundImage'] ??
        '');
    final width = parseDimension(properties['width']);
    final height = parseDimension(properties['height']);
    final fit = _parseBoxFit(readEnum(properties['fit'], context));
    final alignment = _parseAlignment(properties['alignment']);
    final placeholder = stringOf(properties['placeholder'], context);
    final errorWidget = stringOf(properties['errorWidget'], context);
    final fallback = properties['fallback'] as Map<String, dynamic>?;
    final fallbackUrl = context.resolve<String?>(properties['fallbackUrl']);
    final fallbackBehavior =
        stringOf(properties['fallbackBehavior'], context) ?? 'placeholder';
    final loading = properties['loading'] as Map<String, dynamic>?;

    Widget image;

    // Build loading placeholder widget
    Widget buildLoadingWidget(double? w, double? h) {
      if (loading != null) {
        return context.renderer.renderWidget(loading, context);
      }
      return _buildPlaceholder(placeholder, w, h);
    }

    // Build error/fallback widget
    Widget buildFallbackWidget(double? w, double? h) {
      if (fallback != null) {
        return context.renderer.renderWidget(fallback, context);
      }
      if (fallbackUrl != null && fallbackUrl.isNotEmpty) {
        return Image.network(
          fallbackUrl,
          width: w,
          height: h,
          fit: fit,
          alignment: alignment,
          errorBuilder: (ctx, err, st) =>
              _buildErrorWidget(errorWidget, w, h),
        );
      }
      if (fallbackBehavior == 'hide') {
        return const SizedBox.shrink();
      }
      return _buildErrorWidget(errorWidget, w, h);
    }

    // §6.12: every AssetRef slot resolves through one path. The per-factory
    // scheme chain that used to live here supported only the forms a
    // synchronous loader can build, so `data:` rendered a placeholder naming
    // the runtime's limitation and `bundle://` / `client://` fell through to
    // the fallback despite being declared by the spec.
    final ref = src.isEmpty ? null : AssetRef.parse(src);

    // A vector is drawn by a picture widget, not an `ImageProvider`. Same
    // reference, same fallback contract — only the painter differs.
    if (ref != null && AssetResolver.isVector(ref)) {
      final vector = context.assetResolver.vectorWidgetFor(
        ref,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
        loadingBuilder: () => buildLoadingWidget(width, height),
      );
      if (vector != null) {
        return applyCommonWrappers(vector, properties, context);
      }
    }

    final provider =
        ref == null ? null : context.assetResolver.imageProviderFor(ref);

    if (provider == null) {
      // Unsupported scheme, malformed reference, or no source: take the
      // declared fallback (§6.12.4) rather than rendering an implementation
      // detail where the author asked for a picture.
      image = buildFallbackWidget(width, height);
    } else {
      image = Image(
        image: provider,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          // A pending read is not a failure (§6.12.5) — show the loading
          // state, not the fallback.
          if (wasSynchronouslyLoaded || frame != null) return child;
          return buildLoadingWidget(width, height);
        },
        errorBuilder: (context, error, stackTrace) {
          return buildFallbackWidget(width, height);
        },
      );
    }

    return applyCommonWrappers(image, properties, context);
  }

  Widget _buildPlaceholder(String? text, double? width, double? height) {
    return Builder(builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return Container(
        width: width,
        height: height,
        color: cs.surfaceContainerHighest,
        child: Center(
          child: text != null
              ? Text(text,
                  style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)))
              : Icon(Icons.image,
                  color: cs.onSurface.withValues(alpha: 0.6)),
        ),
      );
    });
  }

  Widget _buildErrorWidget(String? text, double? width, double? height) {
    return Builder(builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return Container(
        width: width,
        height: height,
        color: cs.errorContainer,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error, color: cs.error),
              if (text != null)
                Text(text,
                    style: TextStyle(color: cs.onErrorContainer, fontSize: 12)),
            ],
          ),
        ),
      );
    });
  }

  BoxFit _parseBoxFit(String? value) {
    switch (value) {
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
        return BoxFit.contain;
    }
  }

  AlignmentGeometry _parseAlignment(String? value) {
    switch (value) {
      case 'topLeft':
        return Alignment.topLeft;
      case 'topCenter':
        return Alignment.topCenter;
      case 'topRight':
        return Alignment.topRight;
      case 'centerLeft':
        return Alignment.centerLeft;
      case 'center':
        return Alignment.center;
      case 'centerRight':
        return Alignment.centerRight;
      case 'bottomLeft':
        return Alignment.bottomLeft;
      case 'bottomCenter':
        return Alignment.bottomCenter;
      case 'bottomRight':
        return Alignment.bottomRight;
      default:
        return Alignment.center;
    }
  }
}
