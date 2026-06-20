import 'dart:async';

import 'package:flutter/foundation.dart';

import 'offline_queue.dart';
import 'connectivity_manager.dart';
import '../state/state_manager.dart';

/// Sync status for MCP UI DSL v1.1
enum SyncStatus {
  /// No sync operation in progress
  idle,

  /// Currently syncing queued actions
  syncing,

  /// Sync encountered an error
  error,

  /// Sync completed successfully
  complete,
}

/// Sync strategy for processing queued actions
enum SyncStrategy {
  /// Process actions one at a time in order (default)
  sequential,

  /// Process all actions concurrently
  parallel,
}

/// Sync manager for MCP UI DSL v1.1
///
/// Coordinates between [ConnectivityManager] and [OfflineQueue] to
/// automatically sync queued actions when the device comes back online.
///
/// Supports both Dart callbacks and DSL action definitions for sync
/// lifecycle events. Use [onSyncComplete]/[onSyncError] for programmatic
/// callbacks, or [onSyncCompleteDsl]/[onSyncErrorDsl] with an
/// [actionHandler] for server-driven DSL action execution.
///
/// Example usage:
/// ```dart
/// final connectivity = ConnectivityManager();
/// final queue = OfflineQueue();
/// final syncManager = SyncManager(queue, connectivity);
///
/// // Queue actions while offline
/// queue.enqueue({'type': 'saveData', 'value': 'test'});
///
/// // Auto-sync when connectivity is restored
/// syncManager.enableAutoSync((action) async {
///   await api.execute(action);
/// });
///
/// // Or trigger sync manually
/// await syncManager.sync((action) async {
///   await api.execute(action);
/// });
/// ```

/// Callback type for sync lifecycle events.
///
/// Receives the sync result context (e.g., syncedCount, failedCount)
/// and can trigger actions like notifications.
typedef SyncCallback = Future<void> Function(Map<String, dynamic> context);

/// Callback type for executing a DSL action definition.
///
/// Used to bridge sync lifecycle events to the DSL action system.
/// The [action] map is a DSL action definition (e.g., `{"type": "setState", ...}`),
/// and [context] provides sync result metadata.
typedef DslActionExecutor = Future<void> Function(
    Map<String, dynamic> action, Map<String, dynamic> context);

class SyncManager {
  SyncStatus _status = SyncStatus.idle;
  final OfflineQueue _queue;
  final ConnectivityManager _connectivity;

  /// State manager for optimistic updates
  StateManager? _stateManager;
  StreamSubscription<NetworkStatus>? _connectivitySubscription;
  bool _autoSyncEnabled = false;
  final StreamController<SyncStatus> _statusController =
      StreamController<SyncStatus>.broadcast();
  String? _lastError;
  DateTime? _lastSyncTime;
  int _syncedCount = 0;
  int _failedCount = 0;

  /// Sync strategy: sequential (default) or parallel
  SyncStrategy strategy;

  /// Dart callback executed when sync completes successfully
  SyncCallback? onSyncComplete;

  /// Dart callback executed when sync encounters errors
  SyncCallback? onSyncError;

  /// DSL action definition to execute when sync completes successfully.
  /// Requires [actionHandler] to be set.
  Map<String, dynamic>? onSyncCompleteDsl;

  /// DSL action definition to execute when sync encounters errors.
  /// Requires [actionHandler] to be set.
  Map<String, dynamic>? onSyncErrorDsl;

  /// Handler for executing DSL action definitions.
  /// Set this to connect sync lifecycle events to the DSL action system.
  DslActionExecutor? actionHandler;

  SyncManager(this._queue, this._connectivity, {
    this.onSyncComplete,
    this.onSyncError,
    this.onSyncCompleteDsl,
    this.onSyncErrorDsl,
    this.actionHandler,
    this.strategy = SyncStrategy.sequential,
  });

  /// Current sync status
  SyncStatus get status => _status;

  /// Whether auto-sync is currently enabled
  bool get isAutoSyncEnabled => _autoSyncEnabled;

  /// Number of actions pending sync
  int get pendingCount => _queue.pendingCount;

  /// Whether there are actions pending sync
  bool get hasPending => _queue.hasPending;

  /// Stream of sync status changes
  Stream<SyncStatus> get statusStream => _statusController.stream;

  /// Last error message if status is [SyncStatus.error]
  String? get lastError => _lastError;

  /// Timestamp of the last successful sync
  DateTime? get lastSyncTime => _lastSyncTime;

  /// Number of actions synced in the last batch
  int get syncedCount => _syncedCount;

  /// Number of actions that failed in the last sync
  int get failedCount => _failedCount;

  /// Start sync when online
  ///
  /// Processes all queued actions using the provided [executor].
  /// If the device is offline, the status is set to [SyncStatus.error].
  Future<void> sync(
      Future<void> Function(Map<String, dynamic>) executor) async {
    if (_status == SyncStatus.syncing) {
      return; // Already syncing
    }

    if (!_connectivity.isOnline) {
      _updateStatus(SyncStatus.error);
      _lastError = 'Cannot sync while offline';
      return;
    }

    if (!_queue.hasPending) {
      _updateStatus(SyncStatus.complete);
      return;
    }

    _updateStatus(SyncStatus.syncing);
    _lastError = null;

    try {
      final List<QueueProcessResult> results;
      if (strategy == SyncStrategy.parallel) {
        results = await _queue.processQueueParallel(executor);
      } else {
        results = await _queue.processQueue(executor);
      }

      // Track sync counts
      final failures = results.where((r) => !r.success).toList();
      _syncedCount = results.length - failures.length;
      _failedCount = failures.length;

      if (failures.isEmpty) {
        _updateStatus(SyncStatus.complete);
        _lastSyncTime = DateTime.now();
        await _invokeOnSyncComplete();
      } else if (_queue.hasPending) {
        _updateStatus(SyncStatus.error);
        _lastError =
            '${failures.length} action(s) failed during sync';
        await _invokeOnSyncError();
      } else {
        // All actions processed (some may have exceeded retries)
        _updateStatus(SyncStatus.complete);
        _lastSyncTime = DateTime.now();
        await _invokeOnSyncComplete();
      }
    } catch (e) {
      _syncedCount = 0;
      _failedCount = 0;
      _updateStatus(SyncStatus.error);
      _lastError = e.toString();
      await _invokeOnSyncError();
    }
  }

  /// Enable automatic sync when connectivity is restored
  ///
  /// Listens for [NetworkStatus.online] events and automatically
  /// processes the queue using the provided [executor].
  void enableAutoSync(
      Future<void> Function(Map<String, dynamic>) executor) {
    _autoSyncEnabled = true;

    // Cancel any existing subscription
    _connectivitySubscription?.cancel();

    // Listen for connectivity changes
    _connectivitySubscription = _connectivity.statusStream.listen((status) {
      if (status == NetworkStatus.online && _queue.hasPending) {
        sync(executor);
      }
    });
  }

  /// Disable automatic sync
  void disableAutoSync() {
    _autoSyncEnabled = false;
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
  }

  /// Queue an action for sync
  ///
  /// If online, attempts immediate execution. If offline, queues
  /// the action for later sync.
  Future<bool> queueOrExecute(
    Map<String, dynamic> action,
    Future<void> Function(Map<String, dynamic>) executor, {
    Map<String, dynamic>? context,
    QueuePriority priority = QueuePriority.normal,
  }) async {
    if (_connectivity.isOnline) {
      try {
        await executor(action);
        return true;
      } catch (_) {
        // Execution failed, queue for later retry
        _queue.enqueue(action, context: context, priority: priority);
        return false;
      }
    } else {
      // Offline, queue for later
      _queue.enqueue(action, context: context, priority: priority);
      return false;
    }
  }

  /// Invoke onSyncComplete callback and/or DSL action with sync context
  Future<void> _invokeOnSyncComplete() async {
    final context = <String, dynamic>{
      'syncedCount': _syncedCount,
      'failedCount': _failedCount,
      'lastSyncTime': _lastSyncTime?.toIso8601String(),
    };

    // Execute Dart callback if provided
    if (onSyncComplete != null) {
      await onSyncComplete!(context);
    }

    // Execute DSL action if provided and handler is available
    if (onSyncCompleteDsl != null && actionHandler != null) {
      await actionHandler!(onSyncCompleteDsl!, context);
    }
  }

  /// Invoke onSyncError callback and/or DSL action with error context
  Future<void> _invokeOnSyncError() async {
    final context = <String, dynamic>{
      'syncedCount': _syncedCount,
      'failedCount': _failedCount,
      'lastError': _lastError,
    };

    // Execute Dart callback if provided
    if (onSyncError != null) {
      await onSyncError!(context);
    }

    // Execute DSL action if provided and handler is available
    if (onSyncErrorDsl != null && actionHandler != null) {
      await actionHandler!(onSyncErrorDsl!, context);
    }
  }

  /// Update the sync status and notify listeners
  void _updateStatus(SyncStatus newStatus) {
    _status = newStatus;
    if (!_statusController.isClosed) {
      _statusController.add(newStatus);
    }
  }

  /// Set the state manager for optimistic updates
  void setStateManager(StateManager stateManager) {
    _stateManager = stateManager;
  }

  /// Apply an optimistic update to the given state path.
  /// Returns a rollback callback that restores the previous value on failure.
  VoidCallback applyOptimistic(String path, dynamic value) {
    final previousValue = _stateManager?.get<dynamic>(path);
    _stateManager?.set(path, value);
    return () {
      _stateManager?.set(path, previousValue);
    };
  }

  /// Dispose the sync manager and release resources
  void dispose() {
    disableAutoSync();

    if (!_statusController.isClosed) {
      _statusController.close();
    }
  }
}
