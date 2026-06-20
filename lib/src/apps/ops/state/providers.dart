import 'dart:convert';

import 'package:appplayer_studio/base.dart' show BuiltinToolRegistry;
import 'package:appplayer_studio/builtin_api.dart'
    show AgentAxis, IntegratedAxisEntry, KernelTextContent;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/ops_config.dart';
import '../init/knowledge_init.dart';
import '../ops_builtin.dart' show OpsBuiltInApp;
import '../observability/activity_bus.dart';
import '../observability/activity_event.dart';
import '../observability/observability_module.dart';
import '../observability/telemetry_store.dart';
import '../registries/bundle_installer.dart';
import '../registries/bundle_registry.dart';
import '../registries/member_registry.dart';
import '../registries/process_registry.dart';
import '../registries/task_registry.dart';
import '../registries/workspace_registry.dart';

/// Global bootstrap handles — overridden at the scoped [ProviderScope] in
/// `main.dart` after [KnowledgeInit.boot]. All derived providers below list
/// this one as a dependency so Riverpod knows to re-resolve them within the
/// override subtree.
final knowledgeInitProvider = Provider<KnowledgeInit>(
  (ref) => throw UnimplementedError('KnowledgeInit not yet bootstrapped'),
  dependencies: const [],
);

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
// loop. See `diora/design/builtin-os-cleanup-plan-2026-05-28.md`.

/// Observability subsystem — [ActivityBus] + [TelemetryStore]. PRD §FM-OBSERVE.
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

final workspaceChangesProvider = StreamProvider<void>((ref) {
  return ref.watch(knowledgeInitProvider).registries.workspace.changes;
}, dependencies: [knowledgeInitProvider]);

final memberChangesProvider = StreamProvider<void>((ref) {
  return ref.watch(knowledgeInitProvider).registries.member.changes;
}, dependencies: [knowledgeInitProvider]);

final taskChangesProvider = StreamProvider<void>((ref) {
  return ref.watch(knowledgeInitProvider).registries.task.changes;
}, dependencies: [knowledgeInitProvider]);

final processChangesProvider = StreamProvider<void>((ref) {
  return ref.watch(knowledgeInitProvider).registries.process.changes;
}, dependencies: [knowledgeInitProvider]);

final skillChangesProvider = StreamProvider<void>((ref) {
  return ref.watch(knowledgeInitProvider).skills.changes;
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
        final init = ref.watch(knowledgeInitProvider);
        final wsId = ref.watch(activeWorkspaceIdProvider);
        if (wsId == null) return const [];
        if (!init.system.isAgentSubsystemActivated) return const [];
        return init.system.agents.listIntegrated(wsId, axis);
      },
      dependencies: [
        knowledgeInitProvider,
        memberChangesProvider,
        activeWorkspaceIdProvider,
      ],
    );

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
final recentKvFactsProvider = FutureProvider<List<dynamic>>((ref) async {
  final init = ref.watch(knowledgeInitProvider);
  try {
    final all = await init.registries.knowledge.listKvFacts();
    return all.take(3).toList();
  } catch (_) {
    return const <dynamic>[];
  }
}, dependencies: [knowledgeInitProvider]);

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

final knowledgeCountsProvider = FutureProvider<KnowledgeCounts>((ref) async {
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
}, dependencies: [knowledgeInitProvider]);

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
      for (final f in facts.where((f) => f.type.startsWith('agent.')).take(6)) {
        final c = f.content;
        final agentId = (c['agentId'] ?? '—').toString();
        final axis = (c['axis'] ?? '').toString();
        final source = (c['source'] ?? '').toString();
        final isTransfer = source.startsWith('agent:');
        final headline = switch (f.type) {
          'agent.fork.assigned' =>
            isTransfer ? 'received $axis' : 'forked $axis',
          'agent.fork.evolved' => '$axis evolved',
          'agent.invoked' => 'invoked',
          'agent.deleted' => 'deleted',
          _ => f.type,
        };
        out.add(
          HomeActivityEntry(
            actorKind: 'agent',
            actorLabel: agentId,
            headline: headline,
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
      for (final t in tasks.take(3)) {
        final assignee =
            t.assigneeIds.isNotEmpty ? t.assigneeIds.first : 'unassigned';
        final isAgent = members.any(
          (m) => m.id == assignee && m.runtimeType.toString().contains('Agent'),
        );
        out.add(
          HomeActivityEntry(
            actorKind: isAgent ? 'agent' : 'human',
            actorLabel: assignee,
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
