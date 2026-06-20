/// `createProjectFolder` — shared disk-side scaffolding helper used by
/// `studio.project.create` (generic) and any domain-level wrapper
/// (e.g. `studio_builder.newProject`) that needs the same standard
/// project layout: a metadata file, a bundle subdir, `drafts/` +
/// `build/`, plus optional seed files.
///
/// Validates name + parent, refuses path traversal, never overwrites
/// an existing folder. Returns a serialisable result map; callers wrap
/// it in an MCP `CallToolResult`. Lives in `vibe_studio_base` so every
/// studio host (universal vibe_studio, future variants) reuses the
/// same disk layout verbatim — no duplicated string templates / extension
/// handling per host.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Create a workspace-scoped project folder at `<parent>/<name>/` with
/// the standard layout. Returns `{ok: true, projectPath, bundlePath,
/// metaFile}` on success or `{ok: false, error}` on failure.
///
/// * [name] — folder name (no path separators / `..`).
/// * [parent] — parent directory (typically the studio `workspaceDir`).
/// * [ext] — project metadata file extension. Default `.sbproj`.
/// * [bundleSubdir] — bundle subdirectory name under the project.
///   Default `<name>.mbd`.
/// * [initialFiles] — list of `{path, content}` maps. `path` is
///   relative to the new project folder; `content` is a string
///   (written verbatim) or any other value (encoded as pretty JSON).
Future<Map<String, Object?>> createProjectFolder({
  required String name,
  required String parent,
  String ext = '.sbproj',
  String? bundleSubdir,
  List<Map<String, dynamic>> initialFiles = const <Map<String, dynamic>>[],
}) async {
  Map<String, Object?> err(String msg) => <String, Object?>{
    'ok': false,
    'error': msg,
  };
  if (name.isEmpty) return err('name required');
  if (parent.isEmpty) return err('parent required');
  if (name.contains('/') || name.contains('..') || name.contains(r'\')) {
    return err('name must not contain path separators or ..');
  }
  final effectiveBundleSubdir = bundleSubdir ?? '$name.mbd';
  final projectPath = p.join(parent, name);
  final projectDir = Directory(projectPath);
  if (projectDir.existsSync()) {
    return err('project path already exists: $projectPath');
  }
  try {
    await projectDir.create(recursive: true);
    await Directory(p.join(projectPath, effectiveBundleSubdir)).create();
    await Directory(p.join(projectPath, 'drafts')).create();
    await Directory(p.join(projectPath, 'build')).create();
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final meta = <String, dynamic>{
      'schemaVersion': '0.1',
      'name': name,
      'createdAt': nowIso,
      'updatedAt': nowIso,
      'bundle': effectiveBundleSubdir,
      'channels': <String, dynamic>{
        'main': <String, dynamic>{'subdir': effectiveBundleSubdir},
      },
      'activeChannel': 'main',
    };
    final metaFile = File(p.join(projectPath, 'project$ext'));
    await metaFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(meta),
    );
    for (final entry in initialFiles) {
      final relPath = entry['path'];
      final content = entry['content'];
      if (relPath is! String || relPath.isEmpty) continue;
      if (relPath.contains('..')) continue;
      final fullPath = p.join(projectPath, relPath);
      final fileObj = File(fullPath);
      await fileObj.parent.create(recursive: true);
      String written;
      if (content is String) {
        written = content;
      } else if (content == null) {
        written = '';
      } else {
        written = const JsonEncoder.withIndent('  ').convert(content);
      }
      await fileObj.writeAsString(written);
    }
    return <String, Object?>{
      'ok': true,
      'projectPath': projectPath,
      'bundlePath': p.join(projectPath, effectiveBundleSubdir),
      'metaFile': metaFile.path,
    };
  } catch (e) {
    return err('create failed: $e');
  }
}
