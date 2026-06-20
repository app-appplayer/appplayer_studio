import 'package:flutter/material.dart';

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
    final fit = _parseBoxFit(properties['fit']);
    final alignment = _parseAlignment(properties['alignment']);
    final placeholder = properties['placeholder'] as String?;
    final errorWidget = properties['errorWidget'] as String?;
    final fallback = properties['fallback'] as Map<String, dynamic>?;
    final fallbackUrl = context.resolve<String?>(properties['fallbackUrl']);
    final fallbackBehavior =
        properties['fallbackBehavior'] as String? ?? 'placeholder';
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

    if (src.isEmpty) {
      // No source provided
      image = buildFallbackWidget(width, height);
    } else if (src.startsWith('http://') || src.startsWith('https://')) {
      // Network image
      image = Image.network(
        src,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return buildLoadingWidget(width, height);
        },
        errorBuilder: (context, error, stackTrace) {
          return buildFallbackWidget(width, height);
        },
      );
    } else if (src.startsWith('assets/')) {
      // Asset image
      image = Image.asset(
        src,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
        errorBuilder: (context, error, stackTrace) {
          return buildFallbackWidget(width, height);
        },
      );
    } else if (src.startsWith('data:image')) {
      // Base64 image (would need additional implementation)
      image = _buildPlaceholder('Base64 not supported', width, height);
    } else {
      // File path or other
      image = buildFallbackWidget(width, height);
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
