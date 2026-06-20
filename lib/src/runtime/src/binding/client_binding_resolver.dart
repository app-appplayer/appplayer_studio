/// Client binding resolver for MCP UI DSL v1.1
///
/// Resolves {{client.*}} bindings to client-side values.
library client_binding_resolver;

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'package:flutter/material.dart' show ThemeData;

/// Resolves client-side binding expressions
class ClientBindingResolver {
  /// Host environment ThemeData for resolving host theme color bindings.
  /// This is the theme from the embedding app — everything outside the
  /// MCP UI runtime. Distinct from the DSL-level theme (`theme.colors.*`).
  ThemeData? _hostThemeData;

  /// Set the host environment theme for resolving `client.theme.*` color
  /// bindings. Called from the widget tree before the runtime's own
  /// MaterialApp is created.
  void setHostTheme(ThemeData themeData) {
    _hostThemeData = themeData;
  }

  /// Whether `system.info` permission is granted.
  /// When false, `client.env.*` bindings return null.
  /// Set by the runtime engine based on PermissionsConfig.systemInfo.
  bool _systemInfoGranted = false;

  /// Update the system.info permission state for env binding access control
  void setSystemInfoPermission(bool granted) {
    _systemInfoGranted = granted;
  }

  /// Cached values to avoid repeated system calls
  final Map<String, dynamic> _cache = {};

  /// Whether caching is enabled
  bool cacheEnabled = true;

  /// Cache duration in seconds
  int cacheDurationSeconds = 60;

  /// Last cache update time
  DateTime? _lastCacheUpdate;

  /// Check if a binding expression is a client binding
  bool isClientBinding(String expression) {
    return expression.startsWith('{{client.') && expression.endsWith('}}');
  }

  /// Extract the client binding path from an expression
  String? extractPath(String expression) {
    if (!isClientBinding(expression)) return null;
    return expression.substring(9, expression.length - 2);
  }

  /// Resolve a client binding expression
  dynamic resolve(String expression) {
    final path = extractPath(expression);
    if (path == null) return null;

    // Check cache
    if (cacheEnabled && _isCacheValid()) {
      if (_cache.containsKey(path)) {
        return _cache[path];
      }
    }

    // Resolve the value
    final value = _resolveValue(path);

    // Cache the result
    if (cacheEnabled) {
      _cache[path] = value;
      _lastCacheUpdate = DateTime.now();
    }

    return value;
  }

  /// Resolve a value by path
  dynamic _resolveValue(String path) {
    switch (path) {
      case 'workingDirectory':
        return _getWorkingDirectory();

      case 'userName':
        return _getUserName();

      case 'platform':
        return _getPlatformCategory();

      case 'locale':
        return _getLocale();

      case 'theme':
        return _getTheme();

      case 'theme.mode':
        return _getTheme();

      case 'theme.background':
        return _getThemeColor('background');

      case 'theme.primary':
        return _getThemeColor('primary');

      case 'theme.secondary':
        return _getThemeColor('secondary');

      case 'theme.surface':
        return _getThemeColor('surface');

      case 'theme.error':
        return _getThemeColor('error');

      case 'theme.textOnPrimary':
        return _getThemeColor('textOnPrimary');

      case 'theme.textOnSecondary':
        return _getThemeColor('textOnSecondary');

      case 'theme.textOnBackground':
        return _getThemeColor('textOnBackground');

      case 'theme.textOnSurface':
        return _getThemeColor('textOnSurface');

      case 'theme.textOnError':
        return _getThemeColor('textOnError');

      case 'theme.foreground':
        return _getThemeColor('foreground');

      case 'platform.category':
        return _getPlatformCategory();

      case 'orientation':
        return _getOrientation();

      case 'isWeb':
        return kIsWeb;

      case 'isDebug':
        return kDebugMode;

      case 'isRelease':
        return kReleaseMode;

      case 'isProfile':
        return kProfileMode;

      // Network bindings (per spec: client.network.status, client.network.type)
      case 'network.status':
        return _getNetworkStatus();

      case 'network.type':
        return _getNetworkType();

      // File bindings (per spec: client.file.*)
      case 'file.separator':
        return _getFileSeparator();

      // Raw OS name binding (per spec: client.platform.os)
      case 'platform.os':
        return _getPlatformOS();

      // System bindings (per spec: client.system.*)
      case 'system.os':
        return _getPlatformOS();

      case 'system.version':
        return _getOSVersion();

      default:
        // Handle nested paths like client.env.HOME
        if (path.startsWith('env.')) {
          return _getEnvVariable(path.substring(4));
        }
        return null;
    }
  }

  /// Get the current working directory
  String? _getWorkingDirectory() {
    if (kIsWeb) return null;
    try {
      return Directory.current.path;
    } catch (_) {
      return null;
    }
  }

  /// Get the current user name
  String? _getUserName() {
    if (kIsWeb) return null;
    try {
      return Platform.environment['USER'] ??
          Platform.environment['USERNAME'] ??
          Platform.environment['LOGNAME'];
    } catch (_) {
      return null;
    }
  }

  /// Get the raw OS platform name
  String _getPlatformOS() {
    if (kIsWeb) return 'web';

    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isFuchsia) return 'fuchsia';

    return 'unknown';
  }

  /// Get the system locale
  String _getLocale() {
    try {
      final locale = PlatformDispatcher.instance.locale;
      return locale.toString();
    } catch (_) {
      return 'en_US';
    }
  }

  /// Get the system theme (light/dark)
  String _getTheme() {
    try {
      final brightness =
          SchedulerBinding.instance.platformDispatcher.platformBrightness;
      return brightness == Brightness.dark ? 'dark' : 'light';
    } catch (_) {
      return 'light';
    }
  }

  /// Get a host environment theme color by key (e.g., 'primary', 'background').
  /// Reads from the embedding app's ThemeData.colorScheme — NOT from the DSL
  /// ThemeManager. Returns a hex color string, or null if host theme unavailable.
  String? _getThemeColor(String colorKey) {
    if (_hostThemeData == null) return null;
    final cs = _hostThemeData!.colorScheme;
    final color = switch (colorKey) {
      'background' => cs.surface,
      'foreground' => cs.onSurface,
      'primary' => cs.primary,
      'secondary' => cs.secondary,
      'surface' => cs.surface,
      'error' => cs.error,
      'textOnPrimary' => cs.onPrimary,
      'textOnSecondary' => cs.onSecondary,
      'textOnBackground' => cs.onSurface,
      'textOnSurface' => cs.onSurface,
      'textOnError' => cs.onError,
      _ => null,
    };
    if (color == null) return null;
    // Convert Color to hex string (#RRGGBB)
    final r = (color.r * 255).round();
    final g = (color.g * 255).round();
    final b = (color.b * 255).round();
    return '#${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}';
  }

  /// Get the network connectivity status
  String _getNetworkStatus() {
    // Basic implementation - returns 'online' by default
    // A full implementation would use connectivity_plus package
    return 'online';
  }

  /// Get the network connection type
  String _getNetworkType() {
    // Basic implementation - returns 'unknown' by default
    // A full implementation would use connectivity_plus package
    return 'unknown';
  }

  /// Get the platform file separator
  String _getFileSeparator() {
    if (kIsWeb) return '/';
    return Platform.pathSeparator;
  }

  /// Get the OS version string
  String _getOSVersion() {
    if (kIsWeb) return 'web';
    try {
      return Platform.operatingSystemVersion;
    } catch (_) {
      return 'unknown';
    }
  }

  /// Get the platform category (mobile, desktop, web)
  String _getPlatformCategory() {
    if (kIsWeb) return 'web';
    try {
      if (Platform.isAndroid || Platform.isIOS) return 'mobile';
      if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
        return 'desktop';
      }
    } catch (_) {
      // Platform not available
    }
    return 'unknown';
  }

  /// Get the current device orientation
  String _getOrientation() {
    try {
      final window = WidgetsBinding.instance.platformDispatcher.views.first;
      final size = window.physicalSize;
      if (size.width > size.height) return 'landscape';
      return 'portrait';
    } catch (_) {
      return 'portrait';
    }
  }

  /// Safe allowlist of environment variable names that may be exposed.
  /// Variables not on this list return null to prevent secret leakage.
  static const _envAllowlist = {
    'HOME',
    'LANG',
    'LANGUAGE',
    'LC_ALL',
    'LC_CTYPE',
    'LOGNAME',
    'PATH',
    'PWD',
    'SHELL',
    'TERM',
    'TMPDIR',
    'TZ',
    'USER',
    'USERNAME',
  };

  /// Blocked patterns — variable names containing these substrings
  /// are never exposed, even if added to a custom allowlist.
  static const _envBlockedPatterns = [
    'KEY',
    'SECRET',
    'TOKEN',
    'PASSWORD',
    'CREDENTIAL',
    'AUTH',
  ];

  /// Get an environment variable (permission-gated, allowlist-restricted)
  String? _getEnvVariable(String name) {
    if (kIsWeb) return null;
    if (!_systemInfoGranted) return null;
    if (!_isEnvAllowed(name)) return null;
    try {
      return Platform.environment[name];
    } catch (_) {
      return null;
    }
  }

  /// Check whether an environment variable name is safe to expose
  bool _isEnvAllowed(String name) {
    final upper = name.toUpperCase();
    for (final blocked in _envBlockedPatterns) {
      if (upper.contains(blocked)) return false;
    }
    return _envAllowlist.contains(upper);
  }

  /// Check if cache is still valid
  bool _isCacheValid() {
    if (_lastCacheUpdate == null) return false;

    final elapsed = DateTime.now().difference(_lastCacheUpdate!);
    return elapsed.inSeconds < cacheDurationSeconds;
  }

  /// Clear the cache
  void clearCache() {
    _cache.clear();
    _lastCacheUpdate = null;
  }

  /// Get all supported client binding paths
  static List<String> get supportedPaths => [
        'workingDirectory',
        'userName',
        'platform',
        'locale',
        'theme',
        'theme.mode',
        'theme.background',
        'theme.primary',
        'theme.secondary',
        'theme.surface',
        'theme.error',
        'theme.textOnPrimary',
        'theme.textOnSecondary',
        'theme.textOnBackground',
        'theme.textOnSurface',
        'theme.textOnError',
        'theme.foreground',
        'platform.category',
        'platform.os',
        'orientation',
        'network.status',
        'network.type',
        'file.separator',
        'system.os',
        'system.version',
        'isWeb',
        'isDebug',
        'isRelease',
        'isProfile',
        'env.*',
      ];

  /// Get all current client values
  Map<String, dynamic> getAllValues() {
    return {
      'workingDirectory': _getWorkingDirectory(),
      'userName': _getUserName(),
      'platform': _getPlatformCategory(),
      'locale': _getLocale(),
      'theme': _getTheme(),
      'theme.mode': _getTheme(),
      'theme.background': _getThemeColor('background'),
      'theme.primary': _getThemeColor('primary'),
      'theme.secondary': _getThemeColor('secondary'),
      'theme.surface': _getThemeColor('surface'),
      'theme.error': _getThemeColor('error'),
      'theme.foreground': _getThemeColor('foreground'),
      'platform.category': _getPlatformCategory(),
      'platform.os': _getPlatformOS(),
      'orientation': _getOrientation(),
      'network.status': _getNetworkStatus(),
      'network.type': _getNetworkType(),
      'file.separator': _getFileSeparator(),
      'system.os': _getPlatformOS(),
      'system.version': _getOSVersion(),
      'isWeb': kIsWeb,
      'isDebug': kDebugMode,
      'isRelease': kReleaseMode,
      'isProfile': kProfileMode,
    };
  }
}
