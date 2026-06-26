/// StudioBoot — single entry that wires the kernel-backed backbone for
/// a host tool (vibe_app_builder, knowledge_builder, ...). Domain code
/// receives a [StudioBackbone] handle and continues with its own
/// canonical · pipeline · server bridge · chat controller setup.
///
/// Boot is best-effort: when the LLM API key is missing or FlowBrain
/// boot fails, the backbone is still returned with `agentHost / growth
/// / seedLoader = null` so the host can land in a degraded-but-usable
/// welcome state. The host should branch on `backbone.isFlowBrainBooted`
/// before exposing agent / RAG features.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart'
    show KernelApp, KvStoragePortAdapter, LlmPortAdapter, ModelSpec;
import 'package:brain_kernel/mcp_host.dart'
    show McpClientKernelHost, ServerBootstrap;
import 'package:appplayer_claude_code_provider/appplayer_claude_code_provider.dart'
    show ClaudeCodeInteractiveProvider, ProcessClaudeRunner;
import 'package:mcp_llm/mcp_llm.dart' as mll;

import '../agent/agent_host.dart';
import '../agent/agent_profile.dart';
import '../install/bundle_loading.dart';
import '../install/knowledge_seed_loader.dart';
import '../install/vibe_growth_recorder.dart';
import '../main/studio_app.dart';
import 'studio_backbone.dart';

class StudioBoot {
  StudioBoot._();

  /// Wire the backbone for `toolId`. Idempotent across multiple host
  /// processes — each process owns its own backbone.
  ///
  /// `models` is the host catalog — each entry carries its provider id
  /// (`anthropic` / `openai` / `gemini` / …) so we route every model
  /// to its matching mcp_llm provider. `keyForProvider` resolves the
  /// per-provider API key (from `VibeSettings.llmProviders` map);
  /// when null or empty for a given provider, the legacy single
  /// `llmApiKey` is used as a fallback so existing shells that only
  /// stored one key keep working.
  static Future<StudioBackbone> start({
    required String toolId,
    required String configRoot,
    required List<VibeAgentProfile> agentProfiles,
    required List<Map<String, dynamic>> Function() fetchAllToolDefinitions,
    required List<({String id, String? provider})> models,
    String? llmApiKey,
    String? llmEndpoint,
    String? Function(String providerId)? keyForProvider,
    List<SeedBundleEntry> seedBundles = const <SeedBundleEntry>[],
    String? workspaceId,
    String Function(String)? resolveAgentId,
    String? defaultModelId,
  }) async {
    final wsId = workspaceId ?? toolId;
    final llmProviders = <String, LlmPortAdapter>{};
    String? claudeCodeModelId;
    String? claudeCodeExecutable;
    // First catalog model that actually wires an adapter — the de-facto
    // default every agent rides through `_defaultLlm` when its own
    // ModelSpec.provider isn't in the pool. Captured so member/worker
    // agents inherit a REAL model instead of the stub port (FR-OPS-001
    // fix: created agents must default to the configured model, never
    // `stub/stub-1`). `(id, provider)` pair feeds [defaultAgentModel].
    String? firstWiredModelId;
    String? firstWiredProvider;
    for (final m in models) {
      // Provider null = legacy single-key catalog → assume Anthropic
      // (matches the original `LlmPortAdapter` default ctor that
      // hardcoded ClaudeProvider). Modern catalogs tag every entry
      // explicitly (`anthropic` / `openai` / `gemini` / …).
      final providerId = m.provider ?? 'anthropic';
      final perProviderKey = keyForProvider?.call(providerId);
      final apiKey =
          (perProviderKey != null && perProviderKey.isNotEmpty)
              ? perProviderKey
              : (llmApiKey ?? '');
      // Claude Code rides the user's CLI subscription — no API key
      // required. Every other provider needs a key wired before we can
      // hand a working LlmProvider to the kernel.
      if (apiKey.isEmpty && providerId != 'claude_code') continue;
      final mcpProvider = _buildProvider(
        provider: providerId,
        apiKey: apiKey,
        modelId: m.id,
        endpoint: llmEndpoint,
      );
      if (mcpProvider == null) continue;
      // providerName surfaces on `LlmPortAdapter.providerName` so the
      // chat header / Settings banner can render "Opus 4.7 · anthropic"
      // / "claude-code · claude_code" etc. (cherry 2026-05-27 cascade).
      // Mirrors the catalog tag exactly — `anthropic` / `openai` /
      // `gemini` / `claude_code` — so external code can string-match
      // without translating.
      final adapter = LlmPortAdapter.fromInterface(
        modelId: m.id,
        provider: mcpProvider,
        providerName: providerId,
      );
      // Register under both keys — FlowBrain's `_resolveLlmFor` looks
      // up by `model.provider` (`anthropic` / `claude_code` / …) while
      // host-side per-agent UI keys by `model.model` (`claude-opus-4-7`
      // / `claude-code` / …). Wiring both makes the agent record's
      // `ModelSpec.provider` resolve to its real adapter instead of
      // sliding into `_defaultLlm` (which silently funnels every agent
      // through the first-registered model). Later entries win on
      // provider collision so the catalog order picks the effective
      // model per provider (Anthropic Opus today, configurable in
      // Settings → LLM tomorrow).
      llmProviders[m.id] = adapter;
      llmProviders[providerId] = adapter;
      firstWiredModelId ??= m.id;
      firstWiredProvider ??= providerId;
      // Remember claude_code identity so we can swap the adapter for
      // the `forKernel(app, ...)` variant after `KernelApp.boot`
      // returns + the host MCP endpoint's transport has started.
      // `_buildProvider` runs before `KernelApp.boot` so this initial
      // adapter has no `mcpServers` — `StudioBackbone.upgradeClaude
      // CodeForKernel()` is the host-side hook that replaces it.
      if (providerId == 'claude_code') {
        claudeCodeModelId = m.id;
        claudeCodeExecutable = llmEndpoint;
      }
    }

    // Inherited default agent model — the configured model (Settings →
    // LLM, `settings.llmModel` arrives as [defaultModelId]) mapped to its
    // catalog provider; when unset or not in the catalog, fall through to
    // the first WIRED catalog model (the same de-facto default system
    // agents ride). Never the stub port. Member/worker agents created
    // without an explicit ModelSpec inherit this instead of `stub/stub-1`,
    // so a worker the manager spawns can actually answer. Null only when
    // NO provider wired at all (no API keys + no claude_code) — a
    // degenerate state where even the manager has no LLM.
    ModelSpec? defaultAgentModel;
    if (defaultModelId != null && defaultModelId.isNotEmpty) {
      for (final m in models) {
        if (m.id == defaultModelId) {
          defaultAgentModel = ModelSpec(
            provider: m.provider ?? 'anthropic',
            model: defaultModelId,
          );
          break;
        }
      }
    }
    if (defaultAgentModel == null && firstWiredModelId != null) {
      defaultAgentModel = ModelSpec(
        provider: firstWiredProvider ?? 'anthropic',
        model: firstWiredModelId,
      );
    }

    // Typed handle to the booted client host so the extension-transport
    // seam (`connectWith`) stays reachable through the backbone —
    // `app.clientHost` is the abstract `KernelClientHost` type. Mirrors
    // AppPlayer's `_clientHost` capture (cherry `embedded-mcp-serving-base`,
    // 2026-06-10). FFI-free: the host only ever receives an already-built
    // `ClientTransport`; the transport's platform libs live in the caller.
    final clientHost = McpClientKernelHost();

    final app = await KernelApp.boot(
      workspaceId: wsId,
      kvStorage: KvStoragePortAdapter(rootDir: configRoot),
      llmProviders: llmProviders,
      bundleRegistryStorageDir: configRoot,
      // Per cherry inbox 2026-05-25 `kernel-host-adapter-split` —
      // brain_kernel's main barrel no longer re-exports mcp_server /
      // mcp_client. vibe_studio uses the reference MCP-backed host
      // (mcp_server transport for the studio endpoint + mcp_client
      // for any outbound dispatch), so we inject the reference impls
      // from the `mcp_host` sub-barrel. Without these, KernelApp falls
      // back to `InProcessKernelServerHost` (no mcp deps) — a transport
      // bind (`start(streamableHttp, port: 7840)`) would throw.
      serverHostFactory: ServerBootstrap.factory,
      clientHost: clientHost,
      // Per-agent chat log lands at `<configRoot>/chat/<agentId>.jsonl`
      // — keeps the host's chat persistence scoped to the same config
      // tree as the bundle registry / settings / seed markers (default
      // `'.'` would scatter `.jsonl` files into the launch CWD).
      chatLogDir: p.join(configRoot, 'chat'),
    );
    final bundleRegistry = app.bundleRegistry;
    final knowledgeEngine = app.queryEngine;

    AgentHost? agentHost;
    VibeGrowthRecorder? growth;
    KnowledgeSeedLoader? seedLoader;

    try {
      stderr.writeln(
        '$toolId: flowbrain booted (${llmProviders.length} model adapters)',
      );

      seedLoader = KnowledgeSeedLoader(
        system: app.system,
        markerRoot: configRoot,
      );
      // Prune stale registry entries — paths that no longer exist on
      // disk (e.g. older build layouts that have since moved). Without
      // this, bundle.list returns dead entries that confuse downstream
      // UI (BrandingView, etc.) trying to read files from them.
      try {
        final existing = await bundleRegistry.list();
        var pruned = 0;
        for (final e in existing) {
          if (!Directory(e.mbdPath).existsSync()) {
            if (await bundleRegistry.remove(e.mbdPath)) pruned++;
          }
        }
        if (pruned > 0) {
          stderr.writeln(
            '$toolId: bundle registry pruned $pruned stale entries',
          );
        }
      } catch (e) {
        stderr.writeln('$toolId: bundle registry prune skipped — $e');
      }

      // Seed registration — SDD §1.4. Single list; each entry's
      // manifest declaration drives which capability surfaces wire up.
      //   knowledge.sources non-empty → KB index invalidate.
      //   agents non-empty           → FlowBrain ops baseline load.
      // tools / ui / chat / wiring run through the normal activation
      // path when the user (or chrome) opens the bundle — host does
      // not branch on seed vs user-installed.
      for (final entry in seedBundles) {
        final ns = entry.namespace;
        try {
          final abs = File(entry.mbdPath).absolute.path;
          if (!Directory(abs).existsSync()) {
            stderr.writeln('$toolId: seed "$ns" not on disk — $abs');
            continue;
          }
          await bundleRegistry.upsert(mbdPath: abs, namespace: ns);
          stderr.writeln('$toolId: seed "$ns" registered ($abs)');

          final bundle = readBundleAt(abs);
          if (bundle == null) {
            stderr.writeln('$toolId: seed "$ns" manifest read failed');
            continue;
          }

          // Capability: knowledge → BM25 index participation.
          final hasKnowledge = bundle.knowledge?.sources.isNotEmpty == true;
          if (hasKnowledge) {
            knowledgeEngine.invalidate();
            stderr.writeln('$toolId: seed "$ns" knowledge indexed');
          }

          // Capability: agents (skills / profiles) → FlowBrain ops
          // baseline. Idempotent — KnowledgeSeedLoader marks each path
          // with a sentinel under `markerRoot` so repeat boots no-op.
          final hasAgents = bundle.agents?.agents.isNotEmpty == true;
          if (hasAgents) {
            try {
              final loaded = await seedLoader.loadBaseSeedOnce(abs);
              if (loaded) {
                stderr.writeln('$toolId: seed "$ns" ops baseline loaded');
              }
            } catch (e) {
              stderr.writeln('$toolId: seed "$ns" ops baseline skipped — $e');
            }
          }
        } catch (e) {
          stderr.writeln('$toolId: seed "$ns" registration failed — $e');
        }
      }

      agentHost = AgentHost(
        flowbrain: app,
        workspaceId: wsId,
        fetchAllToolDefinitions: fetchAllToolDefinitions,
        profiles: agentProfiles,
        resolveId: resolveAgentId,
        defaultAgentModel: defaultAgentModel,
      );
      await agentHost.registerAgents();
      stderr.writeln(
        '$toolId: ${agentProfiles.length} default agents registered '
        '(${agentProfiles.map((p) => p.id).join(", ")})',
      );

      growth = VibeGrowthRecorder(flowbrain: app);
      await growth.attach();
      stderr.writeln('$toolId: growth recorder attached');
    } catch (e) {
      stderr.writeln('$toolId: flowbrain boot skipped — $e');
    }

    // bundleRegistry / knowledgeEngine forward through StudioBackbone
    // getters — KernelApp owns the originals so we drop the dedicated
    // fields here to avoid duplicate state.
    return StudioBackbone(
      toolId: toolId,
      configRoot: configRoot,
      app: app,
      clientHost: clientHost,
      agentHost: agentHost,
      growth: growth,
      seedLoader: seedLoader,
      claudeCodeModelId: claudeCodeModelId,
      claudeCodeExecutable: claudeCodeExecutable,
      defaultAgentModel: defaultAgentModel,
    );
  }

  /// Resolve an mcp_llm provider instance for a `(provider, model)`
  /// pair. The host catalog (`kStudioModelCatalog`) tags every model
  /// with its provider id; this helper maps that id to a concrete
  /// `mll.LlmProvider`. Unknown providers return null so the caller
  /// silently skips the entry (lets a partial catalog still boot).
  ///
  /// Cherry inbox 2026-05-25 `llm-port-adapter-multi-provider`:
  /// `LlmPortAdapter.fromInterface(modelId, provider)` accepts any
  /// `LlmProvider` — Claude (default ctor backward-compat) + the 8
  /// extra mcp_llm providers (OpenAI · Gemini · Cohere · Bedrock ·
  /// Mistral · Groq · VertexAI · Custom). Today we wire the 3 the
  /// host catalog ships (anthropic · openai · gemini); more land here
  /// when the catalog grows.
  static mll.LlmProvider? _buildProvider({
    required String provider,
    required String apiKey,
    required String modelId,
    String? endpoint,
  }) {
    final cfg = mll.LlmConfiguration(
      apiKey: apiKey,
      model: modelId,
      baseUrl: endpoint,
    );
    switch (provider) {
      case 'anthropic':
        return mll.ClaudeProvider(
          apiKey: apiKey,
          model: modelId,
          baseUrl: endpoint,
          config: cfg,
        );
      case 'openai':
        return mll.OpenAiProvider(
          apiKey: apiKey,
          model: modelId,
          baseUrl: endpoint,
          config: cfg,
        );
      case 'gemini':
        return mll.GeminiProvider(
          apiKey: apiKey,
          model: modelId,
          baseUrl: endpoint,
          config: cfg,
        );
      case 'claude_code':
        // Subscription path, run **without `-p`** (metered from
        // 2026-06-15). The recipe strips `ANTHROPIC_API_KEY` so the call
        // lands on the user's Claude subscription. `endpoint` is reused
        // as the executable path when the host wires a custom location;
        // default `claude` resolves through `PATH`. The `-p`-only knobs
        // (allowedTools / permissionMode / systemMode) are gone.
        return ClaudeCodeInteractiveProvider(
          name: modelId,
          runner: ProcessClaudeRunner(
            executable:
                (endpoint != null && endpoint.isNotEmpty) ? endpoint : 'claude',
          ),
        );
      default:
        return null;
    }
  }
}
