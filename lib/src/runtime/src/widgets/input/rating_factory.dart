import 'package:flutter/material.dart';
import '../../utils/icon_resolver.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for creating rating (star) input widgets.
///
/// Properties:
/// - `value`: Current rating value (double)
/// - `maxRating`: Maximum rating (default 5)
/// - `icon`: Icon name for filled state (default 'star')
/// - `emptyIcon`: Icon name for empty state (default 'star_border')
/// - `color`: Icon color for filled state
/// - `emptyColor`: Icon color for empty state
/// - `size`: Icon size in logical pixels
/// - `allowHalf`: Whether half-star ratings are allowed
/// - `readOnly`: Whether the rating is read-only
/// - `change`: Action binding path for value changes
class RatingFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Spec §2.6.0: binding shorthand — read from state path when no
    // explicit `value` is provided.
    final binding = stringOf(properties['binding'], context);
    final dynamic rawValue = properties['value'] != null
        ? context.resolve(properties['value'])
        : (binding != null ? context.getState(binding) : null);
    final value = (rawValue as num?)?.toDouble() ?? 0.0;
    // Spec §2.6.22 canonical `max`; `maxRating` kept as legacy alias.
    final maxRating =
        ((properties['max'] ?? properties['maxRating']) as num? ?? 5).toInt();
    final iconSize = parseDimension(properties['size']) ?? 24.0;
    // Spec canonical `icon` (optional). It was resolved and then dropped —
    // a rating declaring hearts drew stars, and said nothing.
    final iconName = properties['icon'] == null
        ? null
        : resolveIconRef(context.resolve<Object?>(properties['icon']));
    final filledColor =
        parseColor(context.resolve(properties['color']), context) ?? Colors.amber;
    // Filled star stays amber (universal convention). Empty star pulls
    // from the theme's divider slot so it reads as a dimmed outline in
    // both light and dark chrome.
    final emptyColor =
        parseColor(context.resolve(properties['emptyColor']), context) ??
            context.themeManager.getColorValue('outlineVariant') ??
            Colors.grey;
    final allowHalf = boolOf(properties['allowHalf'], context) ?? false;
    final readOnly = boolOf(properties['readOnly'], context) ?? false;
    Widget widget = _RatingWidget(
      value: value,
      maxRating: maxRating,
      icon: iconName,
      iconSize: iconSize,
      filledColor: filledColor,
      emptyColor: emptyColor,
      allowHalf: allowHalf,
      readOnly: readOnly,
      onChanged: readOnly
          ? null
          : (newValue) {
              if (binding != null) {
                context.stateManager.set(binding, newValue);
              }
              final changeAction = properties['onChange'] ?? properties['change'];
              if (changeAction is Map<String, dynamic>) {
                context.actionHandler.execute(changeAction, context);
              }
            },
    );

    return applyCommonWrappers(widget, properties, context);
  }
}

class _RatingWidget extends StatelessWidget {
  final double value;
  final int maxRating;
  final double iconSize;

  /// The glyph the document asked for. Null keeps the star, which is what a
  /// rating means when nobody says otherwise.
  final IconData? icon;
  final Color filledColor;
  final Color emptyColor;
  final bool allowHalf;
  final bool readOnly;
  final ValueChanged<double>? onChanged;

  const _RatingWidget({
    required this.value,
    required this.maxRating,
    required this.iconSize,
    this.icon,
    required this.filledColor,
    required this.emptyColor,
    required this.allowHalf,
    required this.readOnly,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(maxRating, (index) {
        final starValue = index + 1.0;
        IconData glyph;
        Color color;

        // A named icon has no half or outline variant to fall back on, so it
        // carries the state in its colour — filled or dimmed — which is how
        // every heart rating in the world reads.
        if (value >= starValue) {
          glyph = icon ?? Icons.star;
          color = filledColor;
        } else if (allowHalf && value >= starValue - 0.5) {
          glyph = icon ?? Icons.star_half;
          color = filledColor;
        } else {
          glyph = icon ?? Icons.star_border;
          color = emptyColor;
        }

        final starWidget = Icon(glyph, size: iconSize, color: color);

        if (readOnly || onChanged == null) {
          return starWidget;
        }

        return GestureDetector(
          onTapDown: (details) {
            if (allowHalf) {
              final halfWidth = iconSize / 2;
              final isLeftHalf = details.localPosition.dx < halfWidth;
              onChanged!(isLeftHalf ? starValue - 0.5 : starValue);
            } else {
              onChanged!(starValue);
            }
          },
          child: starWidget,
        );
      }),
    );
  }
}
