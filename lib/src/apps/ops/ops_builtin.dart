/// `OpsBuiltInApp` — Ops built-in registration. Wires the
/// `makemind_ops` Flutter desktop (originally `apps/Ops/`) into
/// vibe_studio as a built-in app so it shares chrome / MCP server /
/// backbone (`StudioBackbone.app.system` — KernelApp wrap) without standing up
/// a parallel boot path. Phase A scaffold only — domain pages, tool
/// registration, and knowledge fan-out land in later phases.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/init/knowledge_init.dart';
import 'package:appplayer_studio/src/apps/ops/registries/member_registry.dart'
    show AgentMember;
import 'package:appplayer_studio/src/apps/ops/registries/task_registry.dart'
    show AgentRun;
import 'package:appplayer_studio/src/apps/ops/server/mcp_inbound.dart';
import 'package:appplayer_studio/src/apps/ops/tools/ui_debug_tools.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart'
    show
        AgentHost,
        BuiltInApp,
        BuiltInLauncher,
        BuiltinToolRegistry,
        ChromeBridge,
        StudioBackbone;
import 'package:appplayer_studio/builtin_api.dart'
    as mk
    show LlmPortAdapter, KernelToolResult;
// Zero direct `package:brain_kernel` imports (after the builtin-os-cleanup
// Phase 4 interface signature swap). Receives only the host-side
// `BuiltinToolRegistry`.

import 'infra/ws_paths.dart' show systemWorkspaceSlot, wsContentRoot;
import '../../base/agent/agent_invoke_queue.dart' show serializePerAgent;
import '../../base/chat/chat_turn.dart' show ChatTurn;
import 'init/workspace_context.dart';
import 'observability/observability_module.dart';
import 'ops_shell.dart';
import 'util/log.dart';
import 'tools/tool_dispatcher.dart';
import 'triggers/trigger_events.dart' show WorkKind;

/// Shared boot result — `OpsConfig` + `KnowledgeInit`. Lazily booted
/// once per host process via [OpsBuiltInApp.ensureBoot] so both the
/// host tool registration (host boot time) and `OpsShell` (tab-open
/// time) read the same `KnowledgeInit` without double-booting.
class OpsBootResult {
  const OpsBootResult({required this.cfg, required this.init});
  final OpsConfig cfg;
  final KnowledgeInit init;
}

class OpsBuiltInApp extends BuiltInApp {
  const OpsBuiltInApp();

  @override
  String get id => 'makemind_ops';

  @override
  String get label => 'Ops';

  static const String _builtInMarker = '.builtin_makemind_ops';

  /// Process-wide cache keyed by the currently-bound project root.
  /// First caller (host boot or shell mount, whichever wins) kicks off
  /// the boot. A different [currentProject] forces a rebuild — the
  /// project root is Ops's `workspacesRoot` now, so switching projects
  /// re-points every registry / adapter at the new tree.
  ///
  /// Phase A.2 — when [ensureBoot] is called with a [backbone], the
  /// host's KnowledgeSystem is adopted (no parallel system / agents /
  /// fact graph). First-call backbone wins for the lifetime of the
  /// current binding.
  static Future<OpsBootResult>? _bootFuture;
  static String? _bootedProject;

  /// Latest boot future. Lets late-registered MCP tools (e.g. those
  /// `mcp_inbound` wires at host-attach time, before any project is
  /// bound) reach the *current* `KnowledgeInit` instead of the stale
  /// snapshot they captured at registration. Returns null when no boot
  /// has been requested yet.
  static Future<OpsBootResult>? get currentBoot => _bootFuture;

  /// Project root the live boot is bound to (null = unbound / no boot).
  /// The shell reads this on tab-close teardown so it only tears the
  /// backend down when THIS tab owns the current boot — closing a stale
  /// Ops tab must not dispose another tab's live backend.
  static String? get bootedProject => _bootedProject;

  /// Whether an Ops tab bound to [tabProject] closing should tear the
  /// backend down. Ops is single-instance (`_openOrFocusSeed` focuses the
  /// one tab keyed to the built-in launchPath), so the closing tab owns
  /// whatever is booted — teardown iff a boot exists AND this tab didn't
  /// bind a DIFFERENT project:
  ///   - `_bootedProject == null` → nothing booted (or the header button
  ///     already closed it via `resetBootCache`) → no teardown.
  ///   - `tabProject == _bootedProject` → this tab bound the boot → teardown.
  ///   - `tabProject == null` → the shell never bound (e.g. the backend was
  ///     booted MCP-only through `ensureBoot`, so `_currentProject` stayed
  ///     null while `_bootedProject` is set) → still teardown: the sole Ops
  ///     tab owns the sole boot. Without this the MCP-only boot leaked until
  ///     the next bind's `resetBootCache`.
  ///   - `tabProject != null && != _bootedProject` → the tab bound a
  ///     different project than what's booted (a race) → leave it alone.
  /// See `_OpsShellState.dispose`.
  static bool shouldTeardownOnClose(String? tabProject) =>
      _bootedProject != null &&
      (tabProject == null || tabProject == _bootedProject);

  /// Test seam — set the booted-project marker without running a full
  /// [ensureBoot] (which needs live host infra). Only for exercising
  /// [shouldTeardownOnClose] / [resetBootCache] in isolation.
  @visibleForTesting
  static void debugSetBootedProject(String? project) {
    _bootedProject = project;
  }

  /// Live [KnowledgeInit] of the most recent boot, sync-accessible. MCP
  /// tool handlers (`SystemTools`) read this so they always reach the
  /// project-bound init instead of the boot-time one captured at
  /// `registerHostTools` (the stale-init bug — `workspacesRoot not bound`
  /// / `/processes` read-only after `studio.project.open`).
  static KnowledgeInit? _liveInit;
  static KnowledgeInit? get liveInit => _liveInit;

  /// The host endpoint's `callTool`, captured once at `registerHostTools`.
  /// Every booted init's `skillExecutor` is bound to it in `_doBoot` so the
  /// Process / Task runner dispatch (which round-trips a skill id through the
  /// host endpoint) works on re-booted inits too — not only the first one
  /// `registerToolsOn` happened to bind ("host callTool not bound" task
  /// blocks otherwise).
  static Future<mk.KernelToolResult> Function(String, Map<String, dynamic>)?
  _hostCallTool;

  /// The host chrome bridge, captured at `registerHostTools`. Read lazily by
  /// the trigger bus's R3 seam to resolve the user's live chat target
  /// (`activeChatAgentId`) at emit time.
  static ChromeBridge? _chromeBridge;

  /// The scoped id of the chat coordinator the user is currently talking to
  /// (`ops.manager.<project>`), or null when no Ops chat is active. This is the
  /// routing override the chat panel uses — the agent whose conversation IS the
  /// visible chat window. `agent_ask(background)` reads it to wire a one-shot
  /// "report this delegation back to me" so a manager delegating from chat gets
  /// the completion in its own window without having to know its own id.
  static String? get activeCoordinatorId {
    final v = _chromeBridge?.chatManagerOverride.value;
    return (v != null && v.isNotEmpty) ? v : null;
  }

  /// Boot (or rebind) the Ops core to [currentProject].
  ///
  /// Standard project wiring (matches App Builder / Scene Builder):
  /// each Ops project is one directory under the host's `workspaceDir`
  /// — the `currentProject` value flowing from the host's chrome
  /// `newProjectInActive` / `openProjectInActive` lifecycle. The seed
  /// `apps/Ops/workspaces/` tree is no longer the default data root;
  /// data lives inside `currentProject`.
  ///
  /// [currentProject] == null routes to the legacy `OpsConfig.load()`
  /// fallback (~/.makemind-ops/config.yaml's `workspacesRoot` /
  /// `activeWorkspace`), which today resolves to empty strings so the
  /// resulting init is effectively idle until the shell binds a real
  /// project. Switching from null to a real path (or between two real
  /// paths) discards the previous future and rebinds.
  /// Outstanding dispose for the previous boot. New [ensureBoot] calls
  /// await this so a same-project reopen sees a clean facade before
  /// `BundleActivation` rebinds — without the gate the new activation
  /// races dispose and trips `Duplicate agent id`.
  static Future<void>? _disposeFuture;

  static Future<OpsBootResult> ensureBoot({
    StudioBackbone? backbone,
    String? currentProject,
  }) async {
    if (_bootFuture != null && _bootedProject == currentProject) {
      return _bootFuture!;
    }
    // An unbound (project-less) ensureBoot — fired by `mount` /
    // `registerHostTools` on every tab activation / rebuild — must NEVER
    // tear down an already-bound project boot. Without this guard the
    // unbound call overwrites `_bootedProject` (→ null) and `_bootFuture`,
    // which defeats the `_doBoot` publish guard (it checks
    // `_bootedProject == currentProject`): the in-flight bound boot then
    // fails to publish `_liveInit`, so `workspace_*` / `member_*` resolve
    // the unbound init and report "workspacesRoot not bound" right after a
    // successful MCP `project.new` / `project.open`. Reuse the live bound
    // boot instead. An explicit close routes through `resetBootCache`
    // (which nulls `_bootFuture` / `_bootedProject`), so the welcome-state
    // unbound boot is still reachable after the user closes a project.
    final unbound = currentProject == null || currentProject.isEmpty;
    if (unbound &&
        _bootFuture != null &&
        (_bootedProject?.isNotEmpty ?? false)) {
      return _bootFuture!;
    }
    final pending = _disposeFuture;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        /* best-effort */
      }
    }
    _bootedProject = currentProject;
    return _bootFuture = _doBoot(backbone, currentProject);
  }

  /// Drop the cached boot result so the next [ensureBoot] re-runs
  /// `KnowledgeInit.boot` (and therefore re-invokes `BundleActivation`
  /// against the on-disk manifest). Used by the shell's `closeProject`
  /// path so reopening the same project picks up manifest edits made
  /// while the project was closed. Also disposes the previous
  /// activations so the `KnowledgeSystem` facades drop the closed
  /// project's entries before the next bind rebinds them.
  static void resetBootCache() {
    final prev = _bootFuture;
    OpsLog.info(
      'lifecycle',
      'resetBootCache: disposing bound init (prev=${prev != null})',
    );
    _bootFuture = null;
    _bootedProject = null;
    // Explicit close → drop the published bound init so the next boot (and
    // the welcome panel) start unbound. This is the only path that downgrades
    // `_liveInit` (the _doBoot publish guard never does — see _doBoot).
    _liveInit = null;
    if (prev != null) {
      _disposeFuture = () async {
        try {
          final result = await prev;
          await result.init.dispose();
        } catch (_) {
          /* best-effort */
        }
      }();
    }
  }

  static Future<OpsBootResult> _doBoot(
    StudioBackbone? backbone,
    String? currentProject,
  ) async {
    var cfg = await OpsConfig.load();
    // Project wiring — [currentProject] is the chrome-bound project
    // root for this Ops tab. We adopt it as Ops's `workspacesRoot`
    // (the parent of `_system / org/<x> / project/<x>` slugs) so the
    // first ensure-system pass writes inside the project, not into
    // the legacy `apps/Ops/workspaces/` tree. Empty / null means the
    // shell hasn't bound a project yet; the boot still runs (so host
    // MCP tools resolve), but every registry rooted at `workspacesRoot`
    // sees a blank tree.
    if (currentProject != null && currentProject.isNotEmpty) {
      cfg = _withProjectRoot(cfg, currentProject);
    }
    // Observability is bootstrapped here for the GUI — the Activity /
    // Diagnostics / Portability routes read `observabilityProvider`, which
    // throws "not yet bootstrapped" when nothing supplies a module. The
    // module is in-memory (ActivityBus + TelemetryStore) and the shell
    // overrides `observabilityProvider` with `init.observability`.
    final observability = ObservabilityModule();
    final init = await KnowledgeInit.boot(
      cfg,
      hostSystem:
          backbone?.isFlowBrainBooted == true ? backbone!.app.system : null,
      observability: observability,
      // Inherited default model — agents created without an explicit
      // ModelSpec ride the configured `settings.llmModel` (resolved at
      // boot) instead of the stub port. host wiring, not builtin logic.
      defaultAgentModel: backbone?.defaultAgentModel,
      // Global agent LLM session pool — base layer for the per-project
      // system's `infraPorts.llmProviders`. Carries the claude-code keyless
      // fallback (registered by `upgradeClaudeCodeForKernel` at host boot,
      // which runs BEFORE this project-bind boot) so a bound project's OWN
      // agent subsystem can resolve a worker's model. Without it,
      // per-project `agent_ask` returns empty content on a keyless setup
      // (the project key pool has no `claude` provider).
      sharedLlmProviders:
          backbone?.isFlowBrainBooted == true
              ? backbone!.app.agentLlmSessions.providers
              : null,
    );
    // Phase A.3 — merge Ops's LlmPort provider pool (multi-provider
    // mcp_llm — Anthropic / OpenAI / Gemini) into the KernelApp's
    // `agentLlmSessions` via the `addAll(Map)` helper (2026-05-24).
    // The backbone's pool is empty by default
    // (vibe_studio doesn't supply an llmApiKey), so without this
    // merge `kStudioAgentProfiles` agents (studio.manager,
    // builder.manager, scene.manager, ops.manager, ...) throw "No
    // LlmPort wired for provider" when chat dispatches to them.
    // `AgentLlmSessions.providers` is unmodifiable; the `addAll`
    // helper is the supported mutation path.
    if (backbone != null && backbone.isFlowBrainBooted) {
      final pool = init.adapters.llm.providerPool;
      if (pool.isNotEmpty) {
        // `providerPool` carries `bundle.LlmPort` values but every
        // entry is a concrete `LlmPortAdapter` instance under the
        // hood (built by `LlmPortAdapterFactory` upstream).
        // `AgentLlmSessions.addAll` accepts the narrower
        // adapter type — cast via the entries iterator so non-adapter
        // entries silently drop instead of throwing.
        final adapters = <String, mk.LlmPortAdapter>{
          for (final entry in pool.entries)
            if (entry.value is mk.LlmPortAdapter)
              entry.key: entry.value as mk.LlmPortAdapter,
        };
        if (adapters.isNotEmpty) {
          backbone.app.agentLlmSessions.addAll(adapters);
        }
      }
    }
    // Skill dispatch for the Process / Task runners. Resolves a skill id
    // to the host MCP tool surface (`executeTool` → BuiltinToolRegistry →
    // ToolDispatcher → SkillExecutor) — step execution is host-owned, not
    // a shell capability. Wired once here at boot so the UI never owns
    // runner wiring; UI actions invoke the `process_start` / `task_run`
    // tools, which reach a runner whose dispatch is already attached.
    final skillDispatch = _skillDispatchFor(init);
    init.registries.process.dispatch ??= skillDispatch;
    init.registries.task.dispatch ??= skillDispatch;
    // Assignee auto-run: when a task is assigned to an agent member, drive
    // that agent to actually perform it (assign + produce) instead of a
    // headless skill dispatch that left the assignee un-run. Resolves the bare
    // member id to its scoped kernel agent (AgentMember.agentId), the way
    // agent_ask does; returns null for persons / unknown ids / off subsystem so
    // TaskRegistry.run falls back to skill dispatch. Wired once here so both
    // manual `task_run` and the recurring scheduler wake the assignee.
    init.registries.task.agentRun ??= buildAgentRun(init);
    // Trigger bus action seams (R2 wake / R3 live-chat relay). Same
    // late-injection shape as agentRun; the closures read the static host
    // handles (`_hostCallTool` / `_chromeBridge`) lazily at emit time, so they
    // resolve even when _doBoot ran ahead of registerHostTools.
    _wireTriggerSeams(init);
    // Bind this init's skillExecutor to the host endpoint so the runner
    // dispatch resolves skill ids through it. On a re-boot `registerToolsOn`
    // does NOT re-run, so without this the new init's skillExecutor stays
    // unbound and `task_run` / `process_start` block with "host callTool not
    // bound". `_hostCallTool` is captured at registerHostTools.
    final hostCall = _hostCallTool;
    if (hostCall != null) {
      init.skillExecutor.bindHostCallTool(hostCall);
    }
    // Publish the project-bound init so MCP tool handlers reach it (not
    // the boot-time standalone init they captured) — but ONLY if this boot
    // is still the current one. The mount / registerHostTools calls run
    // `ensureBoot(backbone:)` with no `currentProject` (unbound boot) while
    // the shell's `_bindProject` runs `ensureBoot(currentProject: path)`
    // (bound boot). If the unbound boot finishes LAST it must not clobber
    // the bound `_liveInit` — that boot race is what left registries
    // ("workspacesRoot not bound") and made `task_*`/`skill_*`/`knowledge_*`
    // intermittently fail while `member_*`/`workspace_*` (which resolve the
    // cached bound boot directly) worked. Guarding on `_bootedProject`
    // (set to the latest ensureBoot's project) keeps `_liveInit` bound.
    if (_bootedProject == currentProject) {
      // Never DOWNGRADE a bound live init to an unbound (project-less) one.
      // `mount` / `registerHostTools` run `ensureBoot(backbone:)` with no
      // project on every tab activation / rebuild — if one of those fires
      // after a project is bound, its unbound init must not clobber the
      // bound `_liveInit` (that left registries "workspacesRoot not bound"
      // and `init.projectRoot` empty for `skill_*` / `knowledge_*`). Only an
      // explicit close (`resetBootCache`, which nulls `_liveInit`) returns to
      // the unbound welcome state.
      final nowBound = init.projectRoot.isNotEmpty;
      final wasBound = _liveInit?.projectRoot.isNotEmpty ?? false;
      if (nowBound || !wasBound) {
        _liveInit = init;
      }
    }
    return OpsBootResult(cfg: cfg, init: init);
  }

  /// The task-assignee auto-run seam. Extracted from `_doBoot` so the three
  /// outcomes below are unit-testable without a full host boot.
  ///
  /// Contract — the distinction the caller depends on:
  ///   * `null`   = DECLINED. The assignee is not a runnable agent (a person,
  ///                an unknown id, or the agent subsystem is off), so
  ///                `TaskRegistry.run` falls back to headless skill dispatch.
  ///   * throws   = FAILED. The agent ran and the run itself failed.
  ///   * a string = the agent's deliverable.
  ///
  /// Collapsing "failed" into "declined" is what made every run failure report
  /// as `assignee is not a runnable agent and has no skill to run`.
  @visibleForTesting
  static AgentRun buildAgentRun(KnowledgeInit init) {
    return (assigneeId, request, {workspaceId}) async {
      if (!init.system.isAgentSubsystemActivated) {
        // Declined, not failed — the task falls back to headless skill
        // dispatch. Logged because the caller can only see the generic
        // "not a runnable agent" wording this null produces.
        OpsLog.info(
          'task',
          'agentRun declined for $assigneeId — agent subsystem not activated; '
              'falling back to skill dispatch',
        );
        return null;
      }
      // Canonicalize the assignee: a task may carry the bare member id OR a
      // full scoped agentId (an LLM-authored delegation fills it from the
      // roster). `resolve` maps both to the runnable member so the task is
      // not silently blocked ("not a runnable agent") on id form alone.
      // Scope to the task's workspace so a bare `lead` resolves to THIS
      // department's lead, not a same-named lead in another workspace found
      // first by scan order (cross-department mis-delivery).
      final m = await init.registries.member.resolve(
        assigneeId,
        wsId: workspaceId,
      );
      if (m is! AgentMember) {
        // A person / unknown id: genuinely not runnable → null is the
        // skill-dispatch fallback signal. This is the ONLY resolution-shaped
        // null left, so the "not a runnable agent" wording finally matches it.
        OpsLog.info(
          'task',
          'agentRun declined for $assigneeId in ws=${workspaceId ?? '(none)'} '
              '— resolves to ${m == null ? 'no member' : 'a non-agent member'}; '
              'falling back to skill dispatch',
        );
        return null;
      }
      // Run failures must NOT be swallowed into null. A null here is read as
      // "assignee is not a runnable agent", so a timeout / tool error / LLM
      // failure used to be reported as an assignee-resolution problem and sent
      // operators chasing the id form. Let the
      // real error propagate — `TaskRegistry.run` catches it and records the
      // actual cause in the run's `errorCode`.
      final reply = await init.system.agents.ask(m.agentId, request);
      return reply.content;
    };
  }

  /// Wire the trigger bus's action seams. Same
  /// late-injection shape as `agentRun`; closures read the static host handles
  /// lazily so they resolve regardless of _doBoot / registerHostTools ordering.
  static void _wireTriggerSeams(KnowledgeInit init) {
    final bus = init.triggerBus;
    // R2 — wake a subscribed target agent with the rendered request. A bare
    // `agents.ask` is terminal (it does not re-emit), so ordinary A→B chains
    // never recurse; the bus's hop cap backstops any emitting wake path.
    bus.wakeAgent ??= (targetAgentId, request, cause) async {
      if (!init.system.isAgentSubsystemActivated) {
        OpsLog.info(
          'trigger',
          'wake $targetAgentId skipped — agent subsystem not activated',
        );
        return;
      }
      // Resolve the target WITHIN the completion's workspace — a bare
      // `member.get` only scans already-loaded workspaces, so the target
      // silently misses when its department was never opened in this session
      // (a live-integration gap: subscription persisted +
      // event emitted, but wake no-op'd because `lead` sat in an unloaded
      // workspace). The event carries the workspace; hand it through.
      final ws = cause.workspaceId.isEmpty ? null : cause.workspaceId;
      final m = await init.registries.member.get(targetAgentId, wsId: ws);
      // Two kinds of wake target, living in two different agent systems:
      //
      //  (a) a workspace MEMBER — resolves to its scoped kernel id and runs in
      //      `init.system` (for a project-bound Ops that is the PROJECT's
      //      KnowledgeSystem; its conv lives under `<project>/.kv/conv`).
      //
      //  (b) a CHAT COORDINATOR (`ops.manager.<project>`) — the agent the user
      //      actually converses with. It is NOT a workspace member; it is a
      //      host-level agent owned by `AgentHost` (its conv is the chat
      //      window, `~/.config/<tool>/conv/...`). For a project-bound Ops the
      //      coordinator is NOT in `init.system` at all, so it must be resolved
      //      and run through `AgentHost.shared.askAgent` — the same path the
      //      chat panel uses — so its report lands in the conversation the user
      //      is watching. (A live gap: a subscription targeting
      //      the coordinator matched, but wake no-op'd because `member.get`
      //      AND `init.system` both miss the host-owned coordinator.)
      if (m is AgentMember) {
        OpsLog.info(
          'trigger',
          'waking member ${m.agentId} ($targetAgentId) in ws=${ws ?? '(none)'} '
              'for ${cause.kind.name}(${cause.refId}) — reply lands in its '
              'kernel conversation',
        );
        await serializePerAgent(
          m.agentId,
          () =>
              ws == null
                  ? init.system.agents.ask(m.agentId, request)
                  : WorkspaceExecutionContext.run(
                    ws,
                    () => init.system.agents.ask(m.agentId, request),
                  ),
        );
        return;
      }
      if (m == null) {
        final host = AgentHost.shared;
        final coordinator =
            host == null
                ? null
                : await host.flowbrain.system.agents.getAgent(targetAgentId);
        if (host != null && coordinator != null) {
          OpsLog.info(
            'trigger',
            'waking coordinator $targetAgentId for '
                '${cause.kind.name}(${cause.refId}) — report lands in its chat '
                'conversation',
          );
          // `askAgent` scopes the coordinator's own tools + runs it in the host
          // system where its conversation lives; serialize so the wake can't
          // race a concurrent chat turn for the same coordinator.
          await serializePerAgent(targetAgentId, () async {
            final reply = await host.askAgent(targetAgentId, request);
            // `askAgent` updated the coordinator's KERNEL conversation (its
            // working memory) but NOT the studio chat transcript the user's
            // panel renders — so the report was durable yet invisible in the
            // open window. Push the assistant
            // report into the coordinator's studio chat so it renders live
            // AND persists for rehydrate.
            final text = reply.content.trim();
            if (text.isNotEmpty) {
              final delivered =
                  _chromeBridge?.deliverAgentChatTurn?.call(
                    targetAgentId,
                    ChatTurn(role: 'assistant', text: text),
                  ) ??
                  false;
              OpsLog.info(
                'trigger',
                'coordinator $targetAgentId report ${delivered ? 'rendered + '
                        'persisted in its live chat panel' : 'kernel-only — no '
                        'studio chat bound (headless / MCP-only)'}',
              );
            }
          });
          return;
        }
      }
      // Neither a runnable member nor a known coordinator → clean no-op.
      OpsLog.info(
        'trigger',
        'wake $targetAgentId no-op — ${m == null ? 'no member or coordinator' : 'not an agent (${m.kind.name})'} in ws=${ws ?? '(none)'}',
      );
    };
    // R3 — surface a completion in the user's LIVE CHAT so a background result
    // shows up without polling. The chat panel is a HOST surface, NOT the ops
    // channel feed — pushing via `channel.send` (as this first did) only lands
    // in the feed and never reaches the chat tab.
    // `chromeBridge.appendChatTurn` is the right hook (the host's active-chat
    // turn injection): it appends a turn to whatever chat the user is on.
    // Only OUT-OF-BAND kinds
    // (task / step) are surfaced — a synchronous ask / route already returned
    // to its caller. Skip the echo only when we KNOW the completer is the
    // active agent (don't hard-skip on an empty activeChatAgentId — that is
    // unset under an MCP-driven chat, which suppressed the relay entirely).
    bus.injectIntoActiveChat ??= (event) async {
      if (event.kind == WorkKind.ask || event.kind == WorkKind.route) return;
      final append = _chromeBridge?.appendChatTurn;
      if (append == null) {
        // R3 surface trail: no chat panel mounted (headless / MCP-only run).
        // This is why an MCP-driven session never sees the live-chat relay —
        // the relay targets the host chat PANEL, not the kernel conversation.
        OpsLog.info(
          'trigger',
          'relay ${event.kind.name}(${event.refId}) skipped — no chat panel '
              'mounted (headless); durable record is the feed notice (R5)',
        );
        return;
      }
      final active = _chromeBridge?.activeChatAgentId.value ?? '';
      OpsLog.info(
        'trigger',
        'relay ${event.kind.name}(${event.refId}) → active chat panel '
            '(activeChatAgentId="$active"); appends a system turn to the '
            'FOCUSED tab controller',
      );
      if (active.isNotEmpty && active == event.sourceAgentId) return;
      final who =
          event.sourceAgentId.isEmpty
              ? 'A background task'
              : event.sourceAgentId;
      final verb = event.isBlocked ? 'was blocked on' : 'completed';
      final digest = (event.summary ?? '').trim();
      final tail = digest.isEmpty ? '' : ': $digest';
      final artifact =
          event.artifactRef == null ? '' : '\nArtifact: ${event.artifactRef}';
      append(
        ChatTurn(
          role: 'system',
          text: '$who $verb ${event.kind.name} (${event.refId})$tail$artifact',
        ),
      );
    };
    // R5 — a durable feed notice for out-of-band completions (task / step),
    // posted to the completer's own conversation so a run leaves a record
    // even when no one is watching a live chat. Skips synchronous kinds and
    // sourceless (process) events. Best-effort with a hang guard.
    bus.notify ??= (event) async {
      if (event.kind == WorkKind.ask || event.kind == WorkKind.route) return;
      if (event.sourceAgentId.isEmpty) return;
      final call = _hostCallTool;
      if (call == null) return;
      final verb = event.isBlocked ? 'blocked' : 'done';
      final digest = (event.summary ?? '').trim();
      final tail = digest.isEmpty ? '' : ': $digest';
      await call('channel.send', <String, dynamic>{
        'channelId': 'in_app',
        'conversationId': event.sourceAgentId,
        'text': '[$verb] ${event.kind.name} (${event.refId})$tail',
        'replyTo': 'trigger-feed-${event.refId}',
      }).timeout(const Duration(seconds: 5));
    };
  }

  /// Skill dispatcher shared by the Process and Task runners. Resolves a
  /// skill id through `ToolDispatcher` (3-layer skillResolver → SkillExecutor)
  /// and runs it DIRECTLY — the same path the host's per-skill tool handler
  /// uses, but without round-tripping through the host endpoint. The endpoint
  /// only knows skills registered at boot, so a round-trip can't run a skill
  /// created at runtime (`skill_save`) — it failed "Tool not registered". The
  /// dispatcher resolves the live skill pool, so runtime skills run too.
  static Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
  _skillDispatchFor(KnowledgeInit init) {
    final dispatcher = ToolDispatcher(
      init: init,
      observability: init.observability,
    );
    return (id, args) => dispatcher.dispatch(id, args);
  }

  /// Build a copy of [src] whose `workspacesRoot` is [projectRoot] and
  /// whose `activeWorkspace` defaults to the reserved `_system` slug
  /// (the workspace registry's ensure-system pass creates it on first
  /// boot if missing). Every other Ops setting (llm / mcp / browser /
  /// storage / channel / security / system agent / theme) is inherited
  /// from the loaded `~/.makemind-ops/config.yaml` so the user's host
  /// config stays the single source of truth.
  static OpsConfig _withProjectRoot(OpsConfig src, String projectRoot) {
    // Prefer the PER-PROJECT active workspace (`<projectRoot>/.makemind-ops-active`,
    // written by `workspace_switch`) over the global config's `activeWorkspace`.
    // The global `~/.makemind-ops/config.yaml` is shared across every host and
    // project, so another host/project switching workspaces overwrites its
    // single `activeWorkspace` field with a FOREIGN id — which is absent here,
    // falls back to `_system`, and hides this project's data (empty Home). The
    // per-project file is the project's own memory and never cross-contaminates.
    var wanted = src.activeWorkspace;
    try {
      final f = File(p.join(projectRoot, '.makemind-ops-active'));
      if (f.existsSync()) {
        final saved = f.readAsStringSync().trim();
        if (saved.isNotEmpty) wanted = saved;
      }
    } catch (_) {
      /* best-effort — fall back to the global value */
    }
    return OpsConfig(
      version: src.version,
      appName: src.appName,
      // Restore the wanted workspace IF it still exists in THIS project, else
      // fall back to the reserved `_system` slot. Guards against a STALE id
      // from a DIFFERENT project (whose `<wsId>.mbd` is absent here) by
      // confirming the workspace's bundle dir exists under THIS project root
      // (`_system` is always valid — reserved, no bundle dir).
      activeWorkspace:
          (wanted == systemWorkspaceSlot ||
                  (wanted.isNotEmpty &&
                      Directory(
                        wsContentRoot(projectRoot, wanted),
                      ).existsSync()))
              ? wanted
              : systemWorkspaceSlot,
      workspacesRoot: projectRoot,
      llm: src.llm,
      mcp: src.mcp,
      browser: src.browser,
      // Root the KV store inside the project (next to chat.jsonl and
      // .factgraph/) so per-project knowledge lives WITH the project —
      // isolated per project, portable with the folder, isolated across
      // instances. An empty/global localKvPath made every project share one
      // store and accumulate. Mirrors the chat.jsonl per-project precedent.
      storage: StorageSettings(
        localKvPath: '$projectRoot/.kv',
        backupIntervalHours: src.storage.backupIntervalHours,
        retentionDays: src.storage.retentionDays,
      ),
      channel: src.channel,
      security: src.security,
      systemAgent: src.systemAgent,
      themeMode: src.themeMode,
      loadedFromDisk: src.loadedFromDisk,
    );
  }

  @override
  bool canHandle(String bundlePath) {
    final dir = Directory(bundlePath);
    if (!dir.existsSync()) return false;
    // Two recognised forms (host's `_resolveSeedNamespacePath` may hand
    // us either depending on lookup priority — seed mbd first vs
    // launcher path first):
    //  - launcher path: workspace marker dir with `.builtin_makemind_ops`.
    //  - seed mbd path: bundle dir whose manifest.json `id` matches the
    //    Ops bundle id (`com.makemind.ops`). Recognising both keeps the
    //    built-in mounted regardless of which form the host resolves to.
    if (File(p.join(bundlePath, _builtInMarker)).existsSync()) return true;
    final manifest = File(p.join(bundlePath, 'manifest.json'));
    if (!manifest.existsSync()) return false;
    try {
      final body = manifest.readAsStringSync();
      // Cheap substring check — avoids a JSON decode on every chrome
      // `matchFor` walk. The id is unique enough that a false positive
      // would require the user to plant the literal string in another
      // manifest, which doesn't happen with seed cleanup contract.
      return body.contains('"id": "com.makemind.ops"') ||
          body.contains('"id":"com.makemind.ops"');
    } catch (_) {
      return false;
    }
  }

  @override
  BuiltInLauncher launcher(ChromeBridge chromeBridge, String workspaceDir) {
    final defaultDir = p.join(workspaceDir, 'makemind_ops');
    final dir = Directory(defaultDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final marker = File(p.join(defaultDir, _builtInMarker));
    if (!marker.existsSync()) {
      marker.writeAsStringSync('');
    }
    return BuiltInLauncher(
      id: id,
      label: label,
      iconName: 'dashboard',
      launchPath: defaultDir,
      onLaunch: () async {
        /* marker eager-created above */
      },
    );
  }

  @override
  Widget mount({
    required BuildContext context,
    required String bundlePath,
    required ChromeBridge chromeBridge,
    required dynamic Function(String tabKey) chatLookup,
    required String tabKey,
    required BuiltinToolRegistry server,
    required StudioBackbone backbone,
    Map<String, Object?> inheritedSettings = const <String, Object?>{},
    String overridesFile = '',
  }) {
    // Kick the lazy boot here too — when the user clicks the Ops
    // launcher card before the host's registerHostTools path has
    // reached its `ensureBoot(backbone)` call, ensure the host-system
    // adoption still happens on the first call.
    ensureBoot(backbone: backbone);
    return OpsShell(
      bundlePath: bundlePath,
      chromeBridge: chromeBridge,
      tabKey: tabKey,
      backbone: backbone,
      app: this,
      server: server,
      inheritedSettings: inheritedSettings,
      overridesFile: overridesFile,
    );
  }

  @override
  Future<void> registerHostTools(
    BuiltinToolRegistry server,
    ChromeBridge chromeBridge, {
    StudioBackbone? backbone,
  }) async {
    // Phase D — fold Ops's tool surface (docs prompts + system tools +
    // per-skill 1:1 tools + browser primitives) onto the vibe_studio
    // host server. Lazy boot kicks the shared KnowledgeInit so the
    // shell can reuse it without a second boot.
    //
    // Phase A.2 — pass `backbone` so `KnowledgeInit` adopts the host's
    // existing `KnowledgeSystem` instead of building a parallel one.
    // Without backbone (legacy path / unit test), the standalone wiring
    // still works.
    try {
      final result = await ensureBoot(backbone: backbone);
      // Capture the host endpoint's callTool so `_doBoot` can bind it on
      // every (re-)booted init's skillExecutor — the runner dispatch needs it.
      _hostCallTool = server.callTool;
      // Capture the chrome bridge so the trigger bus's R3 seam can resolve the
      // user's live chat target at emit time.
      _chromeBridge = chromeBridge;
      // All ops tool families (system / docs / prompts / skill / browser
      // primitives + ui_debug) register through the host API surface
      // (`server`, a `BuiltinToolRegistry` the host wraps before mount —
      // no raw `KernelServerHost` ever leaks into builtin code).
      McpInbound.registerToolsOn(
        server,
        result.init,
        observability: result.init.observability,
      );
      // The first boot may have happened before `_hostCallTool` was set
      // (mount kicks `ensureBoot` ahead of registerHostTools). Bind it now.
      result.init.skillExecutor.bindHostCallTool(server.callTool);
      const UiDebugTools().registerOn(server);
    } catch (e, st) {
      // Boot failure here must not abort the host MCP server bring-up
      // — vibe_studio still launches without Ops surface available.
      // Re-throw is intentionally avoided; the error surfaces in
      // OpsShell's FutureBuilder when the tab opens.
      Zone.current.handleUncaughtError(e, st);
    }
  }

  @override
  Future<List<Map<String, dynamic>>> knowledgeSources() async {
    // Code-channel knowledge stays empty for makemind_ops — the seed
    // bundle `vibe_studio/seed/makemind_ops.mbd/` carries Ops's
    // `manifest.knowledge.*` (fanned out by the host's
    // `_fanOutSeedKnowledgeAsResources`), so this code-side hook adds
    // nothing on top.
    return const <Map<String, dynamic>>[];
  }
}
