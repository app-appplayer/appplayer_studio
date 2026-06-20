/// Client resource resolver for MCP UI DSL v1.1
///
/// Resolves client:// URIs to local resources.
library client_resource_resolver;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/client_action_types.dart';
import '../core/client_resource_manager.dart' show ResourceLifecycleState;
import '../utils/path_validator.dart';

// ---------------------------------------------------------------------------
// Custom resource provider registry (spec §Custom Resource Providers)
// ---------------------------------------------------------------------------

/// Handler function signature for custom resource providers.
///
/// Receives the path component after `client://<scheme>/` and should return
/// a [ResourceResult]. May also receive a config map from the provider declaration.
typedef CustomResourceHandler = Future<ResourceResult> Function(
  String path,
  Map<String, dynamic>? config,
);

/// A registered custom resource provider
class CustomResourceProvider {
  /// The scheme name (e.g., "database", "api")
  final String scheme;

  /// The handler function
  final CustomResourceHandler handler;

  /// Required permissions for this provider
  final List<String> permissions;

  /// Static configuration for the provider
  final Map<String, dynamic>? config;

  const CustomResourceProvider({
    required this.scheme,
    required this.handler,
    this.permissions = const [],
    this.config,
  });
}

/// Registry for custom client:// resource providers.
///
/// Allows applications to extend the `client://` protocol with custom schemes
/// accessed as `client://<scheme>/path` (spec §Custom Resource Providers).
class CustomResourceProviderRegistry {
  final Map<String, CustomResourceProvider> _providers = {};

  /// Register a custom provider for a given scheme.
  ///
  /// After registration, `client://<scheme>/path` URIs will be dispatched
  /// to the provided [handler].
  void register(CustomResourceProvider provider) {
    _providers[provider.scheme] = provider;
  }

  /// Remove a previously registered provider
  void unregister(String scheme) {
    _providers.remove(scheme);
  }

  /// Whether a provider is registered for [scheme]
  bool has(String scheme) => _providers.containsKey(scheme);

  /// Resolve a URI via the registered provider for [scheme]
  Future<ResourceResult> resolve(String scheme, String path) async {
    final provider = _providers[scheme];
    if (provider == null) {
      return ResourceResult.error('No provider registered for scheme: $scheme');
    }
    return provider.handler(path, provider.config);
  }

  /// Return all registered scheme names
  List<String> get registeredSchemes => _providers.keys.toList();
}

// ---------------------------------------------------------------------------
// Binary resource type detection (spec §Binary Resource Handling)
// ---------------------------------------------------------------------------

/// Content type information derived from a file extension or explicit encoding
class ResourceContentType {
  /// Whether this resource should be treated as binary (base64-encoded)
  final bool isBinary;

  /// MIME type string (e.g., "image/png", "application/pdf")
  final String mimeType;

  const ResourceContentType({required this.isBinary, required this.mimeType});

  /// Derive content type from a file extension
  static ResourceContentType fromExtension(String ext) {
    switch (ext.toLowerCase()) {
      // Text types
      case 'txt':
        return const ResourceContentType(isBinary: false, mimeType: 'text/plain');
      case 'json':
        return const ResourceContentType(isBinary: false, mimeType: 'application/json');
      case 'md':
        return const ResourceContentType(isBinary: false, mimeType: 'text/markdown');
      case 'csv':
        return const ResourceContentType(isBinary: false, mimeType: 'text/csv');
      case 'yaml':
      case 'yml':
        return const ResourceContentType(isBinary: false, mimeType: 'text/yaml');
      case 'xml':
        return const ResourceContentType(isBinary: false, mimeType: 'application/xml');
      case 'html':
      case 'htm':
        return const ResourceContentType(isBinary: false, mimeType: 'text/html');
      case 'css':
        return const ResourceContentType(isBinary: false, mimeType: 'text/css');
      case 'js':
        return const ResourceContentType(isBinary: false, mimeType: 'application/javascript');
      case 'dart':
        return const ResourceContentType(isBinary: false, mimeType: 'text/x-dart');
      // Binary image types
      case 'png':
        return const ResourceContentType(isBinary: true, mimeType: 'image/png');
      case 'jpg':
      case 'jpeg':
        return const ResourceContentType(isBinary: true, mimeType: 'image/jpeg');
      case 'gif':
        return const ResourceContentType(isBinary: true, mimeType: 'image/gif');
      case 'webp':
        return const ResourceContentType(isBinary: true, mimeType: 'image/webp');
      case 'svg':
        return const ResourceContentType(isBinary: false, mimeType: 'image/svg+xml');
      case 'ico':
        return const ResourceContentType(isBinary: true, mimeType: 'image/x-icon');
      // Binary document types
      case 'pdf':
        return const ResourceContentType(isBinary: true, mimeType: 'application/pdf');
      case 'zip':
        return const ResourceContentType(isBinary: true, mimeType: 'application/zip');
      case 'gz':
        return const ResourceContentType(isBinary: true, mimeType: 'application/gzip');
      case 'tar':
        return const ResourceContentType(isBinary: true, mimeType: 'application/x-tar');
      // Binary audio/video
      case 'mp3':
        return const ResourceContentType(isBinary: true, mimeType: 'audio/mpeg');
      case 'mp4':
        return const ResourceContentType(isBinary: true, mimeType: 'video/mp4');
      case 'wav':
        return const ResourceContentType(isBinary: true, mimeType: 'audio/wav');
      default:
        return const ResourceContentType(isBinary: false, mimeType: 'application/octet-stream');
    }
  }
}

/// Size limit constants matching spec §Binary Resource Handling table
class ResourceSizeLimits {
  /// 10 MB for text files and workspace resources
  static const int textMaxBytes = 10 * 1024 * 1024;

  /// 50 MB for binary files
  static const int binaryMaxBytes = 50 * 1024 * 1024;

  /// 100 MB for temp resources
  static const int tempMaxBytes = 100 * 1024 * 1024;

  /// 5 MB per entry for cache resources
  static const int cacheMaxBytes = 5 * 1024 * 1024;
}

/// Resolves client:// resource URIs
class ClientResourceResolver {
  /// Current working directory for workspace resources
  String? workingDirectory;

  /// Temporary directory for temp resources
  String? _tempDirectory;

  /// Cache prefix for cache resources
  static const String _cachePrefix = 'mcp_client_cache_';

  SharedPreferences? _prefs;

  /// Registry for custom resource providers (spec §Custom Resource Providers)
  final CustomResourceProviderRegistry customProviders =
      CustomResourceProviderRegistry();

  /// Initialize the resolver
  Future<void> init() async {
    if (!kIsWeb) {
      _tempDirectory = Directory.systemTemp.path;
    }
    _prefs = await SharedPreferences.getInstance();
  }

  /// Set the working directory for workspace resources
  void setWorkingDirectory(String path) {
    workingDirectory = path;
  }

  /// Resolve a client:// URI to its content
  ///
  /// Supported schemes:
  /// - client://file/path - Read file from filesystem
  /// - client://workspace/path - Read file relative to workspace
  /// - client://temp/name - Read temporary file
  /// - client://cache/key - Read cached data
  /// - client://asset/path - Read bundled app asset
  ///
  /// If [fallback] URI is provided and the primary resolution fails,
  /// the fallback URI will be resolved instead. The [fallbackBehavior]
  /// parameter controls handling when both fail: 'placeholder' (default),
  /// 'hide', or 'error' (spec §1106-1124).
  Future<ResourceResult> resolve(
    String uri, {
    String? fallback,
    String? fallbackBehavior,
  }) async {
    final result = await _resolveInternal(uri);

    if (!result.success && fallback != null && fallback.isNotEmpty) {
      final fallbackResult = await _resolveInternal(fallback);
      if (fallbackResult.success) return fallbackResult;
    }

    return result;
  }

  /// Internal resolution without fallback handling
  Future<ResourceResult> _resolveInternal(String uri) async {
    if (!uri.startsWith('client://')) {
      return ResourceResult.error('Invalid client resource URI: $uri');
    }

    final parsed = ClientResourceSchemes.parse(uri);
    if (parsed == null) {
      return ResourceResult.error('Failed to parse URI: $uri');
    }

    switch (parsed.scheme) {
      case 'file':
        return _resolveFile(parsed.path);
      case 'workspace':
        return _resolveWorkspace(parsed.path);
      case 'temp':
        return _resolveTemp(parsed.path);
      case 'cache':
        return _resolveCache(parsed.path);
      case 'asset':
        return _resolveAsset(parsed.path);
      default:
        // Dispatch to custom providers (spec §Custom Resource Providers)
        if (customProviders.has(parsed.scheme)) {
          return customProviders.resolve(parsed.scheme, parsed.path);
        }
        return ResourceResult.error('Unknown scheme: ${parsed.scheme}');
    }
  }

  /// Check if a URI is a client resource
  bool isClientResource(String uri) {
    return uri.startsWith('client://');
  }

  /// Resolve file:// resource with binary detection, size limits, and
  /// chunked reading for large binary files (spec §Binary Resource Handling).
  Future<ResourceResult> _resolveFile(String path,
      {String? encodingHint}) async {
    if (kIsWeb) {
      return ResourceResult.error('File access not supported on web');
    }

    try {
      // Security: validate path does not contain traversal segments
      if (PathValidator.hasTraversalAttempt(path)) {
        return ResourceResult.error('Path traversal not allowed');
      }

      final normalizedPath = PathValidator.normalize(path);
      final file = File(normalizedPath);

      if (!await file.exists()) {
        return ResourceResult.error('File not found: $normalizedPath');
      }

      // Security: resolve symlinks to the real path for all file operations
      final resolvedPath = file.resolveSymbolicLinksSync();
      final resolvedFile = File(resolvedPath);

      final ext = p.extension(resolvedPath).replaceFirst('.', '');
      final contentType = ResourceContentType.fromExtension(ext);
      final isBinary = encodingHint == 'base64' ||
          (encodingHint == null && contentType.isBinary);
      final maxBytes = isBinary
          ? ResourceSizeLimits.binaryMaxBytes
          : ResourceSizeLimits.textMaxBytes;

      final stat = await resolvedFile.stat();
      if (stat.size > maxBytes) {
        return ResourceResult.error(
          'File exceeds size limit (${stat.size} bytes > $maxBytes bytes): $normalizedPath',
        );
      }

      if (isBinary) {
        // Read as bytes and encode to base64 for transport
        final bytes = await _readFileInChunks(resolvedFile);
        final encoded = base64Encode(bytes);
        return ResourceResult.success(
          content: encoded,
          path: normalizedPath,
          type: 'file',
          mimeType: contentType.mimeType,
          encoding: 'base64',
        );
      }

      final content = await resolvedFile.readAsString();
      return ResourceResult.success(
        content: content,
        path: normalizedPath,
        type: 'file',
        mimeType: contentType.mimeType,
      );
    } catch (e) {
      return ResourceResult.error('Failed to read file: $e');
    }
  }

  /// Read a file in 1 MB chunks to avoid memory spikes for large binary files.
  Future<Uint8List> _readFileInChunks(File file) async {
    const chunkSize = 1024 * 1024; // 1 MB
    final sink = BytesBuilder();
    final raf = await file.open();
    try {
      while (true) {
        final chunk = await raf.read(chunkSize);
        if (chunk.isEmpty) break;
        sink.add(chunk);
      }
    } finally {
      await raf.close();
    }
    return sink.toBytes();
  }

  /// Resolve workspace:// resource
  Future<ResourceResult> _resolveWorkspace(String relativePath) async {
    if (kIsWeb) {
      return ResourceResult.error('Workspace access not supported on web');
    }

    if (workingDirectory == null) {
      return ResourceResult.error('Working directory not set');
    }

    try {
      // Security: reject traversal attempts before path resolution
      if (PathValidator.hasTraversalAttempt(relativePath)) {
        return ResourceResult.error('Path traversal not allowed');
      }

      final sanitizedRelative = PathValidator.normalize(relativePath);
      final fullPath = p.join(workingDirectory!, sanitizedRelative);

      // Security: ensure resolved path stays within workspace
      final normalizedPath = p.normalize(fullPath);
      final normalizedWorkspace = p.normalize(workingDirectory!);

      if (!normalizedPath.startsWith(normalizedWorkspace)) {
        return ResourceResult.error('Path traversal not allowed');
      }

      final file = File(fullPath);

      if (!await file.exists()) {
        return ResourceResult.error('File not found: $relativePath');
      }

      // Size limit check: workspace resources capped at 10MB
      final stat = await file.stat();
      if (stat.size > ResourceSizeLimits.textMaxBytes) {
        return ResourceResult.error(
          'Workspace file exceeds size limit '
          '(${stat.size} bytes > ${ResourceSizeLimits.textMaxBytes} bytes): '
          '$relativePath',
        );
      }

      // Symlink resolution: ensure resolved path stays within workspace
      final resolvedPath = file.resolveSymbolicLinksSync();
      if (!p.normalize(resolvedPath).startsWith(normalizedWorkspace)) {
        return ResourceResult.error(
          'Symlink target escapes workspace directory',
        );
      }

      // Binary detection: base64-encode binary files
      final ext = p.extension(fullPath).replaceFirst('.', '');
      final contentType = ResourceContentType.fromExtension(ext);
      if (contentType.isBinary) {
        final bytes = await _readFileInChunks(File(resolvedPath));
        final encoded = base64Encode(bytes);
        return ResourceResult.success(
          content: encoded,
          path: fullPath,
          type: 'workspace',
          mimeType: contentType.mimeType,
          encoding: 'base64',
        );
      }

      final content = await File(resolvedPath).readAsString();
      return ResourceResult.success(
        content: content,
        path: fullPath,
        type: 'workspace',
        mimeType: contentType.mimeType,
      );
    } catch (e) {
      return ResourceResult.error('Failed to read workspace file: $e');
    }
  }

  /// Resolve temp:// resource
  Future<ResourceResult> _resolveTemp(String name) async {
    if (kIsWeb) {
      return ResourceResult.error('Temp access not supported on web');
    }

    if (_tempDirectory == null) {
      return ResourceResult.error('Temp directory not available');
    }

    try {
      // Sanitize name to prevent directory traversal
      final sanitizedName = p.basename(name);
      final fullPath = p.join(_tempDirectory!, 'mcp_$sanitizedName');
      final normalizedTemp = p.normalize(_tempDirectory!);

      final file = File(fullPath);

      if (!await file.exists()) {
        return ResourceResult.error('Temp file not found: $name');
      }

      // Size limit check: temp resources capped at 100MB
      final stat = await file.stat();
      if (stat.size > ResourceSizeLimits.tempMaxBytes) {
        return ResourceResult.error(
          'Temp file exceeds size limit '
          '(${stat.size} bytes > ${ResourceSizeLimits.tempMaxBytes} bytes): '
          '$name',
        );
      }

      // Symlink resolution: ensure resolved path stays within temp directory
      final resolvedPath = file.resolveSymbolicLinksSync();
      if (!p.normalize(resolvedPath).startsWith(normalizedTemp)) {
        return ResourceResult.error(
          'Symlink target escapes temp directory',
        );
      }

      final content = await File(resolvedPath).readAsString();
      return ResourceResult.success(
        content: content,
        path: fullPath,
        type: 'temp',
      );
    } catch (e) {
      return ResourceResult.error('Failed to read temp file: $e');
    }
  }

  /// Resolve cache:// resource
  Future<ResourceResult> _resolveCache(String key) async {
    try {
      if (_prefs == null) {
        await init();
      }

      final cacheKey = '$_cachePrefix$key';
      final cached = _prefs!.getString(cacheKey);

      if (cached == null) {
        return ResourceResult.error('Cache key not found: $key');
      }

      // Size limit check: cache entries capped at 5MB
      if (cached.length > ResourceSizeLimits.cacheMaxBytes) {
        return ResourceResult.error(
          'Cache entry exceeds size limit '
          '(${cached.length} bytes > ${ResourceSizeLimits.cacheMaxBytes} bytes): '
          '$key',
        );
      }

      return ResourceResult.success(
        content: cached,
        path: key,
        type: 'cache',
      );
    } catch (e) {
      return ResourceResult.error('Failed to read cache: $e');
    }
  }

  /// Resolve asset:// resource
  Future<ResourceResult> _resolveAsset(String assetPath) async {
    try {
      // Assets are bundled with the app and loaded via rootBundle
      final content = await rootBundle.loadString('assets/$assetPath');
      return ResourceResult.success(
        content: content,
        path: assetPath,
        type: 'asset',
      );
    } catch (e) {
      return ResourceResult.error('Failed to load asset: $e');
    }
  }

  /// Write to a client resource
  Future<ResourceResult> write(String uri, String content) async {
    if (!uri.startsWith('client://')) {
      return ResourceResult.error('Invalid client resource URI: $uri');
    }

    final parsed = ClientResourceSchemes.parse(uri);
    if (parsed == null) {
      return ResourceResult.error('Failed to parse URI: $uri');
    }

    switch (parsed.scheme) {
      case 'file':
        return _writeFile(parsed.path, content);
      case 'workspace':
        return _writeWorkspace(parsed.path, content);
      case 'temp':
        return _writeTemp(parsed.path, content);
      case 'cache':
        return _writeCache(parsed.path, content);
      default:
        return ResourceResult.error('Unknown scheme: ${parsed.scheme}');
    }
  }

  /// Write to file:// resource
  Future<ResourceResult> _writeFile(String path, String content) async {
    if (kIsWeb) {
      return ResourceResult.error('File write not supported on web');
    }

    try {
      // Security: reject traversal attempts
      if (PathValidator.hasTraversalAttempt(path)) {
        return ResourceResult.error('Path traversal not allowed');
      }

      final normalizedPath = PathValidator.normalize(path);
      final file = File(normalizedPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(content);

      return ResourceResult.success(
        content: content,
        path: path,
        type: 'file',
      );
    } catch (e) {
      return ResourceResult.error('Failed to write file: $e');
    }
  }

  /// Write to workspace:// resource
  Future<ResourceResult> _writeWorkspace(
      String relativePath, String content) async {
    if (kIsWeb) {
      return ResourceResult.error('Workspace write not supported on web');
    }

    if (workingDirectory == null) {
      return ResourceResult.error('Working directory not set');
    }

    try {
      // Security: reject traversal attempts before path resolution
      if (PathValidator.hasTraversalAttempt(relativePath)) {
        return ResourceResult.error('Path traversal not allowed');
      }

      final sanitizedRelative = PathValidator.normalize(relativePath);
      final fullPath = p.join(workingDirectory!, sanitizedRelative);

      // Security: ensure resolved path stays within workspace
      final normalizedPath = p.normalize(fullPath);
      final normalizedWorkspace = p.normalize(workingDirectory!);

      if (!normalizedPath.startsWith(normalizedWorkspace)) {
        return ResourceResult.error('Path traversal not allowed');
      }

      final file = File(fullPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(content);

      return ResourceResult.success(
        content: content,
        path: fullPath,
        type: 'workspace',
      );
    } catch (e) {
      return ResourceResult.error('Failed to write workspace file: $e');
    }
  }

  /// Write to temp:// resource
  Future<ResourceResult> _writeTemp(String name, String content) async {
    if (kIsWeb) {
      return ResourceResult.error('Temp write not supported on web');
    }

    if (_tempDirectory == null) {
      return ResourceResult.error('Temp directory not available');
    }

    try {
      // Sanitize name to prevent directory traversal
      final sanitizedName = p.basename(name);
      final fullPath = p.join(_tempDirectory!, 'mcp_$sanitizedName');

      final file = File(fullPath);
      await file.writeAsString(content);

      return ResourceResult.success(
        content: content,
        path: fullPath,
        type: 'temp',
      );
    } catch (e) {
      return ResourceResult.error('Failed to write temp file: $e');
    }
  }

  /// Write to cache:// resource
  Future<ResourceResult> _writeCache(String key, String content) async {
    try {
      if (_prefs == null) {
        await init();
      }

      final cacheKey = '$_cachePrefix$key';
      await _prefs!.setString(cacheKey, content);

      return ResourceResult.success(
        content: content,
        path: key,
        type: 'cache',
      );
    } catch (e) {
      return ResourceResult.error('Failed to write cache: $e');
    }
  }

  /// Delete a cache entry
  Future<bool> deleteCache(String key) async {
    try {
      if (_prefs == null) {
        await init();
      }

      final cacheKey = '$_cachePrefix$key';
      return _prefs!.remove(cacheKey);
    } catch (_) {
      return false;
    }
  }

  /// Clear all cache entries
  Future<void> clearCache() async {
    try {
      if (_prefs == null) {
        await init();
      }

      final keys = _prefs!.getKeys().where((k) => k.startsWith(_cachePrefix));
      for (final key in keys) {
        await _prefs!.remove(key);
      }
    } catch (_) {
      // Ignore errors
    }
  }
}

/// Result of a resource resolution
class ResourceResult {
  /// Whether the resolution was successful
  final bool success;

  /// The content of the resource (base64-encoded if encoding == 'base64')
  final String? content;

  /// The resolved path
  final String? path;

  /// The type of resource (file, workspace, temp, cache, asset)
  final String? type;

  /// MIME type derived from file extension (spec §Binary Resource Handling)
  final String? mimeType;

  /// Encoding used for content: null/'utf-8' for text, 'base64' for binary
  final String? encoding;

  /// Error message if failed
  final String? error;

  const ResourceResult._({
    required this.success,
    this.content,
    this.path,
    this.type,
    this.mimeType,
    this.encoding,
    this.error,
  });

  /// Create a successful result
  factory ResourceResult.success({
    required String content,
    required String path,
    required String type,
    String? mimeType,
    String? encoding,
  }) {
    return ResourceResult._(
      success: true,
      content: content,
      path: path,
      type: type,
      mimeType: mimeType,
      encoding: encoding,
    );
  }

  /// Create an error result
  factory ResourceResult.error(String message) {
    return ResourceResult._(
      success: false,
      error: message,
    );
  }

  /// Whether this result contains binary (base64-encoded) data
  bool get isBinary => encoding == 'base64';

  /// Convert content to JSON if possible
  dynamic get jsonContent {
    if (content == null) return null;
    try {
      return jsonDecode(content!);
    } catch (_) {
      return content;
    }
  }

  @override
  String toString() {
    if (success) {
      return 'ResourceResult.success($type: $path)';
    }
    return 'ResourceResult.error($error)';
  }
}

/// Caching strategies for client resources
class ResourceCacheManager {
  final Map<String, ResolverCachedEntry> _cache = {};

  /// Resolve a resource with caching strategy
  Future<ResourceResult> resolveWithCache(
    String uri,
    String strategy,
    Future<ResourceResult> Function() fetcher,
  ) async {
    // Normalize strategy name: accept both kebab-case and camelCase
    final normalizedStrategy = _normalizeStrategy(strategy);
    switch (normalizedStrategy) {
      case 'cacheFirst':
        final cached = _cache[uri];
        if (cached != null && !cached.isExpired) {
          return ResourceResult.success(
            content: cached.content,
            path: cached.path,
            type: cached.type,
          );
        }
        final result = await fetcher();
        if (result.success) _cacheResult(uri, result);
        return result;

      case 'networkFirst':
        try {
          final result = await fetcher();
          if (result.success) _cacheResult(uri, result);
          return result;
        } catch (_) {
          final cached = _cache[uri];
          if (cached != null) {
            return ResourceResult.success(
              content: cached.content,
              path: cached.path,
              type: cached.type,
            );
          }
          rethrow;
        }

      case 'staleWhileRevalidate':
        final cached = _cache[uri];
        if (cached != null) {
          // Return stale cache immediately, revalidate in background
          fetcher().then((result) {
            if (result.success) _cacheResult(uri, result);
          });
          return ResourceResult.success(
            content: cached.content,
            path: cached.path,
            type: cached.type,
          );
        }
        final result = await fetcher();
        if (result.success) _cacheResult(uri, result);
        return result;

      case 'cacheOnly':
        final cached = _cache[uri];
        if (cached != null) {
          return ResourceResult.success(
            content: cached.content,
            path: cached.path,
            type: cached.type,
          );
        }
        return ResourceResult.error('Resource not in cache: $uri');

      case 'networkOnly':
      default:
        return fetcher();
    }
  }

  void _cacheResult(String uri, ResourceResult result) {
    _cache[uri] = ResolverCachedEntry(
      content: result.content ?? '',
      path: result.path ?? '',
      type: result.type ?? '',
      cachedAt: DateTime.now(),
    );
  }

  /// Normalize cache strategy name from kebab-case to camelCase
  String _normalizeStrategy(String strategy) {
    switch (strategy) {
      case 'cache-first':
        return 'cacheFirst';
      case 'network-first':
        return 'networkFirst';
      case 'stale-while-revalidate':
        return 'staleWhileRevalidate';
      case 'cache-only':
        return 'cacheOnly';
      case 'network-only':
        return 'networkOnly';
      default:
        return strategy;
    }
  }

  /// Clear all cached resources
  void clear() => _cache.clear();

  /// Remove a specific cached resource
  void remove(String uri) => _cache.remove(uri);
}

/// A simple cached resource entry for the resolver's internal cache.
/// For the richer lifecycle-aware version, see [CachedResource] in
/// `core/client_resource_manager.dart`.
class ResolverCachedEntry {
  final String content;
  final String path;
  final String type;
  final DateTime cachedAt;
  final Duration ttl;

  ResolverCachedEntry({
    required this.content,
    required this.path,
    required this.type,
    required this.cachedAt,
    this.ttl = const Duration(minutes: 5),
  });

  bool get isExpired => DateTime.now().difference(cachedAt) > ttl;
}

/// Resource transformation pipeline
class ResourceTransformer {
  /// Apply a chain of transformations to resource data
  static dynamic applyTransforms(
    dynamic data,
    List<Map<String, dynamic>> transforms,
  ) {
    dynamic result = data;
    for (final transform in transforms) {
      final type = transform['type'] as String?;
      switch (type) {
        case 'parse':
          if (result is String) {
            final format =
                (transform['format'] as String?)?.toLowerCase() ?? 'json';
            switch (format) {
              case 'json':
                try {
                  result = jsonDecode(result);
                } catch (_) {
                  // Keep as string if not valid JSON
                }
                break;
              case 'yaml':
                // TODO: Requires 'package:yaml' — add to pubspec when available
                throw UnsupportedError(
                  'Parse format "yaml" requires the "yaml" package',
                );
              case 'csv':
                // TODO: Requires 'package:csv' — add to pubspec when available
                throw UnsupportedError(
                  'Parse format "csv" requires the "csv" package',
                );
              case 'xml':
                // TODO: Requires 'package:xml' — add to pubspec when available
                throw UnsupportedError(
                  'Parse format "xml" requires the "xml" package',
                );
              default:
                throw UnsupportedError(
                  'Unsupported parse format: "$format". '
                  'Supported formats: json, yaml, csv, xml',
                );
            }
          }
          break;
        case 'select':
          final path = transform['path'] as String?;
          if (path != null && result is Map<String, dynamic>) {
            result = _selectPath(result, path);
          }
          break;
        case 'defaults':
          final defaults = transform['value'] as Map<String, dynamic>?;
          if (defaults != null && result is Map<String, dynamic>) {
            result = {...defaults, ...result};
          }
          break;
        case 'rename':
          // Key remapping on a Map (formerly 'map' behavior)
          final mapping = transform['mapping'] as Map<String, dynamic>?;
          if (mapping != null && result is Map<String, dynamic>) {
            final mapped = <String, dynamic>{};
            for (final entry in mapping.entries) {
              mapped[entry.key] = result[entry.value] ?? entry.value;
            }
            result = mapped;
          }
          break;
        case 'map':
          // List element mapping: applies an expression to each item
          final expression = transform['expression'] as String?;
          if (expression != null && result is List) {
            result = result.map((item) {
              if (item is Map<String, dynamic>) {
                // Evaluate simple dot-path expression (e.g., "item.name")
                final path = expression.startsWith('item.')
                    ? expression.substring(5)
                    : expression;
                return _selectPath(item, path) ?? item;
              }
              return item;
            }).toList();
          }
          break;
        case 'hasKey':
          // Simple key-exists filter on a list (formerly 'filter' behavior)
          final condition = transform['condition'] as String?;
          if (condition != null && result is List) {
            result = result.where((item) {
              if (item is Map<String, dynamic>) {
                return item.containsKey(condition);
              }
              return true;
            }).toList();
          }
          break;
        case 'filter':
          // Evaluate a binding expression condition on each list item
          final condition = transform['condition'] as String?;
          if (condition != null && result is List) {
            result = result.where((item) {
              if (item is Map<String, dynamic>) {
                return _evaluateFilterCondition(item, condition);
              }
              return true;
            }).toList();
          }
          break;
        case 'sort':
          final by = transform['by'] as String?;
          final order = transform['order'] as String? ?? 'asc';
          if (by != null && result is List) {
            result = List.from(result)
              ..sort((a, b) {
                final aVal = a is Map ? a[by] : a;
                final bVal = b is Map ? b[by] : b;
                final cmp = Comparable.compare(
                    aVal as Comparable, bVal as Comparable);
                return order == 'desc' ? -cmp : cmp;
              });
          }
          break;
        case 'resize':
          // Image resize placeholder - would need image processing library
          break;
        case 'format':
          final fmt = transform['format'] as String?;
          if (fmt == 'string' && result != null) {
            result = result.toString();
          }
          break;
      }
    }
    return result;
  }

  /// Evaluate a simple filter condition against a map item.
  ///
  /// Supports expressions like:
  /// - "field == value" — equality check
  /// - "field != value" — inequality check
  /// - "field" — truthy check (non-null, non-false, non-empty)
  static bool _evaluateFilterCondition(
      Map<String, dynamic> item, String condition) {
    // Equality / inequality operators
    for (final op in ['!=', '==']) {
      final idx = condition.indexOf(op);
      if (idx > 0) {
        final field = condition.substring(0, idx).trim();
        final expected = condition.substring(idx + op.length).trim();
        final actual = _selectPath(item, field);
        final actualStr = actual?.toString() ?? '';
        if (op == '==') return actualStr == expected;
        if (op == '!=') return actualStr != expected;
      }
    }

    // Truthy check: field exists and is non-null / non-false / non-empty
    final value = _selectPath(item, condition.trim());
    if (value == null) return false;
    if (value is bool) return value;
    if (value is String) return value.isNotEmpty;
    if (value is List) return value.isNotEmpty;
    return true;
  }

  /// Select a nested value from a map using dot-notation path
  static dynamic _selectPath(Map<String, dynamic> data, String path) {
    final parts = path.split('.');
    dynamic current = data;
    for (final part in parts) {
      if (current is Map<String, dynamic>) {
        current = current[part];
      } else {
        return null;
      }
    }
    return current;
  }
}

// ResourceLifecycleState is imported from core/client_resource_manager.dart
// to avoid duplicate enum definitions.

/// Tracks a resource through its lifecycle
class ResourceEntry {
  /// Current lifecycle state
  ResourceLifecycleState state;

  /// The resource URI
  final String uri;

  /// The resolved content
  String? content;

  /// Error message if in error state
  String? error;

  /// When the resource was last loaded
  DateTime? loadedAt;

  /// Time-to-live before becoming stale
  final Duration staleDuration;

  /// Time-to-live before expiring
  final Duration expireDuration;

  ResourceEntry({
    required this.uri,
    this.state = ResourceLifecycleState.loading,
    this.staleDuration = const Duration(minutes: 5),
    this.expireDuration = const Duration(minutes: 30),
  });

  /// Update state based on age
  void updateState() {
    if (state == ResourceLifecycleState.disposed) return;
    if (state == ResourceLifecycleState.error) return;
    if (loadedAt == null) return;

    final age = DateTime.now().difference(loadedAt!);
    if (age > expireDuration) {
      state = ResourceLifecycleState.expired;
    } else if (age > staleDuration) {
      state = ResourceLifecycleState.stale;
    }
  }

  /// Mark as successfully loaded
  void markReady(String content) {
    this.content = content;
    error = null;
    state = ResourceLifecycleState.ready;
    loadedAt = DateTime.now();
  }

  /// Mark as failed
  void markError(String error) {
    this.error = error;
    state = ResourceLifecycleState.error;
  }

  /// Mark as disposed
  void dispose() {
    state = ResourceLifecycleState.disposed;
    content = null;
    error = null;
  }
}
