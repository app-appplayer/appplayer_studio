import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as bundle;
import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

import '../config/ops_config.dart';
import '../registries/member_registry.dart' show AgentMember;
import '../infra/ws_paths.dart';
import '../skills/skill_definition.dart';
import '../skills/skill_executor.dart';
import '../skills/skill_registry.dart';
import '../util/log.dart';
import 'knowledge_init.dart';

/// Loads a workspace's on-disk knowledge into the live `KnowledgeSystem`.
class WorkspaceLoader {
  WorkspaceLoader({
    required this.config,
    required this.registries,
    required this.system,
    required this.appSkills,
    required this.executor,
    required this.ethosStore,
    this.defaultModel,
  });

  final OpsConfig config;
  final Registries registries;
  final KnowledgeSystem system;
  final AppSkillRegistry appSkills;
  final SkillExecutor executor;
  final EthosStorePort ethosStore;

  /// Host-injected inherited default model (from `settings.llmModel` via
  /// [StudioBackbone.defaultAgentModel]). Used as the mirror fallback for
  /// yaml-loaded agents that carry no per-agent ModelSpec, so reloaded
  /// agents ride a REAL provider instead of the stub port. See FR-OPS-001.
  final ModelSpec? defaultModel;

  Future<void> loadActive() async {
    final wsId = registries.workspace.activeId;
    if (wsId == null) {
      OpsLog.boot('wsload', 'no active workspace');
      return;
    }
    await registries.workspace.list();
    await _loadWorkspace(wsId, isActive: true);
  }

  /// Load EVERY workspace's on-disk knowledge so the kernel agent runtime is
  /// workspace-COMPLETE: cross-workspace `agent_ask` / `bk.agent.*` resolve
  /// any member regardless of which workspace is the active UI lens (the
  /// "all departments run concurrently" model — active is a lens, not an
  /// execution gate). Without this, only the boot-active workspace's agents
  /// are mirrored into flowbrain, so `agent_ask({agentId, workspaceId})` for
  /// another department throws `AgentNotFoundException` even though the member
  /// exists on disk.
  ///
  /// The active workspace is loaded LAST so its entries win any shared-pool
  /// (flowbrain skill-mirror / global profile-registry) id collision and it —
  /// and only it — owns the active philosophy.
  Future<void> loadAll() async {
    final activeId = registries.workspace.activeId;
    final workspaces = await registries.workspace.list();
    final ordered = <String>[
      for (final w in workspaces)
        if (w.id != activeId) w.id,
      if (activeId != null) activeId,
    ];
    if (ordered.isEmpty) {
      OpsLog.boot('wsload', 'loadAll: no workspaces');
      return;
    }
    OpsLog.boot(
      'wsload',
      'loadAll: ${ordered.length} workspaces (active=$activeId)',
    );
    for (final wsId in ordered) {
      await _loadWorkspace(wsId, isActive: wsId == activeId);
    }
  }

  /// Load one workspace's skills → profiles → philosophies → agents into the
  /// live system. `isActive` gates the two globally-singular effects so a
  /// non-active workspace never hijacks them: the active philosophy
  /// (`_loadPhilosophies`) and — by virtue of the active-last ordering in
  /// [loadAll] — the winner of any shared-pool id collision.
  Future<void> _loadWorkspace(String wsId, {required bool isActive}) async {
    OpsLog.boot(
      'wsload',
      'load wsId=$wsId active=$isActive root=${config.workspacesRoot}',
    );
    final wsRoot = wsContentRoot(config.workspacesRoot, wsId);
    final members = await registries.member.listForWorkspace(wsId);

    // Skills first — flowbrain SkillRuntime registry must be populated
    // before agent mirroring, otherwise `tryAssignSkillFromPool` returns
    // `false` (SkillRuntime can't find the pool entry). Profiles +
    // philosophies feed the same `tryAssign*FromPool` codepath, so they
    // must also be present before any agent mirror.
    await _loadSkills('$wsRoot/skills', wsId);
    OpsLog.boot('wsload', 'registered skills=${appSkills.length}');

    await _loadProfiles('$wsRoot/profiles');
    await _loadPhilosophies('$wsRoot/philosophies', setActive: isActive);

    await _mirrorAgentMembers(wsId, members, _poolFingerprint(wsRoot));
  }

  /// Deterministic FNV-1a 32-bit hex — stable across process runs (unlike
  /// `String.hashCode`), so a persisted fork signature compares correctly on
  /// the next boot.
  String _stableHash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = (h ^ c) & 0xffffffff;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  /// Content fingerprint of a workspace's 4-axis POOL (skills / profiles /
  /// philosophies yaml): name + a hash of the file BYTES for every `.yaml`,
  /// sorted for determinism. Folded into each member's fork signature so
  /// editing any pool file re-triggers that workspace's forks — the pool is
  /// COPIED into owned storage at fork time, so a signature that ignored the
  /// pool would freeze an edited skill/profile/philosophy at its old content.
  ///
  /// Hashes CONTENT, not size+mtime: boot re-materialisation / re-save can bump
  /// a yaml's mtime without changing its bytes, and an mtime-based fingerprint
  /// would then differ every boot and never let the skip fire.
  String _poolFingerprint(String wsRoot) {
    final parts = <String>[];
    for (final sub in const ['skills', 'profiles', 'philosophies']) {
      final dir = Directory('$wsRoot/$sub');
      if (!dir.existsSync()) continue;
      final files = dir.listSync().whereType<File>().where(
        (f) => f.path.endsWith('.yaml'),
      ).toList()..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        String body;
        try {
          body = f.readAsStringSync();
        } catch (_) {
          body = '';
        }
        parts.add('${f.path}:${_stableHash(body)}');
      }
    }
    return _stableHash(parts.join('|'));
  }

  /// Ensure every yaml-loaded [AgentMember] has a matching flowbrain
  /// `Agent` record in the Agent Subsystem. Without this mirror, MCP tools
  /// like `agent_assign_skill` / `agent_ask` would throw
  /// `AgentNotFoundException` for any agent that was created via the GUI
  /// (yaml on disk) before the engine restarted. Idempotent — skips agents
  /// that already exist in the flowbrain registry.
  Future<void> _mirrorAgentMembers(
    String wsId,
    List<dynamic> members,
    String poolSig,
  ) async {
    if (!system.isAgentSubsystemActivated) return;
    // Workspace title for the agent self-identity prompt (test2 #3 — a worker
    // agent must know its own name + department, not guess the operator or
    // another persona from ambient context).
    final ws = await registries.workspace.get(wsId);
    final wsTitle = ws?.title ?? wsId;
    // The workspace's effective HARD charter prohibitions, resolved ONCE along
    // its own ancestor chain (company ∘ dept ∘ own). Seated into every member's
    // resident self-identity prompt so the organization's non-negotiable rules
    // fire even in an ungated direct `agent_ask` — not only when a process
    // `philosophy_check` gate happens to run. (Injection-layer gap: a member
    // knows its charter via the pull layer / a reactive gate, but does not
    // re-read it at the moment it acts, so a "classify then refer" rule silently
    // goes unapplied under a direct request.)
    final charterRules = await effectiveHardProhibitions(wsId);
    // Fallback model for yaml agents without a per-agent ModelSpec:
    //   1. host-injected inherited default (configured `settings.llmModel`)
    //   2. explicit Ops yaml provider (`~/.makemind-ops/config.yaml` llm)
    //   3. stub — last resort only (fully unwired standalone / test boot)
    final defaultProvider = config.llm.defaultProvider;
    final providerCfg = config.llm.providers[defaultProvider];
    final fallbackModel =
        defaultModel ??
        (providerCfg != null
            ? ModelSpec(
              provider: defaultProvider,
              model: providerCfg.model,
              maxTokens: providerCfg.maxTokens,
            )
            : const ModelSpec(provider: 'stub', model: 'stub-1'));
    var mirrored = 0;
    var forks = 0;
    var forkSkipped = 0;
    for (final m in members) {
      if (m is! AgentMember) continue;
      try {
        final modelSpec = m.model ?? fallbackModel;
        final existing = await system.agents.getAgent(m.agentId);
        // Fork signature = workspace pool fingerprint + this member's 4-axis
        // assignment refs. A match against the persisted `ops_fork_sig` tag
        // means nothing that feeds `tryAssign*FromPool` changed since the last
        // boot, so the (persisted) owned forks are already current and the
        // re-fork is pure overhead.
        final skillPart = ([...m.skillIds]..sort()).join(',');
        final sig = _stableHash(
          '$poolSig|$skillPart|${m.profileRef}|${m.philosophyRef}',
        );
        var applyForks = true;
        if (existing == null) {
          await system.agents.createAgent(
            id: m.agentId,
            displayName: m.displayName,
            // Seed from the yaml-persisted role (not a hardcoded worker) so
            // a re-role survives a `.kv` rebuild — the member yaml is the
            // durable record, the kernel Agent the runtime one.
            role: m.role,
            model: modelSpec,
            workspaceId: wsId,
            systemPrompt: _identityPrompt(m, wsId, wsTitle, charterRules),
            tags: m.tags,
          );
          mirrored++;
        } else {
          // Already mirrored — persisted across a `.kv`-backed reboot. Re-seed
          // the runtime fields that drift from the durable record: a yaml
          // ModelSpec change (e.g. config-default change between sessions) and
          // the self-identity prompt (composed fresh here — not persisted on
          // the member yaml, so an agent created before this wiring still
          // gains its identity on the next boot).
          final identity = _identityPrompt(m, wsId, wsTitle, charterRules);
          final modelDrift = m.model != null && existing.model != m.model;
          final promptDrift = existing.systemPrompt != identity;
          if (modelDrift || promptDrift) {
            await system.agents.updateAgent(
              m.agentId,
              model: modelDrift ? m.model : null,
              systemPrompt: promptDrift ? identity : null,
            );
          }
          // Skip the 4-axis re-fork when the signature is unchanged — the
          // owned forks persist across the `.kv` reboot, so re-applying an
          // identical assignment set from an identical pool is wasted boot
          // work (the dominant cost when every workspace is loaded eagerly
          // because "active workspace" is a view, not an execution gate).
          applyForks = existing.tags['ops_fork_sig'] != sig;
        }
        if (!applyForks) {
          forkSkipped++;
          continue;
        }
        // Mirror the yaml-declared 4-axis assignments into flowbrain owned
        // storage. Without this step the AgentMember.skillIds list shows
        // "N skills" in the member tile but AgentDetailView's owned-forks
        // lists stay empty — yaml is declarative, owned storage is the
        // truth. `tryAssign*FromPool` is idempotent (existing forks are
        // overwritten with the same forkedRef, conflicting refs throw —
        // both safe at boot since the source ref is unchanged).
        for (final skillId in m.skillIds) {
          if (skillId.isEmpty) continue;
          final ok = await system.agents.tryAssignSkillFromPool(
            m.agentId,
            skillId,
          );
          if (ok) forks++;
        }
        if (m.profileRef.isNotEmpty) {
          final ok = await system.agents.tryAssignProfileFromPool(
            m.agentId,
            m.profileRef,
          );
          if (ok) forks++;
        }
        if (m.philosophyRef.isNotEmpty) {
          final ok = await system.agents.tryAssignPhilosophyFromPool(
            m.agentId,
            m.philosophyRef,
          );
          if (ok) forks++;
        }
        // Stamp the signature so the next boot can skip this member's re-fork
        // while nothing that feeds it changes. Carry m.tags (the durable
        // record) — update replaces the tag map.
        await system.agents.updateAgent(
          m.agentId,
          tags: <String, String>{...m.tags, 'ops_fork_sig': sig},
        );
      } catch (e) {
        OpsLog.warn('wsload', 'agent mirror failed for ${m.id}: $e');
      }
    }
    if (mirrored > 0 || forks > 0 || forkSkipped > 0) {
      OpsLog.boot(
        'wsload',
        'agents mirrored=$mirrored · 4-axis forks=$forks · '
        'fork-skip=$forkSkipped',
      );
    }
  }

  /// The ambient self-identity anchor for a worker agent: who it is and which
  /// department it belongs to, plus the non-negotiable HARD prohibitions of its
  /// organization's charter. Seeded as the kernel Agent `systemPrompt` at mirror
  /// time. The operator's admin agent has its own system prompt — workers get
  /// this so they stop answering with the operator's or another persona's
  /// identity (test2 #3), and so a charter's hard rule fires at the moment they
  /// act (not only inside a process `philosophy_check` gate — [charterRules]).
  String _identityPrompt(
    AgentMember m,
    String wsId,
    String wsTitle,
    List<String> charterRules,
  ) {
    final base =
        'You are ${m.displayName}, a ${m.role.name} in the "$wsTitle" '
        'workspace ($wsId) of this makemind Ops organization. When asked who '
        'you are or which team/department you belong to, answer with this '
        'identity — never the operator or another persona.';
    if (charterRules.isEmpty) return base;
    final rules = charterRules.map((r) => '  • $r').join('\n');
    return '$base\n\n'
        'Charter — non-negotiable rules of your organization. These HARD '
        'prohibitions ALWAYS apply, including to a direct request: honor them '
        'at the moment you act — classify, refer, or refuse exactly as the rule '
        'requires; never just proceed against one:\n$rules';
  }

  /// The HARD charter prohibition statements in force for [wsId], accumulated
  /// along its own ancestor chain (self → parents; same line only, never a
  /// sibling branch — mirrors [SystemTools._charterChain] but returns just the
  /// hard statements to seat in a member's resident prompt). Empty when the
  /// philosophy subsystem is unavailable or no charter is set anywhere on the
  /// chain (backward compatible — the prompt then stays the bare identity).
  /// Best-effort: a member's OWN-workspace charter is loaded before this runs
  /// (`_loadPhilosophies` precedes `_mirrorAgentMembers`); an ancestor charter
  /// not yet loaded this boot is picked up on the next boot via prompt-drift.
  /// Effective HARD prohibition statements for [wsId] — its own charter plus
  /// every LIVE ancestor's charter (archived ancestors are skipped; see the
  /// in-loop rationale). Public only for tests (`org_delete_charter_semantics`);
  /// production callers stay inside the loader.
  @visibleForTesting
  Future<List<String>> effectiveHardProhibitions(String wsId) async {
    final phil = system.philosophy;
    if (!phil.isAvailable) return const <String>[];
    final out = <String>[];
    final seen = <String>{};
    final chain = <String>[
      wsId,
      ...await registries.workspace.ancestors(wsId),
    ];
    for (final id in chain) {
      // Active context must load charter only for LIVE workspaces. An archived
      // (deactivated-but-retained) ancestor's charter must NOT leak into a live
      // descendant's effective prohibitions — the org was dissolved; its
      // institutional memory is retained for history, not to keep governing.
      final ws = await registries.workspace.get(id);
      if (ws != null && ws.archived) continue;
      final charterId = 'charter.$id';
      try {
        final e = await phil.getEthosById(charterId);
        // getEthosById may fall back to the active ethos for an unknown id —
        // only accept the ethos that is THIS level's own charter.
        if (e.id != charterId) continue;
        for (final pr in e.prohibitions) {
          if (pr.severity != bundle.ProhibitionSeverity.hard) continue;
          final s = pr.statement.trim();
          if (s.isNotEmpty && seen.add(s)) out.add(s);
        }
      } catch (_) {
        // A missing / malformed charter must not break member boot.
      }
    }
    return out;
  }

  Future<void> _loadSkills(String dirPath, String wsId) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      OpsLog.boot('wsload', 'skill scan skip missing: $dirPath');
      return;
    }
    OpsLog.boot('wsload', 'skill scan: $dirPath');
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.yaml') && !entity.path.endsWith('.yml')) {
        continue;
      }
      try {
        final raw = await entity.readAsString();
        final yaml = loadYaml(raw);
        if (yaml is YamlMap) {
          final def = SkillDefinition.fromYaml(_recursivelyToMap(yaml));
          // Tag with the owning workspace so the resolver scopes visibility —
          // these are workspace-authored, not globally-visible templates.
          appSkills.register(def, workspaceId: wsId);
          await _mirrorSkillToFlowbrain(def);
        }
      } catch (e) {
        OpsLog.warn('wsload', 'skill load failed: ${entity.path}: $e');
      }
    }
  }

  /// Read every `profiles/*.yaml` file in [dirPath] and register the
  /// resulting `Profile` with flowbrain's L2 `ProfileRegistry`. Each file
  /// must shape its top-level keys to match `Profile.fromJson` (id, name,
  /// version, sections, capabilities, metadata, tags, parentId, active).
  ///
  /// Best-effort — missing dir / parse errors / registry rejection log
  /// `OpsLog.warn` and continue, so a malformed profile never aborts the
  /// boot path.
  Future<void> _loadProfiles(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      OpsLog.boot('wsload', 'profile scan skip missing: $dirPath');
      return;
    }
    OpsLog.boot('wsload', 'profile scan: $dirPath');
    var registered = 0;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.yaml') && !entity.path.endsWith('.yml')) {
        continue;
      }
      try {
        final raw = await entity.readAsString();
        final yaml = loadYaml(raw);
        if (yaml is! YamlMap) continue;
        final map = _recursivelyToMap(yaml);
        final profile = Profile.fromJson(map);
        if (profile.id.isEmpty) {
          OpsLog.warn('wsload', 'profile missing id: ${entity.path}');
          continue;
        }
        system.profile.register(profile);
        registered++;
      } catch (e) {
        OpsLog.warn('wsload', 'profile load failed: ${entity.path}: $e');
      }
    }
    OpsLog.boot('wsload', 'profiles registered=$registered');
  }

  /// Read every `philosophies/*.yaml` file in [dirPath] and seed each as
  /// an [EthosRecord] in the wired [EthosStorePort]. The first file in
  /// scan order is set active so the philosophy pool starter has a
  /// stable default; later files become available via
  /// `EthosStorePort.activateEthos(id)` from the UI.
  ///
  /// Yaml shape matches `Ethos.fromJson` (id, name, version,
  /// valuePriorities, prohibitions, judgmentCriteria, directionalAttitudes,
  /// metadata, scopes). The decoded `Ethos` is stored as `EthosRecord`
  /// payload via `Ethos.toJson()`.
  Future<void> _loadPhilosophies(
    String dirPath, {
    required bool setActive,
  }) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      OpsLog.boot('wsload', 'philosophy scan skip missing: $dirPath');
      return;
    }
    OpsLog.boot('wsload', 'philosophy scan: $dirPath');
    var seeded = 0;
    String? firstId;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.yaml') && !entity.path.endsWith('.yml')) {
        continue;
      }
      try {
        final raw = await entity.readAsString();
        final yaml = loadYaml(raw);
        if (yaml is! YamlMap) continue;
        final map = _recursivelyToMap(yaml);
        final ethos = Ethos.fromJson(map);
        if (ethos.id.isEmpty) {
          OpsLog.warn('wsload', 'philosophy missing id: ${entity.path}');
          continue;
        }
        final record = EthosRecord(
          id: ethos.id,
          name: ethos.name,
          version: '1',
          payload: ethos.toJson(),
          createdAt: DateTime.now(),
        );
        await ethosStore.putEthos(record);
        firstId ??= ethos.id;
        seeded++;
      } catch (e) {
        OpsLog.warn('wsload', 'philosophy load failed: ${entity.path}: $e');
      }
    }
    if (firstId != null && setActive) {
      try {
        await ethosStore.activateEthos(firstId);
      } catch (e) {
        OpsLog.warn('wsload', 'philosophy activate failed for $firstId: $e');
      }
    }
    OpsLog.boot('wsload', 'philosophies seeded=$seeded active=$firstId');
  }

  /// Mirror an Ops [SkillDefinition] into flowbrain's `SkillRuntime.registry`
  /// as a minimal [SkillBundle] wrapper. The wrapper is metadata-only —
  /// real execution stays on `AppSkillRegistry` + `SkillExecutor` — but its
  /// presence makes `agents.assignSkill(agent, PoolForkSource(skillId))`
  /// resolve the pool source so transfer / lifecycle facts work end-to-end.
  /// Without this mirror, every fork attempt against an Ops skill returns
  /// `false` (SkillRuntime registry has no entry).
  ///
  /// Best-effort — `SkillRuntime` not wired or registry rejection is logged
  /// and skipped, so skill load never aborts the boot path.
  Future<void> _mirrorSkillToFlowbrain(SkillDefinition def) async {
    final runtime = system.skillRuntime;
    if (runtime == null) return;
    try {
      final bundle = SkillBundle(
        schemaVersion: '0.1.0',
        manifest: SkillManifest(
          id: def.id,
          name: def.id,
          version: '${def.version}',
          provider: 'makemind-ops',
          description: def.description.isEmpty ? null : def.description,
        ),
        procedures: [
          Procedure(
            id: '${def.id}-default',
            name: def.id,
            description: def.description.isEmpty ? null : def.description,
            steps: const [],
          ),
        ],
        extensions: <String, dynamic>{
          if (def.tags.isNotEmpty) 'ops:tags': def.tags,
          if (def.inputSchema.isNotEmpty) 'ops:inputSchema': def.inputSchema,
          if (def.outputSchema.isNotEmpty) 'ops:outputSchema': def.outputSchema,
        },
      );
      await runtime.registry.registerSkill(bundle);
    } catch (e) {
      OpsLog.warn('wsload', 'skill mirror failed for ${def.id}: $e');
    }
  }

  Map<String, dynamic> _recursivelyToMap(Object? node) {
    if (node is YamlMap) {
      return node.map((k, v) => MapEntry(k.toString(), _convertValue(v)));
    }
    return <String, dynamic>{};
  }

  Object? _convertValue(Object? v) {
    if (v is YamlMap) return _recursivelyToMap(v);
    if (v is YamlList) return v.map(_convertValue).toList();
    return v;
  }
}
