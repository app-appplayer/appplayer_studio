/// `OpsBuiltInApp.buildAgentRun` — the task-assignee auto-run seam.
///
/// Regression cover for konpi's 2026-07-21 / 2026-07-28 field reports: every
/// background delegation that failed was reported as
/// `assignee is not a runnable agent and has no skill to run`, sending
/// operators after the assignee id form while the real cause (a run timeout /
/// tool error / LLM failure) stayed invisible. The seam had swallowed EVERY
/// exception from `agents.ask` into `null`, and `TaskRegistry.run` reads a
/// `null` as "not runnable".
///
/// The contract these tests pin — three distinguishable outcomes:
///   s1  agent assignee, run succeeds        → the deliverable string
///   s2  agent assignee, run FAILS           → THROWS the real error
///                                             (never null, never the
///                                             "not a runnable agent" wording)
///   s3  person assignee                     → null (skill-dispatch fallback)
///   s4  unknown assignee id                 → null (skill-dispatch fallback)
///   s5  full scoped agentId                 → runs (2026-07-11 fix held)
///   s6  end-to-end through TaskRegistry on a background-shaped task
///       (`skillIds: []`): a failed run lands `blocked` carrying the REAL
///       errorCode, not the assignee-resolution wording.
///
/// s3 / s4 are the guard rails on the fix: collapsing them into throws would
/// kill the person-assignee skill fallback that predates all of this.
library;

import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart' show KnowledgeSystem, ModelSpec;
import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/init/knowledge_init.dart';
import 'package:appplayer_studio/src/apps/ops/ops_builtin.dart';
import 'package:appplayer_studio/src/apps/ops/registries/task_registry.dart';
import 'package:appplayer_studio/src/apps/ops/registries/workspace_registry.dart';
import 'package:brain_kernel/brain_kernel.dart' show KvStoragePortAdapter;
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:path/path.dart' as p;

/// Stands in for the `claude` subprocess. [failure] non-null → every
/// completion throws it, the shape a runner timeout (`ClaudeRunnerError`,
/// exit 124) or a tool error arrives in.
class _ScriptedLlmPort extends mb.LlmPort {
  _ScriptedLlmPort({this.failure});

  final Object? failure;

  @override
  mb.LlmCapabilities get capabilities => const mb.LlmCapabilities.minimal();

  @override
  Future<mb.LlmResponse> complete(mb.LlmRequest request) async {
    final f = failure;
    if (f != null) throw f;
    return const mb.LlmResponse(content: 'DELIVERABLE', finishReason: 'stop');
  }
}

OpsConfig _bound(String root) => OpsConfig(
  version: 'test',
  appName: 'test',
  activeWorkspace: '_system',
  workspacesRoot: root,
  llm: const LlmSettings.empty(),
  mcp: const McpSettings.defaults(),
  browser: const BrowserSettings.defaults(),
  storage: StorageSettings(localKvPath: '$root/.kv'),
  channel: const ChannelSettings.empty(),
  security: const SecuritySettings.defaults(),
);

const _kNotRunnableWording = 'not a runnable agent';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('agent_run_seam_'));
  tearDown(() => tmp.existsSync() ? tmp.deleteSync(recursive: true) : null);

  /// Boot a real ops init with one department holding one agent member
  /// (`writer`) and one person member (`chief`) — konpi's newsroom shape.
  Future<KnowledgeInit> bootNewsroom({Object? llmFailure}) async {
    final init = await KnowledgeInit.boot(
      _bound(tmp.path),
      sharedLlmProviders: {'claude': _ScriptedLlmPort(failure: llmFailure)},
    );
    await init.registries.workspace.create(
      type: WorkspaceType.org,
      slug: 'newsroom',
      title: 'Newsroom',
    );
    await init.registries.member.createAgent(
      id: 'writer',
      displayName: 'Wren',
      profileRef: '',
      skillIds: const ['sk_apply_konpi'],
      philosophyRef: '',
      workspaceId: 'org/newsroom',
      model: const ModelSpec(provider: 'claude', model: 'claude-code'),
    );
    await init.registries.member.addPerson(
      id: 'chief',
      displayName: 'Cho',
      workspaceId: 'org/newsroom',
    );
    return init;
  }

  group('buildAgentRun outcomes', () {
    // --- s1: agent assignee, run succeeds ---
    test('s1 an agent assignee returns the deliverable', () async {
      final init = await bootNewsroom();
      final run = OpsBuiltInApp.buildAgentRun(init);

      final out = await run('writer', 'draft it', workspaceId: 'org/newsroom');

      expect(out, 'DELIVERABLE');
    });

    // --- s2: THE FIX — a failed run throws instead of returning null ---
    test('s2 a failed run throws the real error, never null', () async {
      final init = await bootNewsroom(
        llmFailure: StateError('claude exited 124: timed out'),
      );
      final run = OpsBuiltInApp.buildAgentRun(init);

      // Before the fix this resolved to `null`, which the caller renders as
      // "assignee is not a runnable agent" — the misdiagnosis konpi chased.
      await expectLater(
        run('writer', 'draft it', workspaceId: 'org/newsroom'),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('124'), isNot(contains(_kNotRunnableWording))),
          ),
        ),
      );
    });

    // --- s3: guard rail — person assignee still declines to null ---
    test('s3 a person assignee returns null (skill fallback)', () async {
      final init = await bootNewsroom();
      final run = OpsBuiltInApp.buildAgentRun(init);

      final out = await run('chief', 'draft it', workspaceId: 'org/newsroom');

      expect(
        out,
        isNull,
        reason: 'a person is genuinely not runnable — the skill-dispatch '
            'fallback must survive the throw-on-failure change',
      );
    });

    // --- s4: guard rail — unknown id still declines to null ---
    test('s4 an unknown assignee returns null (skill fallback)', () async {
      final init = await bootNewsroom();
      final run = OpsBuiltInApp.buildAgentRun(init);

      final out = await run('ghost', 'draft it', workspaceId: 'org/newsroom');

      expect(out, isNull);
    });

    // --- s5: 2026-07-11 fix still held — full scoped agentId resolves ---
    test('s5 a full scoped agentId resolves and runs', () async {
      final init = await bootNewsroom();
      final member = await init.registries.member.get(
        'writer',
        wsId: 'org/newsroom',
      );
      final scoped = (member as dynamic).agentId as String;
      final run = OpsBuiltInApp.buildAgentRun(init);

      final out = await run(scoped, 'draft it', workspaceId: 'org/newsroom');

      expect(out, 'DELIVERABLE');
    });
  });

  group('through TaskRegistry (background delegation shape)', () {
    // --- s6: the exact field symptom, end to end ---
    test('s6 a failed background task blocks with the REAL error', () async {
      final init = await bootNewsroom(
        llmFailure: StateError('claude exited 124: timed out'),
      );
      final reg = TaskRegistry(
        kv: KvStoragePortAdapter(rootDir: p.join(tmp.path, 'task_kv')),
        knowledgeSystem: KnowledgeSystem.stub(),
        rootDir: p.join(tmp.path, 'tasks'),
      );
      reg.agentRun = OpsBuiltInApp.buildAgentRun(init);
      // `agent_ask({background:true})` creates exactly this shape: an agent
      // assignee and NO skillIds, so there is no fallback to hide behind.
      await reg.create(
        Task(
          id: 'ask-async-1',
          workspaceId: 'org/newsroom',
          kind: TaskKind.oneOff,
          title: 'revise plan.md',
          assigneeIds: const ['writer'],
          skillIds: const [],
          createdAt: DateTime.utc(2026, 7, 28),
        ),
      );

      final ref = await reg.run('ask-async-1');

      expect(ref.endState, TaskState.blocked);
      expect(ref.errorCode, contains('124'));
      expect(
        ref.errorCode,
        isNot(contains(_kNotRunnableWording)),
        reason: 'the run failed; it did not fail to resolve the assignee',
      );
    });
  });
}
