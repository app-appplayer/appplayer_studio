import 'dart:async';
import 'dart:io';

// Builtin = OS-level app — uses host wrapper API.
// Direct `package:brain_kernel` import removed (cleanup Phase 2 — 2026-05-28).
import 'package:appplayer_studio/builtin_api.dart' as mk show BundleActivation;
import 'package:appplayer_studio/builtin_api.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart' show readBundleAt;

import '../adapters/llm_adapter.dart';
import '../config/ops_config.dart';
import '../observability/observability_module.dart';
import '../registries/bundle_installer.dart';
import '../registries/bundle_registry.dart';
import '../registries/knowledge_registry.dart';
import '../registries/member_registry.dart';
import '../registries/process_registry.dart';
import '../registries/task_registry.dart';
import '../registries/workspace_registry.dart';
import '../skills/skill_executor.dart';
import '../skills/skill_registry.dart';
import '../skills/skill_resolver.dart';
import '../util/log.dart';
import 'task_scheduler.dart';
import 'workspace_loader.dart';

/// Engine bootstrap — see `docs/03_DDD/core-knowledge-init.md`.
class KnowledgeInit {
  KnowledgeInit._({
    required this.system,
    required this.registries,
    required this.adapters,
    required this.skills,
    required this.skillResolver,
    required this.skillExecutor,
    required this.scheduler,
    required this.projectRoot,
    List<({mk.BundleActivation activation, mb.McpBundle bundle})> activations =
        const <({mk.BundleActivation activation, mb.McpBundle bundle})>[],
    this.observability,
  }) : _activations =
           List<({mk.BundleActivation activation, mb.McpBundle bundle})>.of(
             activations,
           );

  /// Test-only factory — constructs an instance from already-built parts.
  /// Callers are responsible for matching production wiring.
  @visibleForTesting
  factory KnowledgeInit.forTests({
    required KnowledgeSystem system,
    required Registries registries,
    required Adapters adapters,
    required AppSkillRegistry skills,
    required SkillResolver skillResolver,
    required SkillExecutor skillExecutor,
    required TaskScheduler scheduler,
    String projectRoot = '',
    ObservabilityModule? observability,
  }) => KnowledgeInit._(
    system: system,
    registries: registries,
    adapters: adapters,
    skills: skills,
    skillResolver: skillResolver,
    skillExecutor: skillExecutor,
    scheduler: scheduler,
    projectRoot: projectRoot,
    observability: observability,
  );

  final KnowledgeSystem system;
  final Registries registries;
  final Adapters adapters;
  final AppSkillRegistry skills;
  final SkillResolver skillResolver;
  final SkillExecutor skillExecutor;
  final TaskScheduler scheduler;

  /// Snapshot of `OpsConfig.workspacesRoot` taken at boot — used as the
  /// project-name source for resolving manifest bundle ids (each
  /// `<wsId>.mbd` registers under `<projectRoot.basename>.<wsId>`).
  final String projectRoot;

  /// Active `BundleActivation` instances paired with the `McpBundle`
  /// they activated. The bundle is kept so [dispose] can tear down
  /// every agent id the manifest declared even when the activation
  /// catalog is empty (e.g. when the on-disk KV holds stale entries
  /// from a previous process that the current boot's `BundleActivation`
  /// never added to its in-memory `_registeredAgents`).
  final List<({mk.BundleActivation activation, mb.McpBundle bundle})>
  _activations;

  /// Read agents registered through `BundleActivation` for an Ops
  /// workspace id. Bridges the Ops `WorkspaceRegistry.Workspace.id`
  /// (`_system`, `homepage`, …) to the kernel `KnowledgeSystem.agents`
  /// facade's `workspaceId`, which `BundleActivation` keys with the
  /// manifest's fully-qualified bundle id (`<projectName>.<wsId>`).
  /// Returns an empty list when [projectRoot] is empty (Ops not bound
  /// to a project yet).
  Future<List<Agent>> listKernelAgentsForWorkspace(String wsId) async {
    if (projectRoot.isEmpty) return const <Agent>[];
    final projectName = p.basename(projectRoot);
    final bundleId = '$projectName.$wsId';
    return system.agents.listAgents(workspaceId: bundleId);
  }

  /// The shared `project.mbd` bundle id, under which workspace
  /// knowledge entries register as exposed pool ids
  /// (`<bundleId>.<rawId>`, the `BundleActivation` convention).
  /// Workspace `skill_save` mirrors into `project.mbd`, so a bare skill
  /// id from the appSkills / UI surface forks through this prefix.
  /// Null when no project bundle is active (Ops not bound to a project).
  String? get sharedPoolBundleId {
    for (final a in _activations) {
      if (a.bundle.manifest.id.endsWith('.project')) {
        return a.bundle.manifest.id;
      }
    }
    // Fallback: a transient empty `_activations` (observed when several
    // `project.open` re-boot cycles race within one session) must not drop
    // the pool prefix and silently break raw skill-id normalization.
    // `project.mbd` is the shared pool bundle; its manifest id is
    // `<projectName>.project` by the Ops project seed contract.
    if (projectRoot.isEmpty) return null;
    return '${p.basename(projectRoot)}.project';
  }

  /// Optional — present when the GUI bootstrap path provided one. The
  /// stdio CLI may run without observability (smaller binary, no UI to
  /// drive). Tools that surface telemetry (`diagnostic_export`) check
  /// for null and degrade gracefully.
  final ObservabilityModule? observability;

  /// Broadcast pinged whenever an MCP-triggered config_set_* tool writes
  /// a new [OpsConfig] to disk. Riverpod's opsConfigProvider listens here
  /// so the UI re-reads disk and rebuilds without a manual refresh.
  final StreamController<OpsConfig> _configChanges =
      StreamController<OpsConfig>.broadcast();
  Stream<OpsConfig> get configChanges => _configChanges.stream;
  void notifyConfigChanged(OpsConfig next) => _configChanges.add(next);

  /// When [hostSystem] is non-null, this boot path skips constructing
  /// its own `KnowledgeSystem` (and the FactGraph / SkillRuntime /
  /// ProfileRuntime / PhilosophyEngine / AgentSubsystem wiring that
  /// feeds it) and reuses the host-provided one. Used by the
  /// vibe_studio built-in (`OpsBuiltInApp.ensureBoot`) so chat
  /// dispatch (host) and Ops UI registries land on the same
  /// `KnowledgeSystem` — eliminating the parallel-system split that
  /// hosted-mode Ops had through Phase E.2. When [hostSystem] is null
  /// (standalone Ops main / CLI / tests), the original self-contained
  /// boot path runs.
  ///
  /// Per Phase A scope (ops-internalization-plan §A.2), only the
  /// `KnowledgeSystem` itself is injected. KV now uses the kernel canonical
  /// `KvStoragePortAdapter` (A.3 done — workspace-scoped via `workspaceId`).
  /// Browser / form / ingest are host capabilities (`browser.*` / `form.*`
  /// / `ingest.*`) — built-ins wire them; those ops adapter forks were removed.
  /// LLM / channel still Ops-owned pending cherry's capability decision
  /// (llm → host service + kernel inject; channel → host `channel.*`).
  static Future<KnowledgeInit> boot(
    OpsConfig config, {
    ObservabilityModule? observability,
    KnowledgeSystem? hostSystem,
    ModelSpec? defaultAgentModel,
  }) async {
    OpsLog.boot(
      'init',
      'start activeWs=${config.activeWorkspace} root=${config.workspacesRoot}',
    );
    // 1. KV = kernel canonical file-based KvStoragePort (host-adoptable).
    final kv = KvStoragePortAdapter(
      rootDir: config.storage.localKvPath,
      workspaceId: config.activeWorkspace,
    );

    // 2. LLM holder — host-composed LlmPort pool + inbound MCP serving.
    // Outbound MCP is the host `mcp.*` capability now (S-LLM-2), not here.
    final llm = await LlmAdapter.build(
      llm: config.llm,
      observability: observability,
    );

    // 3. Channel = host `channel.*` capability (mcp_channel connector registry,
    // owned by the host). The ops ChannelAdapter fork was removed; the in-app
    // feed is now one connector behind `channel.*` and skills/notify route
    // through the host endpoint.

    // 4. Browser = host `browser.*` capability (shared engine, owned by the
    // host). Built-ins call it via the host endpoint; the ops BrowserAdapter
    // fork was removed (S3 migration). Skill browser steps + member auth
    // capture route through `browser.*` / `browser.open_login`.

    // 5. Ingest = host `ingest.*` capability (chunking) + flowbrain
    // FactFacade (`system.facts`). Built-ins wire them — see
    // SkillExecutor.ingestFileToFacts — no ops ingest engine. Form likewise
    // = host `form.*`.

    // 6. L0 FactGraph (in-memory; persistence via kv port).
    final factGraph = FactGraphRuntime.inMemory(
      defaultWorkspaceId:
          config.activeWorkspace.isEmpty ? 'default' : config.activeWorkspace,
    );

    // 7. L1 SkillRuntime — flowbrain-native runtime for Bridge events.
    //    YAML-defined skills live in the app-level [AppSkillRegistry]; the
    //    flowbrain SkillRuntime is kept for future Bridge integration but
    //    SkillFacade.execute is not the hot path here.
    final flowbrainSkillRegistry = MemorySkillRegistry();
    // Outbound MCP for skill `mcp` steps routes through the host `mcp.*`
    // capability (SkillExecutor._runMcp → host endpoint), not this port —
    // stub here (S-LLM-2).
    final skillPorts = SkillPorts(
      llm: llm.llmPort,
      mcp: const mb.StubMcpPort(),
    );
    final skillRuntime = SkillRuntime(
      registry: flowbrainSkillRegistry,
      ports: skillPorts,
    );
    final appSkills = AppSkillRegistry();
    final skillResolver = SkillResolver(
      catalog: appSkills,
      workspacesRoot: config.workspacesRoot,
    );

    // L2 ProfileRuntime — registry-backed pool; engines stubbed in v1
    // (Appraisal returns empty metric set, Decision falls back to
    // `proceed`, Expression formats raw content as-is). Workspace yaml
    // seeds populate the registry via [WorkspaceLoader] so AgentFacade's
    // `_poolStarters.profile` enumerates them. Real engines plug in
    // later by replacing `EnginePorts.stub()` here.
    final profileRegistry = ProfileRegistry();
    final profileRuntime = ProfileRuntime(
      registry: profileRegistry,
      engines: EnginePorts.stub(),
    );

    // L3 PhilosophyEngine — single workspace ethos. Persists ethos
    // snapshots through the same KvStoragePort as fork envelopes, so a
    // restart preserves the active ethos. `autoSeedEthos: true` (the
    // default) writes the package's stock ethos when the store is empty
    // — first boot still surfaces a non-null ethos to the philosophy
    // pool starter without the host having to seed manually.
    final ethosStore = KvEthosStoreAdapter(storage: kv);
    final philosophyEngine = PhilosophyEngine(ethosStore: ethosStore);
    await philosophyEngine.initialize();

    // 8. flowbrain KnowledgeSystem — built locally OR adopted from
    //    the host (Phase A.2). When [hostSystem] is provided, skip the
    //    full wiring (factGraph / skillRuntime / profileRuntime /
    //    philosophyEngine / agentSubsystem) since those live inside the
    //    host's system already; reuse the existing instance so chat
    //    dispatch + Ops registries share one source.
    final KnowledgeSystem system;
    final KnowledgeEventBus eventBus;
    if (hostSystem != null) {
      system = hostSystem;
      eventBus = hostSystem.eventBus;
      OpsLog.boot(
        'init',
        'adopted host KnowledgeSystem (workspaceId='
            '${hostSystem.config.workspaceId})',
      );
    } else {
      final knowledgeConfig = KnowledgeConfig.production.copyWith(
        workspaceId:
            config.activeWorkspace.isEmpty ? 'default' : config.activeWorkspace,
      );
      final infraPorts = InfraPorts(
        knowledgePorts: KnowledgePorts(
          llm: llm.llmPort,
          // Outbound MCP = host `mcp.*` capability (kernel clientHost), reached
          // by skill `mcp` steps via the host endpoint. Stub here (S-LLM-2).
          mcp: const mb.StubMcpPort(),
          kvStorage: kv,
          // Kernel-internal notification port: stub. User-facing notify routes
          // through the host `channel.*` capability (channel_notify / skills),
          // not this port.
          notification: mb.StubNotificationPort(),
          // Multi-ethos fork reads through `KnowledgePorts.ethosStore`
          // (mcp_knowledge ≥ 0.2.1). Wire the same adapter
          // PhilosophyEngine uses so per-id ethos resolution works
          // without a separate KnowledgeSystem argument.
          ethosStore: ethosStore,
        ),
        // Forward every wired provider so per-agent ModelSpec routing
        // (`infraPorts.llmProviders[<provider>]`) works out of the box.
        llmProviders: llm.providerPool.isEmpty ? null : llm.providerPool,
      );

      // 8a. Agent Subsystem wire — registry / conversation store / fork
      //     engine / runtime are produced by the helper from a single
      //     (infraPorts, eventBus, config) triplet. The KnowledgeSystem
      //     reference is lazy so the helper can be wired before the
      //     system itself exists.
      eventBus = KnowledgeEventBus();
      late final KnowledgeSystem builtSystem;
      final agentSubsystem = AgentSubsystem.create(
        knowledgeSystemRef: () => builtSystem,
        infraPorts: infraPorts,
        eventBus: eventBus,
        config: knowledgeConfig.agent,
      );

      builtSystem = KnowledgeSystem(
        config: knowledgeConfig,
        infraPorts: infraPorts,
        factGraph: factGraph,
        skillRuntime: skillRuntime,
        profileRuntime: profileRuntime,
        philosophyEngine: philosophyEngine,
        agentRegistry: agentSubsystem.registry,
        agentRuntime: agentSubsystem.runtime,
        eventBus: eventBus,
      );
      system = builtSystem;
    }

    // Surface lifecycle fact write failures to the boot log — without
    // this listener the failure stays silent (`recordLifecycleAsFacts`
    // is best-effort by spec). Lets ops/external LLM diagnose FactGraph
    // adapter issues that would otherwise be invisible.
    eventBus.on<AgentLifecycleFactFailedEvent>().listen((e) {
      OpsLog.warn(
        'lifecycle-fact',
        'write failed for agent=${e.agentId} type=${e.factType}: ${e.error}',
      );
    });

    // Surface KV index/owned-storage corruption to the boot log —
    // emitted by AgentRegistry when a JSON-decoded entry fails to
    // round-trip back into a domain object. Best-effort recovery is
    // already in place (corrupt entries are skipped); this listener
    // lets a host or external LLM see the corruption surface that
    // previously hid behind silent `catch (_) {}` swallows.
    eventBus.on<KvIndexCorruptionEvent>().listen((e) {
      OpsLog.warn(
        'kv-corruption',
        'agent=${e.agentId} kind=${e.keyKind} key=${e.key}: ${e.error}',
      );
    });

    // 8b. Ensure the reserved `_system` workspace exists before the system
    // agent is created — `_ops_admin` lives in this workspace. The
    // WorkspaceRegistry is created here (early) and reused in step 10 so the
    // ensure result is observable everywhere via the same instance.
    //
    // Empty `workspacesRoot` means no project is bound yet — the vibe_studio
    // built-in mounts before the chrome's `newProjectInActive` /
    // `openProjectInActive` lifecycle picks a directory. Calling
    // `ensureSystemWorkspace` here would resolve to `/_system` (root of the
    // filesystem), which fails with `Read-only file system`. Skip the
    // ensure pass; the workspace registry stays empty and every later
    // root-dependent step degrades gracefully until the shell rebinds
    // `ensureBoot(currentProject: ...)`.
    final workspaceRegistry = WorkspaceRegistry(
      kv: kv,
      rootDir: config.workspacesRoot,
    );
    if (config.workspacesRoot.isNotEmpty) {
      await workspaceRegistry.ensureSystemWorkspace();
    }

    // 8c. System administrator agent — chat pane runs through this agent.
    // Created idempotently: skipped when already present so reboots stay
    // cheap. Disabled when OpsConfig.systemAgent.enabled = false.
    // When [hostSystem] is provided, the host has already registered
    // its own `ops.admin` agent through `kStudioAgentProfiles`
    // (Phase E.2) — re-registering would collide on id. The legacy
    // `_ops_admin` (snake_case, distinct from the dotted `ops.admin`)
    // stays the contract for standalone Ops main / CLI; hosted mode
    // routes chat through the host-registered agent.
    if (hostSystem == null && config.systemAgent.enabled) {
      await _ensureSystemAgent(
        system: system,
        agentSettings: config.systemAgent,
        llmSettings: config.llm,
        defaultModel: defaultAgentModel,
      );
    }

    // 10. Registries.
    final registries = Registries(
      workspace: workspaceRegistry,
      member: MemberRegistry(
        kv: kv,
        knowledgeSystem: system,
        rootDir: config.workspacesRoot,
        defaultModel: defaultAgentModel,
      ),
      task: TaskRegistry(
        kv: kv,
        knowledgeSystem: system,
        rootDir: config.workspacesRoot,
      ),
      process: ProcessRegistry(
        kv: kv,
        knowledgeSystem: system,
        rootDir: config.workspacesRoot,
      ),
      knowledge: KnowledgeRegistry(
        kv: kv,
        knowledgeSystem: system,
        rootDir: config.workspacesRoot,
      ),
      bundle: BundleRegistry(
        rootDir: _deriveBundlesRoot(config.workspacesRoot),
      ),
      bundleInstaller: BundleInstaller(
        workspacesRoot: config.workspacesRoot,
        appSkills: appSkills,
      ),
    );
    // Approval escalation (G2+G3): let the process registry resolve a gate
    // approver's org-ancestor chain so a higher org unit can approve on a
    // lower unit's behalf. Wired here where the workspace registry is in
    // scope; null-safe (strict exact-match if left unwired).
    registries.process.ancestorsOf = workspaceRegistry.ancestors;

    OpsLog.boot('init', 'system built');
    // 11. Build the app-level skill executor and attach capabilities.
    final skillExecutor = SkillExecutor(system: system)
      ..attachAdapters(llm: llm, knowledge: registries.knowledge);

    // 11b. Activate the project's mcp_bundle artefacts through the
    // kernel's standard path — `BundleActivation.activate` registers
    // each bundle's `agents` / `skills` / `profiles` / `philosophy` /
    // `facts` / `flows` sections into the shared [KnowledgeSystem]
    // facades. The `project.mbd/` shared bundle plus every
    // `<wsId>.mbd/` workspace bundle materialised under the project
    // root; `_system/` is a free-form runtime dir and not a bundle.
    final activations =
        <({mk.BundleActivation activation, mb.McpBundle bundle})>[];
    if (config.workspacesRoot.isNotEmpty) {
      // Dynamically discover every `.mbd` bundle directly under the
      // project root. Two bundle classes:
      //   * `project.mbd` — organisation-wide shared bundle (knowledge
      //     design + policy, reused across every workspace).
      //   * `<wsId>.mbd` — per-workspace bundle materialised by
      //     `applyOpsWorkspaceSeed` on first `workspace_create`.
      // Both classes flow through the same `BundleActivation.activate`
      // path so the kernel facade pool stays single-source.
      final mbdNames = <String>[];
      try {
        for (final entity in Directory(
          config.workspacesRoot,
        ).listSync(followLinks: false)) {
          if (entity is! Directory) continue;
          final base = p.basename(entity.path);
          if (!base.endsWith('.mbd')) continue;
          mbdNames.add(base);
        }
      } catch (_) {
        /* root missing — boot still proceeds, activations stay empty */
      }
      mbdNames.sort();
      for (final mbdName in mbdNames) {
        final mbdPath = p.join(config.workspacesRoot, mbdName);
        if (!Directory(mbdPath).existsSync()) continue;
        final bundle = readBundleAt(mbdPath);
        if (bundle == null) continue;
        // Pre-clean stale KV entries for this bundle's declared agents.
        // The on-disk KV survives process restarts, so an agent id that
        // a previous boot persisted will collide with this boot's
        // `BundleActivation.registerAgent`. Delete first → register
        // fresh = idempotent upsert.
        for (final ag
            in bundle.agents?.agents ?? const <mb.AgentDefinition>[]) {
          final exposedId = '${bundle.manifest.id}.${ag.id}';
          try {
            await system.agents.deleteAgent(exposedId);
          } catch (_) {
            /* not present — fine */
          }
        }
        final activation = mk.BundleActivation(
          system: system,
          bundleId: bundle.manifest.id,
          // Inject the host tool surface so behavior `do: {tool: ...}` steps
          // (cross-workspace `agent_ask` delegation + the philosophy gate)
          // dispatch. The host endpoint is a `BuiltinToolRegistry` — no raw
          // `KernelServerHost` leaks into builtin code — so `boot` stays null;
          // the skill executor's `callHostTool` is bound to `server.callTool`
          // after boot, and this tear-off resolves it at behavior-run time
          // (which always happens after the bind). See
          // `BundleActivation.callTool` (brain_kernel).
          callTool: skillExecutor.callHostTool,
        );
        final result = await activation.activate(bundle);
        activations.add((activation: activation, bundle: bundle));
        OpsLog.boot(
          'init',
          'bundle activated id=${bundle.manifest.id} '
              'skills=${result.skills} profiles=${result.profiles} '
              'philosophies=${result.philosophies} facts=${result.facts} '
              'flows=${result.flows} agents=${result.agents} '
              'errors=${result.errors.length}',
        );
        for (final e in result.errors) {
          OpsLog.boot('init', 'bundle ${bundle.manifest.id} error: $e');
        }
      }
    }

    OpsLog.boot('init', 'pre-wsload activeWs="${config.activeWorkspace}"');
    // 12. Load active workspace knowledge (agents · skills · philosophy · systems).
    if (config.activeWorkspace.isNotEmpty) {
      await registries.workspace.setActive(config.activeWorkspace);
      await WorkspaceLoader(
        config: config,
        registries: registries,
        system: system,
        appSkills: appSkills,
        executor: skillExecutor,
        ethosStore: ethosStore,
        defaultModel: defaultAgentModel,
      ).loadActive();
      OpsLog.boot('init', 'wsload done — skills=${appSkills.length}');
      // 12b retired — boot used to seed 5 `workspace_insight` sample
      // facts (vendor_terms · q2_clusters · gate_outcome · avg_confidence
      // · process_throughput) for the home page demo. Per the seed
      // cleanup contract (apps.md §0.2 + Ops MOD-APPS-007 — seed ships
      // shared agent + operations-manual knowledge only, project data
      // is user-owned), operational data must not be planted by boot.
      // Home page now reads live registries and shows empty / "No
      // knowledge entries yet" until the user (or `ops.admin` / member
      // agents) writes real facts through the `knowledge_*` tools.
    } else {
      OpsLog.boot('init', 'no active workspace — skipped loader');
    }

    // 13. Start inbound + outbound MCP.
    await llm.start();

    // 14. Scheduler — fires recurring tasks per their cron.
    final scheduler = TaskScheduler(
      tasks: registries.task,
      workspaces: registries.workspace,
    )..start();

    return KnowledgeInit._(
      system: system,
      registries: registries,
      adapters: Adapters(llm: llm, kv: kv),
      skills: appSkills,
      skillResolver: skillResolver,
      skillExecutor: skillExecutor,
      scheduler: scheduler,
      projectRoot: config.workspacesRoot,
      activations: activations,
      observability: observability,
    );
  }

  /// Tear down every `BundleActivation` taken by [boot] so the
  /// `KnowledgeSystem` facades drop this project's entries before the
  /// next ensureBoot rebinds. Agent entries need explicit
  /// `deleteAgent` because `BundleActivation.unregisterAll` documents
  /// agent tear-down as the host's responsibility.
  ///
  /// Two id sources are walked per activation: the activation's own
  /// catalog (`registeredAgents` — agents this boot registered) AND
  /// every agent id declared by the bundle's manifest. The latter
  /// covers KV entries persisted by an earlier boot that the current
  /// catalog never saw — without it those stale entries would survive
  /// dispose and trip `Duplicate agent id` on the next register.
  Future<void> dispose() async {
    for (final entry in _activations) {
      final activation = entry.activation;
      final bundle = entry.bundle;
      // Catalog ids — this boot's own registrations.
      for (final id in activation.registeredAgents) {
        try {
          await system.agents.deleteAgent(id);
        } catch (_) {
          /* best-effort */
        }
      }
      // Manifest ids — covers stale KV entries from prior boots.
      for (final ag in bundle.agents?.agents ?? const <mb.AgentDefinition>[]) {
        final exposedId = '${bundle.manifest.id}.${ag.id}';
        try {
          await system.agents.deleteAgent(exposedId);
        } catch (_) {
          /* best-effort */
        }
      }
      await activation.unregisterAll();
    }
    _activations.clear();
  }

  Future<void> switchWorkspace(String workspaceId) async {
    await registries.workspace.setActive(workspaceId);
    // Re-scan workspace directory so registries see the new workspace contents.
  }

  /// Live-register a behavior into the project bundle's activation so a
  /// freshly-saved process/runbook (`process_save` mirrors it into
  /// `project.mbd`) can `process_start` immediately — without a re-boot to
  /// re-run `BundleActivation`. The run engine resolves
  /// `<projectName>.project.<id>`; this registers the same exposed id live.
  /// No-op when the project bundle activation isn't found.
  void registerProjectBehavior(mb.BehaviorDefinition def) {
    final projName = projectRoot.split(Platform.pathSeparator).last;
    final wantBundleId = '$projName.project';
    for (final a in _activations) {
      if (a.activation.bundleId == wantBundleId) {
        a.activation.registerBehavior(def);
        return;
      }
    }
  }

  Future<void> shutdown() async {
    scheduler.stop();
    await _configChanges.close();
    await adapters.llm.shutdown();
    await system.shutdown();
  }
}

class Registries {
  Registries({
    required this.workspace,
    required this.member,
    required this.task,
    required this.process,
    required this.knowledge,
    required this.bundle,
    required this.bundleInstaller,
  });

  final WorkspaceRegistry workspace;
  final MemberRegistry member;
  final TaskRegistry task;
  final ProcessRegistry process;
  final KnowledgeRegistry knowledge;
  final BundleRegistry bundle;
  final BundleInstaller bundleInstaller;
}

/// Ensure the System administrator agent exists. Creates it idempotently
/// using the configured override / default. The chat pane will route
/// messages through this agent (`agents.ask(systemAgent.id, ...)`).
Future<void> _ensureSystemAgent({
  required KnowledgeSystem system,
  required SystemAgentSettings agentSettings,
  required LlmSettings llmSettings,
  ModelSpec? defaultModel,
}) async {
  final existing = await system.agents.getAgent(agentSettings.id);
  if (existing != null) return;

  // Resolve provider + model:
  //   1. explicit per-agent override (provider/model)
  //   2. host-injected inherited default (configured `settings.llmModel`)
  //   3. Ops yaml LlmSettings default
  //   4. stub — last resort only (fully unwired standalone / test boot)
  final ModelSpec model;
  final overrideProvider = agentSettings.providerOverride;
  final overrideModel = agentSettings.modelOverride;
  if (overrideProvider != null && overrideModel != null) {
    final providerCfg = llmSettings.providers[overrideProvider];
    model = ModelSpec(
      provider: overrideProvider,
      model: overrideModel,
      maxTokens: providerCfg?.maxTokens,
    );
  } else if (defaultModel != null) {
    model = ModelSpec(
      provider: agentSettings.providerOverride ?? defaultModel.provider,
      model: agentSettings.modelOverride ?? defaultModel.model,
      maxTokens: defaultModel.maxTokens,
    );
  } else {
    final providerName =
        agentSettings.providerOverride ??
        (llmSettings.defaultProvider.isEmpty
            ? 'stub'
            : llmSettings.defaultProvider);
    final providerCfg = llmSettings.providers[providerName];
    model = ModelSpec(
      provider: providerName,
      model: agentSettings.modelOverride ?? (providerCfg?.model ?? 'stub-1'),
      maxTokens: providerCfg?.maxTokens,
    );
  }

  await system.agents.createAgent(
    id: agentSettings.id,
    displayName: agentSettings.displayName,
    role: AgentRole.worker,
    model: model,
    workspaceId: agentSettings.workspaceId,
    systemPrompt: agentSettings.systemPrompt ?? _defaultSystemAgentPrompt,
    tags: const {'kind': 'system_admin'},
  );
}

/// Built-in system prompt for the Ops administrator agent. Hosts can
/// override via `OpsConfig.systemAgent.systemPrompt`.
const String _defaultSystemAgentPrompt = '''
You are the makemind Ops administrator agent. You operate this control
panel on behalf of the user — managing workspaces, members, processes,
tasks, and knowledge bundles.

When the user asks you to perform an action, prefer invoking the matching
Ops MCP tool (e.g. `workspace_create`, `member_add_person`,
`process_start`) over writing a free-form description. When tools are not
available or insufficient, answer concisely and explain what is missing.

Always be precise about which workspace and member you are operating on,
and confirm destructive actions before proceeding.
''';

class Adapters {
  Adapters({required this.llm, required this.kv});

  final LlmAdapter llm;
  final KvStoragePortAdapter kv;
}

/// Derive the bundle catalog root from the workspaces root by sibling
/// convention: `<parent>/bundles`. e.g. `apps/Ops/workspaces` →
/// `apps/Ops/bundles`. Falls back to `./bundles` (relative) when the
/// derived path doesn't resolve cleanly — this preserves the legacy
/// behaviour for tests / unusual deployments.
String _deriveBundlesRoot(String workspacesRoot) {
  final norm = workspacesRoot.replaceAll(r'\', '/');
  final lastSep = norm.lastIndexOf('/');
  if (lastSep <= 0) return './bundles';
  return '${norm.substring(0, lastSep)}/bundles';
}
