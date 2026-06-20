/// Sync binding resolver for MCP UI DSL v1.1
///
/// Resolves {{sync.*}} bindings to sync state values from SyncManager.
library sync_binding_resolver;

import '../offline/sync_manager.dart';
import '../utils/mcp_logger.dart';

/// Resolves sync-related binding expressions
class SyncBindingResolver {
  final MCPLogger _logger = MCPLogger('SyncBindingResolver');

  /// The sync manager providing backing data
  SyncManager? _syncManager;

  /// Set the sync manager instance for resolving bindings
  void setSyncManager(SyncManager syncManager) {
    _syncManager = syncManager;
  }

  /// Check if a binding expression is a sync binding
  bool isSyncBinding(String expression) {
    return expression.startsWith('{{sync.') && expression.endsWith('}}');
  }

  /// Resolve a sync binding expression
  ///
  /// Supported bindings:
  /// - {{sync.pending}} — bool, whether actions are pending
  /// - {{sync.pendingCount}} — int, number of queued actions
  /// - {{sync.syncing}} — bool, whether sync is in progress
  /// - {{sync.saving}} — bool, alias for syncing
  /// - {{sync.lastSyncAt}} — string, ISO 8601 timestamp of last sync
  /// - {{sync.syncedCount}} — int, actions synced in last batch
  /// - {{sync.failedCount}} — int, actions failed in last sync
  /// - {{sync.status}} — string, sync status enum name
  /// - {{sync.lastError}} — string, last error message
  dynamic resolve(String expression) {
    if (!isSyncBinding(expression)) return null;

    final path = expression.substring(7, expression.length - 2);
    final manager = _syncManager;

    if (manager == null) {
      _logger.warning('SyncManager not configured for sync binding: $path');
      return null;
    }

    switch (path) {
      case 'pending':
        return manager.hasPending;
      case 'pendingCount':
        return manager.pendingCount;
      case 'syncing':
        return manager.status == SyncStatus.syncing;
      case 'saving':
        return manager.status == SyncStatus.syncing;
      case 'lastSyncAt':
        return manager.lastSyncTime?.toIso8601String();
      case 'syncedCount':
        return manager.syncedCount;
      case 'failedCount':
        return manager.failedCount;
      case 'status':
        return manager.status.name;
      case 'lastError':
        return manager.lastError;
      default:
        _logger.warning('Unknown sync binding path: $path');
        return null;
    }
  }
}
