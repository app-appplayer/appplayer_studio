import 'dart:async';

/// Priority levels for queued actions
enum QueuePriority {
  /// Low priority - processed last
  low,

  /// Normal priority - default processing order
  normal,

  /// High priority - processed first
  high,

  /// Critical priority - must be processed immediately when online
  critical,
}

/// Represents a single action queued for later execution
class QueuedAction {
  /// The action definition to execute
  final Map<String, dynamic> action;

  /// Optional context data associated with this action
  final Map<String, dynamic>? context;

  /// When this action was queued
  final DateTime queuedAt;

  /// Priority level for processing order
  final QueuePriority priority;

  /// Number of times execution has been attempted
  int retryCount;

  /// Maximum number of retry attempts
  final int maxRetries;

  /// Unique identifier for this queued action
  final String id;

  QueuedAction({
    required this.action,
    this.context,
    this.priority = QueuePriority.normal,
    this.maxRetries = 3,
  })  : queuedAt = DateTime.now(),
        retryCount = 0,
        id = '${DateTime.now().microsecondsSinceEpoch}_'
            '${action.hashCode.toRadixString(36)}';

  /// Whether this action has exceeded its retry limit
  bool get isExpired => retryCount >= maxRetries;

  /// Create a map representation for serialization
  Map<String, dynamic> toJson() => {
        'id': id,
        'action': action,
        'context': context,
        'queuedAt': queuedAt.toIso8601String(),
        'priority': priority.name,
        'retryCount': retryCount,
        'maxRetries': maxRetries,
      };
}

/// Result of processing a single queued action
class QueueProcessResult {
  /// The action that was processed
  final QueuedAction action;

  /// Whether processing succeeded
  final bool success;

  /// Error message if processing failed
  final String? error;

  QueueProcessResult({
    required this.action,
    required this.success,
    this.error,
  });
}

/// Overflow strategy when the queue reaches its maximum size
enum QueueOverflowStrategy {
  /// Reject the oldest item to make room for the new one
  rejectOldest,

  /// Reject the newest item (the one being enqueued)
  rejectNewest,
}

/// Offline action queue for MCP UI DSL v1.1
///
/// Queues actions when the device is offline and replays them
/// when connectivity is restored. Actions are processed in
/// priority order (critical > high > normal > low).
///
/// The queue supports an optional [maxSize] limit with configurable
/// [overflowStrategy] to handle capacity overflow.
///
/// Example usage:
/// ```dart
/// final queue = OfflineQueue(maxSize: 100);
///
/// // Queue an action while offline
/// queue.enqueue({'type': 'saveData', 'path': 'user.name', 'value': 'Alice'});
///
/// // Later, when online, process all queued actions
/// await queue.processQueue((action) async {
///   await apiClient.execute(action);
/// });
/// ```
class OfflineQueue {
  final List<QueuedAction> _queue = [];
  bool _processing = false;
  final StreamController<QueueProcessResult> _resultController =
      StreamController<QueueProcessResult>.broadcast();

  /// Maximum number of actions the queue can hold. 0 means unlimited.
  final int maxSize;

  /// Strategy for handling overflow when the queue is full.
  final QueueOverflowStrategy overflowStrategy;

  OfflineQueue({
    this.maxSize = 0,
    this.overflowStrategy = QueueOverflowStrategy.rejectOldest,
  });

  /// Number of actions waiting to be processed
  int get pendingCount => _queue.length;

  /// Whether there are any pending actions
  bool get hasPending => _queue.isNotEmpty;

  /// Whether the queue is currently being processed
  bool get isProcessing => _processing;

  /// Stream of processing results
  Stream<QueueProcessResult> get results => _resultController.stream;

  /// Queue an action for later execution
  ///
  /// Actions are stored with their [context] and will be replayed
  /// when [processQueue] is called. Use [priority] to control
  /// processing order.
  ///
  /// If [maxSize] is set and the queue is full, the [overflowStrategy]
  /// determines whether the oldest item is removed or the new item is
  /// rejected. Returns `true` if the action was enqueued, `false` if
  /// it was rejected due to overflow.
  bool enqueue(
    Map<String, dynamic> action, {
    Map<String, dynamic>? context,
    QueuePriority priority = QueuePriority.normal,
    int maxRetries = 3,
  }) {
    // Check capacity limits
    if (maxSize > 0 && _queue.length >= maxSize) {
      if (overflowStrategy == QueueOverflowStrategy.rejectNewest) {
        return false;
      }
      // rejectOldest: remove the first (lowest priority / oldest) item
      _queue.removeAt(0);
    }

    final queuedAction = QueuedAction(
      action: action,
      context: context,
      priority: priority,
      maxRetries: maxRetries,
    );

    // Insert in priority order
    final insertIndex = _findInsertIndex(priority);
    _queue.insert(insertIndex, queuedAction);
    return true;
  }

  /// Process all queued actions using the provided executor
  ///
  /// Actions are executed sequentially in priority order.
  /// Failed actions are retried up to their maxRetries limit.
  /// Returns a list of results for each processed action.
  Future<List<QueueProcessResult>> processQueue(
    Future<void> Function(Map<String, dynamic>) executor,
  ) async {
    if (_processing) {
      return [];
    }

    _processing = true;
    final results = <QueueProcessResult>[];
    final failedActions = <QueuedAction>[];

    try {
      while (_queue.isNotEmpty) {
        final action = _queue.removeAt(0);

        try {
          // Merge context into the action for execution
          final executionPayload = <String, dynamic>{
            ...action.action,
            if (action.context != null) '_context': action.context,
          };

          await executor(executionPayload);

          final result = QueueProcessResult(
            action: action,
            success: true,
          );
          results.add(result);

          if (!_resultController.isClosed) {
            _resultController.add(result);
          }
        } catch (e) {
          action.retryCount++;

          if (!action.isExpired) {
            // Re-queue for retry
            failedActions.add(action);
          }

          final result = QueueProcessResult(
            action: action,
            success: false,
            error: e.toString(),
          );
          results.add(result);

          if (!_resultController.isClosed) {
            _resultController.add(result);
          }
        }
      }

      // Re-add failed actions that haven't exceeded retry limit
      for (final failed in failedActions) {
        final insertIndex = _findInsertIndex(failed.priority);
        _queue.insert(insertIndex, failed);
      }
    } finally {
      _processing = false;
    }

    return results;
  }

  /// Process all queued actions concurrently using the provided executor
  ///
  /// All actions are executed in parallel. Failed actions are retried
  /// up to their maxRetries limit and re-queued if not expired.
  /// Returns a list of results for each processed action.
  Future<List<QueueProcessResult>> processQueueParallel(
    Future<void> Function(Map<String, dynamic>) executor,
  ) async {
    if (_processing) {
      return [];
    }

    _processing = true;
    final results = <QueueProcessResult>[];
    final failedActions = <QueuedAction>[];

    try {
      // Take all items out of the queue for parallel processing
      final actions = List<QueuedAction>.from(_queue);
      _queue.clear();

      final futures = actions.map((action) async {
        try {
          final executionPayload = <String, dynamic>{
            ...action.action,
            if (action.context != null) '_context': action.context,
          };

          await executor(executionPayload);

          final result = QueueProcessResult(
            action: action,
            success: true,
          );

          if (!_resultController.isClosed) {
            _resultController.add(result);
          }
          return result;
        } catch (e) {
          action.retryCount++;

          if (!action.isExpired) {
            failedActions.add(action);
          }

          final result = QueueProcessResult(
            action: action,
            success: false,
            error: e.toString(),
          );

          if (!_resultController.isClosed) {
            _resultController.add(result);
          }
          return result;
        }
      });

      results.addAll(await Future.wait(futures));

      // Re-add failed actions that haven't exceeded retry limit
      for (final failed in failedActions) {
        final insertIndex = _findInsertIndex(failed.priority);
        _queue.insert(insertIndex, failed);
      }
    } finally {
      _processing = false;
    }

    return results;
  }

  /// Remove a specific action from the queue by ID
  bool remove(String actionId) {
    final index = _queue.indexWhere((a) => a.id == actionId);
    if (index >= 0) {
      _queue.removeAt(index);
      return true;
    }
    return false;
  }

  /// Get a snapshot of all pending actions
  List<QueuedAction> get pendingActions => List.unmodifiable(_queue);

  /// Clear all queued actions
  void clear() {
    _queue.clear();
  }

  /// Dispose the queue and release resources
  void dispose() {
    _queue.clear();
    if (!_resultController.isClosed) {
      _resultController.close();
    }
  }

  /// Find the correct insertion index to maintain priority order
  int _findInsertIndex(QueuePriority priority) {
    // Higher priority items go first
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].priority.index > priority.index) {
        return i;
      }
    }
    return _queue.length;
  }
}

// ConflictStrategy, ConflictResolver, and ConflictResult are defined in
// conflict_resolver.dart (single source of truth per feat-runtime/08-offline-sync.md).
