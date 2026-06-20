/// Resource binding resolver for MCP UI DSL v1.1
///
/// Resolves {{resources.*}} bindings to loaded resource data.
/// Resources are global, read-only data loaded from MCP resource subscriptions.
library resource_binding_resolver;

import '../utils/mcp_logger.dart';

/// Resolves resource-related binding expressions
class ResourceBindingResolver {
  final MCPLogger _logger = MCPLogger('ResourceBindingResolver');

  /// Cached resource data keyed by resource ID
  final Map<String, dynamic> _resourceData = {};

  /// Check if a binding expression is a resources binding
  bool isResourceBinding(String expression) {
    return expression.startsWith('{{resources.') && expression.endsWith('}}');
  }

  /// Extract the resource path from an expression
  String? extractPath(String expression) {
    if (!isResourceBinding(expression)) return null;
    return expression.substring(12, expression.length - 2);
  }

  /// Update cached data for a resource
  void updateResourceData(String resourceId, dynamic data) {
    _resourceData[resourceId] = data;
    _logger.debug('Resource data updated: $resourceId');
  }

  /// Remove cached data for a resource
  void removeResourceData(String resourceId) {
    _resourceData.remove(resourceId);
  }

  /// Resolve a resources binding expression
  ///
  /// Supported patterns:
  /// - `resources.{resourceId}` -> full resource data
  /// - `resources.{resourceId}.{path}` -> nested field from resource data
  ///
  /// Example: `{{resources.config.data}}`, `{{resources.settings.theme}}`
  dynamic resolve(String expression) {
    final path = extractPath(expression);
    if (path == null) return null;

    return _resolveResource(path);
  }

  /// Resolve a resource path
  dynamic _resolveResource(String path) {
    final parts = path.split('.');
    if (parts.isEmpty) return null;

    final resourceId = parts[0];

    // If only resource ID, return the full data
    if (parts.length == 1) {
      return _resourceData[resourceId];
    }

    // Navigate the remaining path through the data
    dynamic current = _resourceData[resourceId];
    if (current == null) {
      _logger.debug('Resource not found: $resourceId');
      return null;
    }

    for (int i = 1; i < parts.length; i++) {
      if (current is Map<String, dynamic>) {
        current = current[parts[i]];
      } else if (current is Map) {
        current = current[parts[i]];
      } else {
        return null;
      }
    }

    return current;
  }

  /// Check if a resource exists
  bool hasResource(String resourceId) {
    return _resourceData.containsKey(resourceId);
  }

  /// Get all loaded resource IDs
  List<String> get loadedResources => _resourceData.keys.toList();

  /// Clear all cached data
  void clearAll() {
    _resourceData.clear();
  }
}
