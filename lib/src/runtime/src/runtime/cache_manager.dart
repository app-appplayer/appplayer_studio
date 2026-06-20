import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/mcp_logger.dart';

/// Cache manager for MCP UI Runtime
class CacheManager {
  CacheManager({
    this.enableDebugMode = kDebugMode,
  }) : _logger = MCPLogger('CacheManager', enableLogging: enableDebugMode);

  final bool enableDebugMode;
  final MCPLogger _logger;

  // In-memory cache for now, can be extended to use persistent storage
  final Map<String, CachedApp> _appCache = {};
  final Map<String, Map<String, dynamic>> _stateCache = {};
  final Map<String, Map<String, dynamic>> _resourceCache = {};

  /// Cache policy configuration
  CachePolicy _defaultPolicy = const CachePolicy();

  /// Gets the default cache policy
  CachePolicy get defaultPolicy => _defaultPolicy;

  /// Sets the default cache policy
  set defaultPolicy(CachePolicy policy) {
    _defaultPolicy = policy;
    if (enableDebugMode) {
      _logger.debug('Default policy updated');
    }
  }

  /// Caches an app definition
  Future<void> cacheApp(CachedApp app) async {
    final key = '${app.domain}:${app.id}';
    _appCache[key] = app;

    if (enableDebugMode) {
      _logger.debug('Cached app $key v${app.version}');
    }
  }

  /// Gets a cached app
  CachedApp? getCachedApp(String domain, String id) {
    final key = '$domain:$id';
    final app = _appCache[key];

    if (app != null && _isAppValid(app)) {
      if (enableDebugMode) {
        _logger.debug('Cache hit for app $key');
      }
      return app;
    }

    if (enableDebugMode) {
      _logger.debug('Cache miss for app $key');
    }
    return null;
  }

  /// Checks if a newer version is available
  bool isUpdateAvailable(String domain, String id, String currentVersion) {
    final key = '$domain:$id';
    final cached = _appCache[key];

    if (cached == null) return false;

    return _compareVersions(cached.version, currentVersion) > 0;
  }

  /// Caches app state
  ///
  /// When the active cache policy has `persistent == true`, the state is also
  /// persisted to SharedPreferences so it survives app restarts.
  Future<void> cacheState(String appKey, Map<String, dynamic> state) async {
    _stateCache[appKey] = Map<String, dynamic>.from(state);

    if (enableDebugMode) {
      _logger.debug('Cached state for $appKey');
    }

    // Only persist when the policy allows it
    final shouldPersist = _defaultPolicy.persistent ?? true;
    if (!shouldPersist) return;

    // Persist to SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      final stateJson = jsonEncode(state);
      await prefs.setString('mcp_ui_state_$appKey', stateJson);

      if (enableDebugMode) {
        _logger.debug('Persisted state for $appKey');
      }
    } catch (e) {
      if (enableDebugMode) {
        _logger.error('Failed to persist state: $e');
      }
    }
  }

  /// Gets cached state
  Map<String, dynamic>? getCachedState(String appKey) {
    return _stateCache[appKey];
  }
  
  /// Loads persisted state from storage
  Future<void> loadPersistedState(String appKey) async {
    // Skip if already in memory cache
    if (_stateCache.containsKey(appKey)) {
      return;
    }
    
    // Load from SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      final stateJson = prefs.getString('mcp_ui_state_$appKey');
      
      if (stateJson != null) {
        final state = jsonDecode(stateJson) as Map<String, dynamic>;
        _stateCache[appKey] = state; // Update memory cache
        
        if (enableDebugMode) {
          _logger.debug('Loaded persisted state for $appKey');
        }
      }
    } catch (e) {
      if (enableDebugMode) {
        _logger.error('Failed to load persisted state: $e');
      }
    }
  }

  /// Caches a resource (e.g., downloaded data)
  Future<void> cacheResource(String key, Map<String, dynamic> data) async {
    _resourceCache[key] = Map<String, dynamic>.from(data);

    if (enableDebugMode) {
      _logger.debug('Cached resource $key');
    }
  }

  /// Gets a cached resource
  Map<String, dynamic>? getCachedResource(String key) {
    return _resourceCache[key];
  }

  /// Clears all caches
  Future<void> clearAll() async {
    _appCache.clear();
    _stateCache.clear();
    _resourceCache.clear();

    // Clear persisted state
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((key) => key.startsWith('mcp_ui_state_'));
      for (final key in keys) {
        await prefs.remove(key);
      }
    } catch (e) {
      if (enableDebugMode) {
        _logger.error('Failed to clear persisted state: $e');
      }
    }

    if (enableDebugMode) {
      _logger.debug('Cleared all caches');
    }
  }

  /// Clears app cache
  Future<void> clearApp(String domain, String id) async {
    final key = '$domain:$id';
    _appCache.remove(key);
    _stateCache.remove(key);

    // Clear persisted state
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('mcp_ui_state_$key');
    } catch (e) {
      if (enableDebugMode) {
        _logger.error('Failed to clear persisted state for app: $e');
      }
    }

    if (enableDebugMode) {
      _logger.debug('Cleared cache for app $key');
    }
  }

  /// Gets cache statistics
  CacheStats getStats() {
    return CacheStats(
      appCount: _appCache.length,
      stateCount: _stateCache.length,
      resourceCount: _resourceCache.length,
      totalSize: _calculateCacheSize(),
    );
  }

  /// Checks if app is still valid based on cache policy
  bool _isAppValid(CachedApp app) {
    final policy = app.cachePolicy ?? _defaultPolicy;

    if (!policy.enabled) return false;

    final now = DateTime.now();
    final age = now.difference(app.cachedAt);

    // Check max age
    if (policy.maxAge != null && age > policy.maxAge!) {
      return false;
    }

    // Check expiry time
    if (app.expiresAt != null && now.isAfter(app.expiresAt!)) {
      return false;
    }

    return true;
  }

  /// Compares version strings (simple semantic versioning)
  int _compareVersions(String v1, String v2) {
    final parts1 = v1.split('.').map(int.tryParse).toList();
    final parts2 = v2.split('.').map(int.tryParse).toList();

    for (int i = 0; i < 3; i++) {
      final p1 = i < parts1.length ? (parts1[i] ?? 0) : 0;
      final p2 = i < parts2.length ? (parts2[i] ?? 0) : 0;

      if (p1 > p2) return 1;
      if (p1 < p2) return -1;
    }

    return 0;
  }

  /// Calculates total cache size (simplified)
  int _calculateCacheSize() {
    int size = 0;

    // Estimate size of app definitions
    for (final app in _appCache.values) {
      size += jsonEncode(app.definition).length;
    }

    // Estimate size of states
    for (final state in _stateCache.values) {
      size += jsonEncode(state).length;
    }

    // Estimate size of resources
    for (final resource in _resourceCache.values) {
      size += jsonEncode(resource).length;
    }

    return size;
  }
}

/// Represents a cached app
class CachedApp {
  const CachedApp({
    required this.id,
    required this.domain,
    required this.version,
    required this.definition,
    required this.cachedAt,
    this.expiresAt,
    this.cachePolicy,
    this.checksum,
  });

  final String id;
  final String domain;
  final String version;
  final Map<String, dynamic> definition;
  final DateTime cachedAt;
  final DateTime? expiresAt;
  final CachePolicy? cachePolicy;
  final String? checksum;

  /// Creates a cached app from runtime definition
  factory CachedApp.fromDefinition(Map<String, dynamic> definition) {
    final runtime = definition['mcpRuntime'];
    if (runtime == null || runtime is! Map) {
      return CachedApp(
        id: 'unknown',
        domain: 'unknown',
        version: '1.0.0',
        definition: definition,
        cachedAt: DateTime.now(),
      );
    }

    final runtimeConfig = runtime['runtime'];
    final config = runtimeConfig is Map ? runtimeConfig : <String, dynamic>{};

    return CachedApp(
      id: config['id']?.toString() ?? 'unknown',
      domain: config['domain']?.toString() ?? 'unknown',
      version: config['version']?.toString() ?? '1.0.0',
      definition: definition,
      cachedAt: DateTime.now(),
      cachePolicy: config['cachePolicy'] is Map
          ? CachePolicy.fromJson(
              Map<String, dynamic>.from(config['cachePolicy'] as Map))
          : null,
    );
  }
}

/// Cache policy configuration
class CachePolicy {
  const CachePolicy({
    this.enabled = true,
    this.maxAge,
    this.staleWhileRevalidate = false,
    this.cacheState = true,
    this.cacheResources = true,
    this.offlineMode = OfflineMode.partial,
    this.strategy = CacheStrategy.networkFirst,
    this.maxSize,
    this.maxEntries,
    this.evictionPolicy = EvictionPolicy.lru,
    this.persistent,
  });

  final bool enabled;
  final Duration? maxAge;
  final bool staleWhileRevalidate;
  final bool cacheState;
  final bool cacheResources;
  final OfflineMode offlineMode;

  /// Caching strategy: how to decide between cache and network
  final CacheStrategy strategy;

  /// Maximum cache size in bytes
  final int? maxSize;

  /// Maximum number of cached entries
  final int? maxEntries;

  /// Policy for evicting entries when cache is full
  final EvictionPolicy evictionPolicy;

  /// Whether cached data should be persisted across sessions.
  ///
  /// When `true`, cache entries are stored/loaded via SharedPreferences so
  /// they survive app restarts. When `false`, cache is memory-only. When
  /// `null`, the cache manager decides based on its own defaults.
  final bool? persistent;

  factory CachePolicy.fromJson(Map<String, dynamic> json) {
    return CachePolicy(
      enabled: json['enabled'] as bool? ?? true,
      maxAge: json['maxAge'] != null
          ? Duration(seconds: json['maxAge'] as int)
          : null,
      staleWhileRevalidate: json['staleWhileRevalidate'] as bool? ?? false,
      cacheState: json['cacheState'] as bool? ?? true,
      cacheResources: json['cacheResources'] as bool? ?? true,
      offlineMode: _parseOfflineMode(json['offlineMode'] as String?),
      strategy: _parseCacheStrategy(json['strategy'] as String?),
      maxSize: json['maxSize'] as int?,
      maxEntries: json['maxEntries'] as int?,
      evictionPolicy:
          _parseEvictionPolicy(json['evictionPolicy'] as String?),
      persistent: json['persistent'] as bool?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'maxAge': maxAge?.inSeconds,
      'staleWhileRevalidate': staleWhileRevalidate,
      'cacheState': cacheState,
      'cacheResources': cacheResources,
      'offlineMode': offlineMode.name,
      'strategy': strategy.name,
      if (maxSize != null) 'maxSize': maxSize,
      if (maxEntries != null) 'maxEntries': maxEntries,
      'evictionPolicy': evictionPolicy.name,
      if (persistent != null) 'persistent': persistent,
    };
  }

  static OfflineMode _parseOfflineMode(String? mode) {
    switch (mode) {
      case 'full':
        return OfflineMode.full;
      case 'partial':
        return OfflineMode.partial;
      case 'disabled':
        return OfflineMode.disabled;
      default:
        return OfflineMode.partial;
    }
  }

  static CacheStrategy _parseCacheStrategy(String? strategy) {
    switch (strategy) {
      case 'cacheFirst':
        return CacheStrategy.cacheFirst;
      case 'networkFirst':
        return CacheStrategy.networkFirst;
      case 'cacheOnly':
        return CacheStrategy.cacheOnly;
      case 'networkOnly':
        return CacheStrategy.networkOnly;
      case 'staleWhileRevalidate':
        return CacheStrategy.staleWhileRevalidate;
      default:
        return CacheStrategy.networkFirst;
    }
  }

  static EvictionPolicy _parseEvictionPolicy(String? policy) {
    switch (policy) {
      case 'lru':
        return EvictionPolicy.lru;
      case 'lfu':
        return EvictionPolicy.lfu;
      case 'fifo':
        return EvictionPolicy.fifo;
      case 'ttl':
        return EvictionPolicy.ttl;
      default:
        return EvictionPolicy.lru;
    }
  }
}

/// Cache strategy for deciding between cache and network
enum CacheStrategy {
  /// Try cache first, fall back to network
  cacheFirst,

  /// Try network first, fall back to cache
  networkFirst,

  /// Only use cache, never network
  cacheOnly,

  /// Only use network, never cache
  networkOnly,

  /// Return stale cache immediately, revalidate in background
  staleWhileRevalidate,
}

/// Eviction policy for removing cache entries
enum EvictionPolicy {
  /// Least Recently Used
  lru,

  /// Least Frequently Used
  lfu,

  /// First In, First Out
  fifo,

  /// Time-To-Live based
  ttl,
}

/// Offline mode options
enum OfflineMode {
  /// Full offline support - all features work offline
  full,

  /// Partial offline support - UI and cached data work, but no tools/streaming
  partial,

  /// No offline support
  disabled,
}

/// Cache statistics
class CacheStats {
  const CacheStats({
    required this.appCount,
    required this.stateCount,
    required this.resourceCount,
    required this.totalSize,
  });

  final int appCount;
  final int stateCount;
  final int resourceCount;
  final int totalSize;

  @override
  String toString() {
    return 'CacheStats(apps: $appCount, states: $stateCount, resources: $resourceCount, size: ${(totalSize / 1024).toStringAsFixed(2)}KB)';
  }
}

/// Update policy for checking app updates
class UpdatePolicy {
  const UpdatePolicy({
    this.checkOnStartup = true,
    this.checkInterval = const Duration(hours: 24),
    this.autoUpdate = false,
    this.requireRestart = true,
  });

  final bool checkOnStartup;
  final Duration checkInterval;
  final bool autoUpdate;
  final bool requireRestart;

  factory UpdatePolicy.fromJson(Map<String, dynamic> json) {
    return UpdatePolicy(
      checkOnStartup: json['checkOnStartup'] as bool? ?? true,
      checkInterval: Duration(seconds: json['checkInterval'] as int? ?? 86400),
      autoUpdate: json['autoUpdate'] as bool? ?? false,
      requireRestart: json['requireRestart'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'checkOnStartup': checkOnStartup,
      'checkInterval': checkInterval.inSeconds,
      'autoUpdate': autoUpdate,
      'requireRestart': requireRestart,
    };
  }
}
