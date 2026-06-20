import 'package:flutter/material.dart';
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Lottie/Rive animation widgets (v1.1)
/// Renders animation playback with controls
/// Note: Actual Lottie/Rive rendering requires platform packages.
/// This provides a visual representation with playback simulation.
class LottieAnimationWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final source = context.resolve<String?>(properties['source'] ?? properties['src']);
    // Spec §2.12.4 canonical `autoPlay`; `autoplay` kept as lowercase legacy.
    final autoplay = context.resolve<bool>(
        properties['autoPlay'] ?? properties['autoplay'] ?? true);
    final loop = context.resolve<bool>(properties['loop'] ?? true);
    final width = context.resolve<double?>(properties['width']);
    final height = context.resolve<double?>(properties['height']);
    final fit = context.resolve<String>(properties['fit'] ?? 'contain');
    final speed = context.resolve<double?>(properties['speed']) ?? 1.0;
    final onComplete = properties['onComplete'] as Map<String, dynamic>?;
    // Theme-adaptive placeholder chrome — the stub widget renders its
    // own box (since the platform Lottie package isn't wired up), so
    // authors setting `backgroundColor: surface` expect it to respect
    // the active mode.
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context) ??
            context.themeManager.getColorValue('surface') ??
            Colors.grey.shade100;

    Widget animation = _LottieAnimationWidget(
      source: source,
      autoplay: autoplay,
      loop: loop,
      fit: _parseFit(fit),
      speed: speed,
      backgroundColor: backgroundColor,
      onComplete: onComplete,
      context: context,
    );

    if (width != null || height != null) {
      animation = SizedBox(
        width: width,
        height: height,
        child: animation,
      );
    }

    return applyCommonWrappers(animation, properties, context);
  }

  BoxFit _parseFit(String fit) {
    switch (fit) {
      case 'cover':
        return BoxFit.cover;
      case 'fill':
        return BoxFit.fill;
      case 'fitWidth':
        return BoxFit.fitWidth;
      case 'fitHeight':
        return BoxFit.fitHeight;
      case 'none':
        return BoxFit.none;
      case 'contain':
      default:
        return BoxFit.contain;
    }
  }
}

class _LottieAnimationWidget extends StatefulWidget {
  final String? source;
  final bool autoplay;
  final bool loop;
  final BoxFit fit;
  final double speed;
  final Color backgroundColor;
  final Map<String, dynamic>? onComplete;
  final RenderContext context;

  const _LottieAnimationWidget({
    this.source,
    required this.autoplay,
    required this.loop,
    required this.fit,
    required this.speed,
    required this.backgroundColor,
    this.onComplete,
    required this.context,
  });

  @override
  State<_LottieAnimationWidget> createState() => _LottieAnimationWidgetState();
}

class _LottieAnimationWidgetState extends State<_LottieAnimationWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (2000 / widget.speed).round()),
    );

    if (widget.autoplay) {
      if (widget.loop) {
        _controller.repeat();
      } else {
        _controller.forward().then((_) {
          if (widget.onComplete != null) {
            widget.context.actionHandler
                .execute(widget.onComplete!, widget.context);
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Placeholder animation visualization
    // Real implementation would use lottie or rive packages
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            color: widget.backgroundColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Theme.of(context).dividerColor),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Transform.rotate(
                  angle: _controller.value * 2 * 3.14159,
                  child: Icon(
                    Icons.animation,
                    size: 48,
                    color: Theme.of(context).colorScheme.primary.withValues(
                        alpha: 0.5 + _controller.value * 0.5),
                  ),
                ),
                const SizedBox(height: 8),
                if (widget.source != null)
                  Text(
                    widget.source!.split('/').last,
                    style: TextStyle(
                      fontSize: 11,
                      color: onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                LinearProgressIndicator(
                  value: _controller.value,
                  minHeight: 2,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
