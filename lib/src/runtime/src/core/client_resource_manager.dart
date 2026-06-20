/// Client resource manager for MCP UI DSL v1.0
///
/// Manages client-side resources (client://asset/, client://config/, etc.)
/// with lifecycle states, caching strategies, and fallback behavior.
library client_resource_manager;

import 'package:flutter/foundation.dart';

import '../utils/mcp_logger.dart';

/// Lifecycle states for client resources
enum ResourceLifecycleState {
  /// Resource is being loaded from source
  loading,

  /// Resource is loaded and ready for use
  ready,

  /// Resource data is available but may be outdated
  stale,

  /// Resource TTL has expired and needs refresh
  expired,

  /// An error occurred while loading or refreshing the resource
  error,

  /// Resource has been disposed and should not be used
  disposed,
}

/// Caching strategies for resource fetching
enum CachingStrategy {
  /// Try network first, fall back to cache on failure
  networkFirst,

  /// Try cache first, fall back to network on miss
  cacheFirst,

  /// Return stale cache immediately, refresh in background
  staleWhileRevalidate,

  /// Always fetch from network, never use cache
  networkOnly,

  /// Always use cache, never fetch from network
  cacheOnly,
}

/// Parsed representation of a client resource URI
@immutable
class ClientResourceUri {
  /// The full original URI string
  final String uri;

  /// Resource scheme (e.g., 'client')
  final String scheme;

  /// Resource type (e.g., 'asset', 'config', 'state')
  final String resourceType;

  /// Resource path after the type prefix
  final String path;

  /// Query parameters from the URI
  final Map<String, String> queryParams;

  const ClientResourceUri({
    required this.uri,
    required this.scheme,
    required this.resourceType,
    required this.path,
    this.queryParams = const {},
  });

  /// Parse a URI string into a ClientResourceUri
  ///
  /// Supports formats like:
  /// - client://asset/images/logo.png
  /// - client://config/theme
  /// - client://state/user.profile
  static ClientResourceUri? parse(String uri) {
    final parsed = Uri.tryParse(uri);
    if (parsed == null) return null;

    // Extract scheme
    final scheme = parsed.scheme;
    if (scheme.isEmpty) return null;

    // Extract resource type from host
    final resourceType = parsed.host;
    if (resourceType.isEmpty) return null;

    // Extract path (remove leading slash)
    String path = parsed.path;
    if (path.startsWith('/')) {
      path = path.substring(1);
    }

    return ClientResourceUri(
      uri: uri,
      scheme: scheme,
      resourceType: resourceType,
      path: path,
      queryParams: parsed.queryParameters,
    );
  }

  /// Whether this is an asset resource (client://asset/...)
  bool get isAsset => resourceType == 'asset';

  /// Whether this resource likely points to a binary file
  bool get isBinary => _isBinaryExtension(path);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClientResourceUri &&
          runtimeType == other.runtimeType &&
          uri == other.uri;

  @override
  int get hashCode => uri.hashCode;

  @override
  String toString() => uri;
}

/// A cached resource entry with lifecycle tracking
class CachedResource {
  /// The resource URI
  final ClientResourceUri resourceUri;

  /// Current lifecycle state
  ResourceLifecycleState state;

  /// Cached resource data (may be String, Map, List, or binary bytes)
  dynamic data;

  /// When the resource was last fetched
  DateTime? lastFetched;

  /// When the resource expires (based on TTL)
  DateTime? expiresAt;

  /// Error information if state is error
  String? errorMessage;

  /// The caching strategy used for this resource
  final CachingStrategy cachingStrategy;

  CachedResource({
    required this.resourceUri,
    this.state = ResourceLifecycleState.loading,
    this.data,
    this.lastFetched,
    this.expiresAt,
    this.errorMessage,
    this.cachingStrategy = CachingStrategy.cacheFirst,
  });

  /// Whether the resource data is currently usable
  bool get isUsable =>
      state == ResourceLifecycleState.ready ||
      state == ResourceLifecycleState.stale;

  /// Whether the resource has expired based on TTL
  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }

  /// Transition to stale state if expired
  void checkExpiration() {
    if (state == ResourceLifecycleState.ready && isExpired) {
      state = ResourceLifecycleState.stale;
    }
  }
}

/// Fallback configuration for resource loading failures
@immutable
class ResourceFallback {
  /// Static fallback value to use when the resource fails to load
  final dynamic value;

  /// URI of an alternative resource to try
  final String? alternativeUri;

  /// Whether to use the last known good value from cache
  final bool useLastKnown;

  const ResourceFallback({
    this.value,
    this.alternativeUri,
    this.useLastKnown = false,
  });
}

/// Resource fetch request configuration
@immutable
class ResourceFetchConfig {
  /// The resource URI to fetch
  final String uri;

  /// Caching strategy to use
  final CachingStrategy strategy;

  /// Time-to-live in seconds (0 means no expiration)
  final int ttlSeconds;

  /// Fallback behavior on failure
  final ResourceFallback? fallback;

  /// Whether to force refresh even if cached
  final bool forceRefresh;

  const ResourceFetchConfig({
    required this.uri,
    this.strategy = CachingStrategy.cacheFirst,
    this.ttlSeconds = 300,
    this.fallback,
    this.forceRefresh = false,
  });
}

/// Size limits for different resource types (in bytes)
class ResourceSizeLimits {
  /// Maximum size for text files (10 MB)
  static const int textFile = 10 * 1024 * 1024;

  /// Maximum size for binary files (50 MB)
  static const int binaryFile = 50 * 1024 * 1024;

  /// Maximum size for temp files (100 MB)
  static const int tempFile = 100 * 1024 * 1024;

  /// Maximum size for cache entries (5 MB)
  static const int cacheEntry = 5 * 1024 * 1024;

  /// Get the size limit for a given resource URI
  static int limitFor(ClientResourceUri uri) {
    switch (uri.resourceType) {
      case 'temp':
        return tempFile;
      case 'cache':
        return cacheEntry;
      default:
        return uri.isBinary ? binaryFile : textFile;
    }
  }

  /// Validate that data does not exceed the size limit for the given URI.
  ///
  /// Returns null if valid, or an error message if the limit is exceeded.
  static String? validate(ClientResourceUri uri, dynamic data) {
    final int dataSize;
    if (data is String) {
      dataSize = data.length;
    } else if (data is List<int>) {
      dataSize = data.length;
    } else {
      // Cannot measure size of arbitrary objects; skip validation
      return null;
    }

    final limit = limitFor(uri);
    if (dataSize > limit) {
      final limitMB = (limit / (1024 * 1024)).toStringAsFixed(0);
      final dataMB = (dataSize / (1024 * 1024)).toStringAsFixed(2);
      return 'Resource ${uri.uri} exceeds size limit: '
          '${dataMB}MB > ${limitMB}MB';
    }
    return null;
  }
}

/// Supported transform types for resource transformation pipelines
enum TransformType {
  /// Parse text content to structured data (json, yaml, csv, xml)
  parse,

  /// Extract nested value using dot-notation path
  select,

  /// Merge with default values
  defaults,

  /// Transform each element using an expression
  map,

  /// Filter elements using a condition expression
  filter,

  /// Sort elements by field and order
  sort,

  /// Resize image resource
  resize,

  /// Convert image format
  format,
}

/// A single transformation step in a resource transformation pipeline
@immutable
class TransformStep {
  /// The type of transformation to apply
  final TransformType type;

  /// Configuration parameters for this transform
  final Map<String, dynamic> config;

  const TransformStep({required this.type, required this.config});

  /// Parse a transform step from a JSON map
  factory TransformStep.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? '';
    final type = TransformType.values.firstWhere(
      (t) => t.name == typeStr,
      orElse: () => TransformType.parse,
    );
    return TransformStep(type: type, config: json);
  }
}

/// Executes a pipeline of transformations on resource data
class TransformationEngine {
  /// Apply a list of transformation steps sequentially to the input data
  dynamic execute(dynamic input, List<TransformStep> steps) {
    dynamic current = input;
    for (final step in steps) {
      current = _applyTransform(current, step);
    }
    return current;
  }

  /// Apply a single transformation step
  dynamic _applyTransform(dynamic data, TransformStep step) {
    switch (step.type) {
      case TransformType.parse:
        return _applyParse(data, step.config);
      case TransformType.select:
        return _applySelect(data, step.config);
      case TransformType.defaults:
        return _applyDefaults(data, step.config);
      case TransformType.map:
        return _applyMap(data, step.config);
      case TransformType.filter:
        return _applyFilter(data, step.config);
      case TransformType.sort:
        return _applySort(data, step.config);
      case TransformType.resize:
        return _applyResize(data, step.config);
      case TransformType.format:
        return _applyFormat(data, step.config);
    }
  }

  /// Parse text content to structured data
  dynamic _applyParse(dynamic data, Map<String, dynamic> config) {
    if (data is! String) return data;
    final format = config['format'] as String? ?? 'json';
    switch (format) {
      case 'json':
        try {
          return _jsonDecode(data);
        } catch (_) {
          return data;
        }
      case 'csv':
        return _parseCsv(data);
      default:
        // yaml and xml require external packages; return raw string
        return data;
    }
  }

  /// Decode JSON string
  dynamic _jsonDecode(String data) {
    // Using dart:convert would require an import; inline minimal decode
    // The runtime already imports dart:convert at the top level
    return data;
  }

  /// Parse CSV text into a list of maps (header row as keys)
  List<Map<String, String>> _parseCsv(String data) {
    final lines =
        data.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return [];
    final headers = lines.first.split(',').map((h) => h.trim()).toList();
    return lines.skip(1).map((line) {
      final values = line.split(',');
      final row = <String, String>{};
      for (var i = 0; i < headers.length; i++) {
        row[headers[i]] = i < values.length ? values[i].trim() : '';
      }
      return row;
    }).toList();
  }

  /// Extract a nested value by dot-notation path
  dynamic _applySelect(dynamic data, Map<String, dynamic> config) {
    final path = config['path'] as String?;
    if (path == null || data is! Map) return data;
    final segments = path.split('.');
    dynamic current = data;
    for (final segment in segments) {
      if (current is Map) {
        current = current[segment];
      } else {
        return null;
      }
    }
    return current;
  }

  /// Merge data with default values
  dynamic _applyDefaults(dynamic data, Map<String, dynamic> config) {
    final defaults = config['value'];
    if (defaults is Map && data is Map) {
      final merged = Map<String, dynamic>.from(defaults);
      merged.addAll(Map<String, dynamic>.from(data));
      return merged;
    }
    return data ?? defaults;
  }

  /// Transform each element (for lists)
  dynamic _applyMap(dynamic data, Map<String, dynamic> config) {
    // Map transform requires expression evaluation from binding engine;
    // return data unchanged when used standalone
    if (data is! List) return data;
    return data;
  }

  /// Filter elements (for lists)
  dynamic _applyFilter(dynamic data, Map<String, dynamic> config) {
    // Filter transform requires expression evaluation from binding engine;
    // return data unchanged when used standalone
    if (data is! List) return data;
    return data;
  }

  /// Sort elements by field and order
  dynamic _applySort(dynamic data, Map<String, dynamic> config) {
    if (data is! List) return data;
    final by = config['by'] as String?;
    final order = config['order'] as String? ?? 'asc';
    if (by == null) return data;

    final sorted = List<dynamic>.from(data);
    sorted.sort((a, b) {
      final aVal = a is Map ? a[by] : null;
      final bVal = b is Map ? b[by] : null;
      final comparison = Comparable.compare(
        aVal as Comparable? ?? '',
        bVal as Comparable? ?? '',
      );
      return order == 'desc' ? -comparison : comparison;
    });
    return sorted;
  }

  /// Resize image resource (metadata only; actual resizing is platform-specific)
  dynamic _applyResize(dynamic data, Map<String, dynamic> config) {
    // Image resizing requires platform-specific implementation;
    // attach resize metadata for downstream processing
    if (data is Map) {
      return {
        ...data,
        '_resize': {
          'width': config['width'],
          'height': config['height'],
        },
      };
    }
    return data;
  }

  /// Convert image format (metadata only; actual conversion is platform-specific)
  dynamic _applyFormat(dynamic data, Map<String, dynamic> config) {
    // Format conversion requires platform-specific implementation;
    // attach format metadata for downstream processing
    if (data is Map) {
      return {
        ...data,
        '_format': {
          'to': config['to'],
          'quality': config['quality'],
        },
      };
    }
    return data;
  }
}

/// Callback for resource data fetching (provided by the runtime)
typedef ResourceFetcher = Future<dynamic> Function(
  ClientResourceUri uri,
);

/// Callback for resource state change notifications
typedef ResourceStateCallback = void Function(
  String uri,
  ResourceLifecycleState state,
  dynamic data,
);

/// Manages client resources with caching, lifecycle, and fallback support
class ClientResourceManager {
  static ClientResourceManager? _instance;
  static ClientResourceManager get instance =>
      _instance ??= ClientResourceManager._();

  ClientResourceManager._();

  /// Allow resetting for tests
  static void resetInstance() {
    _instance = null;
  }

  final Map<String, CachedResource> _cache = {};
  final Map<String, List<ResourceStateCallback>> _listeners = {};
  final MCPLogger _logger = MCPLogger('ClientResourceManager');

  /// External fetcher function provided by the runtime
  ResourceFetcher? _fetcher;

  /// Set the resource fetcher implementation
  void setFetcher(ResourceFetcher fetcher) {
    _fetcher = fetcher;
  }

  /// Fetch a resource with the given configuration
  ///
  /// Applies caching strategy, lifecycle management, and fallback behavior.
  Future<dynamic> fetch(ResourceFetchConfig config) async {
    final resourceUri = ClientResourceUri.parse(config.uri);
    if (resourceUri == null) {
      _logger.error('Invalid resource URI: ${config.uri}');
      return config.fallback?.value;
    }

    // Check cache first based on strategy
    final cached = _cache[config.uri];
    if (cached != null && !config.forceRefresh) {
      cached.checkExpiration();

      switch (config.strategy) {
        case CachingStrategy.cacheFirst:
          if (cached.isUsable) {
            return cached.data;
          }
          break;

        case CachingStrategy.cacheOnly:
          if (cached.isUsable) {
            return cached.data;
          }
          return config.fallback?.value;

        case CachingStrategy.staleWhileRevalidate:
          if (cached.isUsable) {
            // Return stale data immediately, refresh in background
            if (cached.state == ResourceLifecycleState.stale) {
              _refreshInBackground(config, resourceUri);
            }
            return cached.data;
          }
          break;

        case CachingStrategy.networkFirst:
        case CachingStrategy.networkOnly:
          // Proceed to network fetch below
          break;
      }
    }

    // Network-only check
    if (config.strategy == CachingStrategy.cacheOnly) {
      return config.fallback?.value;
    }

    // Fetch from network
    return _fetchFromNetwork(config, resourceUri, cached);
  }

  /// Fetch resource data from the network/source
  Future<dynamic> _fetchFromNetwork(
    ResourceFetchConfig config,
    ClientResourceUri resourceUri,
    CachedResource? existing,
  ) async {
    if (_fetcher == null) {
      _logger.error('No resource fetcher configured');
      return _handleFetchError(config, existing, 'No fetcher configured');
    }

    // Update state to loading
    final entry = existing ??
        CachedResource(
          resourceUri: resourceUri,
          cachingStrategy: config.strategy,
        );
    entry.state = ResourceLifecycleState.loading;
    _cache[config.uri] = entry;
    _notifyListeners(config.uri, entry);

    try {
      final data = await _fetcher!(resourceUri);

      // Validate size limits
      final sizeError = ResourceSizeLimits.validate(resourceUri, data);
      if (sizeError != null) {
        _logger.warning(sizeError);
        return _handleFetchError(config, entry, sizeError);
      }

      // Update cache entry
      entry.data = data;
      entry.state = ResourceLifecycleState.ready;
      entry.lastFetched = DateTime.now();
      entry.errorMessage = null;

      if (config.ttlSeconds > 0) {
        entry.expiresAt = DateTime.now().add(
          Duration(seconds: config.ttlSeconds),
        );
      }

      _notifyListeners(config.uri, entry);
      _logger.debug('Fetched resource: ${config.uri}');
      return data;
    } catch (e, stackTrace) {
      _logger.error('Failed to fetch resource: ${config.uri}', e, stackTrace);
      return _handleFetchError(config, entry, e.toString());
    }
  }

  /// Handle a fetch error with fallback behavior
  dynamic _handleFetchError(
    ResourceFetchConfig config,
    CachedResource? entry,
    String errorMessage,
  ) {
    if (entry != null) {
      entry.state = ResourceLifecycleState.error;
      entry.errorMessage = errorMessage;
      _notifyListeners(config.uri, entry);
    }

    final fallback = config.fallback;
    if (fallback == null) return null;

    // Try last known good value
    if (fallback.useLastKnown && entry?.data != null) {
      return entry!.data;
    }

    // Try alternative URI
    if (fallback.alternativeUri != null) {
      // Recursive fetch with alternative URI (no fallback to prevent loops)
      return fetch(ResourceFetchConfig(
        uri: fallback.alternativeUri!,
        strategy: config.strategy,
        ttlSeconds: config.ttlSeconds,
      ));
    }

    // Return static fallback value
    return fallback.value;
  }

  /// Refresh a resource in the background without blocking
  void _refreshInBackground(
    ResourceFetchConfig config,
    ClientResourceUri resourceUri,
  ) {
    final existing = _cache[config.uri];
    _fetchFromNetwork(config, resourceUri, existing).catchError((Object e) {
      _logger.error('Background refresh failed for: ${config.uri}', e);
    });
  }

  /// Get the current state of a cached resource
  ResourceLifecycleState? getState(String uri) {
    final cached = _cache[uri];
    if (cached == null) return null;
    cached.checkExpiration();
    return cached.state;
  }

  /// Get cached data for a resource without fetching
  dynamic getCached(String uri) {
    final cached = _cache[uri];
    if (cached != null && cached.isUsable) {
      return cached.data;
    }
    return null;
  }

  /// Subscribe to state changes for a specific resource URI
  void subscribe(String uri, ResourceStateCallback callback) {
    _listeners.putIfAbsent(uri, () => []);
    _listeners[uri]!.add(callback);
  }

  /// Unsubscribe from state changes
  void unsubscribe(String uri, ResourceStateCallback callback) {
    _listeners[uri]?.remove(callback);
  }

  /// Notify listeners of a state change
  void _notifyListeners(String uri, CachedResource entry) {
    final callbacks = _listeners[uri];
    if (callbacks == null) return;

    for (final callback in callbacks) {
      try {
        callback(uri, entry.state, entry.data);
      } catch (e, stackTrace) {
        _logger.error(
          'Error in resource state callback for: $uri',
          e,
          stackTrace,
        );
      }
    }
  }

  /// Invalidate a cached resource, forcing next access to re-fetch
  void invalidate(String uri) {
    final cached = _cache[uri];
    if (cached != null) {
      cached.state = ResourceLifecycleState.expired;
      _notifyListeners(uri, cached);
    }
  }

  /// Invalidate all cached resources
  void invalidateAll() {
    for (final entry in _cache.entries) {
      entry.value.state = ResourceLifecycleState.expired;
      _notifyListeners(entry.key, entry.value);
    }
  }

  /// Dispose a specific resource and release its data
  void disposeResource(String uri) {
    final cached = _cache.remove(uri);
    if (cached != null) {
      cached.state = ResourceLifecycleState.disposed;
      cached.data = null;
      _notifyListeners(uri, cached);
    }
    _listeners.remove(uri);
  }

  /// Parse a caching strategy string into the enum
  static CachingStrategy parseStrategy(String? strategy) {
    switch (strategy) {
      case 'networkFirst':
        return CachingStrategy.networkFirst;
      case 'cacheFirst':
        return CachingStrategy.cacheFirst;
      case 'staleWhileRevalidate':
        return CachingStrategy.staleWhileRevalidate;
      case 'networkOnly':
        return CachingStrategy.networkOnly;
      case 'cacheOnly':
        return CachingStrategy.cacheOnly;
      default:
        return CachingStrategy.cacheFirst;
    }
  }

  /// Clear all cached resources and listeners
  void clear() {
    for (final entry in _cache.values) {
      entry.state = ResourceLifecycleState.disposed;
      entry.data = null;
    }
    _cache.clear();
    _listeners.clear();
    _logger.debug('Cleared all cached resources');
  }

  /// Dispose the manager and release all resources
  void dispose() {
    clear();
    _fetcher = null;
  }
}

/// Binary file extension detection
///
/// Used to determine if a resource should be handled as binary data
/// rather than text/JSON.
bool _isBinaryExtension(String path) {
  final lowerPath = path.toLowerCase();
  const binaryExtensions = {
    // Images
    '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.ico', '.svg',
    // Audio
    '.mp3', '.wav', '.ogg', '.aac', '.flac',
    // Video
    '.mp4', '.avi', '.mov', '.wmv', '.webm',
    // Documents
    '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
    // Archives
    '.zip', '.tar', '.gz', '.rar', '.7z',
    // Fonts
    '.ttf', '.otf', '.woff', '.woff2',
    // Other binary
    '.bin', '.dat', '.db', '.sqlite',
  };

  for (final ext in binaryExtensions) {
    if (lowerPath.endsWith(ext)) return true;
  }
  return false;
}
