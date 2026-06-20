import 'dart:typed_data';

import '../core/vibe_project.dart';
import '../feat/build_tools.dart';
import '../feat/file_tools.dart';
import '../feat/inspector_session.dart';
import '../infra/vibe_settings.dart';

/// Shared callback / getter container that lets the MCP server
/// (`ServerBootstrap`) drive shell-owned state and read shell-owned
/// state without inverting ownership. Shell registers every slot in
/// initState; tool handlers in ServerBootstrap call through the bridge.
///
/// Slots that are unset throw [BridgeNotWiredException] when invoked —
/// the MCP layer surfaces a clean "feature not available" error rather
/// than null-dereferencing.
class VibeServerBridge {
  VibeServerBridge();

  /// The bridge of the **currently-live** App Builder mount.
  ///
  /// App Builder is single-instance (one domain, one project), so there is
  /// only ever zero or one live mount — never concurrent instances. A
  /// re-mount (IndexedStack rebuild, re-open from Home, hot restart) swaps
  /// this to the new mount; the mount's dispose clears it only-if-mine.
  /// `vibe_*` tool/resource handlers read through [resolve] so a re-mounted
  /// mount's tool (registered via the standard registry's replace) answers
  /// from the live bridge, never a torn-down mount's nulled state — see
  /// the re-mount lifecycle subsection under MOD-INSTALL-BTR (DDD/infra).
  /// This is *liveness*, not foreground — a backgrounded-but-mounted App
  /// Builder still answers its real project state (no false "no project").
  /// Domain foreground is the platform's `setActiveBundle()`, not this
  /// pointer.
  static VibeServerBridge? live;

  /// Resolve the bridge a handler should read: the live mount's when one
  /// is mounted, else the [captured] bridge (a closed App Builder then
  /// reports its last state / welcome — no live project).
  static VibeServerBridge resolve(VibeServerBridge captured) =>
      live ?? captured;

  /// Mark [mount] the live App Builder bridge (called from mount init).
  static void markLive(VibeServerBridge mount) => live = mount;

  /// Clear the live pointer only if [mount] still holds it — a re-mount
  /// may have swapped it since (called from mount dispose).
  static void clearLiveIfMine(VibeServerBridge mount) {
    if (identical(live, mount)) live = null;
  }

  // ─────────── Project state getters ───────────

  /// Returns the current project, or null when vibe is in the welcome
  /// state (no project loaded).
  VibeProject? Function()? getProject;

  /// Recent project paths in MRU order.
  List<String> Function()? getRecents;

  /// Tool / file / build dispatchers. Bound when a project is open;
  /// null otherwise.
  FileToolsDispatcher? Function()? getFileTools;
  BuildToolsDispatcher? Function()? getBuildTools;

  /// Tool-level settings (workspaceDir, llm config, …).
  VibeSettings Function()? getSettings;
  Future<void> Function(VibeSettings updated)? onUpdateSettings;

  // ─────────── Project lifecycle ───────────

  Future<void> Function(String name, String parent, {ProjectKind? kind})?
  onNewProject;
  Future<void> Function(String projectPath)? onOpenProject;
  Future<void> Function()? onCloseProject;
  Future<void> Function()? onSaveProject;
  Future<void> Function(String newPath)? onSaveAsProject;
  Future<void> Function()? onRevertProject;
  Future<void> Function(String newName)? onRenameProject;

  // ─────────── Channel lifecycle ───────────

  Future<void> Function(String channelId)? onActivateChannel;
  Future<void> Function(String channelId)? onCreateChannel;
  Future<void> Function(String channelId)? onRemoveChannel;
  Future<void> Function(String channelId)? onPurgeChannel;

  /// Copy `from`'s on-disk bundle into `to`. Mirrors the GUI
  /// "Copy to Native channel" menu action — destructive on `to` when
  /// it already has data.
  Future<void> Function(String from, String to)? onCopyChannel;

  /// Swap two channels' on-disk bundle data. Symmetric op.
  Future<void> Function(String a, String b)? onSwapChannels;

  // ─────────── Build preset persistence ───────────

  /// Persist a partial Build dialog selection back to
  /// `<projectPath>/prefs.json`. Each field is optional — fields
  /// omitted by the caller fall through to the existing values.
  /// Triggered by `vibe_build_config_set`.
  Future<void> Function({
    String? target,
    String? channel,
    String? outDir,
    bool? runFlutterCreate,
  })?
  onUpdateBuildConfig;

  /// Wipe build artifacts. `target == null` clears the entire
  /// `build/` directory; otherwise only `build/<target>/`.
  /// Returns the deleted paths (empty list when nothing existed).
  Future<List<String>> Function(String? target)? onCleanBuild;

  /// Capture the live preview surface as PNG bytes. The shell holds
  /// the `RepaintBoundary` key; this slot wraps `toImage(...)` so the
  /// MCP tool layer can stay decoupled from Flutter rendering.
  /// Returns null when no preview is currently mounted (welcome
  /// state, or layer with no rendered content).
  Future<({Uint8List bytes, int width, int height})?> Function({
    double pixelRatio,
  })?
  onCapturePreview;

  /// Walk the live preview's render tree and return a structured
  /// layout snapshot — one entry per `MetaData`-tagged widget with
  /// rect / size / resolved text style / decoration info. Lets the
  /// MCP tool surface "what does this page actually look like" with
  /// the rendered values (not the spec) — without paying for a
  /// vision model. Returns null when no inspect-mode preview is
  /// mounted.
  Future<List<Map<String, dynamic>>?> Function()? onCaptureLayoutSnapshot;

  // ─────────── Shell focus / selection ───────────

  /// Active layer id (`appStructure` / `theme` / `components` /
  /// `dashboard` / `pages` / `whole`).
  String Function()? getFocusedLayer;

  /// Currently selected page id, or null.
  String? Function()? getSelectedPageId;

  /// Currently selected component id, or null.
  String? Function()? getSelectedComponentId;

  /// Selected widget path inside the focused page / component as a
  /// JSON-Pointer-friendly slash-separated string (`""` for root).
  String? Function()? getSelectedWidgetPath;

  /// True when the active canonical has unsaved edits.
  bool Function()? getDirty;

  Future<void> Function(String layerId)? onFocusLayer;
  Future<void> Function(String? pageId)? onSelectPage;
  Future<void> Function(String? componentId)? onSelectComponent;
  Future<void> Function(String widgetPathPointer)? onSelectWidget;

  /// Force the live preview tracks to discard their memoised runtime
  /// and rebuild from canonical. Used by `vibe_preview_refresh` and
  /// any in-shell control that wants a hard reload (e.g. after a
  /// canonical patch the runtime would otherwise serve stale).
  Future<void> Function()? onRequestPreviewRefresh;

  // ─────────── Inspector session manager ───────────

  /// The shell-owned [InspectorSessionManager]. Exposed so MCP tools
  /// can list active sessions, read / write runtime state, page
  /// through wire frames, and replay fixtures against the live
  /// connection — same surface the UI panel drives.
  InspectorSessionManager Function()? getInspectorSessions;

  /// Spawn + connect an inspector session for a built variant by slug
  /// (`inline` / `bundle` / `native_inline` / `native_bundle`) — the same
  /// `connect()` path the Inspector's variant ▶ card drives, exposed for
  /// MCP so the live-debug workflow is automatable (the card is a raw
  /// GestureDetector that synthetic taps can't reach). Resolves the
  /// executable under `build/<slug>/`. Returns `{ok, slug, status}` or
  /// `{ok:false, error}` (not built / no executable / no project).
  Future<Map<String, dynamic>> Function(String slug, {String? transport})?
  spawnInspectorVariant;

  /// Stop a running inspector session by slug. Returns `{ok, slug}`.
  Map<String, dynamic> Function(String slug)? stopInspectorVariant;

  /// Recent chat turns from the shell-owned `VibeChatController`.
  /// Returns the most-recent first; pass `limit` to cap. Each map:
  /// `{role, text, at, layer?, fileCount?}`. Used by the
  /// `vibe_chat_history` MCP tool so an external LLM can answer
  /// "what did the user ask, and what did I respond?".
  List<Map<String, dynamic>> Function({int limit})? getChatHistory;

  /// Runtime render errors captured by the preview tracks
  /// (mcp_ui_runtime + self-UI). Each entry: `{at, where, kind,
  /// message}`. Newest-first. Implementer keeps a bounded ring
  /// buffer so `vibe_runtime_errors` stays cheap.
  List<Map<String, dynamic>> Function({int limit})? getRuntimeErrors;

  /// Tail of the in-memory `package:logging` ring buffer. Optional
  /// `channel` filter (e.g. `vibe.core.patch`, `vibe.infra.transport`,
  /// `vibe.infra.llm`, `vibe.conv.<x>`) — null = all channels. Each
  /// entry: `{at, level, channel, message, stack?}`. Newest-first.
  List<Map<String, dynamic>> Function({int limit, String? channel})?
  getLogsTail;

  /// Submit a message to the chat-side LLM as if the user typed it
  /// in the composer. Returns the assistant's reply turn (text +
  /// optional layer + role). Used by external LLM clients to drive
  /// the chat session for automated debugging — read counterpart is
  /// `getChatHistory`. Implementer awaits the full reply and may
  /// timeout the call (default 120 s in vibe).
  Future<Map<String, dynamic>> Function(String text)? submitChatMessage;

  /// Direct dispatch into a vibe FlowBrain agent. Returns the agent's
  /// reply (text + tool calls). Implementer is responsible for
  /// honouring the agent's allowed-tools subset and for dispatching
  /// any returned tool_calls. See MOD-FEAT-008 AgentHost.
  Future<Map<String, dynamic>> Function(String agentId, String message)?
  askAgent;

  /// List vibe's registered FlowBrain agents — id, displayName, model,
  /// role, tag map. Read-only.
  Future<List<Map<String, dynamic>>> Function()? listAgents;

  /// Recent conversation turns for one agent. Used by external clients
  /// to inspect agent history without going through the chat panel.
  Future<List<Map<String, dynamic>>> Function(String agentId, {int limit})?
  agentHistory;

  /// Aggregate growth stats from vibe's `VibeGrowthRecorder` —
  /// auto-tracked AgentForkEvolvedEvents + explicit recordSuccess
  /// counters. Read-only snapshot.
  Future<Map<String, dynamic>> Function()? agentGrowth;

  /// Install a knowledge bundle (.mbd directory). Implementer validates
  /// the manifest and adds the path to `KnowledgeBundleRegistry` so the
  /// retrieval path (`vibe_knowledge_query`) can find it later. Does
  /// NOT depend on FlowBrain's OpsRuntime — install is independent of
  /// the agent / fact-graph stack so the retrieval surface works zero-LLM.
  /// Returns `{ok, namespace, error?}`.
  Future<Map<String, dynamic>> Function(String mbdPath)? installKnowledgeBundle;

  /// Free-text BM25 query over installed bundles. Returns ranked
  /// chunks `{score, text, source, namespace, sourceId, title?, chunkId?}`.
  /// Supports `namespace` / `sourceId` filters when callers want to
  /// narrow the scope.
  Future<List<Map<String, dynamic>>> Function(
    String query, {
    int topK,
    String? namespace,
    String? sourceId,
  })?
  knowledgeQuery;

  /// Read-only snapshot of installed knowledge bundles —
  /// `[{mbdPath, namespace, installedAt}]`. Backed by
  /// `KnowledgeBundleRegistry`.
  Future<List<Map<String, dynamic>>> Function()? listKnowledgeBundles;

  /// Remove a registered knowledge bundle by `mbdPath`. Returns
  /// `{ok, removed}` — `removed=false` means the path was not in the
  /// registry. Drops the in-memory query cache so the next query
  /// re-reads the (now-smaller) registry.
  Future<Map<String, dynamic>> Function(String mbdPath)?
  uninstallKnowledgeBundle;
}

/// Thrown when an MCP tool tries to use a bridge slot the shell hasn't
/// wired (typically because no project is open).
class BridgeNotWiredException implements Exception {
  BridgeNotWiredException(this.slot);
  final String slot;
  @override
  String toString() => 'Bridge slot "$slot" not wired';
}
