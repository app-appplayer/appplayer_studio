import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart';
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
  });

  final OpsConfig config;
  final Registries registries;
  final KnowledgeSystem system;
  final AppSkillRegistry appSkills;
  final SkillExecutor executor;
  final EthosStorePort ethosStore;

  Future<void> loadActive() async {
    OpsLog.boot(
      'wsload',
      'activeId=${registries.workspace.activeId} root=${config.workspacesRoot}',
    );
    final wsId = registries.workspace.activeId;
    if (wsId == null) {
      OpsLog.boot('wsload', 'no active workspace');
      return;
    }
    final wsRoot = wsContentRoot(config.workspacesRoot, wsId);

    await registries.workspace.list();
    final members = await registries.member.listForWorkspace(wsId);

    // Skills first — flowbrain SkillRuntime registry must be populated
    // before agent mirroring, otherwise `tryAssignSkillFromPool` returns
    // `false` (SkillRuntime can't find the pool entry). Profiles +
    // philosophies feed the same `tryAssign*FromPool` codepath, so they
    // must also be present before any agent mirror.
    await _loadSkills('$wsRoot/skills');
    OpsLog.boot('wsload', 'registered skills=${appSkills.length}');

    await _loadProfiles('$wsRoot/profiles');
    await _loadPhilosophies('$wsRoot/philosophies');

    await _mirrorAgentMembers(wsId, members);
  }

  /// Ensure every yaml-loaded [AgentMember] has a matching flowbrain
  /// `Agent` record in the Agent Subsystem. Without this mirror, MCP tools
  /// like `agent_assign_skill` / `agent_ask` would throw
  /// `AgentNotFoundException` for any agent that was created via the GUI
  /// (yaml on disk) before the engine restarted. Idempotent — skips agents
  /// that already exist in the flowbrain registry.
  Future<void> _mirrorAgentMembers(String wsId, List<dynamic> members) async {
    if (!system.isAgentSubsystemActivated) return;
    final defaultProvider = config.llm.defaultProvider;
    final providerCfg = config.llm.providers[defaultProvider];
    final fallbackModel = ModelSpec(
      provider: providerCfg != null ? defaultProvider : 'stub',
      model: providerCfg?.model ?? 'stub-1',
      maxTokens: providerCfg?.maxTokens,
    );
    var mirrored = 0;
    var forks = 0;
    for (final m in members) {
      if (m is! AgentMember) continue;
      try {
        final modelSpec = m.model ?? fallbackModel;
        final existing = await system.agents.getAgent(m.agentId);
        if (existing == null) {
          await system.agents.createAgent(
            id: m.agentId,
            displayName: m.displayName,
            role: AgentRole.worker,
            model: modelSpec,
            workspaceId: wsId,
            tags: m.tags,
          );
          mirrored++;
        } else if (m.model != null && existing.model != m.model) {
          // yaml carries a per-agent ModelSpec that drifted from flowbrain's
          // in-memory record (e.g. config-default change between sessions).
          // Reapply yaml as the persisted truth.
          await system.agents.updateAgent(m.agentId, model: m.model);
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
      } catch (e) {
        OpsLog.warn('wsload', 'agent mirror failed for ${m.id}: $e');
      }
    }
    if (mirrored > 0 || forks > 0) {
      OpsLog.boot('wsload', 'agents mirrored=$mirrored · 4-axis forks=$forks');
    }
  }

  Future<void> _loadSkills(String dirPath) async {
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
          appSkills.register(def);
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
  Future<void> _loadPhilosophies(String dirPath) async {
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
    if (firstId != null) {
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
