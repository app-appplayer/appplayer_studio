/// Agent-completion trigger bus — the R1/R2/R3 runtime that lets ops agents
/// wake each other instead of running one-shot. See
/// `docs/makemind_ops/ops-agent-trigger-bus.md`.
///
///   events   AgentWorkCompleted flags + depth threading
///   sub      TriggerSubscription match filters + template render + self-loop
///   registry subscribe → persist → reload → matching roundtrip
///   bus      emit fans to R3 inject + R2 wakes; hop cap; best-effort guard
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' show KvStoragePortAdapter;
import 'package:appplayer_studio/builtin_api.dart' show KnowledgeSystem;
import 'package:appplayer_studio/src/apps/ops/registries/member_registry.dart';
import 'package:appplayer_studio/src/apps/ops/registries/task_registry.dart';
import 'package:appplayer_studio/src/apps/ops/triggers/trigger_events.dart';
import 'package:appplayer_studio/src/apps/ops/triggers/trigger_subscription.dart';
import 'package:appplayer_studio/src/apps/ops/triggers/trigger_bus.dart';

AgentWorkCompleted _evt({
  String source = 'worker',
  String ws = 'wsA',
  WorkKind kind = WorkKind.task,
  String state = 'completed',
  String refId = 'run-1',
  String? summary = 'done the thing',
  int depth = 0,
}) => AgentWorkCompleted(
  sourceAgentId: source,
  workspaceId: ws,
  kind: kind,
  refId: refId,
  state: state,
  at: DateTime(2026, 7, 10, 8),
  summary: summary,
  depth: depth,
);

void main() {
  group('AgentWorkCompleted', () {
    test('state flags + withDepth preserves fields', () {
      final e = _evt(state: 'blocked', depth: 1);
      expect(e.isBlocked, isTrue);
      expect(e.isCompleted, isFalse);
      final d = e.withDepth(3);
      expect(d.depth, 3);
      expect(d.refId, e.refId);
      expect(d.summary, e.summary);
      expect(d.state, 'blocked');
    });
  });

  group('TriggerSubscription', () {
    TriggerSubscription sub({
      String target = 'manager',
      String? source,
      WorkKind? kind,
      String onState = 'completed',
      String? tpl,
    }) => TriggerSubscription(
      id: 's1',
      workspaceId: 'wsA',
      targetAgentId: target,
      sourceAgentId: source,
      kind: kind,
      onState: onState,
      requestTemplate: tpl,
      createdAt: DateTime(2026, 7, 10),
    );

    test('matches on any-filters within same workspace', () {
      expect(sub().matches(_evt()), isTrue);
    });

    test('workspace is matched exactly', () {
      expect(sub().matches(_evt(ws: 'wsB')), isFalse);
    });

    test('source / kind / state filters narrow', () {
      expect(sub(source: 'worker').matches(_evt()), isTrue);
      expect(sub(source: 'other').matches(_evt()), isFalse);
      expect(sub(kind: WorkKind.task).matches(_evt()), isTrue);
      expect(sub(kind: WorkKind.route).matches(_evt()), isFalse);
      expect(sub(onState: 'completed').matches(_evt(state: 'blocked')), isFalse);
      expect(sub(onState: 'blocked').matches(_evt(state: 'blocked')), isTrue);
      expect(sub(onState: 'any').matches(_evt(state: 'blocked')), isTrue);
    });

    test('never wakes the source with its own completion (self-loop guard)', () {
      expect(sub(target: 'worker').matches(_evt(source: 'worker')), isFalse);
    });

    test('render substitutes placeholders (and default digest)', () {
      final r = sub(tpl: '{sourceAgentId} → {summary} [{kind}/{state}]')
          .render(_evt());
      expect(r, 'worker → done the thing [task/completed]');
      final d = sub().render(_evt(refId: 'run-9'));
      expect(d, contains('worker completed task (run-9)'));
      expect(d, contains('done the thing'));
    });
  });

  group('TriggerRegistry roundtrip', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('trigger_reg_test_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('subscribe persists and reloads; matching finds it', () async {
      final reg = TriggerRegistry(rootDir: tmp.path);
      final s = await reg.subscribe(
        workspaceId: 'wsA',
        targetAgentId: 'manager',
        sourceAgentId: 'worker',
        kind: WorkKind.task,
        requestTemplate: 'gather: {summary}',
      );
      expect(s.id, isNotEmpty);

      // Fresh registry over the same dir — must read the persisted file back.
      final reg2 = TriggerRegistry(rootDir: tmp.path);
      final matches = await reg2.matching(_evt());
      expect(matches, hasLength(1));
      expect(matches.single.targetAgentId, 'manager');
      expect(matches.single.kind, WorkKind.task);
      expect(matches.single.render(_evt()), 'gather: done the thing');

      // Unsubscribe removes the file and future matches.
      expect(await reg2.unsubscribe(s.id), isTrue);
      final reg3 = TriggerRegistry(rootDir: tmp.path);
      expect(await reg3.matching(_evt()), isEmpty);
    });
  });

  group('OpsTriggerBus.emit', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('trigger_bus_test_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('fans a completion to R3 inject and R2 wakes for matches', () async {
      final reg = TriggerRegistry(rootDir: tmp.path);
      await reg.subscribe(
        workspaceId: 'wsA',
        targetAgentId: 'manager',
        sourceAgentId: 'worker',
        requestTemplate: 'continue with {summary}',
      );
      final injected = <AgentWorkCompleted>[];
      final woke = <({String target, String request})>[];
      final bus = OpsTriggerBus(
        subscriptions: reg,
        injectIntoActiveChat: (e) async => injected.add(e),
        wakeAgent: (target, request, cause) async =>
            woke.add((target: target, request: request)),
      );

      await bus.emit(_evt());

      expect(injected, hasLength(1));
      expect(woke, hasLength(1));
      expect(woke.single.target, 'manager');
      expect(woke.single.request, 'continue with done the thing');
    });

    test('hop cap: past maxHops, R3 still fires but R2 wakes are skipped',
        () async {
      final reg = TriggerRegistry(rootDir: tmp.path);
      await reg.subscribe(workspaceId: 'wsA', targetAgentId: 'manager');
      final injected = <AgentWorkCompleted>[];
      var wakes = 0;
      final bus = OpsTriggerBus(
        subscriptions: reg,
        maxHops: 2,
        injectIntoActiveChat: (e) async => injected.add(e),
        wakeAgent: (t, r, c) async => wakes++,
      );

      await bus.emit(_evt(depth: 2));
      expect(injected, hasLength(1)); // R3 unaffected by the cap
      expect(wakes, 0); // R2 skipped at the cap
    });

    test('a throwing seam is contained — other seams and the caller survive',
        () async {
      final reg = TriggerRegistry(rootDir: tmp.path);
      await reg.subscribe(workspaceId: 'wsA', targetAgentId: 'manager');
      var woke = 0;
      final bus = OpsTriggerBus(
        subscriptions: reg,
        injectIntoActiveChat: (e) async => throw StateError('inject boom'),
        wakeAgent: (t, r, c) async => woke++,
      );
      // Must not throw despite the inject seam blowing up, and the wake still
      // runs.
      await bus.emit(_evt());
      expect(woke, 1);
    });

    test('no wakeAgent seam → subscriptions are recorded but never fired',
        () async {
      final reg = TriggerRegistry(rootDir: tmp.path);
      await reg.subscribe(workspaceId: 'wsA', targetAgentId: 'manager');
      final injected = <AgentWorkCompleted>[];
      final bus = OpsTriggerBus(
        subscriptions: reg,
        injectIntoActiveChat: (e) async => injected.add(e),
      );
      await bus.emit(_evt());
      expect(injected, hasLength(1));
    });

    test('a one-shot (once) subscription fires exactly once then retires',
        () async {
      final reg = TriggerRegistry(rootDir: tmp.path);
      await reg.subscribe(
        workspaceId: 'wsA',
        targetAgentId: 'manager',
        once: true,
      );
      final woke = <String>[];
      final bus = OpsTriggerBus(
        subscriptions: reg,
        wakeAgent: (t, r, c) async => woke.add(t),
      );

      await bus.emit(_evt()); // fires + retires
      await bus.emit(_evt()); // nothing left to match

      expect(woke, ['manager']); // exactly one wake
      expect(await reg.matching(_evt()), isEmpty); // removed from the store
    });
  });

  // The live-integration leg konpi caught: unit-green bus + subscription, yet
  // no wake fired against a running studio. Reproduces it end-to-end at the
  // runtime seam — a subscription and a target agent BOTH persisted to disk in
  // a workspace that the *waking* session never opened, then a completion in
  // that workspace. Proves (a) subscription matching survives a fresh
  // persist→reload registry and (b) the wake resolves the target via
  // `member.get(wsId)` even though a bare `member.get` (no wsId) misses because
  // the department was never loaded. This is exactly the R2 root fix.
  group('OpsTriggerBus.emit — R2 live-integration (unopened workspace)', () {
    late Directory tmp;
    const ws = 'org/packages';

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('trigger_r2_intg_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<MemberRegistry> freshMembers() async => MemberRegistry(
      kv: KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv')),
      knowledgeSystem: KnowledgeSystem.stub(),
      rootDir: tmp.path,
    );

    // Seed `lead` + `proto` agents into `ws` on disk, then subscribe
    // `lead ← any completion in ws`, both through a first registry.
    Future<void> seed() async {
      final members = await freshMembers();
      for (final id in ['lead', 'proto']) {
        await members.createAgent(
          id: id,
          displayName: id,
          profileRef: '',
          skillIds: const [],
          philosophyRef: '',
          workspaceId: ws,
        );
      }
      final triggers = TriggerRegistry(rootDir: tmp.path);
      await triggers.subscribe(workspaceId: ws, targetAgentId: 'lead');
    }

    test(
      'a completion in an unopened workspace wakes the persisted subscriber',
      () async {
        await seed();

        // A brand-new session: neither the subscription nor `lead` is loaded.
        final members = await freshMembers();
        final triggers = TriggerRegistry(rootDir: tmp.path);

        // Control: the bug the fix addresses — a bare lookup misses because the
        // workspace was never opened, so the wake would silently no-op.
        expect(await members.get('lead'), isNull);

        // The real wake seam's shape (see ops_builtin `_wireTriggerSeams`):
        // hydrate the target within the completion's workspace, then run only
        // when it resolves to an AgentMember.
        final woke = <String>[];
        final bus = OpsTriggerBus(
          subscriptions: triggers,
          wakeAgent: (target, request, cause) async {
            final m = await members.get(target, wsId: cause.workspaceId);
            if (m is AgentMember) woke.add(target);
          },
        );

        await bus.emit(_evt(source: 'proto', ws: ws, kind: WorkKind.task));

        expect(woke, ['lead']); // matched + hydrated + dispatched
      },
    );

    test('a completion in a different workspace does not wake', () async {
      await seed();
      final members = await freshMembers();
      final triggers = TriggerRegistry(rootDir: tmp.path);
      final woke = <String>[];
      final bus = OpsTriggerBus(
        subscriptions: triggers,
        wakeAgent: (target, request, cause) async {
          final m = await members.get(target, wsId: cause.workspaceId);
          if (m is AgentMember) woke.add(target);
        },
      );
      await bus.emit(_evt(source: 'proto', ws: 'org/other', kind: WorkKind.task));
      expect(woke, isEmpty);
    });

    // The highest-fidelity reproduction short of a live GUI: a REAL
    // `TaskRegistry.run` drives the assignee to completion, its REAL
    // `_emitCompleted` fires the REAL `OpsTriggerBus.emit`, which runs the REAL
    // `TriggerRegistry.matching` and wakes through the same `member.get(wsId)`
    // resolution the boot seam uses. This is exactly konpi's "background task
    // completed but the subscriber never woke" path — end to end, no fakes on
    // the completion chain (only the agent turn + the wake side effect are
    // stubbed, since those are the LLM / host boundaries).
    test('a real background task run wakes the subscriber (full emit chain)',
        () async {
      await seed();
      final members = await freshMembers();
      final triggers = TriggerRegistry(rootDir: tmp.path);
      final woke = <String>[];
      final bus = OpsTriggerBus(
        subscriptions: triggers,
        wakeAgent: (target, request, cause) async {
          final m = await members.get(target, wsId: cause.workspaceId);
          if (m is AgentMember) woke.add(target);
        },
      );

      final tasks = TaskRegistry(
        kv: KvStoragePortAdapter(rootDir: p.join(tmp.path, 'kv')),
        knowledgeSystem: KnowledgeSystem.stub(),
        rootDir: tmp.path,
      );
      // Wire the real R1 seam (as knowledge_init does at boot) and a stub
      // assignee run standing in for the agent's LLM turn.
      tasks.onWorkCompleted = bus.emit;
      tasks.agentRun = (assignee, request, {workspaceId}) async =>
          assignee == 'proto' ? 'portfolio done' : null;

      await tasks.create(Task(
        id: 'ask-async-1',
        workspaceId: ws,
        kind: TaskKind.oneOff,
        title: 'compile the portfolio',
        assigneeIds: const ['proto'],
        skillIds: const [],
        createdAt: DateTime.utc(2026, 7, 10),
      ));
      final ref = await tasks.run('ask-async-1');
      expect(ref.endState, TaskState.completed);

      // `_emitCompleted` fans out fire-and-forget (the run must not block on
      // downstream wakes), so the wake lands just AFTER the task reports
      // completed — the live consequence konpi should expect: check the
      // subscriber's conversation a moment after, not synchronously. Pump until
      // the async wake settles.
      for (var i = 0; i < 20 && woke.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(woke, ['lead']); // completion fanned out and woke the subscriber
    });
  });
}
