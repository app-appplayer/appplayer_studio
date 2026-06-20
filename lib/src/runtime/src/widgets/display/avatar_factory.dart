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
    final icon = properties['icon'] as String?;

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
        _parseIconData(icon),
        color: foregroundColor,
        size: radius,
      );
    }

    // Build background image
    ImageProvider? backgroundImageProvider;
    if (backgroundImage != null && backgroundImage.isNotEmpty) {
      if (backgroundImage.startsWith('http://') ||
          backgroundImage.startsWith('https://')) {
        backgroundImageProvider = NetworkImage(backgroundImage);
      } else if (backgroundImage.startsWith('assets/')) {
        backgroundImageProvider = AssetImage(backgroundImage);
      }
    }

    Widget avatar = CircleAvatar(
      radius: radius,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      backgroundImage: backgroundImageProvider,
      child: child,
    );

    return applyCommonWrappers(avatar, properties, context);
  }

  IconData _parseIconData(String iconName) {
    // Reuse icon mapping from icon_factory
    switch (iconName) {
      case 'person':
        return Icons.person;
      case 'group':
        return Icons.group;
      case 'account_circle':
        return Icons.account_circle;
      default:
        return Icons.person;
    }
  }
}
