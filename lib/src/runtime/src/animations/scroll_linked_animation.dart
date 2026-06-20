import 'gesture_animation.dart';

/// Scroll-linked animation controller for MCP UI DSL v1.1.
///
/// Properties interpolate between defined values as the user scrolls
/// within a target scrollable widget.
class ScrollLinkedAnimationController {
  /// ID of the scrollable widget to track
  final String scrollTarget;

  /// Start scroll offset
  final double scrollMin;

  /// End scroll offset
  final double scrollMax;

  /// Property interpolation ranges
  final Map<String, PropertyRange> properties;

  const ScrollLinkedAnimationController({
    required this.scrollTarget,
    required this.scrollMin,
    required this.scrollMax,
    required this.properties,
  });

  /// Calculate progress from scroll offset (clamped 0.0 to 1.0)
  double calculateProgress(double scrollOffset) {
    if (scrollMax == scrollMin) {
      return scrollOffset >= scrollMin ? 1.0 : 0.0;
    }
    final progress = (scrollOffset - scrollMin) / (scrollMax - scrollMin);
    return progress.clamp(0.0, 1.0);
  }

  /// Get interpolated property values for a given scroll offset
  Map<String, double> getPropertyValues(double scrollOffset) {
    final progress = calculateProgress(scrollOffset);
    final values = <String, double>{};
    for (final entry in properties.entries) {
      values[entry.key] = entry.value.interpolate(progress);
    }
    return values;
  }

  /// Create from JSON animation definition
  factory ScrollLinkedAnimationController.fromJson(Map<String, dynamic> json) {
    final range = json['scrollRange'] as Map<String, dynamic>? ?? {};
    final propsJson = json['properties'] as Map<String, dynamic>? ?? {};

    final properties = <String, PropertyRange>{};
    for (final entry in propsJson.entries) {
      if (entry.value is Map<String, dynamic>) {
        properties[entry.key] = PropertyRange.fromJson(
          entry.value as Map<String, dynamic>,
        );
      }
    }
    return ScrollLinkedAnimationController(
      scrollTarget: json['scrollTarget'] as String? ?? '',
      scrollMin: (range['min'] as num?)?.toDouble() ?? 0.0,
      scrollMax: (range['max'] as num?)?.toDouble() ?? 0.0,
      properties: properties,
    );
  }
}
