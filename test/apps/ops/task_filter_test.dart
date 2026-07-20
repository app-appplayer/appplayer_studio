/// Unit tests for the Task list filter / grouping / elapsed logic (UX audit
/// P2.4 / P2.5 / P2.8). These mirror the private helpers in
/// `ui/task/task_page.dart` and `ui/process/process_board.dart` (both UI files
/// whose helpers aren't importable) via inline clones — the repo's established
/// pattern for locking private-helper behaviour.
///
/// Scenarios:
///   tf1  TaskFilter.matches — each filter admits the right states
///   tf2  isDelegationTask — only `ask-async-*` ids
///   pe1  fmtElapsed — seconds / minutes / hours compaction
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/registries/task_registry.dart';

// --- inline clone of TaskFilter.matches (task_page.dart) ------------------
enum _TaskFilter { all, active, blocked, done }

bool _matches(_TaskFilter f, TaskState s) => switch (f) {
  _TaskFilter.all => true,
  _TaskFilter.active => s == TaskState.pending || s == TaskState.inProgress,
  _TaskFilter.blocked => s == TaskState.blocked,
  _TaskFilter.done => s == TaskState.completed || s == TaskState.cancelled,
};

// --- inline clone of _isDelegationTask (task_page.dart) -------------------
bool _isDelegation(String id) => id.startsWith('ask-async-');

// --- inline clone of _fmtElapsed (process_board.dart) --------------------
String _fmtElapsed(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  final h = d.inHours;
  final m = d.inMinutes % 60;
  return m > 0 ? '${h}h${m}m' : '${h}h';
}

void main() {
  group('TaskFilter.matches', () {
    test('tf1 each filter admits the right states', () {
      // all → every state
      for (final s in TaskState.values) {
        expect(_matches(_TaskFilter.all, s), isTrue);
      }
      // active → pending + inProgress only
      expect(_matches(_TaskFilter.active, TaskState.pending), isTrue);
      expect(_matches(_TaskFilter.active, TaskState.inProgress), isTrue);
      expect(_matches(_TaskFilter.active, TaskState.blocked), isFalse);
      expect(_matches(_TaskFilter.active, TaskState.completed), isFalse);
      // blocked → blocked only
      expect(_matches(_TaskFilter.blocked, TaskState.blocked), isTrue);
      expect(_matches(_TaskFilter.blocked, TaskState.inProgress), isFalse);
      // done → completed + cancelled
      expect(_matches(_TaskFilter.done, TaskState.completed), isTrue);
      expect(_matches(_TaskFilter.done, TaskState.cancelled), isTrue);
      expect(_matches(_TaskFilter.done, TaskState.pending), isFalse);
    });
  });

  group('isDelegationTask', () {
    test('tf2 only ask-async-* ids are delegations', () {
      expect(_isDelegation('ask-async-1783787301762895'), isTrue);
      expect(_isDelegation('T-PKG-001'), isFalse);
      expect(_isDelegation('daily-brief'), isFalse);
      expect(_isDelegation(''), isFalse);
    });
  });

  group('fmtElapsed', () {
    test('pe1 seconds / minutes / hours compaction', () {
      expect(_fmtElapsed(const Duration(seconds: 5)), '5s');
      expect(_fmtElapsed(const Duration(seconds: 59)), '59s');
      expect(_fmtElapsed(const Duration(minutes: 1)), '1m');
      expect(_fmtElapsed(const Duration(minutes: 12)), '12m');
      expect(_fmtElapsed(const Duration(minutes: 59)), '59m');
      expect(_fmtElapsed(const Duration(hours: 2)), '2h');
      expect(_fmtElapsed(const Duration(hours: 2, minutes: 5)), '2h5m');
    });
  });
}
