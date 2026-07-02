/// Inbox cross-workspace scan + cancel convergence — regression tests for the
/// scoped-KV throw and the lingering pendingApproval on a cancelled run.
///
///   x1  `pendingApprovals` aggregates a run parked in a NON-active workspace.
///       The active-scoped `kv` throws on the first cross-workspace key, so the
///       scan must read through the unscoped `orgKv`. The test also asserts the
///       scoped adapter WOULD have thrown (documents why orgKv is required).
///   x2  `ProcessRegistry.cancel` clears a parked `pendingApproval` so a
///       cancelled run does not linger in the Inbox as a waiting gate, and
///       re-cancel converges to the same clean state (idempotent).
library;

import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart' show KvStoragePortAdapter;
import 'package:appplayer_studio/builtin_api.dart' show KnowledgeSystem;
import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/core/inbox_query.dart';
import 'package:appplayer_studio/src/apps/ops/init/knowledge_init.dart';
import 'package:appplayer_studio/src/apps/ops/registries/process_registry.dart';
import 'package:appplayer_studio/src/apps/ops/registries/workspace_registry.dart';
import 'package:flutter_test/flutter_test.dart';

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

ProcessRun _waitingRun({
  required String runId,
  required String workspaceId,
  String approverId = 'mgr1',
}) => ProcessRun(
  runId: runId,
  processId: 'release',
  workspaceId: workspaceId,
  startedAt: DateTime.utc(2024, 6, 1),
  currentStep: 's1',
  outcomes: const {},
  state: ProcessRunState.waitingApproval,
  pendingApproval: PendingApproval(
    afterStep: 's1',
    approverId: approverId,
    requestedAt: DateTime.utc(2024, 6, 1),
  ),
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('inbox_xws_'));
  tearDown(() => tmp.existsSync() ? tmp.deleteSync(recursive: true) : null);

  // --- x1: cross-workspace aggregation via orgKv ---
  test(
    'x1 pendingApprovals aggregates a run in a non-active workspace '
    '(scoped kv would throw, orgKv must not)',
    () async {
      final init = await KnowledgeInit.boot(_bound(tmp.path));
      // The scan only visits workspaces the registry knows about.
      await init.registries.workspace.create(
        type: WorkspaceType.org,
        slug: 'studio',
        title: 'Studio',
      );

      const otherWs = 'org/studio';
      const runId = 'run-xws-1';
      final key = 'ws/$otherWs/process_runs/$runId';
      // Persist under the non-active workspace partition through the unscoped
      // reader/writer — the only adapter allowed to touch a foreign partition.
      await init.adapters.orgKv.set(
        key,
        _waitingRun(runId: runId, workspaceId: otherWs).toJson(),
      );

      // Bug documentation: the active-scoped kv (bound to `_system`) rejects
      // the cross-workspace key. This is exactly what the old scan hit.
      await expectLater(init.adapters.kv.get(key), throwsA(anything));

      // The fix: the aggregate scan reads it through orgKv without throwing.
      final pending = await pendingApprovals(init);
      expect(pending.map((e) => e['runId']), contains(runId));
      expect(
        pending.firstWhere((e) => e['runId'] == runId)['workspace'],
        otherWs,
      );
    },
  );

  // --- x2: cancel clears a parked pendingApproval and converges ---
  test('x2 cancel clears pendingApproval and re-cancel converges', () async {
    const wsId = 'project/ws1';
    const runId = 'run-cancel-1';
    final key = 'ws/$wsId/process_runs/$runId';
    final kv = KvStoragePortAdapter(
      rootDir: '${tmp.path}/kv',
      workspaceId: wsId,
    );
    final reg = ProcessRegistry(
      kv: kv,
      knowledgeSystem: KnowledgeSystem.stub(),
      rootDir: tmp.path,
    );
    // Seed a run suspended on an approval gate.
    await kv.set(key, _waitingRun(runId: runId, workspaceId: wsId).toJson());

    await reg.cancel(runId);

    final afterCancel = ProcessRun.fromJson(
      Map<String, dynamic>.from(await kv.get(key) as Map),
    );
    expect(afterCancel.state, ProcessRunState.cancelled);
    expect(afterCancel.pendingApproval, isNull);

    // Idempotent: re-cancel leaves it clean, not resurrecting the gate.
    await reg.cancel(runId);
    final afterRecancel = ProcessRun.fromJson(
      Map<String, dynamic>.from(await kv.get(key) as Map),
    );
    expect(afterRecancel.state, ProcessRunState.cancelled);
    expect(afterRecancel.pendingApproval, isNull);
  });
}
