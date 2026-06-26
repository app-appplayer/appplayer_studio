import 'dart:async';

import 'package:meta/meta.dart';

import '../registries/task_registry.dart';
import '../registries/workspace_registry.dart';

/// Minimal cron-based scheduler for recurring tasks.
///
/// Polls every [tickInterval] (default 1 minute) and fires any recurring
/// `Task` whose cron expression matches the current wall-clock minute.
/// Per-task dedupe: a task that already fired in the current minute is
/// skipped for the remainder of that minute.
class TaskScheduler {
  TaskScheduler({
    required this.tasks,
    required this.workspaces,
    this.tickInterval = const Duration(minutes: 1),
    this.maxConcurrent = 4,
    this.maxRetries = 2,
    this.retryBackoff = const Duration(seconds: 2),
  });

  final TaskRegistry tasks;
  final WorkspaceRegistry workspaces;
  final Duration tickInterval;

  /// Governance — keeps the unattended scheduler from stampeding the LLM /
  /// tool surface under bursty cron fires:
  ///   * [maxConcurrent] caps in-flight task runs (back-pressure; excess fires
  ///     defer to the next tick).
  ///   * [maxRetries] retries a failed run with linear [retryBackoff] before
  ///     leaving it blocked (its TaskRunRef already records the error).
  final int maxConcurrent;
  final int maxRetries;
  final Duration retryBackoff;

  Timer? _timer;
  DateTime? _lastTick;
  final Set<String> _firedThisMinute = {};
  final Set<String> _inFlight = {};

  void start() {
    _timer ??= Timer.periodic(tickInterval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    final now = DateTime.now();
    if (_lastTick == null || now.minute != _lastTick!.minute) {
      _firedThisMinute.clear();
    }
    _lastTick = now;

    final allTasks = await tasks.list();
    for (final t in allTasks) {
      if (t.kind != TaskKind.recurring) continue;
      if (t.schedule == null) continue;
      if (t.state == TaskState.cancelled) continue;
      if (_firedThisMinute.contains(t.id)) continue;
      if (_inFlight.contains(t.id)) continue; // a slow run still in progress
      if (!_cronMatches(t.schedule!.cron, now)) continue;
      // Back-pressure — at capacity, defer remaining fires to the next tick.
      if (_inFlight.length >= maxConcurrent) break;

      _firedThisMinute.add(t.id);
      unawaited(_runGoverned(t.id, () => tasks.run(t.id)));
    }
  }

  /// Run [id] with in-flight tracking (back-pressure) + bounded retry. Never
  /// throws — an exhausted run stays blocked (its TaskRunRef records the error).
  Future<void> _runGoverned(String id, Future<Object?> Function() run) async {
    _inFlight.add(id);
    try {
      await _attemptWithRetry(run);
    } finally {
      _inFlight.remove(id);
    }
  }

  /// Runs [run], retrying on failure up to [maxRetries] times with linear
  /// backoff. Returns the number of attempts made (1 = first-try success,
  /// `maxRetries + 1` = exhausted).
  Future<int> _attemptWithRetry(Future<Object?> Function() run) async {
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        await run();
        return attempt;
      } catch (_) {
        if (attempt > maxRetries) return attempt;
        await Future<void>.delayed(retryBackoff * attempt);
      }
    }
  }

  @visibleForTesting
  int get inFlightCount => _inFlight.length;

  @visibleForTesting
  bool get atCapacity => _inFlight.length >= maxConcurrent;

  @visibleForTesting
  Future<int> attemptWithRetryForTest(Future<Object?> Function() run) =>
      _attemptWithRetry(run);

  @visibleForTesting
  Future<void> runGovernedForTest(String id, Future<Object?> Function() run) =>
      _runGoverned(id, run);

  static bool _cronMatches(String expr, DateTime now) =>
      testCronMatches(expr, now);

  /// Public for unit tests.
  @visibleForTesting
  static bool testCronMatches(String expr, DateTime now) {
    final parts = expr.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) return false;
    return _fieldMatches(parts[0], now.minute, 0, 59) &&
        _fieldMatches(parts[1], now.hour, 0, 23) &&
        _fieldMatches(parts[2], now.day, 1, 31) &&
        _fieldMatches(parts[3], now.month, 1, 12) &&
        _fieldMatches(parts[4], now.weekday % 7, 0, 6);
  }

  static bool _fieldMatches(String field, int value, int min, int max) {
    for (final token in field.split(',')) {
      if (token == '*') return true;
      if (token.startsWith('*/')) {
        final step = int.tryParse(token.substring(2));
        if (step != null && step > 0 && (value - min) % step == 0) {
          return true;
        }
        continue;
      }
      if (token.contains('-')) {
        final bounds = token.split('-');
        if (bounds.length == 2) {
          final a = int.tryParse(bounds[0]);
          final b = int.tryParse(bounds[1]);
          if (a != null && b != null && value >= a && value <= b) return true;
        }
        continue;
      }
      final exact = int.tryParse(token);
      if (exact != null && exact == value) return true;
    }
    return false;
  }
}
