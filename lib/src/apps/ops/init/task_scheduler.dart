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
  });

  final TaskRegistry tasks;
  final WorkspaceRegistry workspaces;
  final Duration tickInterval;

  Timer? _timer;
  DateTime? _lastTick;
  final Set<String> _firedThisMinute = {};

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
      if (!_cronMatches(t.schedule!.cron, now)) continue;

      _firedThisMinute.add(t.id);
      // Fire and forget — failures are recorded as TaskRunRef with endState=blocked.
      unawaited(_safeRun(t.id));
    }
  }

  Future<void> _safeRun(String id) async {
    try {
      await tasks.run(id);
    } catch (_) {
      // Error is captured in TaskRunRef.errorCode already.
    }
  }

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
