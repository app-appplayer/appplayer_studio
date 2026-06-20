import 'package:flutter/services.dart';
import '../utils/mcp_logger.dart';

/// Manages orientation locking/unlocking for the application.
class OrientationManager {
  static final MCPLogger _logger = MCPLogger('OrientationManager');
  static String? _currentLock;

  /// Lock orientation to portrait mode
  static Future<void> lockPortrait() async {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    _currentLock = 'portrait';
    _logger.debug('Orientation locked to portrait');
  }

  /// Lock orientation to landscape mode
  static Future<void> lockLandscape() async {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _currentLock = 'landscape';
    _logger.debug('Orientation locked to landscape');
  }

  /// Lock to a specific mode string ('portrait' or 'landscape')
  static Future<void> lock(String mode) async {
    if (mode == 'portrait') {
      await lockPortrait();
    } else if (mode == 'landscape') {
      await lockLandscape();
    } else {
      _logger.warning('Unknown orientation lock mode: $mode');
    }
  }

  /// Unlock orientation (allow all orientations)
  static Future<void> unlock() async {
    await SystemChrome.setPreferredOrientations([]);
    _currentLock = null;
    _logger.debug('Orientation unlocked');
  }

  /// Get current lock state (null = unlocked)
  static String? get currentLock => _currentLock;

  /// Check if orientation is locked
  static bool get isLocked => _currentLock != null;

  /// Reset state (for testing)
  static void reset() {
    _currentLock = null;
  }
}
