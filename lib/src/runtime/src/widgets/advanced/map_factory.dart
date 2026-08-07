import 'package:flutter/material.dart';

import '../../capabilities/runtime_capabilities.dart';
import '../../renderer/render_context.dart';
import '../capability_absent.dart';
import '../widget_factory.dart';

/// Map marker data (kept: hosts and tests read this shape).
class MapMarker {
  MapMarker({
    required this.latitude,
    required this.longitude,
    required this.title,
    this.icon,
    this.color,
  });

  final double latitude;
  final double longitude;
  final String title;
  final String? icon;
  final String? color;
}

/// `map` (spec 10.5).
///
/// Tiles come from a host-provided surface (6.13). This factory used to paint a
/// schematic - a pale-green rectangle with dots where markers belonged - which
/// satisfied "parse and render" while showing a place that does not exist. With
/// no surface wired the capability is reported absent instead.
class MapWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final surface = context.capabilities.mapBuilder;
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
      capability: RuntimeCapability.map,
      onError: actionOf(properties['onError'], context),
      renderContext: context,
    );
  }
}
