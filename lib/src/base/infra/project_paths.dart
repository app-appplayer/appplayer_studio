/// Host-level helper for **project-portable** file references.
///
/// A Studio project folder (App Builder / Ops / Scene Builder / any bundle-app
/// project) must be self-contained: every file link stored in project data is
/// kept RELATIVE to the project root, so the folder can be renamed, copied, or
/// moved without breaking. External content is exported INTO the project rather
/// than linked by absolute path.
///
/// This centralises the convention App Builder already follows
/// (`p.relative(path, from: projectRoot)`) so Ops, Scene Builder, and future
/// bundle apps share one implementation instead of re-rolling their own.
library;

import 'package:path/path.dart' as p;

/// Project-root-relative path normalisation + resolution.
class ProjectPaths {
  const ProjectPaths._();

  /// A stored reference that is NOT a project-relative filesystem path — an
  /// http(s) URL or the reserved `project://` scheme — is left untouched by
  /// [toRelative] / [resolve].
  static bool isExternalRef(String ref) =>
      ref.startsWith('http://') ||
      ref.startsWith('https://') ||
      ref.startsWith('project://');

  /// True when [path] resolves at or inside [projectRoot].
  static bool isInside(String projectRoot, String path) {
    if (projectRoot.isEmpty || path.isEmpty) return false;
    final root = p.normalize(p.absolute(projectRoot));
    final abs =
        p.isAbsolute(path)
            ? p.normalize(path)
            : p.normalize(p.join(root, path));
    return abs == root || p.isWithin(root, abs);
  }

  /// Normalise [path] to a project-root-relative path when it points inside
  /// [projectRoot]; otherwise return it unchanged.
  ///
  ///   * already relative        → normalised, returned as-is (assumed rooted
  ///                               at the project);
  ///   * absolute, inside project → made relative to [projectRoot];
  ///   * absolute, outside / URL  → returned unchanged (an external ref the
  ///                               caller is responsible for exporting).
  ///
  /// Empty inputs are returned unchanged. Relative results use POSIX
  /// separators so a project authored on one OS resolves on another.
  static String toRelative(String projectRoot, String path) {
    if (path.isEmpty || projectRoot.isEmpty) return path;
    if (isExternalRef(path)) return path;
    if (!p.isAbsolute(path)) return p.posix.normalize(_toPosix(path));
    if (!isInside(projectRoot, path)) return path; // external — leave as-is
    final rel = p.relative(
      p.normalize(path),
      from: p.normalize(p.absolute(projectRoot)),
    );
    return _toPosix(rel);
  }

  /// Resolve a [stored] reference against the CURRENT [projectRoot]. A relative
  /// stored ref rebinds to wherever the project now lives (portable); an
  /// absolute path or URL is returned unchanged.
  static String resolve(String projectRoot, String stored) {
    if (stored.isEmpty || projectRoot.isEmpty) return stored;
    if (isExternalRef(stored)) return stored;
    if (p.isAbsolute(stored)) return stored;
    return p.normalize(p.join(p.absolute(projectRoot), stored));
  }

  static String _toPosix(String path) => path.replaceAll(r'\', '/');
}
