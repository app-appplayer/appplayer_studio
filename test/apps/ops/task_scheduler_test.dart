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
