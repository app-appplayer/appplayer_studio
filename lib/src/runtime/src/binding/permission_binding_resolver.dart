/// Permission binding resolver for MCP UI DSL v1.1
///
/// Resolves {{permissions.*}} bindings to permission status values.
/// Integrates with PermissionManager to check whether specific
/// permissions are configured and available.
library permission_binding_resolver;

import '../permissions/permission_checker.dart';
import '../models/ui_definition.dart';
import '../utils/mcp_logger.dart';

/// Resolves permission-related binding expressions
class PermissionBindingResolver {
  final MCPLogger _logger = MCPLogger('PermissionBindingResolver');

  /// Permission checker for validating permissions
  PermissionChecker? _checker;

  /// Set the permission checker
  void setChecker(PermissionChecker checker) {
    _checker = checker;
  }

  /// Initialize with a permissions config
  void initialize(PermissionsConfig? config) {
    _checker = PermissionChecker(config);
  }

  /// Check if a binding expression is a permissions binding
  bool isPermissionBinding(String expression) {
    return expression.startsWith('{{permissions.') &&
        expression.endsWith('}}');
  }

  /// Extract the permission path from an expression
  String? extractPath(String expression) {
    if (!isPermissionBinding(expression)) return null;
    return expression.substring(14, expression.length - 2);
  }

  /// Resolve a permissions binding expression
  ///
  /// Supported patterns:
  /// - `permissions.file.read` -> whether file read permission is configured
  /// - `permissions.file.write` -> whether file write permission is configured
  /// - `permissions.network.http` -> whether HTTP permission is configured
  /// - `permissions.shell` -> whether shell execution is configured
  /// - `permissions.clipboard` -> whether clipboard access is configured
  /// - `permissions.notification` -> whether notification is configured
  /// - `permissions.systemInfo` -> whether system info access is configured
  dynamic resolve(String expression) {
    final path = extractPath(expression);
    if (path == null) return null;

    return _resolvePermission(path);
  }

  /// Resolve a permission path to a boolean status
  dynamic _resolvePermission(String path) {
    if (_checker == null) {
      _logger.warning(
          'PermissionChecker not initialized, returning false for: $path');
      return false;
    }

    // Strip .status suffix if present (e.g., 'file.read.status' -> 'file.read')
    final normalizedPath = path.endsWith('.status')
        ? path.substring(0, path.length - 7)
        : path;

    switch (normalizedPath) {
      case 'file.read':
        return _checker!.checkFileRead('/').allowed;

      case 'file.write':
        return _checker!.checkFileWrite('/').allowed;

      case 'network.http':
        return _checker!.checkHttp('https://example.com').allowed;

      case 'shell':
      case 'system.exec':
        return _checker!.checkShellExec('echo').allowed;

      case 'clipboard':
      case 'system.clipboard':
        return _checker!.checkClipboard().allowed;

      case 'notification':
        return _checker!.checkNotification().allowed;

      case 'systemInfo':
      case 'system.info':
        return _checker!.checkSystemInfo().allowed;

      default:
        _logger.warning('Unknown permission path: $path');
        return false;
    }
  }

  /// Get all supported permission binding paths
  static List<String> get supportedPaths => [
        'file.read',
        'file.write',
        'network.http',
        'shell',
        'system.exec',
        'clipboard',
        'system.clipboard',
        'notification',
        'systemInfo',
        'system.info',
      ];
}
