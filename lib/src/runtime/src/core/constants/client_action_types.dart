/// Client action type constants for MCP UI DSL v1.1
///
/// These action types are executed on the client side and require
/// appropriate permissions.
library client_action_types;

import '../../utils/path_validator.dart';

/// Client action type constants
class ClientActionTypes {
  ClientActionTypes._();

  /// File selection dialog
  /// Opens a file picker to select one or more files
  static const String selectFile = 'client.selectFile';

  /// Read file content
  /// Reads content from a file on the local filesystem
  static const String readFile = 'client.readFile';

  /// Write file content
  /// Writes content to a file on the local filesystem
  static const String writeFile = 'client.writeFile';

  /// HTTP request
  /// Makes an HTTP request to a specified URL
  static const String httpRequest = 'client.httpRequest';

  /// Get system information
  /// Returns platform, locale, and other system info
  static const String getSystemInfo = 'client.getSystemInfo';

  /// Execute shell command
  /// Runs a shell command with restricted allowlist
  static const String exec = 'client.exec';

  /// Clipboard operations (read/write)
  /// Uses params.action to distinguish: "read" or "write" (per Spec v1.1)
  static const String clipboard = 'client.clipboard';

  /// Show notification
  /// Displays a system notification
  static const String notification = 'client.notification';

  /// Save file with Save-As dialog
  /// Opens a save-as dialog to save content to a file
  static const String saveFile = 'client.saveFile';

  /// List files in a directory
  /// Lists files matching a pattern in a directory
  static const String listFiles = 'client.listFiles';

  /// Get a value from client storage
  static const String storageGet = 'client.storage.get';

  /// Set a value in client storage
  static const String storageSet = 'client.storage.set';

  /// Remove a value from client storage
  static const String storageRemove = 'client.storage.remove';

  /// All client action types
  static const List<String> all = [
    selectFile,
    readFile,
    writeFile,
    saveFile,
    listFiles,
    httpRequest,
    getSystemInfo,
    exec,
    clipboard,
    notification,
    storageGet,
    storageSet,
    storageRemove,
  ];

  /// Check if an action type is a client action
  static bool isClientAction(String? actionType) {
    if (actionType == null) return false;
    return actionType.startsWith('client.');
  }
}

/// Permission types for client actions
/// Uses dot-namespaced format per spec standard
class ClientPermissions {
  ClientPermissions._();

  /// Permission to read files
  static const String fileRead = 'file.read';

  /// Permission to write files
  static const String fileWrite = 'file.write';

  /// Permission to make HTTP requests
  static const String http = 'network.http';

  /// Permission to execute shell commands
  static const String shell = 'system.exec';

  /// Permission to access clipboard
  static const String clipboard = 'system.clipboard';

  /// Permission to show notifications
  static const String notification = 'system.notification';

  /// Permission to access system info
  static const String systemInfo = 'system.info';

  /// Permission to use WebSocket connections
  static const String websocket = 'network.websocket';

  /// Map action types to required permissions
  static String? getRequiredPermission(String actionType) {
    switch (actionType) {
      case ClientActionTypes.selectFile:
      case ClientActionTypes.readFile:
        return fileRead;
      case ClientActionTypes.writeFile:
      case ClientActionTypes.saveFile:
        return fileWrite;
      case ClientActionTypes.listFiles:
        return fileRead;
      case ClientActionTypes.httpRequest:
        return http;
      case ClientActionTypes.exec:
        return shell;
      case ClientActionTypes.clipboard:
        return clipboard;
      case ClientActionTypes.notification:
        return notification;
      case ClientActionTypes.getSystemInfo:
        return systemInfo;
      default:
        return null;
    }
  }
}

/// Client resource URI schemes
class ClientResourceSchemes {
  ClientResourceSchemes._();

  /// Protocol access: client://protocol/...
  static const String protocol = 'client://protocol';

  /// File system access: client://file/path/to/file
  static const String file = 'client://file';

  /// Workspace access: client://workspace/relative/path
  static const String workspace = 'client://workspace';

  /// Temporary files: client://temp/name
  static const String temp = 'client://temp';

  /// Cache storage: client://cache/key
  static const String cache = 'client://cache';

  /// Bundled application assets: client://asset/path
  static const String asset = 'client://asset';

  /// Parse a client resource URI with path security validation.
  ///
  /// Returns null if the URI is invalid or contains path traversal attempts.
  /// Paths are normalized to remove redundant separators and `.` segments.
  static ClientResourceUri? parse(String uri) {
    if (!uri.startsWith('client://')) return null;

    final withoutScheme = uri.substring('client://'.length);
    final slashIndex = withoutScheme.indexOf('/');

    if (slashIndex == -1) {
      return ClientResourceUri(
        scheme: withoutScheme,
        path: '',
      );
    }

    final scheme = withoutScheme.substring(0, slashIndex);
    final rawPath = withoutScheme.substring(slashIndex + 1);

    // Reject paths with traversal attempts (§Path Resolution Rules)
    if (PathValidator.hasTraversalAttempt(rawPath)) {
      return null;
    }

    // Normalize path: remove redundant slashes and `.` segments
    final normalizedPath = PathValidator.normalize(rawPath);

    return ClientResourceUri(
      scheme: scheme,
      path: normalizedPath,
    );
  }
}

/// Parsed client resource URI
class ClientResourceUri {
  final String scheme;
  final String path;

  const ClientResourceUri({
    required this.scheme,
    required this.path,
  });

  @override
  String toString() => 'client://$scheme/$path';
}

/// Channel types for bidirectional communication
class ChannelTypes {
  ChannelTypes._();

  /// Watch a single file for changes
  static const String fileWatch = 'client.watchFile';

  /// Watch a directory for changes
  static const String directoryWatch = 'client.watchDirectory';

  /// Monitor system metrics
  static const String systemMonitor = 'client.systemMonitor';

  /// Periodic polling
  static const String poll = 'client.poll';

  /// WebSocket bidirectional communication
  static const String websocket = 'client.websocket';
}
