/// Workspace-COMPLETE agent runtime — integration regression over a real
/// `KnowledgeInit.boot` re-boot cycle.
///
/// Reproduces the reported bug (konpi test2 #2/#4): only the boot-ACTIVE
/// workspace's agents were mirrored into the flowbrain runtime (`loadActive`),
/// so `agent_ask({agentId, workspaceId})` / `bk.agent.*` for another
/// department threw `AgentNotFoundException` even though the member exists on
/// disk. `loadAll` mirrors EVERY workspace's agents, so a non-active
/// department's agent resolves regardless of the active UI lens.
///
///   t1  after a reboot with active=`_system`, agents authored in `org/hr`
///       and `org/media` are BOTH present in the kernel — neither is active.
///   t2  `agents.ask` on a non-active-ws agent resolves (no AgentNotFound).
///   t3  a mirrored worker carries a self-identity systemPrompt (test2 #3):
///       its own displayName + department, not the operator/persona.
library;

import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart' show ModelSpec;
import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
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
  setUp(() => tmp = Directory.systemTemp.createTempSync('ws_complete_'));
  tearDown(() => tmp.existsSync() ? tmp.deleteSync(recursive: true) : null);

  Future<KnowledgeInit> boot() => KnowledgeInit.boot(
    _bound(tmp.path),
    sharedLlmProviders: {'claude': _FakeLlmPort()},
  );

  test(
    'loadAll mirrors EVERY workspace\'s agents (cross-ws resolves + identity)',
    () async {
      // Seed two departments, each with a worker agent, on the first boot.
      final init = await boot();
      expect(init.system.isAgentSubsystemActivated, isTrue);
      final ws = init.registries.workspace;
      await ws.create(type: WorkspaceType.org, slug: 'hr', title: 'People');
      await ws.create(type: WorkspaceType.org, slug: 'media', title: 'Media');
      const model = ModelSpec(provider: 'claude', model: 'claude-code');
      await init.registries.member.createAgent(
        id: 'hr_lead',
        displayName: 'Julia',
        profileRef: '',
        skillIds: const [],
        philosophyRef: '',
        workspaceId: 'org/hr',
        model: model,
      );
      await init.registries.member.createAgent(
        id: 'media_lead',
        displayName: 'Milo',
        profileRef: '',
        skillIds: const [],
        philosophyRef: '',
        workspaceId: 'org/media',
        model: model,
      );

      // Re-boot from the same on-disk tree. The kernel runtime starts empty
      // and `loadAll` repopulates it from yaml. active resets to `_system`
      // (config) — so NEITHER department is the active lens.
      final init2 = await boot();
      expect(init2.registries.workspace.activeId, '_system');

      // t1 — both departments' agents mirrored despite neither being active.
      final hr = await init2.system.agents.getAgent('hr_lead');
      final media = await init2.system.agents.getAgent('media_lead');
      expect(hr, isNotNull, reason: 'org/hr agent must resolve while inactive');
      expect(
        media,
        isNotNull,
        reason: 'org/media agent must resolve while inactive',
      );

      // t2 — the exact reported call path: ask a non-active-ws agent. Before
      // the fix this threw AgentNotFoundException; now it resolves.
      final reply = await init2.system.agents.ask('media_lead', 'hi');
      expect(reply.agentId, 'media_lead');

      // t3 — self-identity systemPrompt carries the agent's own name + its
      // department title (not the operator / another persona).
      final prompt = media!.systemPrompt ?? '';
      expect(prompt, contains('Milo'));
      expect(prompt, contains('Media'));
      expect(prompt, contains('org/media'));
    },
  );
}
