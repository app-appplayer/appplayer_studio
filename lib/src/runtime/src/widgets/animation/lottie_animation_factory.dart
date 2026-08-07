import 'package:flutter/material.dart';

import '../../capabilities/runtime_capabilities.dart';
import '../../renderer/render_context.dart';
import '../capability_absent.dart';
import '../widget_factory.dart';

/// `lottieAnimation`.
///
/// Vector animation is a platform power (6.13); the host supplies the surface.
/// What used to be here drew theme-adaptive chrome and a fake progress
/// visualisation - an animation that never animated anything.
class LottieAnimationWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final surface = context.capabilities.lottieBuilder;
    if (surface != null) {
      return applyCommonWrappers(
        Builder(
          builder: (ctx) =>
              surface(
                ctx,
                properties,
                surfaceEventsFor(properties, context),
                surfaceAssetsFor(context),
              ) ??
              const SizedBox.shrink(),
        ),
        properties,
        context,
      );
    }

    return CapabilityAbsent(
      capability: RuntimeCapability.lottie,
      onError: actionOf(properties['onError'], context),
      renderContext: context,
    );
  }
}
