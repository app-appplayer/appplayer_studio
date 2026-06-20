/// Storage action executor for MCP UI DSL v1.1
///
/// Handles client.storage.set, client.storage.get, and client.storage.remove actions.
/// Uses an in-memory storage backend. A production implementation would use
/// SharedPreferences or another persistent storage mechanism.
library storage_action_executor;

import '../../actions/action_result.dart';
import '../../renderer/render_context.dart';

/// Executes storage-related client actions
class StorageActionExecutor {
  /// In-memory storage backend
  final Map<String, dynamic> _storage = {};

  /// Execute a storage action based on its type
  Future<ActionResult> execute(
    String actionType,
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    switch (actionType) {
      case 'client.storage.set':
        return _set(action);
      case 'client.storage.get':
        return _get(action);
      case 'client.storage.remove':
        return _remove(action);
      default:
        return ActionResult.error(
          'Unknown storage action: $actionType',
          errorCode: 'UNKNOWN_ACTION',
        );
    }
  }

  /// Extract a parameter supporting both nested (params.key) and flat (key) formats (P6)
  dynamic _param(Map<String, dynamic> action, String name) {
    final params = action['params'] as Map<String, dynamic>?;
    return params?[name] ?? action[name];
  }

  /// Set a value in storage
  Future<ActionResult> _set(Map<String, dynamic> action) async {
    try {
      final key = _param(action, 'key') as String?;
      if (key == null) {
        return ActionResult.error(
          'Key parameter is required',
          errorCode: 'MISSING_PARAM',
        );
      }

      final value = _param(action, 'value');
      _storage[key] = value;

      return ActionResult.success(data: {
        'key': key,
        'value': value,
      });
    } catch (e) {
      return ActionResult.error('Failed to set storage value: $e');
    }
  }

  /// Get a value from storage
  Future<ActionResult> _get(Map<String, dynamic> action) async {
    try {
      final key = _param(action, 'key') as String?;
      if (key == null) {
        return ActionResult.error(
          'Key parameter is required',
          errorCode: 'MISSING_PARAM',
        );
      }

      final value = _storage[key];
      final defaultValue = _param(action, 'defaultValue');

      return ActionResult.success(data: {
        'key': key,
        'value': value ?? defaultValue,
        'exists': _storage.containsKey(key),
      });
    } catch (e) {
      return ActionResult.error('Failed to get storage value: $e');
    }
  }

  /// Remove a value from storage
  Future<ActionResult> _remove(Map<String, dynamic> action) async {
    try {
      final key = _param(action, 'key') as String?;
      if (key == null) {
        return ActionResult.error(
          'Key parameter is required',
          errorCode: 'MISSING_PARAM',
        );
      }

      final existed = _storage.containsKey(key);
      _storage.remove(key);

      return ActionResult.success(data: {
        'key': key,
        'removed': existed,
      });
    } catch (e) {
      return ActionResult.error('Failed to remove storage value: $e');
    }
  }

  /// Clear all storage (utility method)
  void clear() {
    _storage.clear();
  }

  /// Get all keys in storage (utility method)
  List<String> get keys => _storage.keys.toList();
}
