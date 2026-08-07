import '../../utils/icon_resolver.dart';
import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for CircleAvatar widgets
class AvatarWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties - support both design doc keys and implementation keys
    // Design: size (diameter) → Implementation: radius
    final sizeValue = parseDimension(properties['size']);
    final radius = sizeValue != null ? sizeValue / 2 : (parseDimension(properties['radius']) ?? 20.0);
    // Spec §2.5.10 canonical `color`; §17.3.2 legacy alias `backgroundColor`.
    final backgroundColor = parseColor(context.resolve(
        properties['color'] ?? properties['backgroundColor']), context);
    final foregroundColor =
        parseColor(context.resolve(properties['foregroundColor']), context);
    // Design: src → Implementation: backgroundImage
    final backgroundImage = (properties['src'] ?? properties['backgroundImage']) as String?;
    // Design: label → Implementation: text
    final text = context.resolve<String?>(properties['label'] ?? properties['text']);
    final icon = properties['icon'];

    // Build child widget
    Widget? child;
    if (text != null && text.isNotEmpty) {
      child = Text(
        text.length > 2
            ? text.substring(0, 2).toUpperCase()
            : text.toUpperCase(),
        style: TextStyle(color: foregroundColor),
      );
    } else if (icon != null) {
      child = Icon(
        resolveIconRef(icon),
        color: foregroundColor,
        size: radius,
      );
    }

    // Build background image
    // §6.12 — one resolution path. This chain used to accept two schemes, so
    // an avatar served as a `data:` URI or from the bundle silently fell back
    // to the label.
    final backgroundImageProvider = context.resolveAssetImage(backgroundImage);

    Widget avatar = CircleAvatar(
      radius: radius,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      backgroundImage: backgroundImageProvider,
      child: child,
    );

    return applyCommonWrappers(avatar, properties, context);
  }

  // `_parseIconData` moved to `resolveIconRef` — one icon vocabulary.
}
