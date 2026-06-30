/// Per-project agent LLM resolution — integration coverage for the
/// shared-fallback wiring.
///
/// When a project is bound, `KnowledgeInit.boot` builds a PER-PROJECT
/// `KnowledgeSystem` with its OWN agent subsystem (agents isolate per
/// project — the same separation facts / knowledge / chat already have).
/// That per-project subsystem resolves an agent's model through
/// `infraPorts.llmProviders`, which is otherwise seeded only from the
/// project's configured key pool — empty on a keyless setup, so a worker
/// tagged `claude` never reaches the claude-code fallback that lives only
/// in the host's global agent LLM session pool.
///
/// `boot(sharedLlmProviders: ...)` merges that global pool in as a BASE
/// layer (project-configured keys overlaid on top). These tests pin the
/// contract:
///   t1  bound keyless agent WITH a shared `claude` provider resolves it
///       (reply carries the provider's content).
///   t2  bound keyless agent WITHOUT a shared pool resolves no real
///       provider (empty content) — the exact symptom the wiring fixes.
library;

import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart' show ModelSpec;
import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/init/knowledge_init.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;

/// Canned-response LlmPort so a successful resolution is observable as
/// non-empty reply content. Only `complete` is abstract on `LlmPort`.
class _FakeLlmPort extends mb.LlmPort {
  @override
  mb.LlmCapabilities get capabilities => const mb.LlmCapabilities.minimal();

  @override
  Future<mb.LlmResponse> complete(mb.LlmRequest request) async =>
      const mb.LlmResponse(content: 'FAKE_OK', finishReason: 'stop');
}

/// Unbound host stand-in — empty `workspacesRoot` keeps it off-disk
/// (in-memory factGraph, no workspace tree) so it can play the host
/// KnowledgeSystem a bound boot adopts / contrasts against.
OpsConfig _unboundConfig(String kvPath) => OpsConfig(
  version: 'test',
  appName: 'test',
  activeWorkspace: '',
  workspacesRoot: '',
  llm: const LlmSettings.empty(),
  mcp: const McpSettings.defaults(),
  browser: const BrowserSettings.defaults(),
  storage: StorageSettings(localKvPath: kvPath),
  channel: const ChannelSettings.empty(),
  security: const SecuritySettings.defaults(),
);

OpsConfig _boundConfig(String root) => OpsConfig(
  version: 'test',
  appName: 'test',
  // `_system` is a valid activeWorkspace slot (validation allows it).
  activeWorkspace: '_system',
  // Absolute, non-default root → `projectBound == true` → the boot takes
  // the per-project build branch (own factGraph + own agent subsystem).
  workspacesRoot: root,
  // Keyless — no configured providers, so the project key pool is empty.
  llm: const LlmSettings.empty(),
  mcp: const McpSettings.defaults(),
  browser: const BrowserSettings.defaults(),
  storage: StorageSettings(localKvPath: '$root/.kv'),
  channel: const ChannelSettings.empty(),
  security: const SecuritySettings.defaults(),
);

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pp_agent_llm_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<KnowledgeInit> bootWith(Map<String, mb.LlmPort>? shared) =>
      KnowledgeInit.boot(_boundConfig(tmp.path), sharedLlmProviders: shared);

  test(
    't1 bound keyless agent resolves through the shared fallback pool',
    () async {
      final init = await bootWith({'claude': _FakeLlmPort()});
      expect(init.system.isAgentSubsystemActivated, isTrue);

      await init.system.agents.createAgent(
        id: 'w1',
        displayName: 'Worker',
        model: const ModelSpec(provider: 'claude', model: 'claude-code'),
        workspaceId: '_system',
      );
      final reply = await init.system.agents.ask('w1', 'hello');
      expect(reply.content, 'FAKE_OK');
    },
  );

  test(
    't2 bound keyless agent without a shared pool resolves no provider',
    () async {
      final init = await bootWith(null);
      await init.system.agents.createAgent(
        id: 'w1',
        displayName: 'Worker',
        model: const ModelSpec(provider: 'claude', model: 'claude-code'),
        workspaceId: '_system',
      );
      final reply = await init.system.agents.ask('w1', 'hello');
      expect(reply.content, isEmpty);
    },
  );

  // P2-6 — a bound project builds its OWN system, so the host-registered
  // `ops.manager` is absent there. The boot must seed `_ops_admin` into the
  // per-project system (gate widened to `hostSystem == null || projectBound`)
  // so `system_agent_set_model`'s default target resolves instead of hitting
  // AgentNotFound.
  test(
    't3 bound project seeds its own `_ops_admin` (hosted) — set_model resolves',
    () async {
      final hostInit = await KnowledgeInit.boot(
        _unboundConfig('${tmp.path}/host.kv'),
      );
      final boundInit = await KnowledgeInit.boot(
        _boundConfig('${tmp.path}/proj'),
        hostSystem: hostInit.system,
      );

      // The per-project system carries its OWN admin agent.
      final admin = await boundInit.system.agents.getAgent('_ops_admin');
      expect(admin, isNotNull);

      // The `system_agent_set_model` path (updateAgent on the per-project
      // system) now succeeds instead of throwing AgentNotFound.
      final updated = await boundInit.system.agents.updateAgent(
        '_ops_admin',
        model: const ModelSpec(provider: 'claude', model: 'claude-code'),
      );
      expect(updated.model.provider, 'claude');
      expect(updated.model.model, 'claude-code');
    },
  );
}
