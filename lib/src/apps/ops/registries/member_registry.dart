import 'dart:async';
import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart';
import 'package:yaml/yaml.dart';

import '../infra/ws_paths.dart';
import '../util/atomic_write.dart';

/// See `SRS §2.10 FR-OPS-001` for the design specification.
enum MemberKind { person, agent }

sealed class Member {
  Member({
    required this.id,
    required this.kind,
    required this.displayName,
    this.tags = const {},
  });

  final String id;
  final MemberKind kind;
  final String displayName;
  final Map<String, String> tags;
}

class PersonMember extends Member {
  PersonMember({
    required super.id,
    required super.displayName,
    this.email,
    this.roleLabels = const [],
    super.tags,
  }) : super(kind: MemberKind.person);

  final String? email;
  final List<String> roleLabels;
}

class AgentMember extends Member {
  AgentMember({
    required super.id,
    required super.displayName,
    String? agentId,
    required this.profileRef,
    required this.skillIds,
    required this.philosophyRef,
    this.model,
    this.role = AgentRole.worker,
    this.authProfiles = const [],
    super.tags,
  }) : agentId = agentId ?? id,
       super(kind: MemberKind.agent);

  /// flowbrain Agent id — `system.agents.getAgent(agentId)` resolves to the
  /// underlying self-contained agent. Defaults to [id] for the common 1:1
  /// mapping; kept as a separate field so future iterations can decouple
  /// the workspace surface (Member id) from the flowbrain identity.
  final String agentId;

  /// Per-agent LLM selection. `null` ⇒ boot-time fallback resolves to
  /// `OpsConfig.llm.defaultProvider` / its `model`, then `stub/stub-1`.
  /// Persisted to yaml so reloads keep the same provider/model without
  /// going back to the config default. See `FR-OPS-001`.
  final ModelSpec? model;

  /// Orchestration role (worker / manager / reviewer) — mirrors the kernel
  /// `Agent.role`. Persisted to yaml so a re-role survives a `.kv` rebuild
  /// (the boot mirror seeds the kernel record from this, not a hardcoded
  /// worker). Changed in place via `update(role:)` — never delete→recreate,
  /// which would destroy the agent's accumulated individuality (FactGraph ·
  /// owned forks · history).
  final AgentRole role;

  /// Compatibility fields, slated for gradual deprecation. The new code path
  /// trusts flowbrain `agents.assignProfile` / `assignSkill` etc. — these
  /// fields exist for the UI's quick-display path during the transition.
  final String profileRef;
  final List<String> skillIds;
  final String philosophyRef;

  final List<AuthProfileRef> authProfiles;
}

class AuthProfileRef {
  AuthProfileRef({
    required this.systemId,
    required this.fileRef,
    this.capturedAt,
    this.expiresAt,
  });
  final String systemId;
  final String fileRef;
  final DateTime? capturedAt;
  final DateTime? expiresAt;
}

/// Resolve a member reference to its display name. Accepts EITHER a fully
/// qualified agentId (`<ns>.<ws>.<member>`, e.g. a lifecycle-fact `content.agentId`
/// or an emitted activity actor) OR a bare member id (`proto`, e.g. a task
/// `assigneeId`). Falls back to the last id segment — never the raw qualified
/// id — so a user-facing surface never shows an internal routing id (audit P1.3).
///
/// Lives here (not the UI layer) so both the tool layer (activity emit) and the
/// UI layer (Home feed, Facts view) resolve identically; `ui/_shared/fact_display.dart`
/// re-exports it for existing UI import sites.
String memberDisplayNameFor(Iterable<Member> members, String ref) {
  // Qualified agentId match first (lifecycle facts / emitted actors carry the
  // qualified form).
  for (final m in members) {
    if (m is AgentMember && m.agentId == ref) return m.displayName;
  }
  // Bare member id match — task assignees carry the short id, not the qualified
  // agentId, so without this they fell back to the last-segment id ("proto")
  // instead of the displayName ("Leo"). Covers person members too.
  for (final m in members) {
    if (m.id == ref) return m.displayName;
  }
  final dot = ref.lastIndexOf('.');
  return (dot >= 0 && dot < ref.length - 1) ? ref.substring(dot + 1) : ref;
}

class MemberRegistry {
  MemberRegistry({
    required this.kv,
    required this.knowledgeSystem,
    this.rootDir = './workspaces',
    this.defaultModel,
  });

  final KvStoragePortAdapter kv;
  final KnowledgeSystem knowledgeSystem;
  final String rootDir;

  /// Host-injected default ModelSpec for agents created without an explicit
  /// model — the inherited configured model (resolved from the host's
  /// `settings.llmModel` / first wired catalog model, threaded down via
  /// `StudioBackbone.defaultAgentModel`). When wired, created agents ride a
  /// REAL provider (so a worker the manager spawns can answer); the
  /// [defaultModelSpec] stub is only reached in a fully unwired standalone /
  /// test boot. See FR-OPS-001.
  final ModelSpec? defaultModel;

  final Map<String, Map<String, Member>> _byWorkspace = {};
  final Set<String> _loaded = {};

  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  void _notify() => _changes.add(null);

  Future<List<Member>> listForWorkspace(String wsId) async {
    await _ensureLoaded(wsId);
    return _byWorkspace[wsId]?.values.toList(growable: false) ?? const [];
  }

  Future<Member?> get(String memberId, {String? wsId}) async {
    // Explicit workspace scope: hydrate the target workspace FIRST so a
    // member living in a not-yet-opened workspace resolves. The bare scan
    // below only visits `_byWorkspace.keys` (workspaces already loaded, i.e.
    // whatever the UI happened to open), so an explicit `workspaceId` that
    // was never opened would never be `_ensureLoaded`ed → member missed →
    // caller falls through to a bare id → AgentNotFoundException.
    if (wsId != null) {
      await _ensureLoaded(wsId);
      final m = _byWorkspace[wsId]?[memberId];
      if (m != null) return m;
    }
    for (final ws in _byWorkspace.keys) {
      await _ensureLoaded(ws);
      final m = _byWorkspace[ws]?[memberId];
      if (m != null) return m;
    }
    return null;
  }

  /// Resolve [idOrAgentId] to a member whether the caller passed the bare
  /// member id (`proto`) OR the scoped kernel agentId (`<ns>.<ws>.proto`).
  /// Member records are keyed by the BARE id, so `get` alone misses a scoped
  /// agentId — and an LLM-authored delegation routinely fills the assignee
  /// with the full agentId exposed in the roster. Both forms must map to the
  /// same runnable member, else a `task_run` silently blocks ("assignee is
  /// not a runnable agent"). Bare lookup first (cheap, common); on a miss,
  /// match by `.agentId`; then fall back to the trailing dot segment.
  /// The single canonicalization point for assignee resolution.
  Future<Member?> resolve(String idOrAgentId, {String? wsId}) async {
    final direct = await get(idOrAgentId, wsId: wsId);
    if (direct != null) return direct;
    if (wsId != null) await _ensureLoaded(wsId);
    for (final ws in _byWorkspace.keys) {
      await _ensureLoaded(ws);
      for (final m in _byWorkspace[ws]!.values) {
        if (m is AgentMember && m.agentId == idOrAgentId) return m;
      }
    }
    final dot = idOrAgentId.lastIndexOf('.');
    if (dot > 0 && dot < idOrAgentId.length - 1) {
      return get(idOrAgentId.substring(dot + 1), wsId: wsId);
    }
    return null;
  }

  /// Drop the in-memory cache for [wsId] so the next read re-hydrates from
  /// disk. Called when a workspace is DELETED: `workspace.delete` removes the
  /// `.mbd` bundle (the members' on-disk home), but this registry keeps a
  /// per-workspace cache guarded by `_loaded`, so without eviction a deleted
  /// workspace's members stay resolvable for the rest of the session — the
  /// "half-delete" inconsistency (gone from `workspace_list`, still alive by
  /// explicit `workspaceId`). Clearing `_loaded` + `_byWorkspace` makes the
  /// next `listForWorkspace` / `get` re-scan the now-absent disk dir → empty.
  void evictWorkspace(String wsId) {
    _byWorkspace.remove(wsId);
    _loaded.remove(wsId);
    _notify();
  }

  /// Create an AgentMember and mirror it into flowbrain's Agent Subsystem.
  ///
  /// Flow (FR-OPS-001):
  ///   1. flowbrain `agents.createAgent` — spawns the self-contained agent
  ///      (own LLM context · own ModelSpec · own forked 4-axis storage).
  ///   2. `tryAssign{Skill,Profile,Philosophy}` for each id in the spec —
  ///      best-effort fork. partial-wire (e.g. SkillRuntime null) returns
  ///      false silently for that axis only.
  ///   3. Persist the AgentMember yaml on disk for the workspace UI.
  ///
  /// `model` defaults to [defaultModelSpec] when omitted — typically the
  /// host wires a workspace-level fallback. `agentId` defaults to [id].
  Future<AgentMember> createAgent({
    required String id,
    required String displayName,
    required String profileRef,
    required List<String> skillIds,
    required String philosophyRef,
    required String workspaceId,
    ModelSpec? model,
    String? agentId,
    String? systemPrompt,
    Map<String, String> tags = const {},
    String? rootDir,
    AgentRole role = AgentRole.worker,
  }) async {
    final resolvedAgentId = agentId ?? id;
    if (knowledgeSystem.isAgentSubsystemActivated) {
      final existing = await knowledgeSystem.agents.getAgent(resolvedAgentId);
      if (existing == null) {
        await knowledgeSystem.agents.createAgent(
          id: resolvedAgentId,
          displayName: displayName,
          // Orchestration role (worker / manager / reviewer) — governs which
          // AgentFacade methods are callable (manager routes, reviewer
          // verdicts). Defaults to worker; the ops tool resolves it from the
          // assigned profile's `defaultRole` (profile = the persona/role).
          role: role,
          // Explicit per-call model → host-injected inherited default →
          // stub only as the last resort (unwired standalone / test boot).
          model: model ?? defaultModel ?? defaultModelSpec,
          workspaceId: workspaceId,
          systemPrompt: systemPrompt,
          tags: tags,
        );
      }
      // Best-effort 4-axis fork — partial-wire safe. New agents always seed
      // from the workspace pool; transfer (agent → agent) flows go through
      // the integrated-axis MCP tool instead.
      for (final skillId in skillIds) {
        await knowledgeSystem.agents.tryAssignSkillFromPool(
          resolvedAgentId,
          skillId,
        );
      }
      if (profileRef.isNotEmpty) {
        await knowledgeSystem.agents.tryAssignProfileFromPool(
          resolvedAgentId,
          profileRef,
        );
      }
      if (philosophyRef.isNotEmpty) {
        await knowledgeSystem.agents.tryAssignPhilosophyFromPool(
          resolvedAgentId,
          philosophyRef,
        );
      }
    }

    final agent = AgentMember(
      id: id,
      agentId: resolvedAgentId,
      displayName: displayName,
      profileRef: profileRef,
      skillIds: skillIds,
      philosophyRef: philosophyRef,
      model: model,
      role: role,
      tags: tags,
    );
    await _persist(workspaceId, agent, rootDir ?? this.rootDir);
    _byWorkspace.putIfAbsent(workspaceId, () => {})[id] = agent;
    _notify();
    return agent;
  }

  /// Last-resort ModelSpec when neither a per-call model NOR a host-injected
  /// [defaultModel] is present — i.e. a fully unwired standalone / test boot
  /// with no LLM provider pool. The hosted studio always injects
  /// [defaultModel] (the inherited configured model), so real agents never
  /// land here; this `stub` provider only keeps tests / dry-runs from
  /// requiring a wired pool. NOT a default for created agents.
  static const ModelSpec defaultModelSpec = ModelSpec(
    provider: 'stub',
    model: 'stub-1',
  );

  Future<PersonMember> addPerson({
    required String id,
    required String displayName,
    String? email,
    required String workspaceId,
    List<String> roleLabels = const [],
    String? rootDir,
  }) async {
    final person = PersonMember(
      id: id,
      displayName: displayName,
      email: email,
      roleLabels: roleLabels,
    );
    await _persist(workspaceId, person, rootDir ?? this.rootDir);
    _byWorkspace.putIfAbsent(workspaceId, () => {})[id] = person;
    _notify();
    return person;
  }

  /// Update agent fields or person fields. Only provided args are changed.
  ///
  /// When `model` is provided for an [AgentMember], the in-memory record
  /// and yaml are refreshed and `system.agents.updateAgent(agentId, model:)`
  /// is invoked so the next invocation picks up the new ModelSpec without
  /// a process restart. flowbrain's `Agent.model` stays the single source
  /// of truth at runtime; yaml carries the persisted choice for reloads.
  Future<Member> update({
    required String memberId,
    required String workspaceId,
    String? displayName,
    ModelSpec? model,
    AgentRole? role,
    String? profileRef,
    List<String>? skillIds,
    String? philosophyRef,
    String? email,
    List<String>? roleLabels,
    Map<String, String>? tags,
  }) async {
    // Hydrate the target workspace before reading the cache — an explicit
    // `workspaceId` that was never opened in the UI is absent from
    // `_byWorkspace` and would spuriously throw "Member not found" (the
    // `agent_ask {workspaceId}` resolution family; D4).
    await _ensureLoaded(workspaceId);
    final cur = _byWorkspace[workspaceId]?[memberId];
    if (cur == null)
      throw StateError('Member not found: $memberId in $workspaceId');
    final Member updated;
    if (cur is AgentMember) {
      updated = AgentMember(
        id: cur.id,
        agentId: cur.agentId,
        displayName: displayName ?? cur.displayName,
        profileRef: profileRef ?? cur.profileRef,
        skillIds: skillIds ?? cur.skillIds,
        philosophyRef: philosophyRef ?? cur.philosophyRef,
        model: model ?? cur.model,
        // Re-role IN PLACE — the kernel agent record is updated (below),
        // never deleted+recreated, so the individuality (FactGraph · owned
        // forks · history) is preserved.
        role: role ?? cur.role,
        authProfiles: cur.authProfiles,
        tags: tags ?? cur.tags,
      );
      if ((model != null || role != null) &&
          knowledgeSystem.isAgentSubsystemActivated) {
        try {
          await knowledgeSystem.agents.updateAgent(
            cur.agentId,
            model: model,
            role: role,
          );
        } on StateError {
          // Agent not yet mirrored in flowbrain — yaml persists the choice
          // so the next boot's WorkspaceLoader picks it up. Silent skip.
        }
      }
    } else if (cur is PersonMember) {
      updated = PersonMember(
        id: cur.id,
        displayName: displayName ?? cur.displayName,
        email: email ?? cur.email,
        roleLabels: roleLabels ?? cur.roleLabels,
        tags: tags ?? cur.tags,
      );
    } else {
      throw StateError('Unknown member kind for $memberId');
    }
    await _persist(workspaceId, updated, rootDir);
    _byWorkspace.putIfAbsent(workspaceId, () => {})[memberId] = updated;
    _notify();
    return updated;
  }

  /// Delete a member from a workspace (removes file + cache entry).
  Future<void> deleteMember(String memberId, String workspaceId) async {
    _byWorkspace[workspaceId]?.remove(memberId);
    final file = File('${_membersDir(rootDir, workspaceId)}/$memberId.yaml');
    if (await file.exists()) await file.delete();
    _notify();
  }

  Future<void> attachToWorkspace(String memberId, String wsId) async {
    // N:M: writing a member file into the target workspace dir. In a later
    // revision this becomes a symlink / reference rather than a copy.
    final src = await get(memberId);
    if (src == null) throw StateError('Member not found: $memberId');
    await _persist(wsId, src, rootDir);
    _byWorkspace.putIfAbsent(wsId, () => {})[memberId] = src;
    _notify();
  }

  Future<void> detachFromWorkspace(String memberId, String wsId) async {
    _byWorkspace[wsId]?.remove(memberId);
    // File cleanup: delete the members/<memberId>.yaml in this ws.
    final file = File('${_membersDir(rootDir, wsId)}/$memberId.yaml');
    if (await file.exists()) await file.delete();
    _notify();
  }

  /// Actual capture flow is driven by `MOD-ADAPT-BROWSER`; this method is a
  /// thin passthrough so the UI can record the resulting AuthProfileRef.
  Future<AuthProfileRef> captureAuthProfile({
    required String memberId,
    required String systemId,
    String? rootDir,
  }) async {
    final effectiveRoot = rootDir ?? this.rootDir;
    final m = await get(memberId);
    if (m is! AgentMember) {
      throw StateError('Can only capture auth for agent members: $memberId');
    }
    final fileRef = './auth/$memberId-$systemId.enc';
    final updatedAuths =
        [...m.authProfiles]
          ..removeWhere((a) => a.systemId == systemId)
          ..add(
            AuthProfileRef(
              systemId: systemId,
              fileRef: fileRef,
              capturedAt: DateTime.now(),
            ),
          );
    final updated = AgentMember(
      id: m.id,
      agentId: m.agentId,
      displayName: m.displayName,
      profileRef: m.profileRef,
      skillIds: m.skillIds,
      philosophyRef: m.philosophyRef,
      // Carry model + role through — omitting them here silently wiped the
      // persisted ModelSpec (pre-existing bug) and would wipe the role.
      model: m.model,
      role: m.role,
      authProfiles: updatedAuths,
      tags: m.tags,
    );
    // Propagate to every workspace hosting this member.
    for (final ws in _byWorkspace.keys) {
      if (_byWorkspace[ws]?.containsKey(memberId) == true) {
        await _persist(ws, updated, effectiveRoot);
        _byWorkspace[ws]![memberId] = updated;
      }
    }
    _notify();
    return updatedAuths.last;
  }

  /// 4-axis evolution counters from the underlying flowbrain Agent.
  /// Returns null when the member is not an agent or the Agent Subsystem
  /// is not activated.
  Future<AgentGrowth?> growthStatus(String memberId) async {
    final m = await get(memberId);
    if (m is! AgentMember) return null;
    if (!knowledgeSystem.isAgentSubsystemActivated) return AgentGrowth.zero;
    final agent = await knowledgeSystem.agents.getAgent(m.agentId);
    return agent?.growth ?? AgentGrowth.zero;
  }

  // --- internals ---

  /// Directory holding this workspace's member records — inside the
  /// workspace `.mbd` bundle (see [wsContentRoot]).
  String _membersDir(String root, String wsId) =>
      '${wsContentRoot(root, wsId)}/members';

  Future<void> _ensureLoaded(String wsId) async {
    if (_loaded.contains(wsId)) return;
    final dir = Directory(_membersDir(rootDir, wsId));
    final map = _byWorkspace.putIfAbsent(wsId, () => {});
    if (await dir.exists()) {
      await for (final entry in dir.list()) {
        if (entry is! File) continue;
        if (!entry.path.endsWith('.yaml')) continue;
        try {
          final yaml = loadYaml(await entry.readAsString());
          if (yaml is YamlMap) {
            final m = _fromYaml(Map<String, dynamic>.from(yaml));
            map[m.id] = m;
          }
        } catch (e) {
          stderr.writeln('Member load failed: ${entry.path}: $e');
        }
      }
    }
    _loaded.add(wsId);
  }

  Future<void> _persist(String wsId, Member m, String rootDir) async {
    if (rootDir.isEmpty) {
      throw StateError(
        'MemberRegistry: workspacesRoot not bound — open an Ops project '
        'before creating members.',
      );
    }
    final dir = Directory(_membersDir(rootDir, wsId));
    final file = File('${dir.path}/${m.id}.yaml');
    await writeStringAtomic(file, _toYaml(m));
  }

  Member _fromYaml(Map<String, dynamic> y) {
    final kind = y['kind'] as String? ?? 'agent';
    if (kind == 'person') {
      return PersonMember(
        id: y['id'] as String,
        displayName: (y['displayName'] as String?) ?? y['id'] as String,
        email: y['email'] as String?,
        roleLabels: (y['roleLabels'] as List?)?.cast<String>() ?? const [],
        tags:
            (y['tags'] as Map?)?.map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            ) ??
            const {},
      );
    }
    final authProfiles = <AuthProfileRef>[];
    final rawAuth = y['authProfiles'];
    if (rawAuth is List) {
      for (final a in rawAuth) {
        if (a is Map) {
          authProfiles.add(
            AuthProfileRef(
              systemId: a['systemId'] as String? ?? '',
              fileRef: a['fileRef'] as String? ?? '',
              capturedAt:
                  a['capturedAt'] is String
                      ? DateTime.tryParse(a['capturedAt'] as String)
                      : null,
              expiresAt:
                  a['expiresAt'] is String
                      ? DateTime.tryParse(a['expiresAt'] as String)
                      : null,
            ),
          );
        }
      }
    }
    // Growth counters are owned by flowbrain `Agent.growth` (single source).
    // Any legacy `growth:` block in yaml is ignored on read.

    ModelSpec? model;
    final rawModel = y['model'];
    if (rawModel is Map) {
      final provider = (rawModel['provider'] as String?)?.trim() ?? '';
      final modelId = (rawModel['model'] as String?)?.trim() ?? '';
      if (provider.isNotEmpty && modelId.isNotEmpty) {
        model = ModelSpec(
          provider: provider,
          model: modelId,
          maxTokens: (rawModel['maxTokens'] as num?)?.toInt(),
          temperature: (rawModel['temperature'] as num?)?.toDouble(),
        );
      }
    }

    return AgentMember(
      id: y['id'] as String,
      agentId: y['agentId'] as String?,
      displayName: (y['displayName'] as String?) ?? y['id'] as String,
      profileRef: (y['profileRef'] as String?) ?? '',
      skillIds: (y['skillIds'] as List?)?.cast<String>() ?? const [],
      philosophyRef: (y['philosophyRef'] as String?) ?? '',
      model: model,
      role: AgentRole.values.asNameMap()[y['role'] as String? ?? ''] ??
          AgentRole.worker,
      authProfiles: authProfiles,
      tags:
          (y['tags'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          ) ??
          const {},
    );
  }

  String _toYaml(Member m) {
    final buf = StringBuffer();
    buf.writeln('id: ${m.id}');
    buf.writeln('kind: ${m.kind.name}');
    buf.writeln('displayName: ${m.displayName}');
    if (m is PersonMember) {
      if (m.email != null) buf.writeln('email: ${m.email}');
      if (m.roleLabels.isNotEmpty) {
        buf.writeln('roleLabels:');
        for (final r in m.roleLabels) {
          buf.writeln('  - $r');
        }
      }
    } else if (m is AgentMember) {
      if (m.agentId != m.id) buf.writeln('agentId: ${m.agentId}');
      // Orchestration role — persisted so a re-role survives a .kv rebuild
      // (boot mirror seeds from this). Omitted when worker (the default).
      if (m.role != AgentRole.worker) buf.writeln('role: ${m.role.name}');
      final ms = m.model;
      if (ms != null) {
        buf.writeln('model:');
        buf.writeln('  provider: ${ms.provider}');
        buf.writeln('  model: ${ms.model}');
        if (ms.maxTokens != null) buf.writeln('  maxTokens: ${ms.maxTokens}');
        if (ms.temperature != null) {
          buf.writeln('  temperature: ${ms.temperature}');
        }
      }
      buf.writeln('profileRef: ${m.profileRef}');
      buf.writeln('philosophyRef: ${m.philosophyRef}');
      buf.writeln('skillIds:');
      for (final s in m.skillIds) {
        buf.writeln('  - $s');
      }
      if (m.authProfiles.isNotEmpty) {
        buf.writeln('authProfiles:');
        for (final a in m.authProfiles) {
          buf.writeln('  - systemId: ${a.systemId}');
          buf.writeln('    fileRef: ${a.fileRef}');
          if (a.capturedAt != null) {
            buf.writeln('    capturedAt: ${a.capturedAt!.toIso8601String()}');
          }
          if (a.expiresAt != null) {
            buf.writeln('    expiresAt: ${a.expiresAt!.toIso8601String()}');
          }
        }
      }
      // growth counters live on the flowbrain Agent (`Agent.growth`) — not
      // mirrored into yaml to avoid drift. UI calls `growthStatus` which
      // resolves the up-to-date counters from `system.agents.getAgent`.
    }
    if (m.tags.isNotEmpty) {
      buf.writeln('tags:');
      m.tags.forEach((k, v) => buf.writeln('  $k: $v'));
    }
    return buf.toString();
  }
}
