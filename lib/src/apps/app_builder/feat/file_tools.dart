import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Outcome of a file-tool call. The LLM dispatch wraps this into a
/// `ChatTurn` so the user sees what changed.
class FileToolResult {
  FileToolResult._({
    required this.success,
    required this.message,
    this.path,
    this.entries,
  });

  factory FileToolResult.success({
    required String message,
    String? path,
    List<String>? entries,
  }) => FileToolResult._(
    success: true,
    message: message,
    path: path,
    entries: entries,
  );

  factory FileToolResult.failure(String message, {String? path}) =>
      FileToolResult._(success: false, message: message, path: path);

  final bool success;
  final String message;
  final String? path;
  final List<String>? entries;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ok': success,
    'message': message,
    if (path != null) 'path': path,
    if (entries != null) 'entries': entries,
  };
}

/// Sandbox-bounded file ops the LLM may call to drive code generation
/// inside the project (server templates, native handlers, build
/// scripts, …). Every path is resolved relative to [projectRoot] and
/// rejected when it escapes that root — protecting the user's wider
/// disk from a misfired tool call.
class FileToolsDispatcher {
  FileToolsDispatcher({required this.projectRoot, this.onAfterMutate});

  /// Absolute project folder. All file ops are rooted here.
  final String projectRoot;

  /// Fired after every successful mutation (write / edit / delete /
  /// make_dir). The host hook uses this to refresh derivative state
  /// — most importantly the per-channel dirty cache, since a direct
  /// file write into `bundles/<id>.mbd/...` bypasses the canonical
  /// patch pipeline and would otherwise leave the orange "unsaved"
  /// dot dark even though disk now diverges from canonical's
  /// in-memory state.
  final Future<void> Function(String absPath)? onAfterMutate;

  /// Resolve [rel] against [projectRoot] and ensure it stays inside.
  /// Rejects absolute paths and `..` walks above the root.
  String? _resolve(String rel) {
    if (p.isAbsolute(rel)) return null;
    final normalized = p.normalize(p.join(projectRoot, rel));
    final canonicalRoot = p.normalize(projectRoot);
    if (!p.isWithin(canonicalRoot, normalized) && normalized != canonicalRoot) {
      return null;
    }
    return normalized;
  }

  Future<FileToolResult> writeFile({
    required String path,
    required String content,
    bool createDirs = true,
  }) async {
    final abs = _resolve(path);
    if (abs == null) {
      return FileToolResult.failure(
        'path escapes the project root',
        path: path,
      );
    }
    try {
      if (createDirs) {
        await Directory(p.dirname(abs)).create(recursive: true);
      }
      await File(abs).writeAsString(content);
      await onAfterMutate?.call(abs);
      return FileToolResult.success(
        message: 'wrote ${content.length} bytes',
        path: path,
      );
    } catch (e) {
      return FileToolResult.failure('write failed: $e', path: path);
    }
  }

  Future<FileToolResult> editFile({
    required String path,
    required String oldString,
    required String newString,
  }) async {
    final abs = _resolve(path);
    if (abs == null) {
      return FileToolResult.failure(
        'path escapes the project root',
        path: path,
      );
    }
    final file = File(abs);
    if (!await file.exists()) {
      return FileToolResult.failure('file not found', path: path);
    }
    try {
      final original = await file.readAsString();
      final firstIndex = original.indexOf(oldString);
      if (firstIndex < 0) {
        return FileToolResult.failure(
          'oldString not found in file',
          path: path,
        );
      }
      final secondIndex = original.indexOf(oldString, firstIndex + 1);
      if (secondIndex >= 0) {
        return FileToolResult.failure(
          'oldString matches multiple times — narrow the snippet',
          path: path,
        );
      }
      final updated = original.replaceRange(
        firstIndex,
        firstIndex + oldString.length,
        newString,
      );
      await file.writeAsString(updated);
      await onAfterMutate?.call(abs);
      return FileToolResult.success(
        message: 'replaced ${oldString.length} → ${newString.length} bytes',
        path: path,
      );
    } catch (e) {
      return FileToolResult.failure('edit failed: $e', path: path);
    }
  }

  Future<FileToolResult> makeDir({required String path}) async {
    final abs = _resolve(path);
    if (abs == null) {
      return FileToolResult.failure(
        'path escapes the project root',
        path: path,
      );
    }
    try {
      await Directory(abs).create(recursive: true);
      await onAfterMutate?.call(abs);
      return FileToolResult.success(message: 'directory ready', path: path);
    } catch (e) {
      return FileToolResult.failure('mkdir failed: $e', path: path);
    }
  }

  Future<FileToolResult> deleteFile({required String path}) async {
    final abs = _resolve(path);
    if (abs == null) {
      return FileToolResult.failure(
        'path escapes the project root',
        path: path,
      );
    }
    final file = File(abs);
    final dir = Directory(abs);
    try {
      if (await file.exists()) {
        await file.delete();
        await onAfterMutate?.call(abs);
        return FileToolResult.success(message: 'file deleted', path: path);
      }
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        await onAfterMutate?.call(abs);
        return FileToolResult.success(message: 'directory deleted', path: path);
      }
      return FileToolResult.failure('not found', path: path);
    } catch (e) {
      return FileToolResult.failure('delete failed: $e', path: path);
    }
  }

  Future<FileToolResult> readFile({required String path}) async {
    final abs = _resolve(path);
    if (abs == null) {
      return FileToolResult.failure(
        'path escapes the project root',
        path: path,
      );
    }
    final file = File(abs);
    if (!await file.exists()) {
      return FileToolResult.failure('file not found', path: path);
    }
    try {
      final content = await file.readAsString();
      // The result map's `entries` field is reused as the content
      // payload — keeps the JSON shape stable across the four ops.
      return FileToolResult.success(
        message: 'read ${content.length} bytes',
        path: path,
        entries: <String>[content],
      );
    } catch (e) {
      return FileToolResult.failure('read failed: $e', path: path);
    }
  }

  Future<FileToolResult> listDir({required String path}) async {
    final abs = _resolve(path);
    if (abs == null) {
      return FileToolResult.failure(
        'path escapes the project root',
        path: path,
      );
    }
    final dir = Directory(abs);
    if (!await dir.exists()) {
      return FileToolResult.failure('directory not found', path: path);
    }
    try {
      final entries = <String>[];
      await for (final e in dir.list(followLinks: false)) {
        final rel = p.relative(e.path, from: projectRoot);
        entries.add(e is Directory ? '$rel/' : rel);
      }
      entries.sort();
      return FileToolResult.success(
        message: '${entries.length} entries',
        path: path,
        entries: entries,
      );
    } catch (e) {
      return FileToolResult.failure('list failed: $e', path: path);
    }
  }

  /// Tool schemas advertised to the LLM. Mirror the [FileToolsDispatcher]
  /// methods one-to-one. The dispatcher in [vibeLlm] inspects the
  /// `name` to route the call.
  static const List<Map<String, dynamic>> toolDefinitions =
      <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'write_file',
          'description':
              'Write a UTF-8 text file inside the project. Replaces existing '
              'content. Use this for fresh files or wholesale rewrites.',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'path': <String, dynamic>{
                'type': 'string',
                'description':
                    'Project-relative path. Must stay inside the project '
                    'folder; absolute paths and `..` escapes are rejected.',
              },
              'content': <String, dynamic>{
                'type': 'string',
                'description': 'Full file content as UTF-8 text.',
              },
            },
            'required': <String>['path', 'content'],
          },
        },
        <String, dynamic>{
          'name': 'edit_file',
          'description':
              'Edit an existing text file by replacing exactly one occurrence '
              'of `oldString` with `newString`. Fails when oldString '
              'appears zero or multiple times — caller must narrow the '
              'snippet so it is unique.',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'path': <String, dynamic>{'type': 'string'},
              'oldString': <String, dynamic>{
                'type': 'string',
                'description':
                    'The exact substring to replace. Include enough context '
                    'lines to be unique.',
              },
              'newString': <String, dynamic>{
                'type': 'string',
                'description':
                    'Replacement text. Empty string deletes the snippet.',
              },
            },
            'required': <String>['path', 'oldString', 'newString'],
          },
        },
        <String, dynamic>{
          'name': 'make_dir',
          'description':
              'Ensure a directory (and parents) exists inside the project. '
              'Use for empty scaffold folders; `write_file` already '
              'auto-creates the parents of any file you write.',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'path': <String, dynamic>{'type': 'string'},
            },
            'required': <String>['path'],
          },
        },
        <String, dynamic>{
          'name': 'delete_file',
          'description':
              'Delete a file or directory inside the project. Recursive for '
              'directories. No-op when the target is missing.',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'path': <String, dynamic>{'type': 'string'},
            },
            'required': <String>['path'],
          },
        },
        <String, dynamic>{
          'name': 'read_file',
          'description':
              'Read a text file from the project. Returns the full UTF-8 '
              'content in the result entries[0].',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'path': <String, dynamic>{'type': 'string'},
            },
            'required': <String>['path'],
          },
        },
        <String, dynamic>{
          'name': 'list_dir',
          'description':
              'List entries (files + subdirectories) under a project-relative '
              'directory. Returns sorted relative paths; directory entries '
              'end with `/`.',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'path': <String, dynamic>{'type': 'string'},
            },
            'required': <String>['path'],
          },
        },
      ];

  /// Dispatch the named call against this sandbox. Returns null when
  /// the name is not one of [toolDefinitions] (so the LLM router can
  /// fall through to other dispatchers).
  Future<FileToolResult?> dispatch(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'write_file':
        return writeFile(
          path: args['path'] as String? ?? '',
          content: args['content'] as String? ?? '',
        );
      case 'edit_file':
        return editFile(
          path: args['path'] as String? ?? '',
          oldString: args['oldString'] as String? ?? '',
          newString: args['newString'] as String? ?? '',
        );
      case 'make_dir':
        return makeDir(path: args['path'] as String? ?? '');
      case 'delete_file':
        return deleteFile(path: args['path'] as String? ?? '');
      case 'read_file':
        return readFile(path: args['path'] as String? ?? '');
      case 'list_dir':
        return listDir(path: args['path'] as String? ?? '');
      default:
        return null;
    }
  }

  /// Tool names the dispatcher claims — used by the LLM tool router to
  /// decide whether to route a call here.
  static const Set<String> claimedTools = <String>{
    'write_file',
    'edit_file',
    'make_dir',
    'delete_file',
    'read_file',
    'list_dir',
  };
}

/// Helper for callers that want to encode a [FileToolResult] back into
/// the LLM tool-result JSON shape without importing the class itself.
String encodeFileToolResult(FileToolResult r) => jsonEncode(r.toJson());
