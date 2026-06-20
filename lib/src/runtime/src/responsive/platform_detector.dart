import 'package:flutter/foundation.dart';

/// Platform type classification
enum PlatformType { mobile, tablet, desktop, web }

/// Detects the current platform type based on screen dimensions and input mode.
/// Caches the result for the application lifetime.
class PlatformDetector {
  static PlatformType? _cached;

  /// Detect platform type from screen width and touch capability.
  /// Results are cached after first detection.
  static PlatformType detect(double width, {bool hasTouch = true}) {
    if (_cached != null) return _cached!;
    _cached = _classify(width, hasTouch: hasTouch);
    return _cached!;
  }

  /// Classify without caching (for testing)
  static PlatformType classify(double width, {bool hasTouch = true}) {
    return _classify(width, hasTouch: hasTouch);
  }

  static PlatformType _classify(double width, {bool hasTouch = true}) {
    if (kIsWeb) return PlatformType.web;
    if (width < 600) return PlatformType.mobile;
    if (width < 1024 && hasTouch) return PlatformType.tablet;
    return PlatformType.desktop;
  }

  /// Get cached platform type (null if not yet detected)
  static PlatformType? get cached => _cached;

  /// Reset cache (for testing)
  static void resetCache() => _cached = null;
}
