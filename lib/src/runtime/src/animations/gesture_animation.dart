/// Gesture-driven animation controller for MCP UI DSL v1.1.
///
/// Provides interactive animations where gesture position drives animation
/// progress. Supports horizontal and vertical drag gestures with property
/// interpolation and completion thresholds.
class PropertyRange {
  final double from;
  final double to;

  const PropertyRange({required this.from, required this.to});

  /// Interpolate value at given progress (0.0 to 1.0)
  double interpolate(double progress) {
    return from + (to - from) * progress;
  }

  factory PropertyRange.fromJson(Map<String, dynamic> json) {
    return PropertyRange(
      from: (json['from'] as num).toDouble(),
      to: (json['to'] as num).toDouble(),
    );
  }
}

class GestureAnimationController {
  /// Gesture type: "horizontalDrag" or "verticalDrag"
  final String gesture;

  /// Minimum gesture range value
  final double rangeMin;

  /// Maximum gesture range value
  final double rangeMax;

  /// Property interpolation ranges
  final Map<String, PropertyRange> properties;

  /// Action to execute on completion (when drag passes threshold)
  final Map<String, dynamic>? onComplete;

  /// Completion threshold (0.0 to 1.0, default 0.5)
  final double threshold;

  const GestureAnimationController({
    this.gesture = 'horizontalDrag',
    required this.rangeMin,
    required this.rangeMax,
    required this.properties,
    this.onComplete,
    this.threshold = 0.5,
  });

  /// Calculate animation progress from gesture offset (clamped 0.0 to 1.0)
  double calculateProgress(double offset) {
    if (rangeMax == rangeMin) return offset >= rangeMin ? 1.0 : 0.0;
    final progress = (offset - rangeMin) / (rangeMax - rangeMin);
    return progress.clamp(0.0, 1.0);
  }

  /// Get interpolated property values for a given progress
  Map<String, double> getPropertyValues(double progress) {
    final values = <String, double>{};
    for (final entry in properties.entries) {
      values[entry.key] = entry.value.interpolate(progress);
    }
    return values;
  }

  /// Check if drag has passed the completion threshold
  bool isComplete(double progress) => progress >= threshold;

  /// Create from JSON animation definition
  factory GestureAnimationController.fromJson(Map<String, dynamic> json) {
    final range = json['range'] as Map<String, dynamic>? ?? {};
    final propsJson = json['properties'] as Map<String, dynamic>? ?? {};
    final properties = <String, PropertyRange>{};
    for (final entry in propsJson.entries) {
      if (entry.value is Map<String, dynamic>) {
        properties[entry.key] = PropertyRange.fromJson(
          entry.value as Map<String, dynamic>,
        );
      }
    }
    return GestureAnimationController(
      gesture: json['gesture'] as String? ?? 'horizontalDrag',
      rangeMin: (range['min'] as num?)?.toDouble() ?? 0.0,
      rangeMax: (range['max'] as num?)?.toDouble() ?? 0.0,
      properties: properties,
      onComplete: json['onComplete'] as Map<String, dynamic>?,
      threshold: (json['threshold'] as num?)?.toDouble() ?? 0.5,
    );
  }
}
