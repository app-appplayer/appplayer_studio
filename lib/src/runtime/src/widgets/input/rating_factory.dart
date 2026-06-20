import 'package:flutter/material.dart';
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
    final binding = properties['binding'] as String?;
    final dynamic rawValue = properties['value'] != null
        ? context.resolve(properties['value'])
        : (binding != null ? context.getState(binding) : null);
    final value = (rawValue as num?)?.toDouble() ?? 0.0;
    // Spec §2.6.22 canonical `max`; `maxRating` kept as legacy alias.
    final maxRating =
        ((properties['max'] ?? properties['maxRating']) as num? ?? 5).toInt();
    final iconSize = parseDimension(properties['size']) ?? 24.0;
    // Spec canonical `icon` (optional). Accepted; current painter renders
    // stars regardless of icon name (custom icons tracked separately).
    // ignore: unused_local_variable
    final iconName = properties['icon'] as String?;
    final filledColor =
        parseColor(context.resolve(properties['color']), context) ?? Colors.amber;
    // Filled star stays amber (universal convention). Empty star pulls
    // from the theme's divider slot so it reads as a dimmed outline in
    // both light and dark chrome.
    final emptyColor =
        parseColor(context.resolve(properties['emptyColor']), context) ??
            context.themeManager.getColorValue('outlineVariant') ??
            Colors.grey;
    final allowHalf = properties['allowHalf'] as bool? ?? false;
    final readOnly = properties['readOnly'] as bool? ?? false;
    Widget widget = _RatingWidget(
      value: value,
      maxRating: maxRating,
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
  final Color filledColor;
  final Color emptyColor;
  final bool allowHalf;
  final bool readOnly;
  final ValueChanged<double>? onChanged;

  const _RatingWidget({
    required this.value,
    required this.maxRating,
    required this.iconSize,
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
        IconData icon;
        Color color;

        if (value >= starValue) {
          icon = Icons.star;
          color = filledColor;
        } else if (allowHalf && value >= starValue - 0.5) {
          icon = Icons.star_half;
          color = filledColor;
        } else {
          icon = Icons.star_border;
          color = emptyColor;
        }

        final starWidget = Icon(icon, size: iconSize, color: color);

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
