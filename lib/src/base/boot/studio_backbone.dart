/// Backbone — the wiring result of `StudioBoot.start(...)`. Holds the
/// KernelApp + agent stack + growth recorder for a single host process.
/// Domain code (vibe_app_builder, knowledge tool, ...) reads / mutates
/// through this handle without touching the underlying instances.
///
/// `bundleRegistry` / `knowledgeEngine` are forwarded from the embedded
/// `KernelApp`. The legacy `flowbrain` (`FlowBrainWiring`) field is
/// retired — code reaches the KnowledgeSystem through `backbone.app.system`
/// per cherry's wiring-getter reply (2026-05-24). One mutation site —
/// Ops's multi-provider LLM pool merge — uses the new
/// `AgentLlmSessions.addAll(Map)` helper instead of the old unmodifiable
/// `flowbrain.llmProviders` map.
///
/// Domain-specific objects (canonical · pipeline · validator · projection
/// · llm adapter · server bridge · chat controller · build_tools dispatcher)
/// stay outside the backbone — the host wires them next to the backbone
/// in its main entry.
library;

import 'dart:io' show stderr;

import 'package:brain_kernel/brain_kernel.dart' as fb;
// Extension-transport seam — the outbound mcp_client host (`connectWith`)
// and the transport type the host passes in. Mirrors AppPlayer's
// `connectExtensionTransport` wiring (cherry `embedded-mcp-serving-base`,
// 2026-06-10). The host stays FFI-free: the `ClientTransport` is built
// outside (e.g. by mcp_bridge) and handed in already opened.
import 'package:brain_kernel/mcp_host.dart' show McpClientKernelHost;
import 'package:appplayer_claude_code_provider/appplayer_claude_code_provider.dart'
    show ClaudeCodeInteractiveProvider, ProcessClaudeRunner;
import 'package:mcp_client/mcp_client.dart' show ClientTransport;

import '../agent/agent_host.dart';
import '../install/knowledge_seed_loader.dart';
import '../install/vibe_growth_recorder.dart';

class StudioBackbone {
  StudioBackbone({
    required this.toolId,
    required this.configRoot,
    required this.app,
    required this.clientHost,
    required this.agentHost,
    required this.growth,
    required this.seedLoader,
    this.claudeCodeModelId,
    this.claudeCodeExecutable,
  });

  /// Catalog model id stamped on the `claude_code` adapter (e.g.
  /// `'claude-code'`). Used by [upgradeClaudeCodeForKernel] to swap the
  /// initial subscription-only `ClaudeCodeInteractiveProvider` for the
  /// `forKernel(app, ...)` variant once `app.hostMcpServerSpec` is
  /// available (cherry 2026-05-27 cascade — gives the CLI access to
  /// the host's MCP tool catalog via `--mcp-config`).
  final String? claudeCodeModelId;

  /// `claude` CLI executable path used during boot. Null = default `claude`.
  final String? claudeCodeExecutable;

  /// Host tool identifier — used as `~/.config/<toolId>/` path segment
  /// (or its compat override) and as the FlowBrain workspace id.
  final String toolId;

  /// Root directory for host config — settings · agents · knowledge
  /// bundle registry · seed loader marker. Typically
  /// `~/.config/<toolId>/`.
  final String configRoot;

  /// Booted KernelApp — replaces the old `FlowBrainWiring` field.
  /// `app.system` (KnowledgeSystem) is the cascade entry point;
  /// `app.bundleRegistry` / `app.queryEngine` forward through the
  /// getters below for backward-compatible chrome cascade.
  final fb.KernelApp app;

  /// Typed handle to the booted outbound client host. `app.clientHost`
  /// exposes only the abstract `KernelClientHost`; the concrete
  /// `McpClientKernelHost` carries the `connectWith` extension-transport
  /// seam, so we keep the typed reference for [connectExtensionTransport].
  final McpClientKernelHost clientHost;

  /// Agent registry — null while FlowBrain isn't booted (no API key,
  /// flowbrain init failure, ...).
  final AgentHost? agentHost;

  /// Auto-tracked growth + explicit success recorder. Null when
  /// FlowBrain didn't boot.
  final VibeGrowthRecorder? growth;

  /// Seed loader handle — host calls `loadProjectSeed` on every
  /// project open. Null when FlowBrain didn't boot.
  final KnowledgeSeedLoader? seedLoader;

  /// Persistent list of installed knowledge bundles — forwarded from
  /// `KernelApp.bundleRegistry`.
  fb.KnowledgeBundleRegistry get bundleRegistry => app.bundleRegistry;

  /// BM25 zero-LLM RAG over installed bundles — forwarded from
  /// `KernelApp.queryEngine`.
  fb.KnowledgeQueryEngine get knowledgeEngine => app.queryEngine;

  /// FlowBrain boot status — KernelApp instance existence == booted.
  /// Retained for backward compatibility; callers can drop the guard
  /// where the KernelApp is guaranteed present.
  bool get isFlowBrainBooted => true;

  /// Connect to an external MCP server (e.g. an embedded board) over a
  /// host-supplied **extension transport** (serial / usb / ble / tcp / ws),
  /// injected through the kernel seam (`McpClientKernelHost.connectWith`).
  ///
  /// The transport is built outside the backbone — desktop Studio builds
  /// it through `mcp_bridge` (the opt-in FFI home), opens it, and hands it
  /// in here; brain_kernel / mcp_client / mcp_server stay free of the
  /// transport's platform / FFI dependencies. Returns a connection whose
  /// `callTool` / `readResource` / `listTools` reach the remote server
  /// (e.g. `led.set`, `ui://app`). See `specs/platform/08-extension.md` §4.
  Future<fb.KernelClientConnection> connectExtensionTransport({
    required String id,
    required ClientTransport transport,
  }) => clientHost.connectWith(id: id, transport: transport);

  /// Replace the `claude_code` LLM adapter (initially built without an
  /// MCP server spec since boot order forces it: `_buildProvider` runs
  /// before `KernelApp.boot`) with a `ClaudeCodeInteractiveProvider.forKernel(app,
  /// ...)` adapter so the CLI's `--mcp-config` flag now points at the
  /// host MCP endpoint. Manager / worker agents reach the host catalog
  /// (`bk.*` · `studio.*` · `<bundleId>.*`) as native MCP tools instead
  /// of relying on the catalog text injection the legacy path used.
  ///
  /// Caller responsibility — invoke this after the host endpoint's
  /// transport has started (so `app.hostMcpServerSpec` is non-null).
  /// No-op when `claudeCodeModelId` is null (catalog has no claude_code
  /// entry) or when the spec is still null (transport not up yet).
  void upgradeClaudeCodeForKernel() {
    final modelId = claudeCodeModelId;
    if (modelId == null) {
      stderr.writeln('upgradeClaudeCodeForKernel: SKIP (modelId=null)');
      return;
    }
    // `hostMcpServerSpec` is now a method (cherry 2026-05-27 r2 —
    // multi-endpoint hosts must name the endpoint they wire onto Claude
    // Code's `--mcp-config`). vibe_studio's host MCP endpoint label
    // (see `vibe_studio_host_app.buildServer` — `addEndpoint(label:
    // 'studio')`) is the right key here; domain-spawned narrow links
    // attach under `'narrow:<host>_<port>'` labels and aren't the
    // surface the manager should reach for cross-domain dispatch.
    final spec = app.hostMcpServerSpec(endpointLabel: 'studio');
    if (spec == null) {
      stderr.writeln(
        'upgradeClaudeCodeForKernel: SKIP (spec=null, modelId=$modelId)',
      );
      return;
    }
    stderr.writeln(
      'upgradeClaudeCodeForKernel: swap modelId=$modelId spec.url=${spec.url}',
    );
    // Cherry r3 (2026-05-27) — `ServerBootstrap.startStreamableHttp`
    // now config-sources the spec URL from the transport's `endpoint`
    // setting (default `/mcp`), so `spec.url` already carries the full
    // listening path. No host-side rewrite needed.
    // `_buildArgs` already injects `-p` (line 443 default) — passing it
    // again via `extraArgs` would surface twice on the command line and
    // some CLI versions reject duplicate short flags. Leave `extraArgs`
    // empty so the swap path only adds the kernel's MCP server spec on
    // top of the default arg set.
    //
    // `permissionMode: 'bypassPermissions'` — without an explicit mode
    // Claude Code's CLI default prompts the user before each tool call
    // (`bk.agent.list` → permission dialog → subprocess waits for
    // approval that never arrives in headless / GUI-host context).
    // Cherry's verifier case 8 / 10 / 11 use the same value to keep the
    // subprocess flowing through tool calls without the host needing
    // to surface the prompts back through chrome.
    final provider = ClaudeCodeInteractiveProvider.forKernel(
      app,
      name: modelId,
      runner: ProcessClaudeRunner(executable: claudeCodeExecutable ?? 'claude'),
    );
    final adapter = fb.LlmPortAdapter.fromInterface(
      modelId: modelId,
      provider: provider,
      providerName: 'claude_code',
    );
    // Overwrite under both keys — the dual-key registration the boot
    // path uses (modelId + providerId) so `_resolveLlmFor` lookups
    // (provider key 'claude_code') and host-side per-agent UI lookups
    // (model key 'claude-code') both reach the upgraded adapter.
    // Three-key overwrite — see comment below for why 'anthropic' lands
    // on the same adapter.
    //
    //   modelId       — host-side per-agent UI lookup (`claude-code`)
    //   'claude_code' — `_resolveLlmFor(model.provider='claude_code')`
    //   'anthropic'   — fallback for anthropic-tagged agents when no
    //                   API key is wired (Settings → LLM unfilled). The
    //                   chat chip's fallback indicator already shows
    //                   "Opus 4.7 → Claude Code" in this case; without
    //                   this entry `_resolveLlmFor('anthropic')` would
    //                   miss the pool and fall through to
    //                   `KnowledgeSystem.withAgents`'s captured-at-boot
    //                   default adapter (the pre-swap ClaudeCodeInteractiveProvider
    //                   instance, `mcpServers: null`) → final argv has
    //                   no `--mcp-config`, the manager never sees the
    //                   host MCP catalog. Pointing 'anthropic' at the
    //                   upgraded adapter keeps the fallback in lockstep
    //                   with the active mode A.1 wiring.
    app.agentLlmSessions.addAll(<String, fb.LlmPortAdapter>{
      modelId: adapter,
      'claude_code': adapter,
      'anthropic': adapter,
    });
    stderr.writeln(
      'upgradeClaudeCodeForKernel: swap done · keys=[$modelId, claude_code, anthropic]',
    );
  }
}
