/// `StudioApp` — the single contract every builder (vibe_app_builder ·
/// vibe_knowledge_builder · vibe_studio universal host) implements so
/// kernel + base can wire it identically regardless of how the user
/// launches the tool (standalone `.app` today; embedded inside a future
/// universal-host workspace tomorrow).
///
/// The contract groups hooks the host calls in deterministic order from
/// [StudioMain.run]:
///
///   1. `buildServer({backbone, bundles})` — domain MCP server instance
///      (`mcp_server.Server` for vkb, `vibe_app_builder.ServerBootstrap`
///      for vibe). Returned as `Object` so each host stays free to keep
///      its own typed flavour.
///   2. `registerMcpTools(server, backbone, bundles)` — domain tools.
///      Bundles are passed in so `install / list / uninstall / query`
///      handlers route through the shared surface.
///   3. `startTransport({server, transport, port})` — domain owns the
///      transport boot (background) so it can pick `streamableHttp` /
///      `sse` flavour without the host having to type-erase first.
///   4. `buildLlmAdapter({backbone, settings, server})` — typically a
///      thin wrapper around `backbone.agentHost` + optional sampling
///      fallback against the connected MCP host.
///   5. `buildChatController({backbone, settings, llm, server})` —
///      `VibeChatController` with project chat-log persistence wired.
///   6. `buildShell({...})` — [ShellBlueprint] (`Widget` today, `Dsl`
///      reserved for Round B). The host frames it in `MaterialApp` +
///      `Scaffold` + standard chrome.
///
/// The `Object` types on server / llm are intentional — base has no
/// reason to know either flavour, and forcing a typed parent class on
/// every host would force unnecessary kernel/base churn whenever a new
/// domain ships.
library;

import 'package:flutter/widgets.dart';

import '../agent/agent_profile.dart';
import '../boot/studio_backbone.dart';
import '../chat/chat_controller.dart';
import '../chat/model_option.dart';
import '../settings/vibe_settings.dart';
import 'bundle_install_surface.dart';
import 'shell_blueprint.dart';

/// One seed bundle declaration. Per SDD §1.4 the host returns a single
/// list of these; `studio_boot` reads each entry's manifest and wires
/// whichever capability surfaces the manifest declares (knowledge →
/// KB index, agents → FlowBrain ops baseline, tools/ui/chat → handled
/// at activation time same as user-installed bundles).
class SeedBundleEntry {
  final String mbdPath;
  final String namespace;
  const SeedBundleEntry({required this.mbdPath, required this.namespace});
}

abstract class StudioApp {
  const StudioApp();

  // ── Identity ─────────────────────────────────────────────────────

  /// Stable identifier — used as the FlowBrain workspace id and the
  /// launcher window title prefix. Pick once and never rename.
  String get toolId;

  /// Human-readable label for the chrome titlebar / About dialog.
  String get displayName;

  /// Optional override for the directory under `~/.config/`. Defaults
  /// to [toolId]; vibe_app_builder keeps `'app_builder_vibe'` for
  /// backwards-compat with existing user data.
  String? get configRootName => null;

  /// Default MCP transport port. Honoured when no `--port` CLI arg is
  /// supplied. Each domain picks a different number so concurrent runs
  /// don't collide on `127.0.0.1`.
  int get defaultPort;

  // ── Boot inputs (forwarded to StudioBoot.start) ─────────────────

  /// Agent profile catalogue — registered with FlowBrain on boot.
  List<VibeAgentProfile> get agentProfiles;

  /// Models the chat header dropdown / Settings dialog exposes. The
  /// boot path also feeds these ids into FlowBrain's LlmPort registry.
  List<VibeModelOption> get modelCatalog;

  /// Resolve a manifest agent id (e.g. `'kb.manager'`) into the
  /// internal id FlowBrain knows. Convention: return [input] unchanged
  /// when the id isn't recognised — the FlowBrain layer treats unknown
  /// ids as a fall-through to the manager channel.
  String Function(String)? get resolveAgentId => null;

  /// Seed bundles registered automatically at boot. Each entry's
  /// manifest declaration drives which capability surfaces wire up
  /// (knowledge → KB index, agents → FlowBrain ops baseline, etc.).
  /// Per SDD §1.4 the host does not pick channels — manifest decides.
  List<SeedBundleEntry> seedBundles() => const <SeedBundleEntry>[];

  /// Tool definitions FlowBrain's agent host fetches each turn. Each
  /// `{name, description, inputSchema}` entry mirrors the MCP server's
  /// `tools/list` shape so the LLM sees the same surface.
  List<Map<String, dynamic>> fetchAllToolDefinitions();

  // ── Async pre-boot hook ─────────────────────────────────────────

  /// Domain-specific work that needs CLI args + loaded settings before
  /// the kernel-backed backbone is started. Typical use: open a
  /// project (vibe_app_builder), load extra config, instantiate
  /// canonical / pipeline. Default no-op.
  ///
  /// Stash any state on the [StudioApp] instance (mutable fields are
  /// fine — there's exactly one instance per process).
  Future<void> onBoot({
    required Map<String, dynamic> args,
    required VibeSettings settings,
  }) async {}

  // ── Server / tools / transport ─────────────────────────────────

  /// Build the domain MCP server instance. Called after backbone +
  /// bundles are ready. The server flavour is opaque to the host
  /// (`Object`); each domain keeps its own typed reference internally.
  Object buildServer({
    required StudioBackbone backbone,
    required BundleInstallSurface bundles,
  });

  /// Register domain-specific MCP tools on [server]. [bundles] is
  /// shared so install / list / uninstall / query handlers route
  /// through the standard surface without each domain re-implementing
  /// the install path.
  void registerMcpTools({
    required Object server,
    required StudioBackbone backbone,
    required BundleInstallSurface bundles,
  });

  /// Start the MCP transport in the background so the GUI thread keeps
  /// pumping. Domain decides between streamable-http and SSE based on
  /// [transport] (`'http'` | `'sse'`).
  Future<void> startTransport({
    required Object server,
    required String transport,
    required int port,
  });

  // ── LLM + chat ─────────────────────────────────────────────────

  /// Build the LLM adapter. Most domains return a thin wrapper around
  /// `backbone.agentHost` plus an optional sampling fallback.
  Object buildLlmAdapter({
    required StudioBackbone backbone,
    required VibeSettings settings,
    required Object server,
  });

  /// Build the chat controller. Domain wires the LLM adapter's send
  /// methods + project chat.jsonl persistence + agent send routing.
  Future<VibeChatController> buildChatController({
    required StudioBackbone backbone,
    required VibeSettings settings,
    required Object llm,
    required Object server,
  });

  // ── Shell ───────────────────────────────────────────────────────

  /// Describe how the centre pane renders. `WidgetShellBlueprint` is
  /// the only path wired in Round A; `DslShellBlueprint` is reserved
  /// for Round B (vibe_studio_runtime mounts the bundle).
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
  });
}
