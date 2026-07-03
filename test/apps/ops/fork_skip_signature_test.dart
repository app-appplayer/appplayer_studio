/// 4-axis fork-skip signature — integration regression over real
/// `KnowledgeInit.boot` reboot cycles.
///
/// Eager `loadAll` re-forks every workspace's members on every boot (the cost
/// grows with the roster, since "active workspace" is a view, not an execution
/// gate). The optimization stamps each mirrored agent with an `ops_fork_sig`
/// tag = hash(workspace pool fingerprint + the member's 4-axis refs); a boot
/// whose signature matches skips the re-fork. Correctness hinges on the
/// signature INVALIDATING whenever anything that feeds the fork changes — the
/// pool is copied into owned storage at fork time, so a stale skip would freeze
/// an edited skill/profile/philosophy.
///
///   fs1  an unchanged reboot keeps the same signature (the skip path).
///   fs2  editing the workspace pool (a new/changed yaml) re-stamps the
///        signature — so the re-fork fires and picks up the edit.
library;

import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart' show ModelSpec;
import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/infra/ws_paths.dart';
import 'package:appplayer_studio/src/apps/ops/init/knowledge_init.dart';
import 'package:appplayer_studio/src/apps/ops/registries/workspace_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;

class _FakeLlmPort extends mb.LlmPort {
  @override
  mb.LlmCapabilities get capabilities => const mb.LlmCapabilities.minimal();
  @override
  Future<mb.LlmResponse> complete(mb.LlmRequest request) async =>
      const mb.LlmResponse(content: 'FAKE_OK', finishReason: 'stop');
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

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('fork_skip_'));
  tearDown(() => tmp.existsSync() ? tmp.deleteSync(recursive: true) : null);

  test('fork signature is stable while unchanged and re-stamps on a pool edit',
      () async {
    Future<KnowledgeInit> boot() => KnowledgeInit.boot(
          _bound(tmp.path),
          sharedLlmProviders: {'claude': _FakeLlmPort()},
        );

    // Seed a department with one worker on the first boot.
    final init = await boot();
    final ws = init.registries.workspace;
    await ws.create(type: WorkspaceType.org, slug: 'eng', title: 'Engineering');
    await init.registries.member.createAgent(
      id: 'eng_lead',
      displayName: 'Ada',
      profileRef: '',
      skillIds: const [],
      philosophyRef: '',
      workspaceId: 'org/eng',
      model: const ModelSpec(provider: 'claude', model: 'claude-code'),
    );

    // Second boot: the background load mirrors the agent and stamps the fork
    // signature (org/eng is not the active workspace, so it streams in).
    final init2 = await boot();
    await init2.workspacesReady;
    final t1 = (await init2.system.agents.getAgent('eng_lead'))?.tags['ops_fork_sig'];
    expect(t1, isNotNull, reason: 'a mirrored agent must carry a fork signature');
    expect(t1, isNotEmpty);

    // fs1 — an unchanged reboot leaves the signature untouched (skip path).
    final init3 = await boot();
    await init3.workspacesReady;
    final t2 = (await init3.system.agents.getAgent('eng_lead'))?.tags['ops_fork_sig'];
    expect(t2, t1, reason: 'unchanged workspace must keep the same signature');

    // fs2 — edit the workspace POOL (add a yaml to skills/). The pool
    // fingerprint changes, so the signature must move — the re-fork fires and
    // would pick up the edited pool content.
    final skillsDir =
        Directory('${wsContentRoot(tmp.path, 'org/eng')}/skills');
    skillsDir.createSync(recursive: true);
    File('${skillsDir.path}/probe.yaml').writeAsStringSync('id: probe\n');

    final init4 = await boot();
    await init4.workspacesReady;
    final t3 = (await init4.system.agents.getAgent('eng_lead'))?.tags['ops_fork_sig'];
    expect(t3, isNot(t1), reason: 'a pool edit must re-stamp the signature');
  });
}
