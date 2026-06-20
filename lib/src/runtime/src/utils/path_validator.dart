/// Path security validation for client resource URIs.
///
/// Provides path traversal detection, normalization, and symlink validation
/// as specified in the design doc (§Path Resolution Rules).
library path_validator;

import 'dart:io';
import 'package:path/path.dart' as p;

/// Exception thrown when a path security violation is detected.
class PathSecurityException implements Exception {
  /// Description of the security violation
  final String message;

  const PathSecurityException(this.message);

  @override
  String toString() => 'PathSecurityException: $message';
}

/// Validates and normalizes resource paths to prevent traversal attacks.
///
/// Enforces three layers of path security:
/// 1. Path traversal rejection - rejects paths containing `..` segments
/// 2. Path normalization - removes redundant slashes and `.` segments
/// 3. Symlink resolution - validates resolved paths stay within allowed directories
class PathValidator {
  PathValidator._();

  /// Validates and normalizes a resource path.
  ///
  /// Throws [PathSecurityException] if a path traversal attempt is detected.
  /// Returns the normalized path with redundant separators and `.` segments removed.
  static String validateAndNormalize(String path) {
    if (hasTraversalAttempt(path)) {
      throw const PathSecurityException(
        'Path traversal attempt detected: ".." segments are not allowed',
      );
    }
    return normalize(path);
  }

  /// Checks if a path contains traversal attempts (`..` segments).
  ///
  /// Detects `..` as a standalone segment in the path, whether separated by
  /// forward slashes, backslashes, or at the start/end of the path.
  static bool hasTraversalAttempt(String path) {
    // Split on both forward and back slashes to catch all platforms
    final segments = path.split(RegExp(r'[/\\]'));
    return segments.any((segment) => segment == '..');
  }

  /// Normalizes a path by removing redundant separators and `.` segments.
  ///
  /// Examples:
  /// - `src//config.json` -> `src/config.json`
  /// - `./src/./config.json` -> `src/config.json`
  /// - `src/config.json` -> `src/config.json` (unchanged)
  static String normalize(String path) {
    if (path.isEmpty) return path;

    // Use posix context for URI paths (always forward slashes)
    final segments = path.split('/');
    final normalized = <String>[];

    for (final segment in segments) {
      // Skip empty segments (from redundant slashes) and current-dir markers
      if (segment.isEmpty || segment == '.') continue;
      normalized.add(segment);
    }

    // Preserve leading slash for absolute paths
    final prefix = path.startsWith('/') ? '/' : '';
    return '$prefix${normalized.join('/')}';
  }

  /// Validates that a resolved file path stays within the allowed root directory.
  ///
  /// Resolves symlinks to their real path, then checks that the result is
  /// still under [allowedRoot]. This prevents symlink-based escape attacks.
  ///
  /// Returns the resolved real path if valid.
  /// Throws [PathSecurityException] if the resolved path escapes [allowedRoot].
  static Future<String> validateSymlink(
    String filePath,
    String allowedRoot,
  ) async {
    final file = File(filePath);
    if (!await file.exists()) {
      // If file doesn't exist yet, just validate the normalized path
      final normalizedPath = p.normalize(filePath);
      final normalizedRoot = p.normalize(allowedRoot);
      if (!normalizedPath.startsWith(normalizedRoot)) {
        throw const PathSecurityException(
          'Path escapes allowed directory',
        );
      }
      return normalizedPath;
    }

    final resolvedPath = file.resolveSymbolicLinksSync();
    final normalizedResolved = p.normalize(resolvedPath);
    final normalizedRoot = p.normalize(allowedRoot);

    if (!normalizedResolved.startsWith(normalizedRoot)) {
      throw const PathSecurityException(
        'Symlink target escapes allowed directory',
      );
    }

    return normalizedResolved;
  }
}
