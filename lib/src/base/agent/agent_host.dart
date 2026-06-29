/// AgentHost — registers domain-supplied agent profiles onto the
/// FlowBrain agent layer + exposes per-agent tool surfaces and a single
/// `askAgent` entry point.
///
/// Generic over the catalog: domains pass their own `profiles` list and
/// optional `resolveId` (e.g. legacy id alias map) at construction. The
/// host itself has no knowledge of vibe-specific 7-agent ids.
library;

import '../session/session.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:brain_kernel/brain_kernel.dart' as fb;

import 'agent_profile.dart';

class AgentHost {
  AgentHost({
    required this.flowbrain,
    required this.workspaceId,
    required this.fetchAllToolDefinitions,
    required List<VibeAgentProfile> profiles,
    String Function(String)? resolveId,
    this.defaultAgentModel,
  }) : profiles = List<VibeAgentProfile>.from(profiles),
       resolveId = resolveId ?? _identity;

  final fb.KernelApp flowbrain;
  final String workspaceId;

  /// Inherited default model (configured `settings.llmModel` resolved to a
  /// catalog provider, else the first wired model — see
  /// [StudioBackbone.defaultAgentModel]). Used when synthesising agents
  /// that have no declared model (e.g. a bundle's fallback `<id>.manager`)
  /// so they inherit the configured model instead of a hardcoded one.
  /// Null only when no provider is wired at all.
  final fb.ModelSpec? defaultAgentModel;

  /// Pulls the full tool catalog (every tool the host's dispatcher
  /// knows). Filtered by each profile's `toolNames` to project the
  /// per-agent subset.
  final List<Map<String, dynamic>> Function() fetchAllToolDefinitions;

  /// Mutable agent catalog. Constructor seeds it with the
  /// host-supplied list; activation contracts (`BundleActivationContext.
  /// registerAgent`) extend it at runtime via [addProfile] /
  /// [removeProfile].
  final List<VibeAgentProfile> profiles;

  /// Maps incoming agent ids (e.g. legacy aliases stored in chat.jsonl
  /// or sent by external MCP clients) to current ids. Default = identity.
  final String Function(String) resolveId;

  bool _registered = false;

  /// Process-wide handle for tools (e.g. `agent_dispatch`) that need to
  /// reach the registry without an explicit constructor wire. Set after
  /// `registerAgents()` succeeds; null while FlowBrain hasn't booted.
  static AgentHost? _shared;
  static AgentHost? get shared => _shared;

  /// Idempotent — running twice on the same workspace is a no-op.
  Future<void> registerAgents() async {
    if (_registered) return;
    // KernelApp instance present = booted.
    final agents = flowbrain.system.agents;
    for (final profile in profiles) {
      final existing = await agents.getAgent(profile.id);
      if (existing != null) continue;
      await agents.createAgent(
        id: profile.id,
        displayName: profile.displayName,
        role: profile.role,
        model: fb.ModelSpec(provider: profile.provider, model: profile.modelId),
        systemPrompt: profile.systemPrompt,
        workspaceId: workspaceId,
        tags: <String, String>{
          'origin': 'studio.default',
          'workspace': workspaceId,
        },
      );
    }
    _registered = true;
    _shared = this;
  }

  /// Ensure a scope-qualified clone of [baseId] exists — the studio's
  /// per-project (or per-workspace) chat-context boundary. FlowBrain keys
  /// each agent's conversation by id (`conv/<agentId>/turns`), so a
  /// distinct id per scope = an isolated conversation. The clone reuses
  /// the base's persona (`systemPrompt`), model, role, and tool scope
  /// (`toolNames`); only the conversation differs. The clone is added to
  /// [profiles] (so `toolsFor` resolves its tool scope) AND registered in
  /// the FlowBrain registry (so `ask` finds it). Idempotent. Returns the
  /// qualified id (`<baseId>.<safeScope>`), or [baseId] when the base
  /// profile is unknown (graceful fallback to the shared manager).
  ///
  /// Id scheme = `<baseId>.<readable leaf>_<stable hash of the full scope>`.
  /// The FULL [scope] (e.g. an absolute unit path) is what keeps distinct
  /// units distinct; the leaf (basename) keeps the id legible; the hash
  /// BOUNDS the length — the id is also a `conv/<id>/` directory + chat
  /// filename component, and a raw full path collapsed into one path segment
  /// would blow past the 255-byte filename limit on deep projects — and
  /// avoids the lossy-sanitisation collisions a raw full-path id has (`/`,
  /// `.`, `-` all collapse to `_`, so two distinct paths could map to one id).
  static String _scopedAgentId(String baseId, String scope) {
    if (scope.isEmpty) return baseId;
    final safeLeaf = _scopeLeaf(
      scope,
    ).replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    return '$baseId.${safeLeaf}_${_stableHash(scope)}';
  }

  /// Trailing path segment of a unit [scope] — the human-readable label.
  static String _scopeLeaf(String scope) {
    final parts =
        scope.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? scope : parts.last;
  }

  /// FNV-1a 32-bit, hex — deterministic across runs (unlike `String.hashCode`,
  /// which isn't guaranteed stable across SDK versions and would orphan
  /// persisted conversations on upgrade).
  static String _stableHash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = (h ^ c) & 0xffffffff;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  Future<String> ensureScopedManager(String baseId, String scope) async {
    VibeAgentProfile? base;
    for (final p in profiles) {
      if (p.id == baseId) {
        base = p;
        break;
      }
    }
    if (base == null) return baseId;
    final qualifiedId = _scopedAgentId(baseId, scope);
    if (qualifiedId == baseId) return baseId;
    final label = '${base.displayName} · ${_scopeLeaf(scope)}';
    if (!profiles.any((p) => p.id == qualifiedId)) {
      profiles.add(
        VibeAgentProfile(
          id: qualifiedId,
          displayName: label,
          provider: base.provider,
          modelId: base.modelId,
          systemPrompt: base.systemPrompt,
          toolNames: base.toolNames,
          role: base.role,
        ),
      );
    }
    final agents = flowbrain.system.agents;
    if (await agents.getAgent(qualifiedId) == null) {
      await agents.createAgent(
        id: qualifiedId,
        displayName: label,
        role: base.role,
        model: fb.ModelSpec(provider: base.provider, model: base.modelId),
        systemPrompt: base.systemPrompt,
        workspaceId: workspaceId,
        tags: <String, String>{
          'origin': 'studio.scoped',
          'workspace': workspaceId,
          'base': baseId,
        },
      );
    }
    return qualifiedId;
  }

  /// Per-agent allowed tool definitions handed to LLM tool-use. Two
  /// sources merged:
  ///   1. `profile.toolNames` non-empty → explicit allowlist (manifest
  ///      `agents[i].tools` field). Delegated to
  ///      `KernelApp.toolsForAgent(explicitAllowlist:)` so the helper's
  ///      glob matcher (e.g. `bk.fact.*`) handles patterns.
  ///   2. `profile.toolNames` empty → role-default subset via
  ///      `KernelApp.toolsForAgent(role:, bundleId:)` (cherry 2026-05-27
  ///      per-agent scoping cascade). `manager` sees the master catalog
  ///      (Home / domain manager — coordinator role); `worker` sees only
  ///      its owning bundle's `<bundleId>.*` + `bk.<bundleId>.*` slice;
  ///      `reviewer` sees the read-friendly query surface.
  ///
  /// Bundle ownership = `BundleActivationRegistry.findOwnerOfAgent` so
  /// worker agents land scoped to their activation's exposed namespace.
  /// Host-owned agents (studio.manager / ops.manager / host seed manager)
  /// have no activation owner — passed bundleId stays null and the
  /// helper either returns master (manager role) or empty (worker role
  /// without bundle, which never matches a host-owned agent in practice).
  List<mb.LlmTool> toolsFor(String agentId) {
    final resolved = resolveId(agentId);
    final profile = profiles.firstWhere(
      (p) => p.id == resolved,
      orElse: () => throw StateError('Unknown agent id: $agentId'),
    );
    final owner = fb.BundleActivationRegistry.instance.findOwnerOfAgent(
      resolved,
    );
    return flowbrain.toolsForAgent(
      resolved,
      role: profile.role,
      bundleId: owner?.bundleId,
      explicitAllowlist:
          profile.toolNames.isEmpty ? null : profile.toolNames.toList(),
    );
  }

  /// Direct ask — used by chat panel manager bind, MCP `vibe_agent_ask`,
  /// and the `agent_dispatch` tool. Caller is responsible for dispatching
  /// any toolCalls in the reply via the appropriate dispatcher and
  /// following up with another ask.
  Future<fb.AgentReply> askAgent(String agentId, String message) async {
    final resolved = resolveId(agentId);
    final tools = toolsFor(resolved);
    // Scope tool calls made during this ask to the agent's owning
    // bundle (if any). LLM tool_use payloads dispatched mid-turn
    // see `DispatchContext` and prefix local ids accordingly.
    // Host-default agents (studio.manager / ops.manager / etc., not
    // owned by any BundleActivation) fall back to master so they
    // can read across the union catalog.
    final owner = fb.BundleActivationRegistry.instance.findOwnerOfAgent(
      resolved,
    );
    // Build an ephemeral session so the Zone-scoped run sees the
    // right caller. The session isn't registered with
    // SessionRegistry — it lives only for the duration of this ask
    // (no UI mounts, no subscriptions to track). Long-lived sessions
    // are opened by the host's activate path; this is the one-shot
    // dispatch-time wrapper.
    final session = DispatchSession(
      sessionId: 'ask#$resolved',
      bundleId: owner?.bundleId ?? 'host',
      activation: owner,
      master: owner == null,
    );
    return DispatchContext.instance.runScoped(session, () async {
      return flowbrain.system.agents.ask(
        resolved,
        message,
        tools: tools.isEmpty ? null : tools,
      );
    });
  }

  /// Add a profile after construction — used by the activation
  /// contract when a domain bundle declares agents. Default mode is
  /// idempotent on duplicate ids (returns false). Pass `replace: true`
  /// to **drop the stale catalog entry + delete the FlowBrain agent +
  /// re-create** with the new profile's metadata — required when a
  /// bundle is re-activated after manifest.agents[] changed (model /
  /// systemPrompt / tools), otherwise the old AgentHost instance
  /// lingers and `agent.list` reports both. Calls
  /// `flowbrain.system.agents.createAgent` mirroring [registerAgents].
  Future<bool> addProfile(
    VibeAgentProfile profile, {
    bool replace = false,
  }) async {
    final existingIdx = profiles.indexWhere((p) => p.id == profile.id);
    if (existingIdx >= 0) {
      if (!replace) return false;
      profiles.removeAt(existingIdx);
      try {
        await flowbrain.system.agents.deleteAgent(profile.id);
      } catch (_) {
        /* best-effort */
      }
    }
    final agents = flowbrain.system.agents;
    final existing = await agents.getAgent(profile.id);
    if (existing == null) {
      await agents.createAgent(
        id: profile.id,
        displayName: profile.displayName,
        role: profile.role,
        model: fb.ModelSpec(provider: profile.provider, model: profile.modelId),
        systemPrompt: profile.systemPrompt,
        workspaceId: workspaceId,
        tags: <String, String>{
          'origin': 'studio.activation',
          'workspace': workspaceId,
        },
      );
    }
    profiles.add(profile);
    return true;
  }

  /// Drop a profile — used by activation tear-down. Removes the
  /// catalog entry; the underlying FlowBrain agent is left in place
  /// (cheaper to re-use than re-create) unless the caller passes
  /// `deleteOnFlowBrain: true`.
  Future<bool> removeProfile(
    String agentId, {
    bool deleteOnFlowBrain = false,
  }) async {
    final removed = profiles.where((p) => p.id == agentId).toList();
    if (removed.isEmpty) return false;
    profiles.removeWhere((p) => p.id == agentId);
    if (deleteOnFlowBrain) {
      try {
        await flowbrain.system.agents.deleteAgent(agentId);
      } catch (_) {
        /* best-effort */
      }
    }
    return true;
  }

  /// Catalog lookup. Resolves legacy ids before searching.
  VibeAgentProfile? profileFor(String agentId) {
    final resolved = resolveId(agentId);
    for (final p in profiles) {
      if (p.id == resolved) return p;
    }
    return null;
  }

  static String _identity(String s) => s;
}
