import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import '../utils/mcp_logger.dart';

/// Widget caching system for performance optimization
/// according to MCP UI DSL v1.0 specification
class WidgetCache {
  static final WidgetCache _instance = WidgetCache._internal();
  factory WidgetCache() => _instance;
  static WidgetCache get instance => _instance;

  WidgetCache._internal();

  /// A cache belonging to ONE renderer.
  ///
  /// A cached widget is not a pure function of its definition: the event
  /// closures inside it capture the `RenderContext` that built it — its state
  /// manager, its action handler, its engine. Sharing one map across renderers
  /// therefore hands the second document a widget wired to the FIRST
  /// document's state, and a `binding` write lands in the wrong place with
  /// nothing on screen to say so. `MCPUIRuntime.destroy` used to paper over
  /// the sequential half of this by clearing the singleton; two runtimes ALIVE
  /// at once — a dashboard tile beside an open app — had no such protection.
  ///
  /// Storage is per instance; the on/off switch stays global, because it is a
  /// host policy rather than a property of one document.
  WidgetCache.isolated();

  final Map<String, Widget> _cache = {};
  final Map<String, int> _hitCount = {};
  final Map<String, DateTime> _lastAccessed = {};
  final MCPLogger _logger = MCPLogger('WidgetCache');

  static const int _maxCacheSize = 100;
  /// How long an entry stays fresh.
  ///
  /// Settable because a fixed thirty minutes means the expiry path can only
  /// be seen by waiting half an hour — the code was there, and whether it
  /// removed the right entries was nobody's knowledge. A host may also shorten
  /// it for a screen whose widgets go stale sooner.
  static Duration maxAge = const Duration(minutes: 30);

  /// Generate cache key from widget definition
  String _generateKey(
      Map<String, dynamic> definition, Map<String, dynamic>? context) {
    final content = {
      'definition': definition,
      'context': context,
    };
    final jsonString = jsonEncode(content);
    final bytes = utf8.encode(jsonString);
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 16); // Use first 16 chars
  }

  /// Get cached widget if available
  Widget? get(Map<String, dynamic> definition, Map<String, dynamic>? context) {
    if (!_enabled) {
      return null; // Don't return cached widgets if caching is disabled
    }

    final key = _generateKey(definition, context);

    if (_cache.containsKey(key)) {
      final widget = _cache[key];
      if (widget != null && !_isExpired(key)) {
        _hitCount[key] = (_hitCount[key] ?? 0) + 1;
        _lastAccessed[key] = DateTime.now();
        _logger.debug('Cache hit for key: $key (hits: ${_hitCount[key]})');
        return widget;
      } else {
        // Remove expired entry
        _removeEntry(key);
      }
    }

    return null;
  }

  /// Cache a widget
  void put(Map<String, dynamic> definition, Map<String, dynamic>? context,
      Widget widget) {
    if (!_enabled) {
      return; // Don't cache if caching is disabled
    }

    final key = _generateKey(definition, context);

    // Check cache size limit
    if (_cache.length >= _maxCacheSize) {
      _evictOldest();
    }

    _cache[key] = widget;
    _hitCount[key] = 0;
    _lastAccessed[key] = DateTime.now();

    _logger
        .debug('Cached widget with key: $key (cache size: ${_cache.length})');
  }

  /// Check if entry is expired
  bool _isExpired(String key) {
    final lastAccessed = _lastAccessed[key];
    if (lastAccessed == null) return true;

    return DateTime.now().difference(lastAccessed) > maxAge;
  }

  /// Remove a cache entry
  void _removeEntry(String key) {
    _cache.remove(key);
    _hitCount.remove(key);
    _lastAccessed.remove(key);
    _logger.debug('Removed cache entry: $key');
  }

  /// Evict oldest entry
  void _evictOldest() {
    if (_lastAccessed.isEmpty) return;

    String? oldestKey;
    DateTime? oldestTime;

    for (final entry in _lastAccessed.entries) {
      if (oldestTime == null || entry.value.isBefore(oldestTime)) {
        oldestTime = entry.value;
        oldestKey = entry.key;
      }
    }

    if (oldestKey != null) {
      _removeEntry(oldestKey);
      _logger.debug('Evicted oldest cache entry: $oldestKey');
    }
  }

  /// Clear all cache
  void clear() {
    final count = _cache.length;
    _cache.clear();
    _hitCount.clear();
    _lastAccessed.clear();
    _logger.debug('Cleared all cache entries ($count items)');
  }

  /// Clear expired entries
  void clearExpired() {
    final now = DateTime.now();
    final expiredKeys = <String>[];

    for (final entry in _lastAccessed.entries) {
      if (now.difference(entry.value) > maxAge) {
        expiredKeys.add(entry.key);
      }
    }

    for (final key in expiredKeys) {
      _removeEntry(key);
    }

    if (expiredKeys.isNotEmpty) {
      _logger.debug('Cleared ${expiredKeys.length} expired cache entries');
    }
  }

  /// Get cache statistics
  Map<String, dynamic> getStatistics() {
    final totalHits = _hitCount.values.fold(0, (sum, hits) => sum + hits);
    final avgHits = _hitCount.isNotEmpty ? totalHits / _hitCount.length : 0;

    return {
      'size': _cache.length,
      'maxSize': _maxCacheSize,
      'totalHits': totalHits,
      'averageHits': avgHits.toStringAsFixed(2),
      'hitRate': _cache.isNotEmpty
          ? (totalHits / _cache.length).toStringAsFixed(2)
          : '0',
    };
  }

  /// Enable or disable caching globally
  static bool _enabled = true;
  bool get enabled => _enabled;

  void enable() {
    _enabled = true;
    _logger.debug('Widget cache enabled');
  }

  void disable() {
    _enabled = false;
    clear();
    _logger.debug('Widget cache disabled and cleared');
  }
}
