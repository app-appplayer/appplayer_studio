import 'dart:convert';

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:path/path.dart' as p;

/// Resolves `bundle://` URIs to consumable asset references.
///
/// Composes with [BundleStoragePort] for asset I/O, following the
/// composition-over-inheritance pattern used by mcp_bundle's own adapters.
///
/// Resolution modes:
/// - **Online** (basePath == null): resolves to data URIs (base64)
/// - **Local** (basePath != null): resolves to local file paths
class BundleAssetProvider {
  final BundleStoragePort _storage;
  final String? _basePath;

  /// Size threshold in bytes for inline data URI encoding.
  /// Assets exceeding this size in online mode fall back to a URL reference
  /// instead of being inlined as base64 data URIs.
  static const int maxInlineBytes = 512 * 1024; // 512 KB

  /// Creates a BundleAssetProvider.
  ///
  /// [storage] — injected storage port for reading asset bytes.
  /// [basePath] — local base directory for unpacked bundle assets.
  ///   If null, assets are resolved as data URIs (online mode).
  ///   If non-null, assets are resolved as local file paths (local mode).
  BundleAssetProvider({
    required BundleStoragePort storage,
    String? basePath,
  })  : _storage = storage,
        _basePath = basePath;

  /// Resolve a `bundle://` URI to a consumable reference.
  ///
  /// Returns:
  /// - For non-`bundle://` URIs: the original URI unchanged (passthrough)
  /// - Data URI string (online mode): `data:image/png;base64,...`
  /// - Local file path (local mode): `/path/to/bundle/assets/icon.png`
  /// - `null` only on I/O errors (asset read failure)
  Future<String?> resolve(String uri) async {
    if (!uri.startsWith('bundle://')) return uri;

    final assetPath = uri.substring('bundle://'.length);

    if (_basePath != null) {
      // Local mode: return filesystem path using p.join for correct OS separators
      return p.join(_basePath!, assetPath);
    }

    // Online mode: read bytes and return data URI or URL reference
    try {
      final assetUri = Uri.parse(uri);
      final bytes = await _storage.readAsset(assetUri);

      // Large assets fall back to URL reference instead of inline data URI
      if (bytes.length > maxInlineBytes) {
        return uri;
      }

      final mimeType = _guessMimeType(assetPath);
      final base64Data = base64Encode(bytes);
      return 'data:$mimeType;base64,$base64Data';
    } catch (_) {
      return null;
    }
  }

  /// Whether the given string is a `bundle://` URI.
  static bool isBundleUri(String? value) =>
      value != null && value.startsWith('bundle://');

  /// Guess MIME type from file extension.
  static String _guessMimeType(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'svg' => 'image/svg+xml',
      'webp' => 'image/webp',
      'ico' => 'image/x-icon',
      'json' => 'application/json',
      _ => 'application/octet-stream',
    };
  }
}
