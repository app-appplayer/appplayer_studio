/// `OpsBuiltInApp` — Ops built-in registration. Wires the
/// `makemind_ops` Flutter desktop (originally `apps/Ops/`) into
/// vibe_studio as a built-in app so it shares chrome / MCP server /
/// backbone (`StudioBackbone.app.system` — KernelApp wrap) without standing up
/// a parallel boot path. Phase A scaffold only — domain pages, tool
/// registration, and knowledge fan-out land in later phases per
/// `diora/design/ops-internalization-plan-2026-05-21.md`.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/init/knowledge_init.dart';
import 'package:appplayer_studio/src/apps/ops/server/mcp_inbound.dart';
import 'package:appplayer_studio/src/apps/ops/tools/ui_debug_tools.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart'
    show
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

import 'observability/observability_module.dart';
import 'ops_shell.dart';
import 'tools/tool_dispatcher.dart';

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
    );
    // Phase A.3 — merge Ops's LlmPort provider pool (multi-provider
    // mcp_llm — Anthropic / OpenAI / Gemini) into the KernelApp's
    // `agentLlmSessions` via the `addAll(Map)` helper (FR-LLM-008,
    // 2026-05-24). The backbone's pool is empty by default
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
        // `AgentLlmSessions.addAll` (FR-LLM-008) accepts the narrower
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
    return OpsConfig(
      version: src.version,
      appName: src.appName,
      // Always reset to the reserved `_system` slot on project switch.
      // Carrying `src.activeWorkspace` (a host-global) over made a freshly
      // opened project inherit the PREVIOUS project's workspace id, so
      // `wsContentRoot(projectRoot, <stale wsId>)` pointed at a `<wsId>.mbd`
      // that doesn't exist in the new project → its content failed to load.
      activeWorkspace: '_system',
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
