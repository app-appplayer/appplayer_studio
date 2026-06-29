/// `VibeStudioHostApp` — the universal-host `StudioApp` implementation.
///
/// Domain code is zero: the host doesn't carry a vibe / kb-style
/// canonical, server bootstrap, or LLM adapter of its own. It mounts
/// the standard backbone (kernel agent stack + bundle install
/// surface) and surfaces a "pick an installed bundle" welcome view.
/// Once the user activates a bundle, [DslWorkspaceView] renders that
/// bundle's `ui/app.json` through the runtime — the host has nothing
/// to know about the bundle's domain.
///
/// Round B (current): single-bundle activation, simple welcome
/// screen. Round C: multi-bundle composition (split / tabbed / nested
/// workspaces, cross-domain MCP routing).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/apps.dart' as apps;
import 'package:appplayer_studio/base.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:brain_kernel/mcp_host.dart' as mh;
import 'package:appplayer_studio/workspace.dart';
import 'package:appplayer_studio/src/base/agent/agent_invoke_queue.dart';
import 'package:appplayer_studio/src/base/install/coverage_capabilities.dart';
import 'package:appplayer_studio/src/base/install/plugin_install.dart';
import 'package:appplayer_studio/src/base/shell/plugins_panel.dart';
import 'package:appplayer_studio/src/base/install/secret_vault_install.dart';

/// Collaborators handed to a host extension so it can register tools and
/// surfaces without `standard` (the open base) knowing what the extension
/// is. The pro tier injects the marketplace through this seam; standard
/// itself registers nothing (see [VibeStudioHostApp.registerExtensions]).
///
/// Exposes only closures + kernel types — never standard's internal
/// classes — so an extension package depends on `vibe_studio` for the
/// seam without reaching into private host wiring.
class StudioExtensionContext {
  StudioExtensionContext({
    required this.boot,
    required this.installBundle,
    required this.activatePackage,
    required this.clientHost,
    required this.addOverlay,
    required this.addHomeEntry,
  });

  /// Kernel server host — register MCP tools (`boot.addTool`).
  final mk.KernelServerHost boot;

  /// Install a `.mbd` at [mbdPath] through the host's bundle base model.
  /// Returns the install surface result (`{ok, namespace, mbdPath}`).
  final Future<Map<String, dynamic>> Function(String mbdPath) installBundle;

  /// Open an installed package as a tab (host's activate path).
  final Future<void> Function(String mbdPath) activatePackage;

  /// Kernel client host for outbound MCP connections (null if none).
  final mk.KernelClientHost? clientHost;

  /// Add a widget to the shell overlay stack (shown over the body).
  final void Function(Widget overlay) addOverlay;

  /// Add an entry to the Home grid — an icon to the right of the BUILT-IN
  /// APPS section title. This is how an extension gives users a visible
  /// entry point on the welcome screen (e.g. a "Marketplace" icon that
  /// opens the market overlay).
  final void Function({
    required String label,
    required IconData icon,
    required void Function() onTap,
  })
  addHomeEntry;
}

/// Standard model catalogue every builder reuses. Mirrors
/// `kVibeModelCatalog` (vibe_app_builder) — same Claude line-up so the
/// universal host's chat header offers the same picks as a standalone
/// builder. The catalogue lives on the host instance because base must
/// stay vibe-flavour-free; future builders pick their own catalogue.
const List<VibeModelOption> kStudioModelCatalog = <VibeModelOption>[
  VibeModelOption(
    id: 'claude-opus-4-8',
    label: 'Opus 4.8',
    note: 'most capable · default',
    provider: 'anthropic',
  ),
  VibeModelOption(
    id: 'claude-opus-4-7',
    label: 'Opus 4.7',
    note: 'previous flagship',
    provider: 'anthropic',
  ),
  VibeModelOption(
    id: 'claude-sonnet-4-6',
    label: 'Sonnet 4.6',
    note: 'balanced · everyday',
    provider: 'anthropic',
  ),
  VibeModelOption(
    id: 'claude-haiku-4-5-20251001',
    label: 'Haiku 4.5',
    note: 'fast · light tasks',
    provider: 'anthropic',
  ),
  VibeModelOption(
    id: 'gpt-5.5',
    label: 'GPT-5.5',
    note: 'OpenAI flagship',
    provider: 'openai',
  ),
  VibeModelOption(
    id: 'gpt-5.4-mini',
    label: 'GPT-5.4 mini',
    note: 'fast · cheap',
    provider: 'openai',
  ),
  VibeModelOption(
    id: 'gemini-3.1-pro-preview',
    label: 'Gemini 3.1 Pro',
    note: 'Google flagship · reasoning',
    provider: 'gemini',
  ),
  VibeModelOption(
    id: 'gemini-3.5-flash',
    label: 'Gemini 3.5 Flash',
    note: 'fast · agentic',
    provider: 'gemini',
  ),
  // Claude Code subprocess — runs on the user's existing Claude
  // subscription (no API key). Recipe at
  // `os/core/brain_kernel/recipes/claude_code/` strips
  // `ANTHROPIC_API_KEY` from the env so PAYG never gets hit.
  VibeModelOption(
    id: 'claude-code',
    label: 'Claude Code (subscription)',
    note: 'CLI subprocess · uses your Claude subscription',
    provider: 'claude_code',
  ),
];

/// Empty baseline — every agent (including `studio.manager`) is defined
/// in the host seed (`seed/studio.mbd/manifest.json`) and the built-in
/// app seeds. Boot fans the seed-declared agents into the catalog
/// through `agentProfiles`; no hard-coded host-side profile pool.
const List<VibeAgentProfile> kStudioAgentProfiles = <VibeAgentProfile>[];

class VibeStudioHostApp extends StudioApp {
  VibeStudioHostApp();

  mk.KernelServerHost? _mcpBoot;

  /// Bundle-host bridge — owns session lifecycle, Zone-scoped
  /// dispatch, attached-handle bookkeeping. Created at MCP boot
  /// time (once the ServerBootstrap exists) and threaded into every
  /// `HostBundleActivationContext` so each bundle activation opens
  /// its own DispatchSession.
  BundleSessionBridge? _bridge;

  /// Plugin-mode bundle activations (`plugin.register kind:bundle`), kept so
  /// `plugin.unregister` can tear each fully down via `unregisterAll`.
  final Map<String, HostBundleActivationContext> _pluginBundleCtxs =
      <String, HostBundleActivationContext>{};

  /// Per-domain key-value storage. Each activated bundle gets a
  /// namespace (== `manifest.id`) and stores its state (recents /
  /// pins / preferences / caches) under it. Lifecycle is process-long
  /// — the JSON-file adapter is durable across restarts.
  mk.DomainStorage? _domainStorage;

  /// Chrome-level UI action bridge — `StandardStudioShell` populates
  /// the setters from inside its `setState`. The MCP tool handlers
  /// below call into the bridge so an LLM driving the host over MCP
  /// hits the same code path a user click does.
  final ChromeBridge _chromeBridge = ChromeBridge();

  /// Overlays contributed by host extensions (e.g. the pro tier's
  /// marketplace surface) via [registerExtensions]. Mounted in the shell
  /// overlay stack. Empty in the base build (standard adds none).
  final List<Widget> _extensionOverlays = <Widget>[];

  void _addExtensionOverlay(Widget overlay) => _extensionOverlays.add(overlay);

  /// Home-grid entries contributed by extensions (e.g. pro's "Marketplace"
  /// icon). Passed to the workspace's home view; rendered to the right of
  /// the BUILT-IN APPS title. Empty in the base build.
  final List<HomeExtensionEntry> _extensionHomeEntries = <HomeExtensionEntry>[];

  void _addExtensionHomeEntry({
    required String label,
    required IconData icon,
    required void Function() onTap,
  }) => _extensionHomeEntries.add(
    HomeExtensionEntry(label: label, icon: icon, onTap: onTap),
  );

  /// Toggles the host-level Plugins surface (overlay). Opened from the
  /// Plugins Home entry — plugins are host-level (shared catalog), reached
  /// from Home like apps, not owned by any built-in app.
  final PluginsController _pluginsController = PluginsController();

  /// Extension seam — overridden by a consumer host (e.g. the pro tier)
  /// to register extra tools / surfaces against [ctx]. The base
  /// (standard) host registers nothing, so the open build carries no
  /// extension code. Called once during `registerMcpTools` when the
  /// kernel, bundle surface and client host are all live.
  @protected
  void registerExtensions(StudioExtensionContext ctx) {}

  /// Last-activated bundle path remembered on the StudioApp instance.
  /// Round B uses this for tracing only; the actual rebuild is owned
  /// by `_HostScaffold` so chat / workspace re-render in lockstep.
  /// Round C will lift the active-bundle state out of the scaffold so
  /// multi-bundle composition can address several at once.
  String? lastActivatedBundle;

  /// Per-tab chat controllers. Key = tab path, or `'home'` for the
  /// home tab. Each tab keeps its own message history so switching
  /// tabs doesn't wipe conversation. Created lazily on first activation.
  final Map<String, VibeChatController> _chatByKey =
      <String, VibeChatController>{};

  /// Notifier the shell listens to. Flips to the chat controller of
  /// the currently-active tab. Initialised in `buildChatController`.
  late final ValueNotifier<VibeChatController> _activeChat;

  /// Unit base key of the active chat (`home` / `<pkg>` / `<pkg>::<project>`).
  /// A per-agent chat switch derives its conversation key from this.
  String _activeChatBaseKey = 'home';

  /// Switch the active chat to [agentId]'s own conversation. A roster agent
  /// gets a dedicated conversation keyed `<baseKey>::agent::<agentId>` (its
  /// turns load from disk, the chip reflects it, the next message routes to
  /// it). Selecting the active tab's manager returns to the base conversation.
  /// Keeps the kernel generic — the host re-keys the panel; FlowBrain already
  /// isolates `conv/<agentId>/turns`.
  void _switchChatAgent(String agentId) {
    final base = _activeChatBaseKey;
    final mgrOverride = _chromeBridge.chatManagerOverride.value;
    final mgrBase = _chromeBridge.activeChatAgentId.value;
    // The manager roster entry is surfaced with the base id (`mgrBase`); the
    // actual routed manager may be the per-unit scoped clone (`mgrOverride`).
    // Either selecting it returns to the base (manager) conversation.
    final isManager =
        agentId.isEmpty || agentId == mgrBase || agentId == mgrOverride;
    final key = isManager ? base : '$base::agent::$agentId';
    final ctrl = _chatFor(key);
    // `_chatFor` seeds `selectedAgentId` with the roster manager; for an agent
    // conversation route to the picked agent instead (the send path uses
    // `selectedAgentId != 'manager'` → `sendForAgent`). For the manager use the
    // *base* id (clean label like `admin`, not the per-unit scoped clone's
    // hash) — `sendForAgent` upgrades the base manager to the scoped override
    // at send time, so routing stays per-unit isolated.
    ctrl.selectedAgentId =
        isManager
            ? (mgrBase.isNotEmpty ? mgrBase : (mgrOverride ?? ''))
            : agentId;
    _activeChat.value = ctrl;
  }

  /// Backbone cached for lazy chat-controller creation when the user
  /// opens a new tab after launch. Stashed in `buildShell` (the only
  /// caller already has a backbone in scope at that point).
  StudioBackbone? _backboneCached;

  /// Latest host settings, cached from `buildShell` (which re-runs on a
  /// settings change). Lazily-booted host capabilities (browser) read
  /// `chromiumPath` from here fresh per call so a hot-swap takes effect.
  VibeSettings? _settings;

  /// Config-root hint injected by `studio_main` before the first call
  /// to [agentProfiles]. Lets the getter resolve the host_agents.json
  /// path even though `_backboneCached` only lands after `buildServer`.
  /// Null when the host runs without `studio_main` (tests, fixtures).
  String? configRootHint;

  /// Configured default model id (`settings.llmModel`) injected by
  /// `studio_main` before the first [agentProfiles] read. Used as the
  /// modelId fallback for seed / host agents that declare no model, so
  /// they inherit the configured model instead of a hardcoded id. Null
  /// when the host runs without `studio_main` (tests / fixtures).
  String? defaultModelHint;

  /// Notifier the buildShell binding listens to for the Settings
  /// dialog's Domain panel. Path null = home (no domain panel); non-null
  /// = active package path used to look up its display name.
  final ValueNotifier<String?> _activePackageNotifier = ValueNotifier<String?>(
    null,
  );

  /// Notifier tracking the active tab's *currentProject* (the target
  /// the user is authoring). Distinct from [_activePackageNotifier]
  /// (the tab's host package). Drives the shell's bundle-name
  /// surface so the user sees the project they're working on (e.g.
  /// the draft `.mbd` the App Builder BuiltInApp is editing) instead
  /// of just the tab's host shell name.
  final ValueNotifier<String?> _activeProjectNotifier = ValueNotifier<String?>(
    null,
  );

  // ── StudioApp metadata ─────────────────────────────────────────

  @override
  String get toolId => 'vibe_studio_debug';

  /// Public-facing name. The package id stays `vibe_studio` for now —
  /// rename happens in a separate migration round once we're sure no
  /// downstream callers hard-code `'standard'` strings.
  @override
  String get displayName => 'AppPlayer Studio';

  /// Debug instance binds 7840 by default so it can coexist with the
  /// release instance (7830 default). Release tree = `release/0.1/`,
  /// debug tree = `debug/` (this build). See memory `project-vibe-
  /// studio-paths`.
  @override
  int get defaultPort => 7840;

  /// The legacy `studio_builder.mbd` host-shell seed is retired. The
  /// host registers `builder.*` agents directly through
  /// [kStudioAgentProfiles] (no seed manifest required), `seed/`
  /// contains only the per-built-in-app knowledge seeds, and the home
  /// picker surfaces only the public BuiltInApp launchers (App Builder
  /// / Scene Builder / Ops). New `.mbd` drafts go through
  /// `_createNewPackage`, which drops the `.builtin_app_builder`
  /// marker so `BuiltInAppRegistry.canHandle` matches them naturally —
  /// no host shell tab to adopt anything into.
  String? seedPath() => null;

  /// Resolve `<pkgName>/seed/<mbdName>` — the apps wrapper keeps its
  /// seed directory at the package root (alongside `dart/`), not
  /// inside the dart pubspec, so new built-in apps can drop a
  /// `seed/<id>.mbd` + a `dart/lib/src/<id>/` sibling and the host
  /// picks them up automatically.
  String? _findPackageSeed(String pkgName, String mbdName) {
    final cwdCandidate = p.join(
      Directory.current.path,
      '..',
      pkgName,
      'seed',
      mbdName,
    );
    if (Directory(cwdCandidate).existsSync()) {
      return p.normalize(cwdCandidate);
    }
    var current = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 14; i++) {
      final c = p.join(current.path, pkgName, 'seed', mbdName);
      if (Directory(c).existsSync()) return p.normalize(c);
      final next = current.parent;
      if (next.path == current.path) break;
      current = next;
    }
    return null;
  }

  @override
  List<SeedBundleEntry> seedBundles() {
    // Built-in apps publish themselves through `BuiltInAppRegistry`;
    // each app's seed mbd lives at `vibe_studio/seed/<id>.mbd/`
    // by convention so adding a new built-in needs no host edits.
    final builtInEntries = <SeedBundleEntry>[];
    for (final app in BuiltInAppRegistry.instance.apps) {
      final seedPath = _findPackageSeed('standard', '${app.id}.mbd');
      if (seedPath != null) {
        builtInEntries.add(
          SeedBundleEntry(mbdPath: seedPath, namespace: app.id),
        );
      }
    }
    // Host-level seed (studio.mbd) — knowledge + the baseline agent
    // catalog. Fans out studio.* tool catalog + host concepts as
    // `studio://knowledge/studio_host_*` resources so external LLMs
    // discover the host surface via resources/list + studio.knowledge
    // .query, and supplies the `agents[]` block that boot reads to
    // seed `host_agents.json` (Home tab's Domain panel source).
    // Per MOD-INFRA-010 §10.1 — host knowledge stays at host scope.
    final hostDocs = _findPackageSeed('standard', 'studio.mbd');
    final hostDocsEntries = <SeedBundleEntry>[
      if (hostDocs != null)
        SeedBundleEntry(mbdPath: hostDocs, namespace: 'studio'),
    ];
    return <SeedBundleEntry>[...hostDocsEntries, ...builtInEntries];
  }

  /// Combined agent set — host baseline (read from `host_agents.json`
  /// when present, else `kStudioAgentProfiles`) merged with the agents
  /// declared in each built-in app's seed manifest. Built-in tabs
  /// bypass the normal `_activateBundle` path (their bodies are Flutter
  /// widgets), so the seed-declared agents are folded into the baseline
  /// at boot here — otherwise `<shortId>.manager` ids the chat panel
  /// dispatches to would never reach `AgentHost.registerAgents`.
  ///
  /// `host_agents.json` becomes the single source of truth for host
  /// baseline agent → model bindings once it exists; the Domain tab's
  /// Home view edits the same file (see [_resolveDomainPanel]). First
  /// run seeds the file from [kStudioAgentProfiles].
  ///
  /// Seed-supplied agents win on id collision so the seed remains the
  /// single source of truth for the built-in's identity.
  @override
  List<VibeAgentProfile> get agentProfiles {
    _ensureHostAgentsFile();
    var profiles = _loadHostAgents();
    // Host seed is already folded into `host_agents.json`; only fan
    // out the remaining seed bundles (built-in apps) so their agents
    // get exposed-id prefixes without duplicating the host catalog.
    final hostSeedNs =
        seedBundles().isNotEmpty ? seedBundles().first.namespace : null;
    for (final entry in seedBundles()) {
      if (entry.namespace == hostSeedNs) continue;
      profiles = loadSeedAgentProfiles(
        seedPath: entry.mbdPath,
        baseline: profiles,
        exposedShortId: entry.namespace,
        defaultModelId: defaultModelHint,
      );
    }
    return profiles;
  }

  /// Absolute path to host_agents.json, the disk source-of-truth for
  /// the baseline agent → model bindings. Null when no configRoot was
  /// injected yet (e.g. test harness without `studio_main`).
  String? _hostAgentsPath() {
    final root = configRootHint ?? _backboneCached?.configRoot;
    if (root == null) return null;
    return p.join(root, 'host_agents.json');
  }

  /// Seed `host_agents.json` from the host seed (`studio.mbd/manifest.
  /// json` — agents block) so the Home-tab Domain panel reflects what
  /// shipped with the build. The seed manifest is the source of truth;
  /// the user-editable disk copy is a fork that survives across boots.
  /// Falls back to [kStudioAgentProfiles] when the seed is missing
  /// (test harnesses, broken installs).
  void _ensureHostAgentsFile() {
    final path = _hostAgentsPath();
    if (path == null) return;
    final file = File(path);
    if (file.existsSync()) return;
    try {
      Map<String, dynamic>? agentsBlock;
      final seedPath = _findPackageSeed('standard', 'studio.mbd');
      if (seedPath != null) {
        final seedManifest = File(p.join(seedPath, 'manifest.json'));
        if (seedManifest.existsSync()) {
          final raw = jsonDecode(seedManifest.readAsStringSync());
          if (raw is Map<String, dynamic>) {
            final a = raw['agents'];
            // Host seed = the host itself — no namespace prefix gets
            // added. Built-in / user bundle seeds get their namespace
            // through `loadSeedAgentProfiles(exposedShortId: …)`, but
            // the host catalog stores the raw manifest id (`manager`).
            if (a is Map<String, dynamic>) agentsBlock = a;
          }
        }
      }
      agentsBlock ??= <String, dynamic>{
        'agents': <Map<String, dynamic>>[
          for (final p in kStudioAgentProfiles)
            <String, dynamic>{
              'id': p.id,
              'name': p.displayName,
              'role': p.role.name,
              'systemPrompt': p.systemPrompt,
              'model': <String, dynamic>{
                'provider': p.provider,
                'model': p.modelId,
              },
              'tools': p.toolNames,
            },
        ],
      };
      final manifest = <String, dynamic>{'agents': agentsBlock};
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(manifest),
      );
    } catch (e) {
      stderr.writeln('vibe_studio: host_agents.json seed skipped — $e');
    }
  }

  /// Parse host_agents.json (canonical or flat agents shape) into
  /// [VibeAgentProfile]s. Falls back to [kStudioAgentProfiles] when the
  /// file is missing / unreadable / malformed.
  List<VibeAgentProfile> _loadHostAgents() {
    final path = _hostAgentsPath();
    if (path == null) return kStudioAgentProfiles;
    final file = File(path);
    if (!file.existsSync()) return kStudioAgentProfiles;
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) return kStudioAgentProfiles;
      final agentsRaw = raw['agents'];
      List? agents;
      if (agentsRaw is Map<String, dynamic>) {
        agents = agentsRaw['agents'] as List?;
      } else if (agentsRaw is List) {
        agents = agentsRaw;
      }
      if (agents == null || agents.isEmpty) return kStudioAgentProfiles;
      final out = <VibeAgentProfile>[];
      for (final a in agents) {
        if (a is! Map<String, dynamic>) continue;
        final id = a['id'] as String?;
        if (id == null || id.isEmpty) continue;
        final name =
            (a['name'] as String?) ?? (a['displayName'] as String?) ?? id;
        String modelId;
        String provider;
        final modelEntry = a['model'];
        if (modelEntry is Map<String, dynamic>) {
          modelId =
              (modelEntry['model'] as String?) ??
              (a['modelId'] as String?) ??
              defaultModelHint ??
              'claude-opus-4-7';
          provider = (modelEntry['provider'] as String?) ?? 'anthropic';
        } else {
          modelId =
              (a['modelId'] as String?) ??
              defaultModelHint ??
              'claude-opus-4-7';
          provider = 'anthropic';
        }
        final tools =
            (a['tools'] as List?)?.cast<String>() ??
            (a['toolNames'] as List?)?.cast<String>() ??
            const <String>[];
        out.add(
          VibeAgentProfile(
            id: id,
            displayName: name,
            provider: provider,
            modelId: modelId,
            systemPrompt: (a['systemPrompt'] as String?) ?? '',
            toolNames: tools,
            role: _parseAgentRole(a['role'] as String?),
          ),
        );
      }
      return out.isEmpty ? kStudioAgentProfiles : out;
    } catch (e) {
      stderr.writeln('vibe_studio: host_agents.json read skipped — $e');
      return kStudioAgentProfiles;
    }
  }

  mk.AgentRole _parseAgentRole(String? raw) {
    switch ((raw ?? 'worker').toLowerCase()) {
      case 'manager':
        return mk.AgentRole.manager;
      case 'reviewer':
        return mk.AgentRole.reviewer;
      default:
        return mk.AgentRole.worker;
    }
  }

  @override
  List<VibeModelOption> get modelCatalog => kStudioModelCatalog;

  @override
  List<Map<String, dynamic>> fetchAllToolDefinitions() =>
      studioToolDefinitions(_mcpBoot);

  // ── Server / tools / transport ─────────────────────────────────

  @override
  Object buildServer({
    required StudioBackbone backbone,
    required BundleInstallSurface bundles,
  }) {
    // Universal host — kb_* domain tools live in a future
    // knowledge_builder.mbd that activates inside the studio (per
    // memory `project_studio_appplayer_superset` — universal host
    // ships only host-level surface, domains add their own).
    //
    // Round C (kernel-app F) — the host's MCP endpoint joins the
    // shared `KernelApp` pool through `app.addEndpoint(label:'studio')`
    // so it sits next to the spawn factory's narrow-link endpoints
    // (PORTING_GUIDE §6.2.5). The returned `endpoint.server` is the
    // same `mk.KernelServerHost` type the rest of buildServer + the
    // mirror helpers (`_mirrorHostToolsOnto` / `_mirrorHostResourcesOnto`)
    // already accept, so the call sites below stay unchanged.
    final hostEndpoint = backbone.app.addEndpoint(
      label: 'studio',
      appName: toolId,
    );
    final boot = hostEndpoint.server..register();
    _mcpBoot = boot;
    _bridge = BundleSessionBridge(
      systemResolver:
          () =>
              _backboneCached?.isFlowBrainBooted == true
                  ? _backboneCached!.app.system
                  : null,
      // vibe_studio exposes an external MCP endpoint via ServerBootstrap.
      // Mirror every bridge.registerTool onto the server's tool table
      // so external LLM clients reach the same tools the in-process
      // dispatch sees. AppPlayer (client-default) skips this.
      serverAdapter: (def) {
        boot.addTool(
          name: def.name,
          description: def.description ?? '',
          inputSchema: def.inputSchema ?? const <String, dynamic>{},
          handler: def.handler,
        );
      },
      serverAdapterRemove: boot.removeTool,
      // Resource mirror — bridge.registerResource also lands on the
      // server's resources/list so external LLMs can resources/read it.
      resourceServerAdapter: (uri, name, description, mimeType, handler) {
        boot.addResource(
          uri: uri,
          name: name ?? uri,
          description: description ?? uri,
          mimeType: mimeType ?? 'application/octet-stream',
          handler: (u, _) async {
            final value = await handler(u);
            final text = value is String ? value : jsonEncode(value);
            return mk.KernelReadResourceResult(
              contents: <mk.KernelResourceContent>[
                mk.KernelResourceContent(
                  uri: u,
                  mimeType: mimeType ?? 'application/octet-stream',
                  text: text,
                ),
              ],
            );
          },
        );
      },
      resourceServerAdapterRemove: (uri) {
        try {
          boot.removeResource(uri);
        } catch (_) {
          /* best-effort — server lib throws on unknown */
        }
      },
    );
    _chromeBridge.sessionBridge = _bridge;
    return boot;
  }

  @override
  void registerMcpTools({
    required Object server,
    required StudioBackbone backbone,
    required BundleInstallSurface bundles,
  }) {
    final boot = server as mk.KernelServerHost;
    // Phase A.2 — cache backbone for downstream helpers
    // (startTransport's `_initBuiltInAttachAfterKnowledgeReady` +
    // mount call sites). registerMcpTools always fires before
    // startTransport on the StudioBoot path, so this beats the
    // attach race.
    _backboneCached = backbone;
    // Kernel-standard `bk.<facade>.<verb>` tools — single source of
    // truth for agent / fact / skill / profile / philosophy /
    // knowledge / ops / pipelines / runbooks / workflows. Replaces
    // the per-facade host-side `registerXxxTools` wrappers
    // (`base/install/{fact,knowledge,ops,philosophy,profile,skill}_tools.dart`
    // + `base/agent/agent_dispatch_tools.dart`) which previously
    // re-registered same-named tools — cleanup 2026-05-26 per cherry
    // inbox `cli-llm-provider-recipe-2026-05-26.md` §5 (bridge alias
    // mechanism owns the `bk.*` namespace; hosts let kernel publish
    // the standard surface).
    final hostEndpoint = backbone.app.endpoint('studio');
    if (hostEndpoint != null) {
      hostEndpoint.addStandardTools(backbone.app);
    }

    // Host capability registry — general (non-knowledge) capabilities
    // land here via `registerExposed`. vibe_studio dispatches through
    // `boot.callTool`, so the dispatcher hooks are no-ops; `boot.addTool`
    // (inside `registerExposed`) covers both the external transport and
    // in-process dispatch. One registry shared by every capability below.
    final hostTools = mk.HostToolRegistry(
      endpoint: boot,
      attachToDispatcher: (_, __) {},
      detachFromDispatcher: (_) {},
      // §6 destructive-action gate (spec 12 / cherry FlowBrain runtime
      // handoff). Tools registered `destructive: true` (irreversible —
      // git push · external send · settlement · publish) require human
      // confirmation before running. Surfaced through the host's standard
      // yes/no dialog; deny-by-default when no UI is mounted (returns false).
      confirmDestructive: (toolName, args) async {
        // A post to the internal `in_app` feed (e.g. a process handoff to a
        // workspace thread) is not the irreversible *external* send this gate
        // guards — it is an internal, reversible append. Auto-allow so an
        // autonomous process flows unattended. Human sign-off is a *separate*
        // mechanism: an approval gate assigned to a person (team member /
        // lead), which suspends only that one process while everything else
        // keeps running — not this global blocking dialog.
        if (toolName == 'channel.send' && args['channelId'] == 'in_app') {
          return true;
        }
        // Sandboxed process execution (io.execute) is already constrained by
        // the io capability's own policy — an exe allowlist (git/dart/flutter/
        // pub), allowedRoots sandbox, operator role, no shell. Read-only dev
        // commands (analyze / test / version / status / log / get / --dry-run)
        // carry no irreversible effect, so an autonomous process runs them
        // without this modal. Mutating commands (publish / push / commit / …)
        // still fall through to confirmation — model human sign-off on those
        // as the process's own approval gate before the step.
        if (toolName == 'io.execute' || toolName == 'io.commit_execute') {
          final inner = args['args'];
          final argv = inner is Map ? inner['argv'] : null;
          final sub =
              (argv is List && argv.isNotEmpty) ? argv.first.toString() : '';
          const readOnly = <String>{
            '--version',
            'version',
            'analyze',
            'test',
            'status',
            'log',
            'diff',
            'get',
            'show',
            'doctor',
            'list',
            'outdated',
          };
          final dryRun =
              argv is List && argv.any((a) => a.toString() == '--dry-run');
          if (readOnly.contains(sub) || dryRun) return true;
        }
        final ask = _chromeBridge.dialog;
        if (ask == null) return false;
        return ask(
          title: 'Confirm irreversible action',
          body:
              'An agent wants to run "$toolName" — this action cannot be '
              'undone.\n\nArguments:\n${jsonEncode(args)}\n\nAllow it?',
        );
      },
    );
    // `mcp.*` — connect · call_tool · read_resource · list_tools ·
    // list_resources · disconnect, so apps drive external MCP servers
    // *through* the host rather than the host pre-connecting/flattening.
    // Kernel-owned impl (`system/host/client_tools.dart`); `clientHost`
    // was supplied at `KernelApp.boot` (studio_boot.dart).
    final clientHost = backbone.app.clientHost;
    if (clientHost != null) {
      mk.registerClientTools(hostTools, clientHost);
      // `mcp.connect_extension` — host-side companion that builds serial /
      // usb / ble / tcp / ws transports through mcp_bridge (the FFI home)
      // and injects them via the kernel seam. The connection lands in the
      // same client host registry, so the kernel `mcp.*` verbs above drive
      // the board by id afterward (cherry `embedded-mcp-serving-base`).
      registerExtensionConnectTool(hostTools, backbone);
    }
    // `plugin.*` — register a plugin (server / hub / bundle) so its tools enter
    // the catalog as `<id>.<tool>` for any app/agent; persists (shared on-disk)
    // and re-connects / re-activates on boot. Vendored `plugin_host` recipe.
    // Unconditional: server/hub use `clientHost` (may be null → those error
    // gracefully); bundle uses the host's plugin-mode activation closures.
    registerPluginTools(
      hostTools,
      clientHost: clientHost,
      activateBundle: (source) async {
        // Plugin mode = activate the bundle's tools with no UI tab (tabKey:'').
        final bundle =
            await mk.McpBundleLoader.loadDirectory(source.endpoint ?? '');
        final ctx = HostBundleActivationContext(
          boot: boot,
          tabKey: '',
          bundle: bundle,
          exposedShortId: source.id,
          chromeBridge: _chromeBridge,
          backbone: _backboneCached,
          sessionBridge: _bridge,
        );
        _pluginBundleCtxs[source.id] = ctx;
        final names = <String>[];
        for (final t in bundle.tools?.tools ?? const []) {
          final r = await ctx.registerTool(t);
          if (r.ok) {
            names.add(t.name);
          } else {
            stderr.writeln(
              'plugin "${source.id}" tool "${t.name}" failed: ${r.error}',
            );
          }
        }
        return names;
      },
      deactivateBundle: (id) async {
        await _pluginBundleCtxs.remove(id)?.unregisterAll();
      },
    );
    // Extension seam — a consumer host (pro tier) registers extra
    // tools / surfaces here. Standard registers nothing, so the open
    // base build carries no extension (e.g. marketplace) code. The
    // context exposes only closures + kernel types, never standard's
    // internal wiring.
    registerExtensions(
      StudioExtensionContext(
        boot: boot,
        installBundle: (mbdPath) => bundles.install(mbdPath),
        activatePackage: (mbdPath) async {
          await _chromeBridge.activatePackage?.call(mbdPath);
        },
        clientHost: backbone.app.clientHost,
        addOverlay: _addExtensionOverlay,
        addHomeEntry: _addExtensionHomeEntry,
      ),
    );
    // `plugin.*` host surface — a Home entry (right of the BUILT-IN APPS
    // title) opening an overlay to manage installed plugins, the same seam
    // the pro tier uses for Marketplace. Plugins are host-level (shared
    // `<id>.<tool>` catalog), reached from Home like apps — not an app.
    _addExtensionHomeEntry(
      label: 'Plugins',
      icon: Icons.extension_outlined,
      onTap: _pluginsController.open,
    );
    _addExtensionOverlay(
      PluginsOverlayHost(controller: _pluginsController, bridge: _chromeBridge),
    );
    // `browser.*` — 9 mcp_browser ops on one shared engine, booted
    // lazily from the host's `chromiumPath` (settings, hot-swappable).
    // Built-ins (ops, …) and bundle apps *use* this instead of each
    // owning a browser engine (parity rule).
    registerBrowserCapability(
      registry: hostTools,
      chromiumPath: () => _settings?.chromiumPath,
      // Full engine config (cap / identity / robots) read fresh per boot so a
      // settings change applies on the next browser call.
      engineConfig: () {
        final s = _settings;
        final w = s?.browserViewportWidth;
        final h = s?.browserViewportHeight;
        return BrowserEngineConfig(
          maxConcurrentContexts: s?.maxBrowserContexts,
          userAgent: s?.browserUserAgent,
          locale: s?.browserLocale,
          timezone: s?.browserTimezone,
          viewport:
              (w != null && h != null)
                  ? <String, int>{'width': w, 'height': h}
                  : null,
          respectRobots: s?.browserRespectRobots ?? false,
        );
      },
      // `browser.auth_capture` (seal) + `setAuth` re-injection (S2). Sealer
      // is keyed by the OS keychain; no signing identity required. Profiles
      // live under `<configRoot>/browser_auth/<tenant>/<id>.enc`.
      authSealer: defaultAuthSealer(),
      authRoot: () {
        final r = _backboneCached?.configRoot;
        return (r == null || r.isEmpty) ? null : p.join(r, 'browser_auth');
      },
    );
    // `form.*` (mcp_form documents/renderers) + `ingest.*` (mcp_ingest
    // chunking) — shared engines, host-owned like browser, so built-ins
    // and bundle apps use them instead of each booting their own.
    registerFormCapability(hostTools);
    registerIngestCapability(hostTools);
    // `channel.*` — bidirectional multi-connector messaging (mcp_channel). P1
    // = in-app feed connector over the active ops project's canonical KV. P2
    // (agentic inbound) = `askAgent` routes a `channel.receive` message to the
    // agent named by its conversationId (the shared ops/host KnowledgeSystem,
    // addressed by raw id like ops itself) and the reply posts back. P3 =
    // external connectors from settings.
    registerChannelCapability(
      registry: hostTools,
      kv: () => apps.OpsBuiltInApp.liveInit?.adapters.kv,
      facts: () => apps.OpsBuiltInApp.liveInit?.system.facts,
      askAgent: (agentId, message) async {
        // Mirror `bk.agent.ask` exactly: scope the local id to the registered
        // agent id, then ask through the shared KnowledgeSystem facade.
        // Serialize per agent so an inbound channel request queues behind any
        // in-flight work for the same agent (same queue the `agent_ask` tool
        // uses) — a member processes its requests one at a time.
        final app = backbone.app;
        final scoped = app.scopeIdFor(agentId);
        final reply = await serializePerAgent(
          scoped,
          () => app.system.agents.ask(scoped, message),
        );
        return reply.content;
      },
    );
    // `io.*` — sandboxed OS process / shell execution (mcp_io + the
    // mcp_io_process ProcessAdapter). One host-owned runtime shared like
    // browser/form, so built-ins drive processes through it instead of each
    // owning their own. Deny-by-default: dev-workflow exes only, no shell,
    // manager/operator roles (worker auto-denied; spawn stays plan→commit).
    // `allowedRoots` = boot config root; dynamic per-workspace roots are a
    // follow-up (ProcessSandboxConfig is fixed at adapter construction).
    final ioConfigRoot = _backboneCached?.configRoot;
    registerIoCapability(
      registry: hostTools,
      executableAllowlist: const <String>['git', 'dart', 'flutter', 'pub'],
      allowedRoots:
          (ioConfigRoot == null || ioConfigRoot.isEmpty)
              ? const <String>[]
              : <String>[ioConfigRoot],
      roles: const <String>['manager', 'operator'],
    );

    // Capability coverage — canvas / kv / analysis / datastore(fs+db), adopted
    // through the vendored capability_tools recipe (the integrated reference:
    // `registerCapabilityTools` + each example's tool list). Built-ins / bundle
    // apps drive these via `<id>.*`. canvas = pure value type, kv = simple
    // adapter, analysis = the recipe's one-line `standardAnalysisPort()` (full
    // engine assembled in the recipe), datastore = an fs source jailed to the
    // config root + a sqlite source (db file under the same root).
    final capRoot = _backboneCached?.configRoot ?? configRootHint;
    if (capRoot != null && capRoot.isNotEmpty) {
      // open() inside is async; the registry serves db.* once it completes
      // (fs.* is ready immediately), so the open future is fire-and-forget.
      final coverage = registerCoverageCapabilities(
        hostTools,
        capRoot: capRoot,
      );
      unawaited(coverage.ready);
    }
    // Credential vault — `secret.*` over the OS keychain (vendored
    // secure_capability recipe). Independent of capRoot; set / exists /
    // remove / list, no plaintext get.
    registerSecretVault(hostTools);

    // Chrome + renderer surface — 13 chrome.* + 3 renderer.* tools.
    // Bodies live in vibe_studio_base so every studio host gets the
    // same surface. Handlers route through `_chromeBridge`; the shell
    // wires the bridge setters when it mounts.
    registerChromeTools(boot, _chromeBridge);
    registerRendererTools(boot, _chromeBridge);
    // UI control + advanced introspection — `wait_for`, `snapshot_diff`,
    // `screenshot_region`, `studio.ui.tap`. Dispatches host MCP calls
    // through `boot.callTool` for the polling helper.
    registerUiControlTools(
      boot,
      bridge: _chromeBridge,
      callTool: boot.callTool,
    );
    // Seed the chrome bridge's built-in seed path set so the
    // `studio.bundle.*` install surface can distinguish user-installed
    // packages from built-in app seeds — without this `bundle.activate`
    // would accept any `manifest.json`-bearing directory (including the
    // shipped built-in seeds) and let an external caller open a tab the
    // user never installed.
    for (final entry in seedBundles()) {
      _chromeBridge.builtInSeedMbdPaths.add(entry.mbdPath);
    }
    // Bundle install / list / activate / uninstall / dispatch_tool —
    // five `studio.bundle.*` install-surface verbs. Bodies live in
    // vibe_studio_base so every studio host gets the same surface.
    registerBundleInstallTools(boot, bundles: bundles, bridge: _chromeBridge);
    // Bundle manifest mutators — 14 `studio.builder.*` verbs that write
    // ui/app.json, tools/*.js, and various manifest slots. Bodies live
    // in vibe_studio_base so every studio host gets the same surface.
    registerBuilderMutatorTools(boot, bridge: _chromeBridge);
    // `bk.knowledge.*` · `bk.profile.*` · `bk.fact.*` · `bk.philosophy.*`
    // · `bk.skill.*` · `bk.ops.*` are now served by the kernel's
    // standard tool surface (`addStandardTools` above). The previous
    // host wrappers were retired 2026-05-26.
    // Project lifecycle surface — 5 bridge-routed verbs (new · open ·
    // close · info · recents) + generic disk-layout primitive
    // (`studio.project.create`). Bodies live in vibe_studio_base so
    // every studio host gets the same surface. The `recents` reader
    // takes `toolId` because it reads `VibeSettings.defaultPath(toolId)`
    // directly; the others route through `_chromeBridge`.
    registerProjectTools(boot, _chromeBridge, toolId: toolId);
    // Seed bundle's domain tools = mbd JS (kind:'js'). Auto-registered
    // by `host_bundle_activation._registerJsTool` at bundle activation
    // time — no host-side Dart wrappers needed.
    // ── studio.bundle.* — spec-compliant resource readers. Registered
    // in base so every studio gets the same surface (BundleFolder's 7
    // reserved slots: ui · assets · skills · knowledge · profiles ·
    // philosophy · agents). Domain tools reach their own bundle's
    // resources through these without host plumbing.
    registerBundleResourceTools(boot);
    // Generic file IO primitives scoped to VibeSettings.workspaceDir.
    // Domain tools (JS / external MCP) use these to read/write data
    // files under the workspace without needing dart:io bindings.
    registerFsTools(boot, toolId: toolId);
    // ── studio.search.* — BM25 search across installed bundles.
    // Body lives in vibe_studio_base.
    registerSearchTools(boot, bundles: bundles);
    // ── studio.meta.* — tool / capability introspection. Body lives
    // in vibe_studio_base; handlers read `boot.toolDefinitions`.
    registerMetaTools(boot);
    // ── studio.builder.ui.* — atomic ui authoring surface
    // (P1+P2+P3 of studio-builder-rebuild). One catalogue feeds
    // both the LLM-facing catalog tools and the schema-driven
    // validation that gates every write call.
    final catalogSvc = BuilderCatalogService();
    final readerSvc = BuilderUiReadService();
    final writerSvc = BuilderUiWriteService();
    final validatorSvc = SchemaValidator(catalogSvc);
    // Active-project resolver — every studio.builder.* tool that
    // takes mbdPath defaults to the active tab's adopted project
    // when the caller omits the arg. External LLMs no longer have
    // to track / pass paths the host already knows.
    //
    // Use `projectPath` (the adopted project's .mbd) — NOT
    // `packagePath` which is the active *tab's* .mbd (e.g. the
    // Studio Builder shell itself, not the bundle being edited).
    String? resolveActiveMbdPath() {
      final info = _chromeBridge.activeProjectInfo?.call();
      final proj = info?['projectPath'];
      return proj is String && proj.isNotEmpty ? proj : null;
    }

    registerCatalogTools(boot, catalog: catalogSvc);
    registerUiReadTools(
      boot,
      reader: readerSvc,
      resolveActiveMbdPath: resolveActiveMbdPath,
    );
    registerUiWriteTools(
      boot,
      writer: writerSvc,
      reader: readerSvc,
      validator: validatorSvc,
      resolveActiveMbdPath: resolveActiveMbdPath,
    );
    // ── studio.builder.lib.* (P5 + placeInline) — per-project
    // library of widget instances. Isolated work + verify, or
    // inline-expand into the main tree via lib.placeInline.
    registerLibraryTools(
      boot,
      library: BuilderLibraryService(),
      writer: writerSvc,
      validator: validatorSvc,
      resolveActiveMbdPath: resolveActiveMbdPath,
    );
    // ── studio.debug.* — host introspection. Body lives in
    // vibe_studio_base; bridge.debugConfig / debugTabs feed the
    // host-specific state.
    registerDebugTools(
      boot,
      bridge: _chromeBridge,
      bundles: bundles,
      toolId: toolId,
      displayName: displayName,
      defaultPort: defaultPort,
    );
    // ── studio.recorder.* / studio.overlay.* / studio.chat.send —
    // built-in capture surface for scenario-driven demos. Always on
    // (cross-bundle recording is load-bearing for `scene_builder.mbd`
    // and any external LLM that wants to record other bundles' work).
    // Returns the [CaptureSurface] so the shell can mount the overlay
    // controller's `OverlayLayer` inside its RepaintBoundary.
    _captureSurface = registerCaptureTools(
      boot,
      bridge: _chromeBridge,
      configRoot: backbone.configRoot,
      seedScenarioDirs: () {
        // Built-in app seeds are knowledge-only per the R26 cleanup
        // (`docs/03_DDD/host.md` MOD-HOST-007 read-scope rule —
        // `knowledge.* + agents.* + manifest + requires + schemaVersion`
        // only). Scenarios are authored through the Scene Builder UI
        // into the user's scene project folder under the workspace
        // (`<workspaceDir>/<scene_project>/scenarios/*.json`); the
        // scenario tools pick them up through the active scene project,
        // not through the seed bundle. Resolver kept (interface
        // stable) and returns an empty list — future iterations may
        // walk every scene project under the workspace here if
        // multi-project listing is wanted.
        return const <String>[];
      },
    );

    // Seed onboarding prompts — `prompts/list` + `prompts/get` over
    // MCP. Bodies inline so the studio surface is self-contained.
    // Domain bundles' prompts attach through a future mcp_bundle
    // `prompts` section (separate round); first cut covers the four
    // canonical authoring workflows external LLMs need on cold start.
    _registerSeedPrompts(boot);
    // Fan out the seed + builtin bundles' knowledge entries as MCP
    // resources so external LLMs discover the studio's onboarding
    // surface via `resources/list` + `resources/read` without local
    // filesystem access. Bundles installed later wire themselves
    // through a future activation hook; first pass covers boot-time
    // seeds only. Fire-and-forget — bundle loads are async, but
    // resource registration is idempotent and the list_changed
    // notification surfaces them once they land.
    // Capture the Future so the built-in attach step can sequence
    // after fan-out (resource mirror needs the URIs to exist).
    _seedKnowledgeReady = _fanOutSeedKnowledgeAsResources(boot);
    // Fan out the seed bundles' `tools[]` so every bundle's verbs are
    // MCP-callable BEFORE tab activation. Built-in apps (app_builder /
    // scene_builder) bypass the normal `_activateBundle` path because
    // their tab body is a Flutter widget instead of a manifest UI —
    // without this fan-out their seed tools (newAppProject etc.) never
    // reach the MCP server, blocking external-LLM driven flows.
    // ignore: unawaited_futures
    _fanOutSeedTools(boot);
    // Built-in apps register their MCP tools directly in Dart (no JS).
    // Per `studio-builder-runtime-model.md §8.5`, every button / action
    // is a 1:1 MCP tool — built-in apps own their tool impls in code
    // alongside the Flutter shell.
    // ignore: unawaited_futures
    _registerBuiltInAppTools(boot, backbone);
  }

  Future<void> _registerBuiltInAppTools(
    mk.KernelServerHost boot,
    StudioBackbone backbone,
  ) async {
    // Wrap the raw `KernelServerHost` once and reuse the facade across
    // every built-in — each app sees the same host API surface
    // (`addTool` / `addResource` / `addPrompt` / `callTool`) instead of
    // the kernel handle (builtin-os-cleanup Phase 4).
    final registry = BuiltinToolRegistry(boot);
    for (final app in BuiltInAppRegistry.instance.apps) {
      try {
        await app.registerHostTools(
          registry,
          _chromeBridge,
          backbone: backbone,
        );
      } catch (e) {
        stderr.writeln(
          'vibe_studio: built-in "${app.id}" registerHostTools failed — $e',
        );
      }
    }
  }

  /// Walk the seed + builtin bundles, parse each `manifest.knowledge`
  /// section, and register every `(sourceId, docId)` as an MCP
  /// resource under the `studio://knowledge/<sourceId>/<docId>` URI.
  /// Returns the count of resources registered (for tests / logs).
  Future<int> _fanOutSeedKnowledgeAsResources(mk.KernelServerHost boot) async {
    final paths = <String>[for (final b in seedBundles()) b.mbdPath];
    var registered = 0;
    // Channel 1 — seed mbd manifest (existing path). Used by every
    // bundle (seed or installed) that ships a manifest.knowledge.
    for (final path in paths) {
      mk.McpBundle bundle;
      try {
        bundle = await mk.McpBundleLoader.loadDirectory(path);
      } catch (_) {
        // Bundle failed to load — skip silently; the studio still
        // boots, the missing knowledge just doesn't surface.
        continue;
      }
      for (final src in bundle.knowledge?.sources ?? const []) {
        for (final doc in src.documents ?? const <mk.KnowledgeDocument>[]) {
          final docId = doc.id;
          if (docId == null || docId.isEmpty) continue;
          final uri = 'studio://knowledge/${src.id}/$docId';
          final content = doc.content;
          final title = doc.title ?? docId;
          final description = src.description ?? src.name;
          try {
            _bridge!.registerResource(
              uri,
              (u) async => content,
              name: title,
              description: description,
              mimeType: 'text/markdown',
            );
            registered++;
          } on mh.McpError {
            // URI already registered (e.g. seed re-loaded) — skip
            // silently; the bridge's serverAdapter mirrors onto the
            // server, which throws on duplicate URIs.
          }
        }
      }
    }
    // Channel 2 — built-in apps may also publish sources through
    // `BuiltInApp.knowledgeSources()` (typically loaded from a
    // packaged JSON asset, no seed mbd needed). Same URI pattern;
    // addResource throws when the same URI is already registered
    // through channel 1, which we swallow so apps using both
    // channels stay safe (channel 1 wins by registration order).
    for (final app in BuiltInAppRegistry.instance.apps) {
      final codeSources = await app.knowledgeSources();
      for (final src in codeSources) {
        final srcId = src['id'];
        if (srcId is! String || srcId.isEmpty) continue;
        final docs = src['documents'];
        if (docs is! List) continue;
        for (final doc in docs) {
          if (doc is! Map) continue;
          final docId = doc['id'];
          final content = doc['content'];
          if (docId is! String || docId.isEmpty) continue;
          if (content is! String) continue;
          final title = (doc['title'] as String?) ?? docId;
          final description =
              (src['description'] as String?) ??
              (src['title'] as String?) ??
              srcId;
          try {
            _bridge!.registerResource(
              'studio://knowledge/$srcId/$docId',
              (u) async => content,
              name: title,
              description: description,
              mimeType: 'text/markdown',
            );
            registered++;
          } on mh.McpError {
            // Already registered through channel 1 — that's fine,
            // channel 1 wins.
          }
        }
      }
    }

    return registered;
  }

  /// Register every seed bundle's `tools[]` onto the MCP server with
  /// the `<seed.namespace>.<tool.name>` prefix. Mirrors what
  /// `_activateBundle` does for user-installed bundles — seeds bypass
  /// the activation path (built-in apps mount a Flutter shell instead
  /// of going through the manifest UI renderer) so without this their
  /// tools never reach the wire. External LLMs can then call
  /// `app_builder.newAppProject` etc. without going through the chat
  /// agent layer.
  Future<int> _fanOutSeedTools(mk.KernelServerHost boot) async {
    var registered = 0;
    for (final seed in seedBundles()) {
      mk.McpBundle? bundle;
      try {
        bundle = await mk.McpBundleLoader.loadDirectory(seed.mbdPath);
      } catch (_) {
        continue;
      }
      final tools = bundle.tools?.tools;
      if (tools == null || tools.isEmpty) continue;
      final ctx = HostBundleActivationContext(
        boot: boot,
        tabKey: '',
        bundle: bundle,
        exposedShortId: seed.namespace,
        chromeBridge: _chromeBridge,
        backbone: _backboneCached,
        sessionBridge: _bridge,
      );
      for (final tool in tools) {
        try {
          final result = await ctx.registerTool(tool);
          if (result.ok) {
            registered++;
          } else {
            stderr.writeln(
              'seed "${seed.namespace}" tool "${tool.name}" failed: ${result.error}',
            );
          }
        } catch (e) {
          stderr.writeln(
            'seed "${seed.namespace}" tool "${tool.name}" threw: $e',
          );
        }
      }
    }
    if (registered > 0) {
      stderr.writeln('vibe_studio: $registered seed tool(s) registered');
    }
    return registered;
  }

  /// Register the four canonical authoring workflow prompts so
  /// external LLMs discover them via `prompts/list` + `prompts/get`.
  /// Each prompt body is short — a numbered checklist the LLM follows
  /// by calling the named `studio.*` tools in order.
  void _registerSeedPrompts(mk.KernelServerHost boot) {
    (boot as mh.ServerBootstrap).server.addPrompt(
      name: 'new-package',
      description:
          'Bootstrap a new authoring bundle under the studio workspace.',
      arguments: <mh.PromptArgument>[
        mh.PromptArgument(
          name: 'name',
          description: 'Human-readable package name (e.g. "Counter").',
          required: true,
        ),
        mh.PromptArgument(
          name: 'id',
          description: 'Bundle id like `com.example.<slug>` (optional).',
          required: false,
        ),
      ],
      handler: (args) async {
        final name = (args['name'] ?? '').toString();
        final id = (args['id'] ?? '').toString();
        final body = '''
1. Call `studio.builder.newProject` with `name="$name"`${id.isEmpty ? '' : ' and `id="$id"`'}.
   The studio scaffolds an application bundle with a single home page
   (`ui/app.json` envelope + `ui/pages/home.json` body).
2. Inspect the new bundle: `studio.bundle.list` then
   `studio.builder.ui.read` to view the scaffolded page tree.
3. Drive the body via `studio.builder.writeUI` / `addTool` / `addKnowledgeDoc` —
   query `studio.knowledge.query` for DSL spec before mutating.
''';
        return mh.GetPromptResult(
          description: 'Bootstrap a new authoring bundle named "$name".',
          messages: <mh.Message>[
            mh.Message(role: 'user', content: mh.TextContent(text: body)),
          ],
        );
      },
    );
    (boot as mh.ServerBootstrap).server.addPrompt(
      name: 'add-page-widget',
      description:
          'Add a widget to a page in an active bundle\'s mcp_ui_dsl tree.',
      arguments: <mh.PromptArgument>[
        mh.PromptArgument(
          name: 'pageId',
          description: 'Page id (e.g. `home`).',
          required: true,
        ),
        mh.PromptArgument(
          name: 'widget',
          description:
              'Widget type to insert (e.g. `text`, `button`, `VbuTitleBar`).',
          required: true,
        ),
      ],
      handler: (args) async {
        final pageId = (args['pageId'] ?? '').toString();
        final widget = (args['widget'] ?? '').toString();
        final body = '''
1. Query `studio.builder.ui.catalog.list` (or `.schema` for a specific
   widget) to confirm the canonical name + required props of `$widget`.
2. Read the current page tree: `studio.builder.ui.read` with
   `pageId="$pageId"`.
3. Apply an atomic insert: `studio.builder.ui.applyPatch` with an `add`
   op pointing at the parent container's `/children` path.
4. Verify: `studio.builder.ui.read` again, then call
   `studio.chrome.reload_tab` so the change surfaces in the preview.
''';
        return mh.GetPromptResult(
          description: 'Add a `$widget` to page `$pageId`.',
          messages: <mh.Message>[
            mh.Message(role: 'user', content: mh.TextContent(text: body)),
          ],
        );
      },
    );
    (boot as mh.ServerBootstrap).server.addPrompt(
      name: 'wire-button-tool',
      description:
          'Wire a button\'s click action to invoke an MCP tool in an active bundle.',
      arguments: <mh.PromptArgument>[
        mh.PromptArgument(
          name: 'buttonLabel',
          description: 'Existing button\'s label (matches `label` prop).',
          required: true,
        ),
        mh.PromptArgument(
          name: 'tool',
          description:
              'Full tool name to invoke (e.g. `<bundleShortId>.increment`).',
          required: true,
        ),
      ],
      handler: (args) async {
        final label = (args['buttonLabel'] ?? '').toString();
        final tool = (args['tool'] ?? '').toString();
        final body = '''
1. Locate the button node: `studio.builder.ui.read` then
   `studio.builder.ui.findNodes` filtering by `type="button"` and
   `label="$label"`.
2. Apply patch on its `/click` path:
   `{type:"tool", tool:"$tool", params:{...}}`. Use `click` (canonical) —
   NOT `action`; the runtime ignores `action`.
3. If `$tool` returns state-bound keys, name them to match the page's
   state keys so spec §3.10 auto-merge picks them up.
4. Reload tab + click the button in the preview to confirm.
''';
        return mh.GetPromptResult(
          description: 'Wire button "$label" to call `$tool`.',
          messages: <mh.Message>[
            mh.Message(role: 'user', content: mh.TextContent(text: body)),
          ],
        );
      },
    );
    (boot as mh.ServerBootstrap).server.addPrompt(
      name: 'install-bundle',
      description:
          'Install an external bundle from a local `.mcpb` or `.mbd` path.',
      arguments: <mh.PromptArgument>[
        mh.PromptArgument(
          name: 'sourcePath',
          description: 'Absolute path to the `.mcpb` archive or `.mbd` dir.',
          required: true,
        ),
      ],
      handler: (args) async {
        final sourcePath = (args['sourcePath'] ?? '').toString();
        final body = '''
1. Call `studio.bundle.install` with `sourcePath="$sourcePath"`. The
   studio copies the bundle into its install cache, indexes the
   knowledge, and exposes its tools under the bundle's shortId.
2. Verify: `studio.bundle.list` shows the new entry.
3. Activate (if not auto-activated): `studio.bundle.activate` with the
   returned `mbdPath`. The bundle's tools become callable as
   `<shortId>.<toolName>` and its agents register into the chat surface.
''';
        return mh.GetPromptResult(
          description: 'Install bundle at `$sourcePath`.',
          messages: <mh.Message>[
            mh.Message(role: 'user', content: mh.TextContent(text: body)),
          ],
        );
      },
    );
  }

  CaptureSurface? _captureSurface;
  CaptureSurface? get captureSurface => _captureSurface;

  @override
  Future<void> startTransport({
    required Object server,
    required String transport,
    required int port,
  }) async {
    final boot = server as mk.KernelServerHost;
    final transportType =
        transport == 'sse'
            ? mk.KernelTransportKind.sse
            : mk.KernelTransportKind.streamableHttp;
    await boot.start(transportType, host: '127.0.0.1', port: port);
    // Cherry 2026-05-27 cascade 4 — once the host endpoint's transport
    // is up, `app.hostMcpServerSpec` returns the canonical streamable
    // HTTP / SSE URL. Hand it to `ClaudeCodeInteractiveProvider.forKernel(app)` so
    // the subscription path's `--mcp-config` flag points at vibe_studio
    // itself; manager / worker agents now see `bk.*` / `studio.*` /
    // `<bundleId>.*` as native MCP tools instead of the legacy text
    // catalog. No-op when the catalog has no claude_code entry.
    _backboneCached?.upgradeClaudeCodeForKernel();
    // Register the system server with the pool. Domains that
    // attach with `inheritFromSystem = true` (or with the same
    // URL) resolve here via URL lookup. The spawn callback is
    // invoked when a domain references a URL not yet in the pool
    // (Phase 5 — domain-spawned instances are empty servers for
    // now; per-domain tool / knowledge registration lands in 5b/5c).
    // Canonical MCP Streamable HTTP endpoint path. The mcp_server
    // transport listens at `/mcp`; pool keys and external clients
    // must use the full URL including this path so they can reach
    // the JSON-RPC endpoint. Domain override URLs follow the same
    // convention — DomainServerManager normalizes missing paths.
    final systemUrl = '$transport://127.0.0.1:$port/mcp';
    stderr.writeln(
      '$toolId: DomainServerManager.bootWithSystem url=$systemUrl',
    );
    // Lifecycle slot dispatcher — chrome (shell ProjectHeader / future
    // statusbar buttons) calls this when the user presses Save / Undo
    // / Redo / Revert / etc. Built-in apps wire their handlers via
    // BuiltInAppContext.lifecycleBindingsProvider; manifest-driven
    // domains will route through their wiring.lifecycle entries in a
    // follow-up. Returns whether a handler ran so chrome can
    // optionally surface a "no binding" hint.
    // Chrome bridge resolvers — workspace base calls these inside
    // its own `_syncHeaderActions` / `_syncSlashHints`, so built-in
    // apps go through the same code path manifest-driven domains do.
    // Returning non-null wins; null falls back to the manifest reader.
    _chromeBridge.headerActionsResolver = (mbdPath, liveState) {
      final ctx = BuiltInAppRegistry.instance.activeContext;
      if (ctx == null || ctx.bundlePath != mbdPath) return null;
      return ctx.headerActionsProvider?.call();
    };
    _chromeBridge.chatSlashHintsResolver = (mbdPath) {
      final ctx = BuiltInAppRegistry.instance.activeContext;
      if (ctx == null || ctx.bundlePath != mbdPath) return null;
      final specs = ctx.slashCommandsProvider?.call();
      if (specs == null) return null;
      return <ChatSlashHint>[
        for (final s in specs)
          ChatSlashHint(
            s.command,
            s.template,
            s.description,
            s.tool,
            s.toolArgs.isEmpty ? null : s.toolArgs,
          ),
      ];
    };
    _chromeBridge.lifecycleStateResolver = (mbdPath) {
      final ctx = BuiltInAppRegistry.instance.activeContext;
      if (ctx == null || ctx.bundlePath != mbdPath) return null;
      return ctx.lifecycleStateProvider?.call();
    };

    _chromeBridge.recordRecentProject = (String path) async {
      await VibeSettings.recordRecent(toolId: toolId, path: path);
    };

    // Built-in app default chat agent — the workspace's
    // Effective-LLM resolver — chat panel reads this to surface the
    // adapter the kernel actually routes through (fallback-aware).
    _chromeBridge.effectiveModelIdResolver = _effectiveModelIdFor;
    // Chat agent switch — the chat chip calls this to open a conversation
    // with the picked roster agent (or back to the manager).
    _chromeBridge.switchChatAgent = _switchChatAgent;

    // Chat agent = the `role: manager` entry in the seed manifest. Same
    // convention everywhere (host / built-in / user bundles). Built-in
    // matches by `canHandle`; the Home tab and any unmatched path fall
    // back to the host seed (the first seed entry registered — by
    // convention `studio.mbd`).
    _chromeBridge.defaultChatAgentResolver = (String bundlePath) {
      final app = BuiltInAppRegistry.instance.matchFor(bundlePath);
      if (app != null) {
        for (final entry in seedBundles()) {
          if (entry.namespace != app.id) continue;
          return readSeedChatManager(
            manifestPath: p.join(entry.mbdPath, 'manifest.json'),
            exposedShortId: entry.namespace,
          );
        }
      }
      // Home / unknown — host seed = `seedBundles().first` by ordering
      // convention (`_findPackageSeed('standard', 'studio.mbd')`).
      // Empty `exposedShortId` keeps the host manager's raw id (no
      // namespace prefix) — host == studio, no need to label it.
      final seeds = seedBundles();
      if (seeds.isEmpty) return null;
      final hostSeed = seeds.first;
      return readSeedChatManager(
        manifestPath: p.join(hostSeed.mbdPath, 'manifest.json'),
        exposedShortId: '',
      );
    };

    // Generic host-tool dispatch — debug surfaces (Debug-mode sub-tabs
    // in app_builder, inspector polling, external diagnostics) call
    // this to poll any `studio.*` / `vibe_*` instrumentation without
    // owning a separate kernel reference. Decodes the response JSON
    // (matching the contract `studio.debug.dispatch_tool` already
    // returns) so callers see a plain Map.
    _chromeBridge.callHostTool = (
      String tool,
      Map<String, dynamic> params,
    ) async {
      try {
        final result = await boot.callTool(tool, params);
        if (result.content.isNotEmpty &&
            result.content.first is mk.KernelTextContent) {
          final text = (result.content.first as mk.KernelTextContent).text;
          try {
            final decoded = jsonDecode(text);
            if (decoded is Map<String, dynamic>) return decoded;
            return <String, dynamic>{'value': decoded};
          } catch (_) {
            return <String, dynamic>{'text': text};
          }
        }
        return <String, dynamic>{'ok': true};
      } catch (e) {
        return <String, dynamic>{'ok': false, 'error': e.toString()};
      }
    };

    _chromeBridge.dispatchLifecycleSlot = (
      String slot, [
      Map<String, dynamic>? args,
    ]) async {
      final effectiveArgs = args ?? const <String, dynamic>{};
      // Active domain picks the path — built-in or manifest, never
      // both. A built-in that doesn't register [slot] stays no-op;
      // we do NOT fall back to a manifest read against the same path
      // because that would invoke a different domain's handler.
      // Active domain picks the path — built-in or manifest, never
      // both. A built-in that doesn't register [slot] stays no-op;
      // we do NOT fall back to a manifest read against the same path
      // because that would invoke a different domain's handler.
      final ctx = BuiltInAppRegistry.instance.activeContext;
      if (ctx != null) {
        final bindings = ctx.lifecycleBindingsProvider?.call();
        final handler = bindings?[slot];
        stderr.writeln(
          'lifecycle.$slot built-in ctx=set bindings=${bindings != null} '
          'handler=${handler != null}',
        );
        if (handler == null) return false;
        // Hand the lifecycle handler a context BELOW the MaterialApp so
        // `promptForNewProject` / `showDialog` / file pickers resolve
        // MaterialLocalizations + Navigator + Overlay. `rootElement` sits
        // ABOVE the MaterialApp — passing it made every dialog-showing
        // handler throw "No MaterialLocalizations found", which silently
        // killed the chrome toolbar "+" New-project / Open buttons (they
        // dispatch through this slot, unlike the welcome panel which calls
        // the handler with its own in-tree context). `captureRootKey` is the
        // shell root key the host already uses for its own dialogs.
        final BuildContext rootCtx =
            _chromeBridge.captureRootKey?.currentContext ??
            WidgetsBinding.instance.rootElement!;
        try {
          await handler(rootCtx);
        } catch (e, st) {
          stderr.writeln('lifecycle.$slot handler threw: $e\n$st');
        }
        return true;
      } else {
        stderr.writeln('lifecycle.$slot built-in ctx=null');
      }
      // Manifest-driven bundle. Resolve `wiring.lifecycle[slot]` for
      // the currently focused package path.
      final activePath = _activePackageNotifier.value;
      if (activePath == null) return false;
      final result = await dispatchLifecycleSlot(
        mbdPath: activePath,
        slot: slot,
        args: effectiveArgs,
        callTool: boot.callTool,
      );
      return result['ok'] == true;
    };

    _chromeBridge.domainServerManager = DomainServerManager.bootWithSystem(
      boot: boot,
      url: systemUrl,
      spawn: (String url) async {
        final parsed = Uri.parse(url);
        // Round C (kernel-app F) — spawn through `KernelApp.addEndpoint`
        // so the spawned boot lives in the shared endpoint pool
        // (`backbone.app.endpoints`) alongside the host's 'studio'
        // endpoint. `addEndpoint(label)` is idempotent on the same
        // label (FR-EP-008), so reconnects to the same narrow URL
        // return the existing endpoint instead of double-binding.
        // The mirror + register + start sequence stays on the host
        // side per PORTING_GUIDE §6.2.5 — kernel doesn't ship a
        // cross-endpoint reflect helper.
        final ep = _backboneCached!.app.addEndpoint(
          label: 'narrow:${parsed.host}_${parsed.port}',
          appName: '$toolId.${parsed.host}_${parsed.port}',
        );
        final spawnedBoot = ep.server..register();
        // Mirror host (studio.* + app_builder.*) tools onto the
        // spawned boot. Per MOD-INFRA-010 §10.1, a domain-spawned
        // narrow link must surface the same host base as the system
        // server so external clients can drive workflows the same
        // way regardless of which URL they connect to. Each wrapper
        // dispatches into the system boot's actual handler — the
        // spawned boot only forwards.
        _mirrorHostToolsOnto(spawnedBoot, source: boot);
        // Mirror host knowledge resources (studio_host_* docs +
        // any host-published resource that isn't tied to a specific
        // domain). Attached domains add their own knowledge via the
        // existing fan-out path (HostBundleActivationContext).
        _mirrorHostResourcesOnto(spawnedBoot, source: boot);
        final spawnedTransport =
            parsed.scheme == 'sse'
                ? mk.KernelTransportKind.sse
                : mk.KernelTransportKind.streamableHttp;
        await spawnedBoot.start(
          spawnedTransport,
          host: parsed.host.isEmpty ? '127.0.0.1' : parsed.host,
          port: parsed.port,
        );
        return spawnedBoot;
      },
    );
    // Eager attach for every built-in to the DomainServerManager so
    // their `inheritFromSystem` / `mcpServerUrl` overrides take effect
    // without requiring user interaction. Without this hook, built-in
    // tabs bypass `_activateBundle` (their bodies are Flutter widgets,
    // not manifest UI) and `mgr.attach` never fires — narrow-link
    // overrides become a no-op (gap G-1 in MOD-INFRA-010 §10.7).
    //
    // Fires after the manager is constructed AND after the host's
    // knowledge fan-out has settled so the spawn factory's
    // `_mirrorHostResourcesOnto` step sees the registered
    // `studio://knowledge/studio_host_*` URIs (otherwise mirror lands
    // on an empty resource map — see "mirrored 0 host resources" race
    // bug 2026-05-20). For inherit=true (default) each call resolves
    // synchronously to the system instance; only inherit=false + new
    // URL pays the spawn cost. Built-in tool registration on a freshly
    // spawned boot is re-run here so e.g. App Builder's `vibe_*`
    // surface lands on the spawned URL too.
    // `startTransport` doesn't receive backbone (framework signature
    // is fixed), so resolve through the cache populated by
    // `registerMcpTools` — which always runs before `startTransport`
    // on the StudioBoot path.
    final backbone = _backboneCached;
    if (backbone == null) {
      stderr.writeln(
        'vibe_studio: _initBuiltInAttachAfterKnowledgeReady skipped — '
        'backbone not yet cached',
      );
      return;
    }
    // ignore: unawaited_futures
    _initBuiltInAttachAfterKnowledgeReady(boot, backbone);
  }

  /// Sequence the knowledge fan-out → built-in attach order. The
  /// knowledge fan-out is fire-and-forget from `registerMcpTools`;
  /// without an explicit await here the attach (which mirrors host
  /// resources onto spawned boots) races ahead and copies an empty
  /// resource map.
  Future<void> _initBuiltInAttachAfterKnowledgeReady(
    mk.KernelServerHost systemBoot,
    StudioBackbone backbone,
  ) async {
    // Best-effort wait for seed knowledge fan-out. The Future returned
    // by `_fanOutSeedKnowledgeAsResources` was kicked off earlier
    // (line ~660); awaiting it here is safe because Future.value chain
    // resolves in order. If it has already completed, this is a no-op.
    try {
      await _seedKnowledgeReady;
    } catch (e) {
      stderr.writeln(
        'vibe_studio: seed knowledge fan-out failed — built-in '
        'attach proceeds without host resource mirror: $e',
      );
    }
    await _attachBuiltInsToDomainServers(systemBoot, backbone);
    // Now that initial attach is done, start watching the
    // package_settings dir so UI autosave / external edits trigger
    // runtime re-attach without restart.
    _watchDomainOverrides();
  }

  /// Future that completes once `_fanOutSeedKnowledgeAsResources` has
  /// landed every seed bundle's knowledge as MCP resources. Set in
  /// `registerMcpTools` so downstream init steps (built-in attach +
  /// spawn mirror) can sequence after it.
  Future<int>? _seedKnowledgeReady;

  /// Drive built-in apps through `DomainServerManager.attach` based
  /// on their per-package overrides. Required because built-in tabs
  /// use a workspace marker path (no manifest at that path) so the
  /// usual `_activateBundle → mgr.attach` flow never fires. Called
  /// once after the manager is constructed at host boot.
  Future<void> _attachBuiltInsToDomainServers(
    mk.KernelServerHost systemBoot,
    StudioBackbone backbone,
  ) async {
    final mgr = _chromeBridge.domainServerManager;
    if (mgr == null) return;
    final configRoot = _backboneCached?.configRoot;
    if (configRoot == null || configRoot.isEmpty) {
      stderr.writeln(
        'vibe_studio: _attachBuiltInsToDomainServers skipped — '
        'configRoot not ready (built-in attach happens on next boot)',
      );
      return;
    }
    for (final app in BuiltInAppRegistry.instance.apps) {
      final builtInPath = p.join(configRoot, 'workspaces', app.id);
      final overrides = _readBuiltInOverrides(configRoot, builtInPath);
      final inherit = overrides['inheritFromSystem'] != false;
      final url = overrides['mcpServerUrl'] as String?;
      try {
        final outcome = await mgr.attach(
          builtInPath,
          inheritFromSystem: inherit,
          url: url,
        );
        if (!outcome.ok) {
          stderr.writeln(
            'vibe_studio: built-in "${app.id}" attach failed → '
            '${outcome.url}: ${outcome.error}',
          );
          continue;
        }
        final inst = mgr.findByUrl(outcome.url);
        if (inst == null) continue;
        // Spawned URL ≠ system → also register this built-in's tools
        // AND its knowledge on the spawned boot so the narrow link
        // surface holds (host base + this domain's verbs + this
        // domain's docs). Without the knowledge fan-out the narrow
        // link would expose tools but not the spec / pitfall docs
        // those tools reference — half a surface.
        if (inst.kind == ServerKind.domainSpawned &&
            !identical(inst.boot, systemBoot)) {
          try {
            await app.registerHostTools(
              BuiltinToolRegistry(inst.boot),
              _chromeBridge,
              backbone: backbone,
            );
            stderr.writeln(
              'vibe_studio: built-in "${app.id}" tools registered on '
              '${outcome.url} (spawned)',
            );
          } catch (e) {
            stderr.writeln(
              'vibe_studio: built-in "${app.id}" registerHostTools on '
              'spawned ${outcome.url} failed: $e',
            );
          }
          // Fan out this built-in's own knowledge sources (per the
          // seed mbd's `manifest.knowledge.sources[]`) as resources
          // on the spawned boot. Mirrors the system boot's
          // `_fanOutSeedKnowledgeAsResources` path but scoped to the
          // single domain so narrow link doesn't leak other domains'
          // docs. Already on system via the system-wide fan-out.
          // ignore: unawaited_futures
          _fanOutBuiltInKnowledgeOnSpawned(app, inst.boot);
        }
        stderr.writeln(
          'vibe_studio: built-in "${app.id}" attached → '
          '${outcome.url} (${inst.kind.name})',
        );
      } catch (e) {
        stderr.writeln('vibe_studio: built-in "${app.id}" attach threw: $e');
      }
    }
  }

  /// Register the built-in's own `manifest.knowledge.sources[]` as
  /// MCP resources on the spawned boot. Scoped — only this built-in's
  /// docs land here, so the narrow link doesn't leak other domains'
  /// docs (per MOD-INFRA-010 §10.5 narrow-link semantics: host base +
  /// single domain). Idempotent — duplicate `addResource` throws
  /// `mh.McpError` which is swallowed.
  Future<void> _fanOutBuiltInKnowledgeOnSpawned(
    BuiltInApp app,
    mk.KernelServerHost target,
  ) async {
    final seedPath = _findPackageSeed('standard', '${app.id}.mbd');
    if (seedPath == null) {
      stderr.writeln(
        'vibe_studio: knowledge fan-out skipped for "${app.id}" — '
        'seed mbd not found',
      );
      return;
    }
    mk.McpBundle bundle;
    try {
      bundle = await mk.McpBundleLoader.loadDirectory(seedPath);
    } catch (e) {
      stderr.writeln(
        'vibe_studio: knowledge fan-out for "${app.id}" — load failed: $e',
      );
      return;
    }
    var registered = 0;
    for (final src in bundle.knowledge?.sources ?? const []) {
      for (final doc in src.documents ?? const <mk.KnowledgeDocument>[]) {
        final docId = doc.id;
        if (docId == null || docId.isEmpty) continue;
        final uri = 'studio://knowledge/${src.id}/$docId';
        final content = doc.content;
        final title = doc.title ?? docId;
        final description = src.description ?? src.name;
        try {
          target.addResource(
            uri: uri,
            name: title,
            description: description,
            mimeType: 'text/markdown',
            handler:
                (uri, _) async => mk.KernelReadResourceResult(
                  contents: <mk.KernelResourceContent>[
                    mk.KernelResourceContent(
                      uri: uri,
                      mimeType: 'text/markdown',
                      text: content,
                    ),
                  ],
                ),
          );
          registered++;
        } on mh.McpError {
          // URI already registered on this boot — fine. Happens when
          // attach fires more than once for the same built-in.
        }
      }
    }
    stderr.writeln(
      'vibe_studio: built-in "${app.id}" knowledge fanned out on '
      '${target.name} ($registered resources)',
    );
  }

  /// Watch `<configRoot>/package_settings/*.json` for changes and
  /// fire `DomainServerManager.detach + attach` on the affected
  /// built-in. Without this hook, UI autosave (`ManifestFieldList`
  /// onSave path) writes the new inherit/url to disk but the runtime
  /// stays attached to the previous URL — narrow-link UX is silently
  /// broken (user toggles inherit off + types new URL · file changes ·
  /// nothing happens until restart). studio.settings.set has its own
  /// re-attach trigger; this watcher covers the UI path + any other
  /// file-write source (manual disk write, future migration tool,
  /// etc.) so behaviour is source-agnostic.
  StreamSubscription<FileSystemEvent>? _overrideWatcher;
  void _watchDomainOverrides() {
    final root = _backboneCached?.configRoot;
    if (root == null || root.isEmpty) return;
    final dir = Directory(p.join(root, 'package_settings'));
    if (!dir.existsSync()) {
      // Pre-create so watch attaches even on a fresh workspace.
      try {
        dir.createSync(recursive: true);
      } catch (_) {
        /* ignore — watch will silently no-op */
      }
    }
    _overrideWatcher?.cancel();
    _overrideWatcher = dir
        .watch(events: FileSystemEvent.modify | FileSystemEvent.create)
        .listen(
          (event) {
            _onOverrideFileChanged(event.path);
          },
          onError: (e) {
            stderr.writeln('vibe_studio: override watcher error: $e');
          },
        );
    stderr.writeln('vibe_studio: watching domain overrides at ${dir.path}');
  }

  /// Re-attach the built-in whose override file changed. Resolves
  /// the built-in's workspace marker path from the file name (reverse
  /// of the safe-character mangle isn't lossless, so the lookup
  /// walks BuiltInAppRegistry comparing each app's expected file
  /// path against the changed one).
  void _onOverrideFileChanged(String changedPath) {
    final root = _backboneCached?.configRoot;
    if (root == null || root.isEmpty) return;
    final mgr = _chromeBridge.domainServerManager;
    if (mgr == null) return;
    // Find which built-in this override belongs to.
    for (final app in BuiltInAppRegistry.instance.apps) {
      final builtInPath = p.join(root, 'workspaces', app.id);
      final safe = builtInPath.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
      final expected = p.join(root, 'package_settings', '$safe.json');
      if (expected != changedPath) continue;
      // Read the new overrides + re-attach.
      final overrides = _readBuiltInOverrides(root, builtInPath);
      final inherit = overrides['inheritFromSystem'] != false;
      final url = overrides['mcpServerUrl'] as String?;
      // Run on next microtask so the file write has fully landed
      // (some editors do write-rename, watcher fires mid-rename).
      // ignore: unawaited_futures
      Future<void>.microtask(() async {
        try {
          mgr.detach(builtInPath);
          final outcome = await mgr.attach(
            builtInPath,
            inheritFromSystem: inherit,
            url: url,
          );
          if (!outcome.ok) {
            stderr.writeln(
              'vibe_studio: built-in "${app.id}" re-attach failed → '
              '${outcome.url}: ${outcome.error}',
            );
            return;
          }
          final inst = mgr.findByUrl(outcome.url);
          if (inst != null &&
              inst.kind == ServerKind.domainSpawned &&
              !identical(inst.boot, _mcpBoot)) {
            try {
              await app.registerHostTools(
                BuiltinToolRegistry(inst.boot),
                _chromeBridge,
                backbone: _backboneCached,
              );
              // ignore: unawaited_futures
              _fanOutBuiltInKnowledgeOnSpawned(app, inst.boot);
            } catch (e) {
              stderr.writeln(
                'vibe_studio: built-in "${app.id}" registerHostTools '
                'after override change failed: $e',
              );
            }
          }
          stderr.writeln(
            'vibe_studio: built-in "${app.id}" re-attached after '
            'override change → ${outcome.url} (${inst?.kind.name})',
          );
          // If the override change touched the currently active tab,
          // sync the titlebar pill — narrow link spawn / collapse only
          // affects the pool, not the activePath, so this is the one
          // place the chrome learns about the URL change.
          _refreshActiveMcpUrl();
        } catch (e) {
          stderr.writeln(
            'vibe_studio: built-in "${app.id}" re-attach threw: $e',
          );
        }
      });
      break;
    }
  }

  /// Read built-in's per-package overrides (inheritFromSystem +
  /// mcpServerUrl). Mirrors `_readDomainOverrides` in studio_workspace
  /// but accepts the configRoot explicitly so it can run before the
  /// workspace widget tree builds.
  Map<String, dynamic> _readBuiltInOverrides(
    String configRoot,
    String builtInPath,
  ) {
    try {
      final safe = builtInPath.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
      final file = File(p.join(configRoot, 'package_settings', '$safe.json'));
      if (!file.existsSync()) return const <String, dynamic>{};
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is Map<String, dynamic>) return raw;
      return const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  /// Copy host-base `studio.*` tools from [source] (system boot) onto
  /// [target] (newly-spawned domain boot) as thin wrappers that
  /// delegate back into the source's handler. Per MOD-INFRA-010 §10.1
  /// a narrow per-domain link exposes (host base) + (single active
  /// domain). Domain-specific surfaces (`vibe_*` from App Builder,
  /// `app_builder.*` aliases, future `scene_*`, etc.) are
  /// intentionally NOT mirrored — they only land on the spawned boot
  /// if/when that domain attaches here. Without this filter, every
  /// narrow link would re-expose every domain's tools the system
  /// boot carries, defeating the noise-reduction purpose.
  void _mirrorHostToolsOnto(
    mk.KernelServerHost target, {
    required mk.KernelServerHost source,
  }) {
    var mirrored = 0;
    var skipped = 0;
    for (final tool in (source as mh.ServerBootstrap).server.getTools()) {
      // Only host base — `studio.*` family. Anything else is a
      // domain surface and follows the attach lifecycle, not the
      // host mirror.
      if (!tool.name.startsWith('studio.')) {
        skipped++;
        continue;
      }
      try {
        target.addTool(
          name: tool.name,
          description: tool.description,
          inputSchema: tool.inputSchema,
          handler: (args) => source.callTool(tool.name, args),
        );
        mirrored++;
      } catch (e) {
        stderr.writeln(
          'vibe_studio: mirror tool `${tool.name}` onto ${target.name} '
          'failed: $e',
        );
      }
    }
    stderr.writeln(
      'vibe_studio: mirrored $mirrored studio.* host tools onto spawned '
      'boot (skipped $skipped non-host tools — attach-time only)',
    );
  }

  /// Copy host knowledge resources (`studio://knowledge/<host_src>/<doc>`)
  /// from [source] onto [target]. Domain-attached knowledge is added
  /// later via the existing fan-out path; here only host-base docs
  /// (the seed `studio.mbd` content) are mirrored.
  void _mirrorHostResourcesOnto(
    mk.KernelServerHost target, {
    required mk.KernelServerHost source,
  }) {
    var mirrored = 0;
    for (final res in (source as mh.ServerBootstrap).server.getResources()) {
      // Only host-level docs — domains add their own at attach time.
      // The studio seed prefixes its sources with `studio_host_`.
      if (!res.uri.startsWith('studio://knowledge/studio_host_')) continue;
      try {
        target.addResource(
          uri: res.uri,
          name: res.name,
          description: res.description,
          mimeType: res.mimeType,
          handler: (uri, params) async {
            // Delegate to source's handler by re-reading. The kernel
            // does not expose a direct `callResource(uri)` so we use
            // the protocol-level read on the underlying mcp.Server and
            // re-wrap the wire shape into the envelope return type.
            final raw = await (source as mh.ServerBootstrap).server
                .readResource(uri);
            return mk.KernelReadResourceResult(
              contents: <mk.KernelResourceContent>[
                for (final c in raw.contents)
                  mk.KernelResourceContent(
                    uri: c.uri,
                    mimeType: c.mimeType,
                    text: c.text,
                    blob: c.blob,
                  ),
              ],
            );
          },
        );
        mirrored++;
      } catch (e) {
        stderr.writeln(
          'vibe_studio: mirror resource `${res.uri}` onto '
          '${target.name} failed: $e',
        );
      }
    }
    stderr.writeln(
      'vibe_studio: mirrored $mirrored host resources onto spawned boot',
    );
  }

  // ── LLM + chat ─────────────────────────────────────────────────

  @override
  Object buildLlmAdapter({
    required StudioBackbone backbone,
    required VibeSettings settings,
    required Object server,
  }) {
    // Universal host has no domain LLM logic. The placeholder adapter
    // returns a system note; real send paths land once a bundle
    // activates and binds its own adapter through the workspace.
    return const NoopLlm();
  }

  @override
  Future<VibeChatController> buildChatController({
    required StudioBackbone backbone,
    required VibeSettings settings,
    required Object llm,
    required Object server,
  }) async {
    _backboneCached = backbone;
    final home = _chatFor('home');
    _activeChat = ValueNotifier<VibeChatController>(home);
    return home;
  }

  /// Read the agents block (manifest spec — `agents.agents[]` or flat
  /// `agents[]`) from [manifestPath] and project into
  /// [VibeChatAgentEntry]s. Empty when the file is missing / unreadable
  /// or carries no agents.
  List<VibeChatAgentEntry> _readAgentsFromManifest(
    String manifestPath,
    String exposedShortId,
  ) {
    try {
      final file = File(manifestPath);
      if (!file.existsSync()) return const <VibeChatAgentEntry>[];
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) {
        return const <VibeChatAgentEntry>[];
      }
      final agentsRaw = raw['agents'];
      List? agents;
      if (agentsRaw is Map<String, dynamic>) {
        agents = agentsRaw['agents'] as List?;
      } else if (agentsRaw is List) {
        agents = agentsRaw;
      }
      if (agents == null) return const <VibeChatAgentEntry>[];
      final out = <VibeChatAgentEntry>[];
      for (final a in agents) {
        if (a is! Map<String, dynamic>) continue;
        final rawId = a['id'] as String?;
        if (rawId == null || rawId.isEmpty) continue;
        final id =
            rawId.contains('.') || exposedShortId.isEmpty
                ? rawId
                : '$exposedShortId.$rawId';
        final name =
            (a['name'] as String?) ?? (a['displayName'] as String?) ?? id;
        String? modelId;
        final modelEntry = a['model'];
        if (modelEntry is Map<String, dynamic>) {
          modelId = modelEntry['model'] as String?;
        }
        modelId ??= a['modelId'] as String?;
        out.add(
          VibeChatAgentEntry(id: id, displayName: name, modelId: modelId),
        );
      }
      return out;
    } catch (_) {
      return const <VibeChatAgentEntry>[];
    }
  }

  /// Resolve the agent roster for a chat tab key. Mirrors the chat
  /// dispatch's namespace rules — Home reads the host seed (no prefix),
  /// built-in / manifest tabs read their own manifest with the
  /// namespace prefix applied.
  List<VibeChatAgentEntry> _agentRosterForKey(String key) {
    if (key == 'home') {
      final seeds = seedBundles();
      if (seeds.isEmpty) return const <VibeChatAgentEntry>[];
      final host = seeds.first;
      return _readAgentsFromManifest(p.join(host.mbdPath, 'manifest.json'), '');
    }
    final builtin = BuiltInAppRegistry.instance.matchFor(key);
    if (builtin != null) {
      for (final entry in seedBundles()) {
        if (entry.namespace != builtin.id) continue;
        return _readAgentsFromManifest(
          p.join(entry.mbdPath, 'manifest.json'),
          entry.namespace,
        );
      }
      return const <VibeChatAgentEntry>[];
    }
    // Manifest-driven user bundle — `<key>/manifest.json`.
    return _readAgentsFromManifest(
      p.join(key, 'manifest.json'),
      p.basenameWithoutExtension(key),
    );
  }

  /// Dispatch the LLM-issued tool call through the host MCP server's
  /// kernel-tool registry — the same path external MCP clients use, so
  /// the chat manager and an outside LLM hit identical implementations.
  /// Returns a plain-text serialisation of the result (or the error
  /// reason) the standardManagerSend loop can feed back into the next
  /// `ask` as a tool-result message.
  Future<String> _dispatchToolForChat(
    String name,
    Map<String, Object?> args,
  ) async {
    final boot = _mcpBoot;
    if (boot == null) return '[error] MCP server not booted';
    try {
      final result = await boot.callTool(name, Map<String, dynamic>.from(args));
      final buf = StringBuffer();
      if (result.isError == true) buf.write('[error] ');
      for (final c in result.content) {
        if (c is mk.KernelTextContent) {
          buf.write(c.text);
        } else {
          buf.write(c.toString());
        }
      }
      return buf.toString();
    } catch (e) {
      return '[error] $e';
    }
  }

  /// Effective LLM modelId for [agentId] — mirrors FlowBrain's
  /// `_resolveLlmFor` (`_llmProviders[model.provider]` → adapter, else
  /// `_defaultLlm = values.first`). Returns the declared modelId when
  /// the agent's provider has a wired adapter, otherwise the first
  /// adapter's modelId (the fallback the kernel actually dispatches
  /// through). Null when nothing's wired yet.
  String? _effectiveModelIdFor(String agentId) {
    final profile = AgentHost.shared?.profileFor(agentId);
    if (profile == null) return null;
    final pool = _backboneCached?.app.agentLlmSessions.providers;
    if (pool == null || pool.isEmpty) return null;
    // Return the modelId of the adapter the kernel actually routes
    // through — not the declared one. The adapter under `profile.provider`
    // may be the claude_code subscription adapter registered under a
    // non-native key (e.g. 'anthropic' with no API key — see
    // `upgradeClaudeCodeForKernel`'s three-key overwrite). Surfacing its
    // real modelId lets the chat chip render the fallback arrow
    // (`Opus 4.7 → Claude Code`); returning the declared id hid it.
    final underProvider = pool[profile.provider];
    if (underProvider != null) {
      if (underProvider is mk.LlmPortAdapter) return underProvider.modelId;
      return profile.modelId;
    }
    final first = pool.values.first;
    if (first is mk.LlmPortAdapter) return first.modelId;
    return profile.modelId;
  }

  VibeChatController _chatFor(String key) {
    return _chatByKey.putIfAbsent(key, () {
      final file = _chatFilePath(key);
      // The closure resolves the agent id at send time so a bundle
      // that updates its chatAgentId post-activation (or the host
      // changing the tab's binding) takes effect on the very next
      // turn. Reads from the chromeBridge notifier the host keeps in
      // sync as the active tab changes — this matches the chat
      // panel's binding (user types in the active tab's chat).
      // Prefer the active tab's per-unit scoped manager override (App
      // Builder = per-project manager, etc.) so the conversation is
      // isolated per operational unit; fall back to the unscoped tab
      // manager. Resolved at send time so a project switch takes effect
      // on the next turn.
      String resolveAgentId() =>
          _chromeBridge.chatManagerOverride.value ??
          _chromeBridge.activeChatAgentId.value;
      // Per-tab agent roster — read once at controller-create time
      // from the active manifest (`host_agents.json` for Home, the
      // built-in seed manifest for app_builder / scene_builder / ops,
      // the bundle manifest for user packages). The roster surfaces in
      // the chat panel chip's read-only popup.
      final roster = _agentRosterForKey(key);
      final ctrl = VibeChatController(
        agents: roster,
        send: (input) {
          // User posted a chat turn → mark the active tab modified so
          // a careless close lands on the warning dialog instead of
          // silently dropping the conversation.
          try {
            _chromeBridge.markActiveTabModified?.call();
          } catch (_) {
            /* swallow — best effort */
          }
          return standardManagerSend(
            agentHost: _backboneCached?.agentHost,
            input: input,
            managerAgentId: resolveAgentId(),
            dispatchTool: _dispatchToolForChat,
            missingKeyMessage:
                key == 'home'
                    ? 'Set an LLM API key in Settings to enable chat. The '
                        'host manager handles install / query until a bundle '
                        'activates.'
                    : 'Package "$key" has no chat agent bound yet. Project '
                        'lifecycle wires this in a follow-up.',
          );
        },
        // Per-agent send — used when the chat chip selects a non-manager
        // agent from the roster. Same path as the manager send (incl. the
        // tool-call loop), just targeting the picked agent. Unlocks holding
        // a conversation with any roster member, not only the manager.
        sendForAgent: (agentId, input) {
          try {
            _chromeBridge.markActiveTabModified?.call();
          } catch (_) {
            /* swallow — best effort */
          }
          // `VibeChatController.ask` routes through this path whenever the
          // selected agent isn't the literal `'manager'` — which is always,
          // since the controller seeds `selectedAgentId` with the tab's real
          // manager id (e.g. `scene_builder.manager`). So this, not the
          // override-aware `send` closure above, is where per-unit isolation
          // must be honored. When the chat targets the tab's base manager
          // (the default selection), upgrade to the active per-unit scoped
          // manager override (per-project / per-scene manager) so the
          // conversation is isolated per operational unit. A user-picked
          // non-manager roster agent (selected via the chat chip) routes
          // as-is.
          final effective =
              (agentId == _chromeBridge.activeChatAgentId.value)
                  ? (_chromeBridge.chatManagerOverride.value ?? agentId)
                  : agentId;
          return standardManagerSend(
            agentHost: _backboneCached?.agentHost,
            input: input,
            managerAgentId: effective,
            dispatchTool: _dispatchToolForChat,
            missingKeyMessage:
                'Agent "$agentId" is not reachable — check '
                'its model / LLM key in Settings → Domain → Agents.',
          );
        },
        onTurnPersisted: (turn) => appendStudioChatTurn(file, turn),
        onClearLog: () => clearStudioChatLog(file),
      );
      // Initial selected agent = first manager-role entry in the
      // roster (or first entry if none has the role) so the chat
      // panel chip lands on the right agent at create time without
      // relying on the panel's hard-coded `'manager'` literal.
      final manager =
          roster.isEmpty
              ? null
              : roster.firstWhere(
                (a) => a.id.endsWith('.manager') || a.id == 'manager',
                orElse: () => roster.first,
              );
      if (manager != null) ctrl.selectedAgentId = manager.id;
      // Fire-and-forget rehydrate — the panel listens to the controller
      // so seed() will trigger a rebuild once turns load.
      loadStudioChat(file).then((turns) {
        if (turns.isNotEmpty) ctrl.seed(turns);
      });
      return ctrl;
    });
  }

  String _chatFilePath(String key) {
    final root = _backboneCached?.configRoot;
    if (root == null) {
      return p.join('/tmp', 'vibe_studio_chats', '$key.jsonl');
    }
    return studioChatFile(configRoot: root, key: key);
  }

  void _setActiveContext(String? pkgPath, String? projectPath) {
    final key =
        pkgPath == null
            ? 'home'
            : (projectPath == null ? pkgPath : '$pkgPath::$projectPath');
    // Remember the unit base key so a per-agent chat switch can derive its
    // conversation key relative to it (`<baseKey>::agent::<agentId>`) and
    // restore the manager conversation (`<baseKey>`) when deselected.
    _activeChatBaseKey = key;
    _activeChat.value = _chatFor(key);
    lastActivatedBundle = pkgPath;
    _activePackageNotifier.value = pkgPath;
    _activeProjectNotifier.value = projectPath;
    // Re-point the registry's active built-in to the new tab — the
    // mount widgets stay alive across tab swaps (Flutter keeps tab
    // bodies mounted) so without this update `activeContext` would
    // keep returning the most-recently-mounted built-in's hooks even
    // after the user moved to a non-built-in tab. Pass null when the
    // active tab is home or a manifest-driven domain; the registry
    // also no-ops when [pkgPath] is non-null but unknown to it.
    BuiltInAppRegistry.instance.setActivePath(pkgPath);
    // Home / manifest-only tabs leave no built-in active — clear the
    // chrome's row-2 actions and lifecycle state immediately so the
    // previous built-in's buttons (Scene Builder's record / playback
    // strip, Ops's "No project open" label, etc.) don't linger on the
    // Home tab. For the actual Home tab (`pkgPath == null`) push the
    // reserved `.home()` snapshot so projectName=='Home' is the live
    // value — no race with any inactive built-in's postFrame republish
    // (which would only clobber if it ignored its own `_isActiveTab`
    // gate, but the snapshot makes the contract explicit).
    if (pkgPath == null) {
      _chromeBridge.headerActions.value = const <HeaderAction>[];
      _chromeBridge.lifecycleState.value = const DomainLifecycleState.home();
    } else if (BuiltInAppRegistry.instance.activeApp == null) {
      _chromeBridge.headerActions.value = const <HeaderAction>[];
      _chromeBridge.lifecycleState.value = const DomainLifecycleState.empty();
    }
    // Tell the base-side dispatch wrapper which bundle is current so
    // tools called from the active tab's chat / agent dispatch get
    // their local ids prefixed with the right `<bundleId>.`. Home tab
    // and unmapped paths fall back to host master (full union view).
    final bundleId = _chromeBridge.bundleIdForTab(pkgPath);
    // Round E (kernel-app F) — sync the KernelApp's active bundle so
    // tool dispatch outside the chrome's wrappers (`app.system.agents
    // .ask`, in-process call from kernel-internal flows) sees the
    // same scope the chrome shows. PORTING_GUIDE §6.2.6 — one-way
    // chrome → kernel; kernel never reads BuiltInAppRegistry.
    _backboneCached?.app.setActiveBundle(bundleId);
    // Update the foreground singleton so any path that hasn't been
    // wrapped in a proper `runScoped` yet (legacy host call sites)
    // still sees the visible tab's bundle. Background dispatchers
    // (JS bridge / agent ask / workflow runner) override this via
    // `runScoped` regardless.
    if (bundleId == null) {
      DispatchContext.instance.setForeground(master: true);
    } else {
      // Prefer the real session opened by the bundle's activation —
      // it owns the attached-handle list. Fall back to a synthetic
      // marker session when the bundle is mapped but not yet booted
      // (race between `mapTabBundle` and `_ensureKernelActivation`).
      final sessions = SessionRegistry.instance.forBundle(bundleId);
      final session =
          sessions.isEmpty
              ? DispatchSession(
                sessionId: 'foreground#$bundleId',
                bundleId: bundleId,
              )
              : sessions.first;
      DispatchContext.instance.setForeground(session: session);
    }
    _refreshActiveMcpUrl();
  }

  /// Reflect the currently active tab's MCP server URL on the chrome
  /// bridge so the titlebar pill shows where the active domain attaches
  /// (system URL by default, the spawned URL when on a narrow link).
  /// Called from [_setActiveContext] and from the override file watcher
  /// after a re-attach so the pill stays current across both flows.
  void _refreshActiveMcpUrl() {
    final mgr = _chromeBridge.domainServerManager;
    final path = _activePackageNotifier.value;
    if (mgr == null || path == null) {
      _chromeBridge.activeMcpUrl.value = '';
      return;
    }
    final url = mgr.urlForBundle(path);
    _chromeBridge.activeMcpUrl.value = url ?? '';
  }

  /// Resolver passed to [StandardStudioShell.domainSettingsBuilder].
  /// Looks up the active package's display name from the bridge's
  /// `listTabs` snapshot so the Settings dialog header reads correctly
  /// without the host caching tab metadata twice.
  DomainSettingsPanel? _resolveDomainPanel() {
    // MCP-server section is auto-prepended regardless of which domain
    // is active so the user always has the inherit / standalone toggle
    // available. `readManifestSettingsSections` already does this for
    // manifest-driven domains; we mirror the same behaviour for
    // built-in apps and for the home-tab case (no active domain).
    final configRoot = _backboneCached?.configRoot;
    final path = _activePackageNotifier.value;

    SettingsSection mcpSection() {
      final inherited = loadInheritedSettings(toolId);
      final overridesFile =
          path != null
              ? packageOverridesFile(configRoot: configRoot, pkgPath: path)
              : packageOverridesFile(configRoot: configRoot, pkgPath: 'home');
      return SettingsSection(
        label: 'MCP server',
        body: ManifestFieldList(
          fields: buildBaseDomainFields(inherited),
          overridesFile: overridesFile,
        ),
      );
    }

    /// Active bundle's `manifest.json` path. Built-ins point at their
    /// seed manifest (`seed/<id>.mbd/manifest.json`); manifest-driven
    /// domains point at `<bundle>.mbd/manifest.json`. Home tab points
    /// at `host_agents.json` (host baseline source-of-truth). Null when
    /// the host can't resolve a path (e.g. unknown built-in id).
    String? activeManifestPath() {
      final ctx = BuiltInAppRegistry.instance.activeContext;
      if (ctx != null) {
        final app = BuiltInAppRegistry.instance.activeApp;
        if (app == null) return null;
        for (final entry in seedBundles()) {
          if (entry.namespace == app.id) {
            return p.join(entry.mbdPath, 'manifest.json');
          }
        }
        return null;
      }
      if (path != null) return p.join(path, 'manifest.json');
      // Home tab — `host_agents.json` holds the host baseline (writes
      // here flow back into `agentProfiles` on next boot).
      return _hostAgentsPath();
    }

    SettingsSection? agentsSection() {
      final manifestPath = activeManifestPath();
      if (manifestPath == null) return null;
      if (!File(manifestPath).existsSync()) return null;
      // Re-read `activeContext` inside the closure (outer `activeCtx`
      // is declared after this closure literal). Same source, so the
      // label correctly reflects whether the panel sits on the Home
      // tab vs. a built-in / manifest domain.
      final ctx = BuiltInAppRegistry.instance.activeContext;
      final label =
          path == null && ctx == null
              ? 'Agents — host baseline (saved in host_agents.json)'
              : 'Agents — model per agent (saved in bundle)';
      return SettingsSection(
        label: label,
        body: AgentModelsSection(
          manifestPath: manifestPath,
          modelOptions: modelCatalog,
          chromeBridge: _chromeBridge,
        ),
      );
    }

    final activeCtx = BuiltInAppRegistry.instance.activeContext;
    if (activeCtx != null) {
      // Built-in active — its domainSettingsProvider returns the
      // domain-specific sections (read from the source-of-truth
      // manifest, no inline seeds). MCP section is host-owned, always
      // prepended; Agents section reads/writes the bundle manifest.
      final builtInPanel = activeCtx.domainSettingsProvider?.call();
      final domainSections =
          builtInPanel?.sections ?? const <SettingsSection>[];
      final agents = agentsSection();
      // Friendly fallback name — the built-in's own `label` (e.g.
      // "Scene Builder", "Ops") beats `bundlePath` (which would show
      // `~/.config/<toolId>/workspaces/<id>` in the dialog header).
      final fallbackName =
          BuiltInAppRegistry.instance.activeApp?.label ?? activeCtx.bundlePath;
      return DomainSettingsPanel(
        name: builtInPanel?.name ?? fallbackName,
        sections: <SettingsSection>[
          mcpSection(),
          if (agents != null) agents,
          ...domainSections,
        ],
      );
    }

    if (path == null) {
      // Home tab — no manifest domain, but the host baseline agents
      // still need a place to edit. Surface only the Agents section
      // backed by `host_agents.json`; everything else lives in Studio.
      final agents = agentsSection();
      if (agents == null) return null;
      return DomainSettingsPanel(
        name: 'Home',
        sections: <SettingsSection>[agents],
      );
    }
    final list =
        _chromeBridge.listTabs?.call() ?? const <Map<String, dynamic>>[];
    final entry = list.firstWhere(
      (e) => e['key'] == path,
      orElse: () => <String, dynamic>{'name': path},
    );
    final name = (entry['name'] as String?) ?? path;
    final agents = agentsSection();
    final sections = <SettingsSection>[
      if (agents != null) agents,
      // Wiring-declared action entries (manifest.wiring.settings[])
      // appear ABOVE manifest-declared field sections so frequently-used
      // verbs sit at the top of the Domain tab.
      ...readWiringSettingsSections(path, bridge: _chromeBridge),
      ...readManifestSettingsSections(
        path,
        configRoot: configRoot,
        toolId: toolId,
        bridge: _chromeBridge,
      ),
    ];
    return DomainSettingsPanel(name: name, sections: sections);
  }

  List<HistoryLevel> _resolveHistoryLevels() {
    final root = _backboneCached?.configRoot;
    return resolveStudioHistoryLevels(
      bridge: _chromeBridge,
      activePackagePath: _activePackageNotifier.value,
      configRoot: root ?? p.join('/tmp', 'vibe_studio_chats'),
    );
  }

  // ── Shell ──────────────────────────────────────────────────────

  @override
  ShellBlueprint buildShell({
    required BuildContext context,
    required StudioBackbone backbone,
    required VibeChatController chat,
    required Object llm,
    required Object server,
    required BundleInstallSurface bundles,
    required VibeSettings settings,
    required String transport,
    required int port,
  }) {
    _backboneCached = backbone;
    _settings = settings;
    // Sync the debug-mode pin from VibeSettings into the chrome
    // bridge. DslWorkspaceView listens here and re-mounts its
    // runtime through `MCPUIRuntime.withInspector(...)` when true,
    // the production fast path when false. Settings dialog's Save
    // handler flips this through `StudioFrameScope.updateSettings`,
    // which re-runs this builder.
    _chromeBridge.inspectorEnabled.value = settings.debugMode;
    return WidgetShellBlueprint(
      (ctx) => ValueListenableBuilder<String?>(
        // The shell's bundle-name surface reflects the active tab's
        // *currentProject* (the target the user is authoring), not
        // the tab's host package. Tab activate/deactivate is the
        // domain-side lifecycle event — `_setActiveContext`
        // receives it through `onActiveContextChanged` and flips
        // `_activeProjectNotifier`, which feeds the shell's display
        // here. Path null = no project open in the active tab —
        // built-ins surface their own no-project label through
        // `chromeBridge.lifecycleState.value.projectName` (MOD-APPS-003);
        // the 'Home' fallback below is for the actual Home tab.
        valueListenable: _activeProjectNotifier,
        builder:
            (innerCtx, projectPath, _) => StandardStudioShell(
              appLabel: displayName,
              backbone: backbone,
              chat: _activeChat,
              modelOptions: modelCatalog,
              bundles: bundles,
              settings: settings,
              transport: transport,
              port: port,
              bundleName:
                  projectPath == null
                      ? 'Home'
                      : (readFriendlyLabel(projectPath) ??
                          p.basenameWithoutExtension(projectPath)),
              chromeBridge: _chromeBridge,
              shellOverlay:
                  (_captureSurface == null && _extensionOverlays.isEmpty)
                      ? null
                      : Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          if (_captureSurface != null)
                            OverlayLayer(
                              controller: _captureSurface!.overlayController,
                              elementResolver: _chromeBridge.resolveElementRect,
                            ),
                          // Extension overlays (e.g. pro's marketplace surface).
                          ..._extensionOverlays,
                        ],
                      ),
              domainSettingsBuilder: _resolveDomainPanel,
              historyLevelsBuilder: _resolveHistoryLevels,
              center:
                  (innerCtx) => StudioWorkspace(
                    bundles: bundles,
                    chromeBridge: _chromeBridge,
                    configRoot: backbone.configRoot,
                    boot: _mcpBoot!,
                    domainStorage:
                        _domainStorage ??= mk.JsonFileDomainStorage(
                          rootDir: p.join(backbone.configRoot, 'domains'),
                        ),
                    onActiveContextChanged: _setActiveContext,
                    chatForKey: _chatFor,
                    builtInLaunchers: <BuiltInLauncher>[
                      for (final app in BuiltInAppRegistry.instance.apps)
                        app.launcher(
                          _chromeBridge,
                          p.join(backbone.configRoot, 'workspaces'),
                        ),
                    ],
                    // Home entries from extensions (e.g. pro's Marketplace icon).
                    // Empty in the base build.
                    extensionEntries: _extensionHomeEntries,
                    seedPathByNamespace: <String, String>{
                      for (final s in seedBundles()) s.namespace: s.mbdPath,
                    },
                    // Bundle UI body — vibe_studio_workspace (StudioUiRenderer)
                    // stays on the host side so base remains renderer-agnostic.
                    // For the adopted-draft flow (target != tab path), the draft
                    // is read directly; otherwise the tab's own activation bundle
                    // (or a fresh disk read) supplies the manifest.ui entry.
                    bundleBodyBuilder: (tab, target) {
                      // Built-in app branch — every registered `BuiltInApp` gets
                      // first refusal on the target. The first match owns the
                      // body. Apps register themselves into `BuiltInAppRegistry`
                      // via `apps.registerBuiltInApps()` at host boot, so adding
                      // a new built-in is "implement the interface + add one
                      // line to the registry bootstrap" — no host edits.
                      final builtin = BuiltInAppRegistry.instance.matchFor(
                        target,
                      );
                      if (builtin != null) {
                        // Mirror `_setActiveContext`'s key shape so the built-in
                        // app and the host's chat panel resolve the same
                        // controller through `_chatFor`.
                        final tabKey =
                            (target == tab.path)
                                ? tab.path!
                                : '${tab.path}::$target';
                        // Inherited settings come from the studio-wide settings
                        // file (host toolId). Built-ins seed their own field
                        // defaults from this map so e.g. `workspaceDir` shows
                        // the host's value until the user overrides it for the
                        // app specifically (write lands in `overridesFile`).
                        final inheritedSettings = loadInheritedSettings(toolId);
                        final overridesFile = packageOverridesFile(
                          configRoot: _backboneCached?.configRoot,
                          pkgPath: target,
                        );
                        return builtin.mount(
                          context: context,
                          bundlePath: target,
                          chromeBridge: _chromeBridge,
                          chatLookup: _chatFor,
                          tabKey: tabKey,
                          server: BuiltinToolRegistry(_mcpBoot!),
                          backbone: _backboneCached!,
                          inheritedSettings: inheritedSettings,
                          overridesFile: overridesFile,
                        );
                      }
                      final bundleForUi =
                          (target == tab.path)
                              ? (tab.activation?.bundle ?? readBundleAt(target))
                              : readBundleAt(target);
                      final ui = bundleForUi?.uiEntry;
                      // Seed initial DSL state with host-known values the seed's
                      // bindings need (currentProject for embedded target
                      // preview). Other route / page tokens are bundle-owned —
                      // the bundle's ui/app.json `state.initial` block defines
                      // them and persistence across reopens is handled by the
                      // generic per-tab state restore path, NOT by host-side
                      // bundle-specific keys.
                      final initialState = <String, dynamic>{
                        if (tab.currentProject != null)
                          'currentProject': tab.currentProject,
                      };
                      if (ui != null) {
                        return StudioUiRenderer(
                          key: ValueKey('$target::${tab.reloadCounter}::ui'),
                          bundlePath: target,
                          uiKind: ui.kind,
                          uiPath: ui.path,
                          boot: _mcpBoot!,
                          chromeBridge: _chromeBridge,
                          initialState: initialState,
                        );
                      }
                      // No `ui` section in the manifest — treat the bundle as a
                      // builder workspace (empty scaffold or knowledge-only bundle).
                      // The DslWorkspaceView's _uiMissing path renders the "Tell
                      // vibe what to build" canvas; once the builder writes
                      // ui/app.json + patches the manifest, reload_tab swaps to
                      // the rendered UI.
                      return StudioUiRenderer(
                        key: ValueKey('$target::${tab.reloadCounter}::builder'),
                        bundlePath: target,
                        uiKind: UiEntryKinds.mcpUiDsl,
                        uiPath: 'ui/app.json',
                        boot: _mcpBoot!,
                        chromeBridge: _chromeBridge,
                        initialState: initialState,
                      );
                    },
                  ),
            ),
      ),
    );
  }
}
