import 'dart:convert';

import 'package:appplayer_studio/base.dart' show BuiltinToolRegistry;
import 'package:appplayer_studio/builtin_api.dart'
    show AgentAxis, IntegratedAxisEntry, KernelTextContent;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;

import '../config/ops_config.dart';
import '../init/knowledge_init.dart';
import '../ops_builtin.dart' show OpsBuiltInApp;
import '../observability/activity_bus.dart';
import '../observability/activity_event.dart';
import '../observability/observability_module.dart';
import '../observability/telemetry_store.dart';
import '../registries/bundle_installer.dart';
import '../registries/bundle_registry.dart';
import '../registries/knowledge_registry.dart' show KvFactEntry;
import '../registries/member_registry.dart';
import '../registries/process_registry.dart';
import '../registries/task_registry.dart';
import '../registries/workspace_registry.dart';
import '../skills/skill_definition.dart';
import '../ui/_shared/fact_display.dart';
import '../ui/organization/org_chart_model.dart';
import '../ui/organization/org_overlay.dart';
import '../ui/home/today_flow_card.dart' show TodayFlowData, pollTodayFlow;

/// Global bootstrap handles — overridden at the scoped [ProviderScope] in
/// `main.dart` after [KnowledgeInit.boot]. All derived providers below list
/// this one as a dependency so Riverpod knows to re-resolve them within the
/// override subtree.
final knowledgeInitProvider = Provider<KnowledgeInit>(
  (ref) => throw UnimplementedError('KnowledgeInit not yet bootstrapped'),
  dependencies: const [],
);

/// Ops providers fail fast: one that throws (a service not yet
/// bootstrapped, a registry read that failed) reports the error once
/// instead of being retried in the background.
Duration? opsNoRetry(int retryCount, Object error) => null;

/// Host [BuiltinToolRegistry] handle, injected at the OpsShell
/// `ProviderScope` from `mount`. Lets UI actions reach Ops's own MCP
/// tools — and the universal `studio.builder.*` host tools those chain
/// to — via `callTool`, so every button maps 1:1 to a tool instead of
/// mutating registries directly (built-in parity rule — a page calling a
/// registry class straight is a violation).
final opsToolServerProvider = Provider<BuiltinToolRegistry>(
  (ref) => throw UnimplementedError('tool server not yet bootstrapped'),
  dependencies: const [],
);

/// Invoke an Ops MCP tool by [name] through the host tool registry and
/// return its decoded JSON result map. This is the canonical UI→tool
/// path: UI actions call this instead of touching `registries.*`
/// directly, keeping the button↔tool 1:1 mapping. Throws [StateError]
/// when the tool reports an error so callers surface it like any other
/// failure.
Future<Map<String, dynamic>> opsCallTool(
  WidgetRef ref,
  String name,
  Map<String, dynamic> args,
) async {
  final server = ref.read(opsToolServerProvider);
  final result = await server.callTool(name, args);
  final text =
      result.content.whereType<KernelTextContent>().map((c) => c.text).join();
  if (result.isError == true) {
    throw StateError('tool $name failed: $text');
  }
  if (text.isEmpty) return const <String, dynamic>{};
  final decoded = jsonDecode(text);
  return decoded is Map<String, dynamic>
      ? decoded
      : <String, dynamic>{'result': decoded};
}

// `mcpInboundProvider` removed in the builtin-os-cleanup round
// (2026-05-28). Ops no longer owns a separate MCP transport / sampling
// handle — everything routes through the host endpoint
// (`http://127.0.0.1:7840/mcp`) and the host's chat panel tool-use
// loop.

/// Observability subsystem — [ActivityBus] + [TelemetryStore].
/// Bootstrapped at app start in main.dart and overridden into the booted
/// [ProviderScope]. Live Feed, Status Bar, and Diagnostic Export consume
/// from this single instance.
final observabilityProvider = Provider<ObservabilityModule>(
  (ref) => throw UnimplementedError('ObservabilityModule not yet bootstrapped'),
  dependencies: const [],
);

/// Stream of activity events from the bus. Consumed by the Live Activity
/// Feed page; Status Bar derives counters from [telemetryProvider] instead.
final activityStreamProvider = StreamProvider<ActivityEvent>(
  (ref) => ref.watch(observabilityProvider).bus.stream,
  dependencies: [observabilityProvider],
);

/// Snapshot of the in-memory ring buffer (oldest first). Re-resolves on
/// every emitted event so the Live Feed shows the full window without
/// the consumer needing to maintain its own list.
final activitySnapshotProvider = StreamProvider<List<ActivityEvent>>((ref) {
  final bus = ref.watch(observabilityProvider).bus;
  return bus.stream.map((_) => bus.recent).asBroadcastStream();
}, dependencies: [observabilityProvider]);

/// Cumulative telemetry. Status Bar / Diagnostics rebuild on every tick.
final telemetryProvider = StreamProvider<TelemetryStore>((ref) {
  final t = ref.watch(observabilityProvider).telemetry;
  return t.ticks.map((_) => t).asBroadcastStream();
}, dependencies: [observabilityProvider]);

/// Active app theme mode — `system | light | dark`. Watched by the
/// outermost [MaterialApp] so theme switching takes effect immediately.
/// Lives in the root ProviderScope (not the post-boot scope) so the
/// MaterialApp can read it from above the boot logic.
///
/// Initial value is overwritten from [OpsConfig.themeMode] once the
/// config has been loaded; default during the brief boot window is dark
/// to match the historic behavior.
final opsThemeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.dark);

ThemeMode parseThemeMode(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'system':
      return ThemeMode.system;
    case 'light':
      return ThemeMode.light;
    case 'dark':
    default:
      return ThemeMode.dark;
  }
}

/// Currently loaded [OpsConfig]. The shell uses [appNameProvider] derived
/// from this for the AppBar / window title so users can rebrand the app.
///
/// Initial value is provided via override at boot (main.dart). MCP-triggered
/// config writes (config_set_chromium, config_set_llm_provider, etc.) push
/// the new [OpsConfig] through [configChangesProvider]; main.dart's
/// _ConfigStreamSync listens to that provider and writes into this state,
/// so the UI rebuilds without a manual refresh.
final opsConfigProvider = StateProvider<OpsConfig>(
  (ref) => throw UnimplementedError('OpsConfig not yet bootstrapped'),
  dependencies: const [],
);

/// Pings whenever any MCP config_set_* tool writes a new [OpsConfig] to
/// disk. main.dart bridges this stream into [opsConfigProvider].
final configChangesProvider = StreamProvider<OpsConfig>((ref) {
  return ref.watch(knowledgeInitProvider).configChanges;
}, dependencies: [knowledgeInitProvider]);

/// Display name for the app shown in the AppBar and OS window title.
/// Reads from [opsConfigProvider]; falls back to [OpsConfig.defaultAppName]
/// when the value is empty (e.g., first-run before save).
final appNameProvider = Provider<String>((ref) {
  final name = ref.watch(opsConfigProvider).appName.trim();
  return name.isEmpty ? OpsConfig.defaultAppName : name;
}, dependencies: [opsConfigProvider]);

/// SSE endpoint URL when the in-app MCP server is listening.
final mcpSseEndpointProvider = Provider<String?>(
  (ref) => null,
  dependencies: const [],
);

// --- Change notification streams ---
// Each registry exposes a broadcast stream of mutation events. The stream
// providers below convert those into Riverpod `AsyncValue`s. Downstream
// list providers `ref.watch` the matching tick so any mutation — whether
// triggered by the UI or by an MCP tool call — automatically invalidates
// the cached list and the UI rebuilds.
//
// Each tick is a running count, not the raw `void` event: Riverpod skips an
// update whose value equals the previous one, so a stream that always emits
// `null` would notify its watchers once and then go silent.

/// Counts [changes] events so every mutation is a distinct provider value.
Stream<int> changeTicks(Stream<void> changes) {
  var count = 0;
  return changes.map((_) => ++count);
}

final workspaceChangesProvider = StreamProvider<int>((ref) {
  return changeTicks(
    ref.watch(knowledgeInitProvider).registries.workspace.changes,
  );
}, dependencies: [knowledgeInitProvider]);

final memberChangesProvider = StreamProvider<int>((ref) {
  return changeTicks(
    ref.watch(knowledgeInitProvider).registries.member.changes,
  );
}, dependencies: [knowledgeInitProvider]);

final taskChangesProvider = StreamProvider<int>((ref) {
  return changeTicks(ref.watch(knowledgeInitProvider).registries.task.changes);
}, dependencies: [knowledgeInitProvider]);

final processChangesProvider = StreamProvider<int>((ref) {
  return changeTicks(
    ref.watch(knowledgeInitProvider).registries.process.changes,
  );
}, dependencies: [knowledgeInitProvider]);

final skillChangesProvider = StreamProvider<int>((ref) {
  return changeTicks(ref.watch(knowledgeInitProvider).skills.changes);
}, dependencies: [knowledgeInitProvider]);

/// Skill definitions visible in the active workspace — own workspace, its org
/// ancestors, and genuine templates — resolved exactly like the `skill_list`
/// tool so the UI never lists a sibling/parent workspace's skills. Refreshes
/// on any skill or workspace change.
final visibleSkillsProvider = FutureProvider<List<SkillDefinition>>(
  (ref) async {
    ref.watch(skillChangesProvider);
    ref.watch(workspaceChangesProvider);
    final init = ref.watch(knowledgeInitProvider);
    final wsId = init.registries.workspace.activeId;
    final ids = await init.skillResolver.visibleIds(workspaceId: wsId);
    final defs = <SkillDefinition>[];
    for (final id in ids) {
      final def = await init.skillResolver.resolve(id, workspaceId: wsId);
      if (def != null) defs.add(def);
    }
    defs.sort((a, b) => a.id.compareTo(b.id));
    return defs;
  },
  dependencies: [
    knowledgeInitProvider,
    skillChangesProvider,
    workspaceChangesProvider,
  ],
);

final knowledgeChangesProvider = StreamProvider<int>((ref) {
  return changeTicks(
    ref.watch(knowledgeInitProvider).registries.knowledge.changes,
  );
}, dependencies: [knowledgeInitProvider]);

final activeWorkspaceIdProvider = StateProvider<String?>((ref) {
  ref.watch(workspaceChangesProvider);
  return ref.watch(knowledgeInitProvider).registries.workspace.activeId;
}, dependencies: [knowledgeInitProvider, workspaceChangesProvider]);

/// Shell-level "view all workspaces" toggle. When true, detail tabs
/// (Members / Tasks / Processes) render the cross-workspace aggregate
/// list instead of the active-workspace list. Driven by the public icon
/// button at the top-right of the AppBar.
final globalScopeProvider = StateProvider<bool>((ref) => false);

/// Currently selected sidebar route. Lifted out of [ShellPage] so any
/// widget (e.g., the Home page's quick-action buttons or member-row taps)
/// can navigate without prop drilling.
final shellRouteProvider = StateProvider<String>((ref) => 'home');

/// Right-side chat dock visibility. Independent of [shellRouteProvider]:
/// the dock can be open while any page is in view, and closing the dock
/// doesn't affect the active route. The full-screen chat route ('chat')
/// remains accessible via the sidebar for when the user wants the wider
/// surface.
final chatDockOpenProvider = StateProvider<bool>((ref) => false);

/// Filter applied to the home page's recent-activity feed. `null` =
/// show every actor kind; otherwise restrict to that kind.
final activityFilterProvider = StateProvider<ActorKindFilter>(
  (ref) => ActorKindFilter.all,
);

enum ActorKindFilter { all, agents, humans, processes }

final workspaceListProvider = FutureProvider<List<Workspace>>((ref) async {
  ref.watch(workspaceChangesProvider);
  final init = ref.watch(knowledgeInitProvider);
  return init.registries.workspace.list();
}, dependencies: [knowledgeInitProvider, workspaceChangesProvider]);

final workspaceMembersProvider = FutureProvider.family<List<Member>, String>((
  ref,
  wsId,
) async {
  ref.watch(memberChangesProvider);
  final init = ref.watch(knowledgeInitProvider);
  return init.registries.member.listForWorkspace(wsId);
}, dependencies: [knowledgeInitProvider, memberChangesProvider]);

final workspaceTasksProvider = FutureProvider.family<List<Task>, String>((
  ref,
  wsId,
) async {
  ref.watch(taskChangesProvider);
  final init = ref.watch(knowledgeInitProvider);
  return init.registries.task.list(wsId: wsId);
}, dependencies: [knowledgeInitProvider, taskChangesProvider]);

final workspaceProcessesProvider = FutureProvider.family<List<Process>, String>(
  (ref, wsId) async {
    ref.watch(processChangesProvider);
    final init = ref.watch(knowledgeInitProvider);
    return init.registries.process.list(wsId: wsId);
  },
  dependencies: [knowledgeInitProvider, processChangesProvider],
);

final appSkillListProvider = Provider<List<String>>((ref) {
  ref.watch(skillChangesProvider);
  final init = ref.watch(knowledgeInitProvider);
  return init.skills.list().map((s) => s.id).toList();
}, dependencies: [knowledgeInitProvider, skillChangesProvider]);

/// All FactGraph records for the active workspace — feeds the Knowledge page's
/// `Graph` tab (type distribution · timeline · entity cluster · force graph).
/// Re-resolves on member changes (lifecycle facts piggyback on member fork
/// events) and active workspace switch.
final workspaceFactsProvider = FutureProvider.family<List<dynamic>, int>(
  (ref, _) async {
    ref.watch(memberChangesProvider);
    final init = ref.watch(knowledgeInitProvider);
    final wsId = ref.watch(activeWorkspaceIdProvider);
    if (wsId == null) return const [];
    return init.registries.knowledge.query('', workspaceId: wsId, limit: 500);
  },
  dependencies: [
    knowledgeInitProvider,
    memberChangesProvider,
    activeWorkspaceIdProvider,
  ],
);

/// Integrated axis listing — pool seeds + every agent's owned (in-progress)
/// instance for a given axis in the active workspace. Backs the Skills /
/// Profiles / Philosophies (and future Facts) management pages so an entry
/// is visible regardless of whether it lives in the workspace pool or has
/// already been forked into an agent. Re-resolves whenever members change
/// (a new fork or evolution invalidates the union).
final integratedAxisProvider =
    FutureProvider.family<List<IntegratedAxisEntry>, AgentAxis>(
      (ref, axis) async {
        ref.watch(memberChangesProvider);
        // Pool starters come from the skill registry: a skill saved while
        // this view is open must re-list, or the header keeps "0 pool"
        // next to a Pool tab that already shows the entry.
        ref.watch(skillChangesProvider);
        final init = ref.watch(knowledgeInitProvider);
        final wsId = ref.watch(activeWorkspaceIdProvider);
        if (wsId == null) return const [];
        if (!init.system.isAgentSubsystemActivated) return const [];
        return init.system.agents.listIntegrated(wsId, axis);
      },
      dependencies: [
        knowledgeInitProvider,
        memberChangesProvider,
        skillChangesProvider,
        activeWorkspaceIdProvider,
      ],
    );

/// Whole-organization inputs — every workspace (org hierarchy via `parentId`)
/// with its members (role + knowledge refs) and processes (steps + dependsOn
/// DAG + gates + trigger / triggerSource). The Organization page builds the
/// chart from these for the selected lens (workflow / structure / knowledge) —
/// kept as raw inputs (not a built model) so switching lens is a pure
/// re-layout with no re-fetch. No new backend: reads the workspace / member /
/// process registries. Re-resolves on workspace / member / knowledge / skill /
/// process changes so the chart stays live.
final orgChartInputsProvider = FutureProvider<List<OrgWsInput>>(
  (ref) async {
    ref.watch(workspaceChangesProvider);
    ref.watch(memberChangesProvider);
    ref.watch(knowledgeChangesProvider);
    ref.watch(skillChangesProvider);
    final init = ref.watch(knowledgeInitProvider);

    ref.watch(processChangesProvider);

    final wsList = await init.registries.workspace.list();
    final inputs = <OrgWsInput>[];

    for (final ws in wsList) {
      final members = await init.registries.member.listForWorkspace(ws.id);
      // Member id → display name, and member id → qualified flowbrain agent id
      // (for the detail dialog). The process YAML references members by id, but
      // `system.agents.getAgent` needs the qualified agentId — keep both so the
      // chart can match on member id yet open the right agent on tap.
      final labelOf = <String, String>{};
      final agentIdOf = <String, String>{};
      for (final m in members) {
        labelOf[m.id] = m.displayName;
        if (m is AgentMember) {
          labelOf[m.agentId] = m.displayName;
          agentIdOf[m.id] = m.agentId;
        }
      }
      String nameFor(String id) => labelOf[id] ?? id;

      // All members — agents AND people (persons appear in the structure lens
      // org chart; only agents carry knowledge refs). isAgent drives the 🤖/👤
      // icon.
      final agents = <OrgAgentInput>[
        for (final mem in members)
          if (mem is AgentMember)
            OrgAgentInput(
              agentId: mem.agentId,
              memberId: mem.id,
              displayName: mem.displayName,
              role: mem.tags['role'] ?? 'agent',
              isAgent: true,
              skillRefs: mem.skillIds,
              profileRef: mem.profileRef.isEmpty ? null : mem.profileRef,
              philosophyRef:
                  mem.philosophyRef.isEmpty ? null : mem.philosophyRef,
            )
          else
            OrgAgentInput(
              agentId: mem.id,
              memberId: mem.id,
              displayName: mem.displayName,
              role: mem.tags['role'] ?? 'member',
              isAgent: false,
            ),
      ];

      // Processes → pipeline lanes. Each process contributes its ordered steps
      // (assignee + skill) and its gates (approval → sign-off marker, philosophy
      // / quality → inline checkpoint). The approver of an approval gate comes
      // from the separate gates list or an inline step approval (both surface as
      // GateKind.approval with params.approverId).
      final processes = <OrgProcessInput>[];
      try {
        final procs = await init.registries.process.list(wsId: ws.id);
        for (final p in procs) {
          processes.add(
            OrgProcessInput(
              id: p.id,
              title: p.title,
              trigger: p.trigger.name,
              triggerSource: p.triggerSource,
              steps: [
                for (final s in p.steps)
                  OrgStepInput(
                    stepId: s.stepId,
                    assigneeId: s.assigneeId,
                    assigneeLabel: nameFor(s.assigneeId),
                    assigneeAgentId: agentIdOf[s.assigneeId],
                    skillId: s.skillId,
                    dependsOn: s.dependsOn,
                  ),
              ],
              gates: [
                for (final g in p.gates)
                  OrgGateInput(
                    afterStep: g.afterStep,
                    kind: g.kind.name,
                    approverId: g.params['approverId'] as String?,
                    approverLabel:
                        (g.params['approverId'] is String)
                            ? nameFor(g.params['approverId'] as String)
                            : null,
                    approverAgentId:
                        (g.params['approverId'] is String)
                            ? agentIdOf[g.params['approverId'] as String]
                            : null,
                  ),
              ],
            ),
          );
        }
      } catch (_) {
        // Process registry optional / unbound — leave lanes empty.
      }

      inputs.add(
        OrgWsInput(
          id: ws.id,
          title: ws.title,
          type: ws.type.name,
          parentId: ws.parentId,
          leadMemberId: ws.leadMemberId,
          unitRole: ws.unitRole.name,
          sortOrder: ws.sortOrder,
          agents: agents,
          processes: processes,
        ),
      );
    }

    return inputs;
  },
  dependencies: [
    knowledgeInitProvider,
    workspaceChangesProvider,
    memberChangesProvider,
    knowledgeChangesProvider,
    skillChangesProvider,
    processChangesProvider,
  ],
);

/// Processes route view: false = list (default), true = flow board (B2 —
/// runs as cards moving through step columns).
final processBoardViewProvider = StateProvider<bool>((ref) => false);

/// Flow-board data pulse: process defs + their runs for one workspace.
/// Run-state transitions live in KV with NO change tick, so the board polls
/// (same rule as the org overlay). autoDispose — only while the board shows.
final processBoardRunsProvider = StreamProvider.autoDispose
    .family<Map<String, List<ProcessRun>>, String>((ref, wsId) async* {
      final init = ref.watch(knowledgeInitProvider);
      while (true) {
        final map = <String, List<ProcessRun>>{};
        try {
          final procs = await init.registries.process.list(wsId: wsId);
          for (final p in procs) {
            map[p.id] = await init.registries.process.listRuns(
              p.id,
              workspaceId: wsId,
            );
          }
        } catch (_) {
          // Mid-switch/unbound — an empty board this tick, not an error state.
        }
        yield map;
        await Future<void>.delayed(const Duration(seconds: 4));
      }
    }, dependencies: [knowledgeInitProvider]);

/// "Today's flow" home card pulse (B4) — hour-bucketed invocations /
/// delegations / approval waits / run starts for the active workspace.
/// Facts and run records emit no change tick → poll (autoDispose: alive
/// only while Home shows).
final todayFlowProvider = StreamProvider.autoDispose<TodayFlowData>((
  ref,
) async* {
  final init = ref.watch(knowledgeInitProvider);
  final wsId = ref.watch(activeWorkspaceIdProvider);
  while (true) {
    yield await pollTodayFlow(init, wsId);
    await Future<void>.delayed(const Duration(seconds: 5));
  }
}, dependencies: [knowledgeInitProvider, activeWorkspaceIdProvider]);

/// Living-org-chart overlay pulse. The chart geometry rebuilds on registry
/// mutations, but activity (facts / process-run state) emits NO change tick
/// — so this polls. autoDispose keeps the timer alive only while the
/// Organization page is mounted.
final orgOverlayProvider = StreamProvider.autoDispose<OrgOverlayData>((
  ref,
) async* {
  final init = ref.watch(knowledgeInitProvider);
  while (true) {
    yield await pollOrgOverlay(init);
    await Future<void>.delayed(const Duration(seconds: 4));
  }
}, dependencies: [knowledgeInitProvider]);

final bundleListProvider = FutureProvider<List<Bundle>>((ref) async {
  final init = ref.watch(knowledgeInitProvider);
  return init.registries.bundle.list();
}, dependencies: [knowledgeInitProvider]);

final bundleListForTypeProvider =
    FutureProvider.family<List<Bundle>, WorkspaceType>((ref, type) async {
      final init = ref.watch(knowledgeInitProvider);
      return init.registries.bundle.list(filterType: type);
    }, dependencies: [knowledgeInitProvider]);

final installedBundlesProvider =
    FutureProvider.family<List<InstallationRecord>, String>((ref, wsId) async {
      final init = ref.watch(knowledgeInitProvider);
      return init.registries.bundleInstaller.listInstalled(wsId);
    }, dependencies: [knowledgeInitProvider]);

/// Recent KV facts surfaced on the Home page's knowledge band.
final recentKvFactsProvider = FutureProvider<List<dynamic>>(
  (ref) async {
    // Re-read on every knowledge change and workspace switch — the facts live
    // in the active workspace's KV partition.
    ref.watch(knowledgeChangesProvider);
    ref.watch(activeWorkspaceIdProvider);
    final init = ref.watch(knowledgeInitProvider);
    try {
      final all = await init.registries.knowledge.listKvFacts();
      return all.take(3).toList();
    } catch (_) {
      return const <dynamic>[];
    }
  },
  dependencies: [
    knowledgeInitProvider,
    knowledgeChangesProvider,
    activeWorkspaceIdProvider,
  ],
);

/// Aggregate counts for the home KPI tiles + status bar.
class KnowledgeCounts {
  const KnowledgeCounts({
    required this.facts,
    required this.patterns,
    required this.summaries,
  });
  final int facts;
  final int patterns;
  final int summaries;
}

final knowledgeCountsProvider = FutureProvider<KnowledgeCounts>(
  (ref) async {
    ref.watch(knowledgeChangesProvider);
    ref.watch(activeWorkspaceIdProvider);
    final init = ref.watch(knowledgeInitProvider);
    try {
      final facts = await init.registries.knowledge.listKvFacts();
      final patterns = await init.registries.knowledge.queryPatterns();
      return KnowledgeCounts(
        facts: facts.length,
        patterns: patterns.length,
        // SummaryRecord listing isn't exposed on the registry; defer the
        // real count until a list endpoint exists. Kept at 0 for now.
        summaries: 0,
      );
    } catch (_) {
      return const KnowledgeCounts(facts: 0, patterns: 0, summaries: 0);
    }
  },
  dependencies: [
    knowledgeInitProvider,
    knowledgeChangesProvider,
    activeWorkspaceIdProvider,
  ],
);

/// Synthetic activity entries derived from the registries' current state.
/// Each entry is a record matching what the home page renders. Until a
/// dedicated event log lands, this gives the feed real-data shape so the
/// screen can be validated with the actual workspace.
class HomeActivityEntry {
  HomeActivityEntry({
    required this.actorKind,
    required this.actorLabel,
    required this.headline,
    required this.meta,
    required this.route,
  });
  final String actorKind; // agent / human / process
  final String actorLabel;
  final String headline;
  final String meta;
  final String route;
}

final recentActivityProvider = FutureProvider<List<HomeActivityEntry>>(
  (ref) async {
    final wsId = ref.watch(activeWorkspaceIdProvider);
    if (wsId == null) return const [];
    // Live boot init over the ProviderScope override: lifecycle facts live in
    // the per-boot in-memory FactGraph, and a stale override (after a
    // `project.open` re-boot) would surface an empty feed.
    final init = OpsBuiltInApp.liveInit ?? ref.watch(knowledgeInitProvider)!;
    ref.watch(memberChangesProvider);
    ref.watch(taskChangesProvider);
    ref.watch(processChangesProvider);

    final out = <HomeActivityEntry>[];
    try {
      final members = await init.registries.member.listForWorkspace(wsId);
      final tasks = await init.registries.task.list(wsId: wsId);
      final processes = await init.registries.process.list(wsId: wsId);

      // Lifecycle facts (evolution / transfer) — the essence of Ops: which
      // expert grew or received which capability. Surfaced first so the feed
      // reads as agent evolution, not just CRUD. `agent.*` fact types only;
      // a pool source is a fresh fork, an `agent:` source is a transfer.
      final facts = await init.registries.knowledge.query(
        '',
        workspaceId: wsId,
        limit: 30,
      );
      // Agent lifecycle facts (evolution / transfer / invocation) carry real
      // signal, but the initial 4-axis philosophy-pool provisioning is pure
      // setup bookkeeping (one record per axis per agent) that floods the feed
      // and buries actual work. Drop provisioning (audit P1.2); keep the rest,
      // and label the actor with its displayName, never the raw qualified
      // agentId (audit P1.3 — parity with Members / Organization).
      final lifecycle = facts
          .where((f) => isAgentLifecycleFact(f.type) && !isProvisioningFact(f))
          .take(4);
      for (final f in lifecycle) {
        final c = f.content;
        final agentId = (c['agentId'] ?? '—').toString();
        final source = (c['source'] ?? '').toString();
        out.add(
          HomeActivityEntry(
            actorKind: 'agent',
            actorLabel: memberDisplayNameFor(members, agentId),
            headline: agentFactHeadline(f),
            meta: source.isEmpty ? 'lifecycle' : '← $source',
            route: 'members',
          ),
        );
      }

      for (final p in processes.take(2)) {
        out.add(
          HomeActivityEntry(
            actorKind: 'process',
            actorLabel: p.title,
            headline: 'process · ${p.steps.length} steps · ${p.trigger.name}',
            meta:
                '${p.gates.length} gates · ${p.steps.map((s) => s.assigneeId).toSet().length} actors',
            route: 'processes',
          ),
        );
      }
      // Background `agent_ask` delegations (`ask-async-*`) are curation-loop
      // bookkeeping — they dominate the feed and bury real work, exactly as on
      // the Tasks page (which folds them into a separate "Delegations" group).
      // Drop them here so Home Recent activity surfaces actual task activity
      // (audit P1.3 follow-up).
      final feedTasks = tasks.where((t) => !t.id.startsWith('ask-async-'));
      for (final t in feedTasks.take(3)) {
        final assignee =
            t.assigneeIds.isNotEmpty ? t.assigneeIds.first : 'unassigned';
        // Match on BOTH the bare member id and the qualified agentId — a task
        // assigneeId may be either form, and the old `m.id == assignee` check
        // misclassified a qualified-id assignee as human.
        final isAgent = members.any(
          (m) =>
              m.runtimeType.toString().contains('Agent') &&
              (m.id == assignee || (m is AgentMember && m.agentId == assignee)),
        );
        out.add(
          HomeActivityEntry(
            actorKind: isAgent ? 'agent' : 'human',
            // Always the displayName, never the raw/qualified agentId (audit
            // P1.3 — parity with the lifecycle rows above and Members/Tasks).
            actorLabel:
                assignee == 'unassigned'
                    ? 'unassigned'
                    : memberDisplayNameFor(members, assignee),
            headline: '${t.kind.name} task · ${t.title}',
            meta:
                'state: ${t.state.name}'
                '${t.schedule != null ? " · ${t.schedule!.cron}" : ""}'
                '${t.skillIds.isEmpty ? "" : " · skills: ${t.skillIds.join(", ")}"}',
            route: 'tasks',
          ),
        );
      }
      for (final m in members.take(3)) {
        final isAgent = m.runtimeType.toString().contains('Agent');
        out.add(
          HomeActivityEntry(
            actorKind: isAgent ? 'agent' : 'human',
            actorLabel: m.displayName,
            headline: '${isAgent ? "agent" : "human"} · ${m.id}',
            meta: 'attached to workspace',
            route: 'members',
          ),
        );
      }
    } catch (_) {
      // ignore
    }
    return out;
  },
  dependencies: [
    knowledgeInitProvider,
    activeWorkspaceIdProvider,
    memberChangesProvider,
    taskChangesProvider,
    processChangesProvider,
  ],
);

/// Operational assets of the active workspace — the `category:"asset"` facts
/// (ops-asset-management track P1). One asset = one knowledge fact —
/// `knowledge_fact_save` at `category:"asset"` with `metadata` carrying
/// `kind / location / locator / capability / credentialRef`, so there is no
/// new registry or bundle-spec change. Read-only here; writes go through the
/// `knowledge_fact_save` tool (built-in parity rule). Watches
/// [knowledgeChangesProvider] so a save — whether from the UI or an MCP
/// `knowledge_fact_save` call — auto-refreshes the list without a manual tab
/// reload. The toolbar `invalidate` stays as a force-refresh affordance.
final assetsProvider = FutureProvider<List<KvFactEntry>>(
  (ref) async {
    ref.watch(activeWorkspaceIdProvider); // re-fetch on workspace switch
    ref.watch(knowledgeChangesProvider); // re-fetch on any knowledge mutation
    final init = ref.watch(knowledgeInitProvider);
    final facts = await init.registries.knowledge.listKvFacts();
    return facts.where((f) => f.category == 'asset').toList();
  },
  dependencies: [
    knowledgeInitProvider,
    activeWorkspaceIdProvider,
    knowledgeChangesProvider,
  ],
);

/// Whether a secret is stored under [credentialRef] (host vault `secret.exists`).
/// Drives the Resources card lock icon. `invalidate` after a set / remove.
/// ops-asset-management track P2.
final credentialExistsProvider = FutureProvider.family<bool, String>((
  ref,
  credentialRef,
) async {
  final server = ref.read(opsToolServerProvider);
  final result = await server.callTool('secret.exists', {'ref': credentialRef});
  final text =
      result.content.whereType<KernelTextContent>().map((c) => c.text).join();
  if (text.isEmpty) return false;
  final decoded = jsonDecode(text);
  return decoded is Map && decoded['exists'] == true;
}, dependencies: [opsToolServerProvider]);
