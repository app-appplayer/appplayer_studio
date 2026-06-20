/// File action executor for MCP UI DSL v1.1
///
/// Handles file selection, reading, and writing operations.
library file_action_executor;

import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../../actions/action_result.dart';
import '../../renderer/render_context.dart';

/// Executes file-related client actions
class FileActionExecutor {
  /// Select files using a file picker dialog
  Future<ActionResult> selectFile(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    try {
      // Extract parameters
      final multiple = action['multiple'] as bool? ?? false;
      final dialogTitle = action['title'] as String?;

      // Support both flat allowedExtensions list and spec filter objects
      // Spec format: [{"name": "Images", "extensions": ["png", "jpg"]}]
      // Flat format: ["png", "jpg"]
      List<String>? allowedExtensions;
      final filters = action['filters'] as List<dynamic>?;
      if (filters != null && filters.isNotEmpty) {
        allowedExtensions = filters
            .whereType<Map<String, dynamic>>()
            .expand((f) => (f['extensions'] as List<dynamic>? ?? []))
            .cast<String>()
            .map((e) => e.replaceAll('.', ''))
            .toList();
      } else {
        allowedExtensions = (action['allowedExtensions'] as List<dynamic>?)
            ?.cast<String>()
            .map((e) => e.replaceAll('.', ''))
            .toList();
      }

      // Determine file type
      FileType fileType = FileType.any;
      if (allowedExtensions != null && allowedExtensions.isNotEmpty) {
        fileType = FileType.custom;
      }

      // Show file picker
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: multiple,
        type: fileType,
        allowedExtensions: fileType == FileType.custom ? allowedExtensions : null,
        dialogTitle: dialogTitle,
      );

      if (result == null || result.files.isEmpty) {
        return ActionResult.success(data: null);
      }

      if (multiple) {
        final files = result.files.map((file) => {
          'name': file.name,
          'path': file.path,
          'size': file.size,
          'extension': file.extension,
        }).toList();
        return ActionResult.success(data: files);
      } else {
        final file = result.files.first;
        return ActionResult.success(data: {
          'name': file.name,
          'path': file.path,
          'size': file.size,
          'extension': file.extension,
        });
      }
    } catch (e) {
      return ActionResult.error('Failed to select file: $e');
    }
  }

  /// Read file content
  Future<ActionResult> readFile(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    // Web platform doesn't support direct file reading
    if (kIsWeb) {
      return ActionResult.error('File reading not supported on web platform');
    }

    try {
      final path = action['path'] as String?;
      if (path == null) {
        return ActionResult.error('Path parameter is required');
      }

      final encoding = action['encoding'] as String? ?? 'utf-8';
      final asBinary = action['binary'] as bool? ?? false;

      final file = File(path);

      if (!await file.exists()) {
        return ActionResult.error('File not found: $path');
      }

      final stat = await file.stat();
      final mimeType = _getMimeType(path);
      final lastModified = stat.modified.toIso8601String();

      if (asBinary) {
        final bytes = await file.readAsBytes();
        return ActionResult.success(data: {
          'path': path,
          'content': bytes,
          'size': bytes.length,
          'binary': true,
          'mimeType': mimeType,
          'lastModified': lastModified,
        });
      } else {
        final content = await file.readAsString(
          encoding: _getEncoding(encoding),
        );
        return ActionResult.success(data: {
          'path': path,
          'content': content,
          'size': content.length,
          'binary': false,
          'mimeType': mimeType,
          'lastModified': lastModified,
        });
      }
    } catch (e) {
      return ActionResult.error('Failed to read file: $e');
    }
  }

  /// Write content to a file
  Future<ActionResult> writeFile(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    // Web platform doesn't support direct file writing
    if (kIsWeb) {
      return ActionResult.error('File writing not supported on web platform');
    }

    try {
      final path = action['path'] as String?;
      if (path == null) {
        return ActionResult.error('Path parameter is required');
      }

      final content = action['content'];
      if (content == null) {
        return ActionResult.error('Content parameter is required');
      }

      final encoding = action['encoding'] as String? ?? 'utf-8';
      final append = action['append'] as bool? ?? false;
      final createDirectory = action['createDirectory'] as bool? ?? true;

      final file = File(path);
      final existedBefore = await file.exists();

      // Create parent directory if needed
      if (createDirectory) {
        final parent = file.parent;
        if (!await parent.exists()) {
          await parent.create(recursive: true);
        }
      }

      // Write content
      if (content is List<int>) {
        // Binary content
        if (append && await file.exists()) {
          final existing = await file.readAsBytes();
          await file.writeAsBytes([...existing, ...content]);
        } else {
          await file.writeAsBytes(content);
        }
      } else {
        // Text content
        final textContent = content.toString();
        if (append) {
          await file.writeAsString(
            textContent,
            mode: FileMode.append,
            encoding: _getEncoding(encoding),
          );
        } else {
          await file.writeAsString(
            textContent,
            encoding: _getEncoding(encoding),
          );
        }
      }

      final stat = await file.stat();
      return ActionResult.success(data: {
        'path': path,
        'size': stat.size,
        'modified': stat.modified.toIso8601String(),
        'created': !existedBefore,
        'overwritten': existedBefore,
      });
    } catch (e) {
      return ActionResult.error('Failed to write file: $e');
    }
  }

  /// Save file with Save-As dialog
  Future<ActionResult> saveFile(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    try {
      final content = action['content'];
      if (content == null) {
        return ActionResult.error('Content parameter is required');
      }

      final fileName = action['fileName'] as String?;
      final allowedExtensions = (action['allowedExtensions'] as List<dynamic>?)
          ?.cast<String>()
          .map((e) => e.replaceAll('.', ''))
          .toList();
      final dialogTitle = action['title'] as String?;

      FileType fileType = FileType.any;
      if (allowedExtensions != null && allowedExtensions.isNotEmpty) {
        fileType = FileType.custom;
      }

      final result = await FilePicker.platform.saveFile(
        dialogTitle: dialogTitle ?? 'Save File',
        fileName: fileName,
        type: fileType,
        allowedExtensions: fileType == FileType.custom ? allowedExtensions : null,
      );

      if (result == null) {
        return ActionResult.success(data: null);
      }

      if (!kIsWeb) {
        final file = File(result);
        final parent = file.parent;
        if (!await parent.exists()) {
          await parent.create(recursive: true);
        }

        if (content is List<int>) {
          await file.writeAsBytes(content);
        } else {
          final encoding = action['encoding'] as String? ?? 'utf-8';
          await file.writeAsString(
            content.toString(),
            encoding: _getEncoding(encoding),
          );
        }

        final stat = await file.stat();
        return ActionResult.success(data: {
          'path': result,
          'size': stat.size,
          'modified': stat.modified.toIso8601String(),
        });
      }

      return ActionResult.success(data: {
        'path': result,
      });
    } catch (e) {
      return ActionResult.error('Failed to save file: $e');
    }
  }

  /// List files in a directory
  Future<ActionResult> listFiles(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    if (kIsWeb) {
      return ActionResult.error('File listing not supported on web platform');
    }

    try {
      final path = action['path'] as String?;
      if (path == null) {
        return ActionResult.error('Path parameter is required');
      }

      final pattern = action['pattern'] as String?;
      final recursive = action['recursive'] as bool? ?? false;
      final sortBy = action['sortBy'] as String?;
      final limit = action['limit'] as int?;
      final includeHidden = action['includeHidden'] as bool? ?? false;

      final directory = Directory(path);
      if (!await directory.exists()) {
        return ActionResult.error('Directory not found: $path');
      }

      final entities = await directory
          .list(recursive: recursive)
          .where((entity) {
            final name = entity.path.split(Platform.pathSeparator).last;
            // Filter hidden files unless includeHidden is true
            if (!includeHidden && name.startsWith('.')) return false;
            if (pattern == null) return true;
            return RegExp(pattern).hasMatch(name);
          })
          .toList();

      var files = <Map<String, dynamic>>[];
      for (final entity in entities) {
        final stat = await entity.stat();
        files.add({
          'path': entity.path,
          'name': entity.path.split(Platform.pathSeparator).last,
          'type': stat.type == FileSystemEntityType.directory
              ? 'directory'
              : 'file',
          'size': stat.size,
          'modified': stat.modified.toIso8601String(),
        });
      }

      // Sort results based on sortBy parameter
      if (sortBy != null) {
        files.sort((a, b) {
          switch (sortBy) {
            case 'name':
              return (a['name'] as String).compareTo(b['name'] as String);
            case 'size':
              return (a['size'] as int).compareTo(b['size'] as int);
            case 'modified':
              return (a['modified'] as String).compareTo(b['modified'] as String);
            case 'type':
              return (a['type'] as String).compareTo(b['type'] as String);
            default:
              return 0;
          }
        });
      }

      // Apply limit if provided
      if (limit != null && limit > 0 && files.length > limit) {
        files = files.take(limit).toList();
      }

      return ActionResult.success(data: {
        'path': path,
        'files': files,
        'count': files.length,
      });
    } catch (e) {
      return ActionResult.error('Failed to list files: $e');
    }
  }

  /// Get MIME type from file extension
  String _getMimeType(String path) {
    final ext = path.split('.').last.toLowerCase();
    const mimeTypes = {
      'txt': 'text/plain',
      'html': 'text/html',
      'htm': 'text/html',
      'css': 'text/css',
      'js': 'application/javascript',
      'json': 'application/json',
      'xml': 'application/xml',
      'pdf': 'application/pdf',
      'zip': 'application/zip',
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'gif': 'image/gif',
      'svg': 'image/svg+xml',
      'mp3': 'audio/mpeg',
      'mp4': 'video/mp4',
      'csv': 'text/csv',
      'dart': 'text/x-dart',
      'yaml': 'text/yaml',
      'yml': 'text/yaml',
      'md': 'text/markdown',
    };
    return mimeTypes[ext] ?? 'application/octet-stream';
  }

  /// Get encoding from string name
  Encoding _getEncoding(String name) {
    switch (name.toLowerCase()) {
      case 'utf-8':
      case 'utf8':
        return utf8;
      case 'latin1':
      case 'iso-8859-1':
        return latin1;
      case 'ascii':
        return ascii;
      default:
        return utf8;
    }
  }
}
