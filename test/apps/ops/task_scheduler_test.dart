/// TaskScheduler — governance (G-governance): bounded concurrency + retry.
///
/// The cron-match logic is covered inline (`testCronMatches`); these tests
/// exercise the governance the scheduler adds on top so the unattended driver
/// doesn't stampede under bursty fires:
///   g1  retry — first-try success makes one attempt
///   g2  retry — fails twice then succeeds within maxRetries=2 (3 attempts)
///   g3  retry — always-fail exhausts at maxRetries+1 attempts, never throws
///   g4  concurrency — in-flight runs count against the cap; clear on done
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' show KvStoragePortAdapter;
import 'package:appplayer_studio/builtin_api.dart' show KnowledgeSystem;
import 'package:appplayer_studio/src/apps/ops/init/task_scheduler.dart';
import 'package:appplayer_studio/src/apps/ops/registries/task_registry.dart';
import 'package:appplayer_studio/src/apps/ops/registries/workspace_registry.dart';

Future<(TaskScheduler, Directory)> _makeScheduler({
  int maxConcurrent = 4,
  int maxRetries = 2,
}) async {
  final tmp = await Directory.systemTemp.createTemp('task_sched_test_');
  final kv = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv'));
  final tasks = TaskRegistry(
    kv: kv,
    knowledgeSystem: KnowledgeSystem.stub(),
    rootDir: tmp.path,
  );
  final ws = WorkspaceRegistry(kv: kv, rootDir: tmp.path);
  final s = TaskScheduler(
    tasks: tasks,
    workspaces: ws,
    maxConcurrent: maxConcurrent,
    maxRetries: maxRetries,
    retryBackoff: Duration.zero, // no real delay in tests
  );
  return (s, tmp);
}

void main() {
  group('TaskScheduler governance — retry', () {
    test('g1 first-try success makes one attempt', () async {
      final (s, tmp) = await _makeScheduler();
      var calls = 0;
      final attempts = await s.attemptWithRetryForTest(() async => calls++);
      expect(attempts, 1);
      expect(calls, 1);
      await tmp.delete(recursive: true);
    });

    test(
      'g2 fails twice then succeeds within maxRetries=2 (3 attempts)',
      () async {
        final (s, tmp) = await _makeScheduler(maxRetries: 2);
        var calls = 0;
        final attempts = await s.attemptWithRetryForTest(() async {
          calls++;
          if (calls < 3) throw StateError('boom');
          return calls;
        });
        expect(attempts, 3); // 2 failures + 1 success
        expect(calls, 3);
        await tmp.delete(recursive: true);
      },
    );

    test(
      'g3 always-fail exhausts at maxRetries+1 attempts, never throws',
      () async {
        final (s, tmp) = await _makeScheduler(maxRetries: 2);
        var calls = 0;
        final attempts = await s.attemptWithRetryForTest(() async {
          calls++;
          throw StateError('always');
        });
        expect(attempts, 3); // maxRetries(2) + 1
        expect(calls, 3);
        await tmp.delete(recursive: true);
      },
    );
  });

  group('TaskScheduler R4 catchup — missed-slot logic', () {
    test('daily 08:00: missed while closed → true; not-yet / already → false',
        () async {
      final (s, tmp) = await _makeScheduler();
      const cron = '0 8 * * *';
      // Closed since yesterday 09:00, now today 08:30 → today's 08:00 missed.
      expect(
        s.missedSlotSinceForTest(
          cron,
          DateTime(2026, 7, 9, 9),
          DateTime(2026, 7, 10, 8, 30),
        ),
        isTrue,
      );
      // Since 07:00 today, now 07:30 — the 08:00 slot hasn't come yet.
      expect(
        s.missedSlotSinceForTest(
          cron,
          DateTime(2026, 7, 10, 7),
          DateTime(2026, 7, 10, 7, 30),
        ),
        isFalse,
      );
      // Already fired at 08:00; now 08:30 — that slot is not "after" the fire.
      expect(
        s.missedSlotSinceForTest(
          cron,
          DateTime(2026, 7, 10, 8),
          DateTime(2026, 7, 10, 8, 30),
        ),
        isFalse,
      );
      await tmp.delete(recursive: true);
    });

    test('long gap collapses to a single catch-up within the lookback window',
        () async {
      final (s, tmp) = await _makeScheduler();
      // Closed 5 days; a daily 08:00 slot exists within the last 25h → true
      // (one catch-up, not five).
      expect(
        s.missedSlotSinceForTest(
          '0 8 * * *',
          DateTime(2026, 7, 5, 8),
          DateTime(2026, 7, 10, 8, 30),
        ),
        isTrue,
      );
      await tmp.delete(recursive: true);
    });
  });

  group('TaskScheduler R4 catchup — firing', () {
    Future<(TaskScheduler, TaskRegistry, Directory)> make() async {
      final tmp = await Directory.systemTemp.createTemp('task_catchup_test_');
      final kv = KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv'));
      final tasks = TaskRegistry(
        kv: kv,
        knowledgeSystem: KnowledgeSystem.stub(),
        rootDir: tmp.path,
      );
      final ws = WorkspaceRegistry(kv: kv, rootDir: tmp.path);
      final s = TaskScheduler(
        tasks: tasks,
        workspaces: ws,
        retryBackoff: Duration.zero,
      );
      return (s, tasks, tmp);
    }

    test('a recurring task with a stale lastFiredAt catches up once', () async {
      final (s, tasks, tmp) = await make();
      final ran = Completer<void>();
      var calls = 0;
      tasks.dispatch = (id, args) async {
        calls++;
        if (!ran.isCompleted) ran.complete();
        return {'ok': true};
      };
      await tasks.create(Task(
        id: 't-catchup',
        workspaceId: 'wsA',
        kind: TaskKind.recurring,
        title: 'brief',
        assigneeIds: const [],
        skillIds: const ['sk_brief'],
        schedule: TaskSchedule(cron: '* * * * *'),
        createdAt: DateTime.now().subtract(const Duration(hours: 1)),
        lastFiredAt: DateTime.now().subtract(const Duration(minutes: 10)),
      ));

      await s.catchUpForTest();
      await ran.future.timeout(const Duration(seconds: 5));
      expect(calls, 1);
      await tmp.delete(recursive: true);
    });

    test('a one-off task is never caught up', () async {
      final (s, tasks, tmp) = await make();
      var calls = 0;
      tasks.dispatch = (id, args) async {
        calls++;
        return {'ok': true};
      };
      await tasks.create(Task(
        id: 't-oneoff',
        workspaceId: 'wsA',
        kind: TaskKind.oneOff,
        title: 'once',
        assigneeIds: const [],
        skillIds: const ['sk_once'],
        schedule: TaskSchedule(cron: '* * * * *'),
        createdAt: DateTime.now().subtract(const Duration(hours: 1)),
        lastFiredAt: DateTime.now().subtract(const Duration(minutes: 10)),
      ));

      await s.catchUpForTest();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 0);
      await tmp.delete(recursive: true);
    });
  });

  group('TaskScheduler governance — concurrency', () {
    test('g4 in-flight runs count against the cap; clear on done', () async {
      final (s, tmp) = await _makeScheduler(maxConcurrent: 2);
      final gate = Completer<Object?>();
      expect(s.inFlightCount, 0);
      expect(s.atCapacity, false);

      final f1 = s.runGovernedForTest('a', () => gate.future);
      final f2 = s.runGovernedForTest('b', () => gate.future);
      await Future<void>.delayed(Duration.zero); // let them register in-flight

      expect(s.inFlightCount, 2);
      expect(s.atCapacity, true);

      gate.complete(null);
      await Future.wait([f1, f2]);

      expect(s.inFlightCount, 0);
      expect(s.atCapacity, false);
      await tmp.delete(recursive: true);
    });
  });
}
