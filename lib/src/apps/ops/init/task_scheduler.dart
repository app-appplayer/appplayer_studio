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

  /// How far back the boot catchup scans for a missed recurring slot. Bounds
  /// the per-task minute scan (a daily/hourly task closed under this long still
  /// catches up; a task whose only slot was longer ago is treated as expired).
  static const Duration catchupLookback = Duration(hours: 25);

  Timer? _timer;
  DateTime? _lastTick;
  final Set<String> _firedThisMinute = {};
  final Set<String> _inFlight = {};

  void start() {
    if (_timer != null) return;
    // R4 — before ticking, catch up any recurring fire missed while the app was
    // closed (in-memory Timer only fires while running). One collapsed run per
    // task, not one per missed slot.
    unawaited(_catchUp());
    _timer = Timer.periodic(tickInterval, (_) => _tick());
  }

  /// Fire a single catch-up run for every recurring task that had a scheduled
  /// slot between its last fire (or creation) and now. Bounded by
  /// [catchupLookback]; only sees currently-loaded workspaces (the active one
  /// on the boot critical path — background departments catch up on their next
  /// live tick).
  Future<void> _catchUp() async {
    final now = DateTime.now();
    final List<Task> allTasks;
    try {
      allTasks = await tasks.list();
    } catch (_) {
      return; // registries not bound yet — nothing to catch up
    }
    for (final t in allTasks) {
      if (t.kind != TaskKind.recurring) continue;
      if (t.schedule == null) continue;
      if (t.state == TaskState.cancelled) continue;
      if (_firedThisMinute.contains(t.id)) continue;
      if (_inFlight.contains(t.id)) continue;
      final since = t.lastFiredAt ?? t.createdAt;
      if (!_missedSlotSince(t.schedule!.cron, since, now)) continue;
      if (_inFlight.length >= maxConcurrent) break;
      _firedThisMinute.add(t.id);
      unawaited(_runGoverned(t.id, () => tasks.run(t.id)));
    }
  }

  /// True when at least one cron-matching minute falls in `(since, now]` within
  /// [catchupLookback] — i.e. a scheduled fire was missed.
  bool _missedSlotSince(String cron, DateTime since, DateTime now) {
    var scanFrom = now.subtract(catchupLookback);
    if (scanFrom.isBefore(since)) scanFrom = since;
    var t = DateTime(
      scanFrom.year,
      scanFrom.month,
      scanFrom.day,
      scanFrom.hour,
      scanFrom.minute,
    ).add(const Duration(minutes: 1));
    while (!t.isAfter(now)) {
      if (t.isAfter(since) && testCronMatches(cron, t)) return true;
      t = t.add(const Duration(minutes: 1));
    }
    return false;
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
  Future<void> catchUpForTest() => _catchUp();

  @visibleForTesting
  bool missedSlotSinceForTest(String cron, DateTime since, DateTime now) =>
      _missedSlotSince(cron, since, now);

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
