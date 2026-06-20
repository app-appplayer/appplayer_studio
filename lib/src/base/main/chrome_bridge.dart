/// `ChromeBridge` — callback container for chrome-level UI actions
/// the host wants to expose over MCP. Every interactive surface in the
/// standard shell (panel toggles, mode switches, focus jumps, …)
/// publishes a setter on this bridge; [StandardStudioShell] wires
/// each setter from inside its `setState`. The host then registers
/// MCP tools that simply invoke the bridge callbacks — so an external
/// LLM driving the tool over MCP exercises the same code path the
/// user does when they click.
///
/// Domain-specific actions stay on the per-domain bridge
/// (`VibeServerBridge`, `KbServerBridge`); ChromeBridge only carries
/// the chrome the standard shell owns.
library;

import 'dart:async';

import '../session/session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show BuildContext, GlobalKey, InheritedWidget, Rect;

import '../chat/chat_slash_hint.dart';
import '../chat/chat_turn.dart';
import '../install/domain_servers/domain_server_manager.dart';
import '../shell/project_header.dart';

/// Snapshot of the active domain's chrome-relevant lifecycle flags.
/// Bound to [ChromeBridge.lifecycleState] so the host's project
/// header / titlebar / statusbar can enable / emphasise the standard
/// lifecycle buttons (Save / Undo / Redo / Revert) without polling
/// the domain. Owner of the active domain is responsible for updating
/// the notifier whenever any flag changes.
class DomainLifecycleState {
  const DomainLifecycleState({
    required this.hasProject,
    required this.dirty,
    required this.canUndo,
    required this.canRedo,
    required this.canCompareChannels,
    this.projectName,
  });

  const DomainLifecycleState.empty()
    : hasProject = false,
      dirty = false,
      canUndo = false,
      canRedo = false,
      canCompareChannels = false,
      projectName = null;

  /// Reserved snapshot for the Home tab — no project, but the header
  /// shows 'Home' as the label so the row reads as the launcher view
  /// regardless of which built-in's stale `lifecycleState` happened to
  /// be the last push. Without this the projectName falls through to
  /// the shell-level `bundleName` fallback, which races with any
  /// inactive built-in's postFrame republish.
  const DomainLifecycleState.home()
    : hasProject = false,
      dirty = false,
      canUndo = false,
      canRedo = false,
      canCompareChannels = false,
      projectName = 'Home';

  final bool hasProject;
  final bool dirty;
  final bool canUndo;
  final bool canRedo;
  final bool canCompareChannels;
  final String? projectName;
}

class ChromeBridge {
  /// Toggle the chat / project-header column on the left edge of the
  /// shell. Mounted by `StandardStudioShell`. Returns the resulting
  /// visibility so the MCP handler can echo `{visible: true|false}`
  /// back to the caller.
  bool Function()? toggleLeftPanel;

  /// Set left-panel visibility explicitly. Useful when the LLM wants
  /// to land in a specific layout (e.g. fullscreen workspace). Echoes
  /// the resulting state.
  bool Function(bool visible)? setLeftPanelVisible;

  /// Open the standard Settings dialog. Same code path as the user
  /// clicking the gear icon in `ProjectHeader` / activity bar. Returns
  /// after the dialog is dismissed (Save or Cancel).
  Future<void> Function()? openSettings;

  /// Open the chat-history dialog (Studio · Package · Project tabs).
  /// Same code path as the user clicking the history icon. Returns
  /// after the dialog is dismissed.
  Future<void> Function()? openHistory;

  /// Open the External LLM onboarding panel — shows the studio's MCP
  /// endpoint URL + ready-to-paste config snippets for Claude Desktop
  /// + Claude Code + generic MCP Inspector, with copy buttons. Hosts
  /// wire this to a dialog or new tab; MCP-driven external LLMs can
  /// trigger it via `studio.chrome.open_onboarding` to walk a user
  /// through connecting their own client.
  Future<void> Function()? openOnboarding;

  /// Open the Agent surface view — lists every registered agent
  /// (studio defaults + activated bundle additions) with their id /
  /// role / model / toolNames / systemPrompt preview. Same data as
  /// `studio.agent.list` + `studio.agent.describe`, surfaced as a
  /// dialog so a user can see who the manager can dispatch to.
  Future<void> Function()? openAgents;

  /// Focus an existing tab for the seed identified by [namespace], or
  /// mount the seed bundle as a new tab when none is up. Per SDD §1.4
  /// the seed namespace is the single identifier — host resolves the
  /// current path via `StudioApp.seedBundles()`. Returns true when the
  /// tab is active, false when the namespace is not declared by the
  /// host so MCP callers can distinguish error from success.
  Future<bool> Function(String namespace)? openSeed;

  /// Visibility of the universal-host tab strip rendered at the top of
  /// the centre pane. The titlebar trailing icon flips this notifier;
  /// the host's centre widget listens and shows / hides its tab strip
  /// in response. Default true — hosts that don't render a tab strip
  /// can ignore the notifier entirely (titlebar still hides the icon
  /// when the host doesn't opt in via [hasTabStrip]).
  final ValueNotifier<bool> tabBarVisible = ValueNotifier<bool>(true);

  /// Whether the host renders a tab strip at all. The host's centre
  /// widget flips this to true on mount; the titlebar listens and only
  /// renders the show / hide icon when the host opts in.
  final ValueNotifier<bool> hasTabStrip = ValueNotifier<bool>(false);

  /// Select a tab by index. Returns the resulting active index, or -1
  /// when the index is out of range. Mounted by the host's centre
  /// widget; MCP tools call into this for the same code path the user
  /// triggers by clicking a tab pill.
  int Function(int index)? selectTab;

  /// Close a tab by index. Returns the resulting active index, or -1
  /// when the index is out of range / refers to the home tab (which
  /// is never closable). Same code path as the user clicking the ×
  /// on a tab pill — runs the activation teardown.
  int Function(int index)? closeTab;

  /// Snapshot of currently-open tabs — `[{key, name}]` where key is
  /// `'home'` for the home tab or the package path for opened packages.
  /// Mounted by the host's centre widget for MCP introspection.
  List<Map<String, dynamic>> Function()? listTabs;

  /// True when the active tab is the universal-host Home tab (no
  /// bundle activated). Standard shell flips ProjectHeader's lifecycle
  /// row from "project" labels (New / Open project) to "package" labels
  /// (New / Open package) — the Home tab's verbs target the bundle
  /// registry, not a per-bundle project. Hosts without a tab model
  /// can leave this at its default false.
  final ValueNotifier<bool> homeActive = ValueNotifier<bool>(false);

  /// Run the host's "install a package" flow (file picker → register
  /// into bundle list). Wired by the host's centre widget; Home-tab
  /// "Open package" + the Install package button share this code path.
  Future<void> Function()? openPackagePicker;

  /// Scaffold a brand-new package (Studio Builder flow). Called by the
  /// Home "Create package" button (no args → opens the name+parent
  /// dialog) and by the `studio.chrome.create_package` MCP tool (with
  /// args → programmatic, no dialog). Returns the resulting bundle
  /// snapshot `{ok, mbdPath, name, namespace}` so MCP callers can chain
  /// activate / writeUI without a second list call. Null while the
  /// host's centre widget isn't mounted.
  Future<Map<String, dynamic>> Function({
    String? name,
    String? parent,
    String? id,
  })?
  createNewPackage;

  /// Run the host's new-project flow inside the active package tab —
  /// prompts the user for name + parent directory, creates the project
  /// folder, and activates it. Different from
  /// [newProjectInActive], which takes the (name, parent) pair from a
  /// caller (e.g. an MCP-driven LLM) and skips the dialog.
  Future<void> Function()? newProjectDialog;

  /// Run the host's open-project flow inside the active package tab —
  /// shows the directory picker, then sets the chosen folder as the
  /// active tab's project.
  Future<void> Function()? openProjectDialog;

  /// Set the active tab's project to a freshly-created directory at
  /// `<parent>/<name>`. Returns `{ok: true, projectPath}` or
  /// `{ok: false, error}`.
  Future<Map<String, dynamic>> Function({
    required String name,
    required String parent,
  })?
  newProjectInActive;

  /// Set the active tab's project to an existing directory.
  Future<Map<String, dynamic>> Function(String path)? openProjectInActive;

  /// Run a `/slash` command inside the active built-in tab's own
  /// dispatcher. The host chat panel routes `/cmd` input here so the
  /// active app (e.g. App Builder) parses it against its own UI context
  /// (selected page / widget) and runs its build/audit tools. Returns
  /// the reply text (or null). Null slot = the built-in has no slash
  /// dispatch and the host sends the line as a normal chat turn.
  Future<String?> Function(String input)? runSlashCommandInActive;

  /// Drop the active tab's project (return to State B welcome).
  Map<String, dynamic> Function()? closeProjectInActive;

  /// Sync the active tab's bound project into the host's tab model and
  /// re-key the chat panel to it. Built-in apps that own their own project
  /// lifecycle (Ops / Scene) call this AFTER binding so the host gets the
  /// same side effect manifest-domain tabs get for free from the host's
  /// open-project flow: `tab.currentProject` updates and the chat controller
  /// re-keys to `<tabPath>::<projectPath>` (a fresh per-project conversation)
  /// — without it the previous project's chat lingers. Pass null on close to
  /// return to the tab-level (no-project) chat. Wired by `StudioWorkspace`;
  /// no-op when the active tab is Home.
  void Function(String? projectPath)? setActiveTabProject;

  /// Set the center-column mode of the active built-in app
  /// (`ui` / `bundle` / `debug`). Used by `studio.ui.set_center_mode`
  /// so MCP callers can switch the 3-way mode toggle without dispatching
  /// a synthetic tap (synthetic pointer events do not survive Flutter
  /// desktop's `embedderId` filter in production). Returns true when
  /// the active tab is a built-in that owns the toggle.
  bool Function(String mode)? setCenterMode;

  /// Resolve the default chat agent id for a freshly-opened tab at
  /// [bundlePath]. The host wires this for built-in apps so e.g.
  /// app_builder routes to `builder.manager` (the unified builder
  /// agent pool) instead of the legacy `studio.manager` default.
  /// Returns null when no built-in app claims the path — manifest
  /// bundles still go through the `_resolveChatAgentId` /
  /// `manifest.chat.agent` path.
  String? Function(String bundlePath)? defaultChatAgentResolver;

  /// Effective LLM modelId for [agentId] — what the kernel actually
  /// dispatches through (after `_llmProviders[provider]` lookup +
  /// `_defaultLlm` fallback). Differs from the agent's declared
  /// `modelId` when the declared provider has no adapter wired (the
  /// user hasn't entered its API key); chat surfaces this so the user
  /// sees the fallback rather than guessing why a no-key chat works.
  String? Function(String agentId)? effectiveModelIdResolver;

  /// Bump [path] to the head of `VibeSettings.recentProjects` and
  /// set `lastProjectPath`. Wired by the host to its `toolId`-scoped
  /// settings file. Called by the workspace after a successful
  /// open / new / adopt so subsequent `studio.project.recents` reads
  /// (and the `restoreLast` JS tool) see the latest project.
  Future<void> Function(String path)? recordRecentProject;

  /// Optional resolver the host registers so non-manifest domains
  /// (built-in apps) plug their header actions into the same code
  /// path the manifest sync uses. `_syncHeaderActions` in the
  /// workspace calls this with the active tab's mbdPath + live
  /// runtime state; returns the actions list, or null to fall back
  /// to the manifest reader. Eliminates the race where the manifest
  /// sync overwrites the bridge slot with an empty list whenever the
  /// active domain has no manifest.
  List<HeaderAction>? Function(String mbdPath, Map<String, Object?> liveState)?
  headerActionsResolver;

  /// Optional resolver for slash chips — same shape as
  /// [headerActionsResolver] but for `chatSlashHints`. Returns the
  /// chip list for non-manifest domains; null falls back to the
  /// workspace's manifest path.
  List<ChatSlashHint>? Function(String mbdPath)? chatSlashHintsResolver;

  /// Optional resolver for project / dirty / undo lifecycle state —
  /// same shape as [headerActionsResolver] but for the chrome's
  /// ProjectHeader binding. Built-in apps return their per-tab
  /// snapshot; null falls back to [DomainLifecycleState.empty] (the
  /// ProjectHeader then uses `bundleName` as the tab title — manifest
  /// domains don't carry a project, so the empty default is the
  /// correct rendering). Mirrors the header-actions resolver pattern
  /// so the chrome reads ONE place for every tab transition, and
  /// built-in apps never have to write the shared bridge slot
  /// themselves.
  DomainLifecycleState? Function(String mbdPath)? lifecycleStateResolver;

  /// Fire a chrome lifecycle slot against the active domain. Slot
  /// names match `wiring.lifecycle[].slot` in manifest-driven domains
  /// (`project.new` / `project.open` / `project.save` /
  /// `project.saveAs` / `project.revert` / `project.close` /
  /// `project.rename` / `project.export` / `project.import` /
  /// `history.show` / `edit.undo` / `edit.redo` / `build.run` /
  /// `build.clean` / `build.settings` / `assets.manage` /
  /// `channels.compare` / `settings.show`). Built-in apps publish
  /// handlers through `BuiltInAppContext.lifecycleBindingsProvider`;
  /// manifest-driven domains resolve through their `wiring.lifecycle`
  /// entries. Returns whether a handler ran — host UI may surface a
  /// "no binding" hint when the slot is unbound for the active domain.
  Future<bool> Function(String slot, [Map<String, dynamic> args])?
  dispatchLifecycleSlot;

  /// Live `canUndo` / `canRedo` / `dirty` / `hasProject` snapshot
  /// the host shell binds to so chrome buttons (Save / Undo / Redo /
  /// Revert) can enable / disable / emphasise without polling. The
  /// owner of the active domain bumps this notifier whenever any of
  /// the four flags flips. Built-in apps wire it through
  /// `BuiltInAppRegistry.revision`; manifest domains may bind their
  /// own bump source (or leave it static).
  final ValueNotifier<DomainLifecycleState> lifecycleState =
      ValueNotifier<DomainLifecycleState>(const DomainLifecycleState.empty());

  /// Force the bundle-tab at [index] (or the active tab if null) to
  /// re-mount its DslWorkspaceView — re-reads ui/app.json and the
  /// manifest from disk. Hosts wire this to a per-tab reload counter
  /// that flips the widget key. Used by the builder write tools
  /// (studio.builder.writeUI / patchManifest / addTool) so changes
  /// surface without close+re-open.
  void Function(int? index)? reloadTab;

  /// Open an installed package as a tab (or focus the existing tab if
  /// already open). Same code path as the user tapping a card in the
  /// home picker. Returns `{active, key, name}` reflecting the
  /// resulting tab. Async so activation (tool registration / agent
  /// registration / UI mount) completes before the caller continues.
  /// Mounted by the host's centre widget.
  Future<Map<String, dynamic>> Function(String mbdPath)? activatePackage;

  /// Dispatch a tool on the bundle activated for [mbdPath]. The host
  /// resolves the bundle's exposed namespace and calls the underlying
  /// MCP server with the prefixed name (`<exposedShortId>.<toolShort>`)
  /// — same code path as a domain icon tap or an external MCP client
  /// calling the tool by its full name. Used by surfaces that bind
  /// tools but don't own the bundle's namespace lookup themselves
  /// (e.g. the wiring-driven settings menu). Mounted by the host's
  /// centre widget; null when no centre is attached.
  Future<void> Function(
    String mbdPath,
    String toolShort,
    Map<String, dynamic> args,
  )?
  dispatchBundleTool;

  /// Snapshot of the active tab's project context — `{packageName,
  /// packagePath, projectPath, projectName}`. Returns null fields when
  /// no project is active. Mounted by the host's centre widget.
  Map<String, dynamic> Function()? activeProjectInfo;

  /// Pool of every MCP server instance the studio process owns,
  /// keyed by URL. The system server is the always-alive entry;
  /// later phases add per-domain entries for bundles whose
  /// `inheritFromSystem` is false. Mounted by `studio_main` after
  /// the system transport binds. Null until then — callers degrade
  /// gracefully when reading.
  DomainServerManager? domainServerManager;

  /// Snapshot of host-level configuration — `{configRoot, tabsFile,
  /// settingsFile, port, transport}`. Mounted by the host. Used by
  /// `studio.debug.config`.
  Map<String, dynamic> Function()? debugConfig;

  /// Snapshot of every tab's full state including chat message count
  /// and project path. Heavier than [listTabs] (which is for end-user
  /// surfaces); intended for `studio.debug.tabs`.
  List<Map<String, dynamic>> Function()? debugTabs;

  /// Active tab's bundle activation context — `{shortId, exposedNs,
  /// bundlePath, tools, agents}`. Surfaces what MCP names an external
  /// LLM can call against the active tab. Used by
  /// `studio.debug.activation`.
  Map<String, dynamic> Function()? debugActivation;

  /// Per-tab runtime state snapshot for every open tab — `[{tabKey,
  /// name, state}]`. Reads each tab's hooks synchronously so multi-
  /// tab inspection sees fresh state without waiting for emit ticks.
  /// Used by `studio.debug.runtimes`.
  List<Map<String, dynamic>> Function()? debugRuntimes;

  /// Active tab's chat surface — `{agentId, modelId, turns}` with the
  /// most recent N turns (role / content / ts). Lets an external LLM
  /// reconstruct the conversation context for the active tab. Used by
  /// `studio.debug.chat`.
  Map<String, dynamic> Function(int limit)? debugChat;

  /// Append a one-line event to the host's boot log. Called from
  /// `_loadTabs` / `_activateBundle` etc. so post-mortem debugging
  /// has the activation chain for the current session. Stored on the
  /// bridge so debug tools can read it back without instrumenting
  /// each call site.
  void recordBootEvent(String message) {
    _bootLog.add(<String, Object?>{
      'ts': DateTime.now().toUtc().toIso8601String(),
      'message': message,
    });
    while (_bootLog.length > _bootLogLimit) {
      _bootLog.removeAt(0);
    }
  }

  final List<Map<String, Object?>> _bootLog = <Map<String, Object?>>[];
  static const int _bootLogLimit = 200;

  /// Read-only snapshot of the boot event log.
  List<Map<String, Object?>> get bootEvents =>
      List<Map<String, Object?>>.unmodifiable(_bootLog);

  /// Append a turn into the currently-active chat thread (whichever
  /// tab the user is on). Used by tools like `studio.agent.dispatch`
  /// to emit inline trace turns ("→ studio.ux_designer", "← returned
  /// 412 chars") so the user can see the manager's specialist chain
  /// without leaving the chat. Hosts wire this to push into their
  /// active VibeChatController.
  void Function(ChatTurn turn)? appendChatTurn;

  /// Marks the currently-active tab as modified — chat sent, a
  /// `studio.builder.*` mutator executed, or any other action whose
  /// loss on tab close would surprise the user. `_closeTab` reads the
  /// flag and raises a Cancel / Close-anyway dialog before tearing
  /// down. Wired by the workspace; no-ops on the Home tab.
  void Function()? markActiveTabModified;

  /// Reports a change in the active tab's bundle runtime state. The
  /// workspace wires this from `DslWorkspaceView`'s state listener so
  /// chrome surfaces (header-action emphasis, peek hints, …) can
  /// react to a bundle's state without knowing which keys the bundle
  /// declared as authoritative. The map carries the FULL current
  /// state snapshot (every top-level key from `state.initial` plus
  /// anything written since), not just the delta — chrome consumers
  /// pick out what they care about (typically the keys their
  /// emphasisedWhen entries reference).
  void Function(Map<String, Object?> state)? onRuntimeStateChange;

  /// Read-side dual of [onRuntimeStateChange] — returns the latest
  /// cached snapshot of the active tab's runtime state. Wired by the
  /// workspace; consumed by `studio.debug.runtime_state` so an
  /// external LLM can introspect what the active bundle's stateManager
  /// currently holds without a screenshot round-trip.
  Map<String, Object?> Function()? readActiveRuntimeState;

  /// Dispatch a tool call against the active tab's runtime executor —
  /// the same path the bundle's default executor uses for button
  /// clicks, so the response auto-merges into runtime state per spec
  /// §3.10. Returns the raw response map. Consumed by
  /// `studio.debug.dispatch_tool` so an external LLM (or a test
  /// harness) can drive the studio exactly the way a click does:
  /// state writes are observable on `studio.debug.runtime_state`
  /// immediately after the call returns.
  Future<Map<String, dynamic>> Function(
    String tool,
    Map<String, dynamic> params,
  )?
  dispatchActiveRuntimeTool;

  /// Dispatch any **host-level** MCP tool (`studio.*`, `vibe_*`, etc.)
  /// against the studio's own server bootstrap. Used by debug surfaces
  /// (variant inspector, runtime / dispatch log monitors) that need to
  /// poll host instrumentation regardless of which tab is active.
  /// Returns the decoded JSON response of the underlying
  /// `boot.callTool` — `{ok: false, error}` on dispatch failure
  /// so callers do not have to catch.
  Future<Map<String, dynamic>> Function(
    String tool,
    Map<String, dynamic> params,
  )?
  callHostTool;

  /// Register a tab's runtime hooks under [tabKey] so the workspace
  /// can route chrome-bridge calls (`runtimeNavigate`,
  /// `updateRuntimeState`) to the CURRENTLY ACTIVE tab — without this
  /// the slots get last-write-wins overwritten by whichever
  /// `DslWorkspaceView` booted most recently, which silently misroutes
  /// navigation when the user switches tabs. Pass `null` for the
  /// hooks map to unregister (called from `DslWorkspaceView.dispose`).
  void Function(String tabKey, TabRuntimeHooks? hooks)? registerTabRuntime;

  /// Agent id the chat panel is currently bound to (for the active
  /// tab). Home tab and bundles without an explicit
  /// `manifest.chat.agent` declaration default to `studio.manager`.
  /// Listened to by `StandardStudioShell` so the model chip reflects
  /// the active agent's model + the picker writes back via
  /// `studio.agent.set_model`.
  /// Empty at construction — the host's resolver writes the actual
  /// per-tab manager (seed manifest's `role: manager` entry) before
  /// the first chat send. Listeners (chat panel chip, etc.) bind to
  /// this notifier directly; an empty value means "no manager wired".
  final ValueNotifier<String> activeChatAgentId = ValueNotifier<String>('');

  /// Per-operational-unit chat manager override. A built-in that scopes
  /// its chat conversation by an inner unit (App Builder = project,
  /// Scene = scene project) sets this to a unit-qualified manager id
  /// (e.g. `app_builder.manager.<projectId>`) so the chat send routes to
  /// that agent — FlowBrain keys conversations by agentId, so a distinct
  /// id per unit isolates the conversation (no cross-project leak). Null
  /// = use [activeChatAgentId] (the unscoped tab manager). The built-in
  /// clears it to null when its tab deactivates so a sibling tab's chat
  /// isn't routed to this tab's scoped manager.
  final ValueNotifier<String?> chatManagerOverride = ValueNotifier<String?>(
    null,
  );

  /// Tab-key → bundleId map. Filled by `HostBundleActivationContext`
  /// at mount time and read by the host's `_setActiveContext` hook to
  /// resolve the active bundle for `DispatchContext`. Independent of
  /// `BundleActivationRegistry` — the kernel doesn't know which tab
  /// holds which bundle; that's chrome-layer state.
  final Map<String, String> _tabKeyToBundleId = <String, String>{};

  /// Built-in app + host docs seed `.mbd/` paths. Host boot writes the
  /// resolved seed locations here from `StudioApp.seedBundles()`. The
  /// `studio.bundle.*` MCP tools consult this set so external callers
  /// can't bypass the install path: `studio.bundle.list` filters seed
  /// entries out (sees user-installed packages only) and
  /// `studio.bundle.activate` rejects a seed `mbdPath` with a friendly
  /// envelope — built-in apps open via the home picker, never via the
  /// generic activate verb.
  final Set<String> builtInSeedMbdPaths = <String>{};

  /// Close every tab whose path equals [mbdPath]. Mounted by the
  /// workspace so the `studio.bundle.uninstall` handler can cascade
  /// the registry remove into the chrome tab strip — without this the
  /// lifecycle invariant ("tab open ⇒ installed OR seed") breaks the
  /// moment a user uninstalls a package whose tab is still up.
  /// Returns the closed tab keys for the MCP envelope.
  List<String> Function(String mbdPath)? closeTabsByMbdPath;

  /// Bundle-host bridge — owns session lifecycle, Zone-scoped
  /// dispatch, attached-handle bookkeeping. The host sets it once
  /// at MCP boot; consumers (`HostBundleActivationContext` callers,
  /// agent dispatchers, UI mount factories) read it to open / wrap
  /// sessions per bundle activation.
  BundleSessionBridge? sessionBridge;

  void mapTabBundle(String tabKey, String bundleId) {
    _tabKeyToBundleId[tabKey] = bundleId;
  }

  void unmapTabBundle(String tabKey) {
    _tabKeyToBundleId.remove(tabKey);
  }

  String? bundleIdForTab(String? tabKey) {
    if (tabKey == null) return null;
    return _tabKeyToBundleId[tabKey];
  }

  /// Composer slash command hints surfaced as chips in the chat
  /// panel. Hosts update this notifier on tab change + bundle
  /// activation: Home (universal host) → minimal defaults (/help,
  /// /agents, …); activated domain bundle → its
  /// `manifest.chat.slashCommands[]` appended. Standalone domain
  /// builders that don't set this fall through to ChatPanel's
  /// legacy default catalog (see `_kDefaultSlashHints`).
  final ValueNotifier<List<ChatSlashHint>> chatSlashHints =
      ValueNotifier<List<ChatSlashHint>>(const <ChatSlashHint>[]);

  /// Domain-defined icon-button actions appended to [ProjectHeader]'s
  /// Row 2 (and the collapsed [ActivityBar]'s history group). Hosts
  /// flip this on active-tab / editor-mode change to surface
  /// per-bundle verbs (e.g. Import / Export / UI / Tools / Knowledge /
  /// Manifest for Studio Builder bundles). Empty list (default) hides
  /// the slot — Home tab and inert app-mode tabs leave it empty.
  /// Standard shell listens via [ValueListenableBuilder] and merges
  /// with the static [StandardStudioShell.trailing] list (static
  /// first, dynamic after).
  final ValueNotifier<List<HeaderAction>> headerActions =
      ValueNotifier<List<HeaderAction>>(const <HeaderAction>[]);

  /// Resolved titlebar user-zone string for the active tab — the
  /// interpolated form of the bundle's `wiring.titlebar` binding
  /// template (e.g. `"build {{status}}"` → `"build green"`). Empty
  /// string when the active bundle declared no titlebar entry. Hosts
  /// update on tab switch + runtime state change; the titlebar widget
  /// renders this verbatim after the fixed pills (server / status /
  /// version). The package zone is a single payload — splitting +
  /// arrangement is the bundle's responsibility (combine in tool /
  /// binding before assigning).
  final ValueNotifier<String> titlebarText = ValueNotifier<String>('');

  /// Resolved statusbar user-zone string for the active tab — same
  /// pattern as [titlebarText] but rendered inside the bottom
  /// [VibeStatusbar] after the host's fixed status entries.
  final ValueNotifier<String> statusbarText = ValueNotifier<String>('');

  /// Active tab's lint badge counts for the host [VibeStatusbar]. The
  /// active built-in pushes its block/warn totals here; the statusbar
  /// watches and renders the badge. 0/0 = clean (default for tabs with
  /// no lint surface).
  final ValueNotifier<int> lintBlocks = ValueNotifier<int>(0);
  final ValueNotifier<int> lintWarns = ValueNotifier<int>(0);

  /// Click handler for the host statusbar's lint badge — opens the
  /// active built-in's lint modal. Null = badge inert (no active lint
  /// dispatch). Set/cleared by the active tab alongside its other
  /// active-slot handlers ([newProjectInActive] / [runSlashCommandInActive]).
  VoidCallback? onTapLintInActive;

  /// Resolved bundle version label for the active tab (e.g. `1.2.3`).
  /// Empty on Home / non-bundle tabs (falls back to spec version).
  final ValueNotifier<String> bundleVersion = ValueNotifier<String>('');

  /// MCP server URL the active tab attaches to. Reflects per-domain
  /// override (`inheritFromSystem` + `mcpServerUrl`) — when a built-in
  /// or manifest domain runs on a narrow link, this updates to that
  /// URL. Empty on Home / non-bundle tabs (titlebar falls back to the
  /// system URL string passed at boot).
  final ValueNotifier<String> activeMcpUrl = ValueNotifier<String>('');

  /// Identifier of the chrome tab currently selected. DslWorkspaceView
  /// watches this so an inactive tab's runtime stops calling
  /// `runtime.buildUI()` — without that gate two `application`-typed
  /// bundles alive in different tabs both reach for the same
  /// `NavigationService.instance.navigatorKey` (process singleton on
  /// the `vibe_studio_runtime` fork) and Flutter reparents the
  /// Navigator from one to the other (visible "tab content vanishes"
  /// regression). Mirrors AppPlayer's "one buildWidget at a time"
  /// lifecycle pattern. Workspace pushes this on every tab select,
  /// close, and reorder.
  final ValueNotifier<String?> activeTabKey = ValueNotifier<String?>(null);

  /// Tracks the studio's "debug mode" — when true every
  /// `DslWorkspaceView` mounts its bundle through
  /// `MCPUIRuntime.withInspector(widgetWrapper:)` so every rendered
  /// widget gets a hit-test-tagged MetaData wrapper. Off by default
  /// (production fast path). The Settings dialog flips this through
  /// `VibeSettings.debugMode`; host boot wires the initial value and
  /// the dialog `Save` handler pushes updates here.
  final ValueNotifier<bool> inspectorEnabled = ValueNotifier<bool>(false);

  /// Bumped whenever a workspace tab's runtime is destroyed (close
  /// path's `_runtime.destroy()` → process-singleton
  /// `ThemeManager.instance.reset()`). Surviving tabs whose
  /// brightness/theme would otherwise revert to the default Blue-indigo
  /// seed listen for the bump and re-inject their merged theme. The
  /// `activeTabKey` swap-edge already covers the case where closing
  /// the active tab moves focus elsewhere; this tick covers the
  /// **inactive close** case (active stays, but the destroyed tab
  /// wiped the singleton out from under it).
  final ValueNotifier<int> themeReinjectTick = ValueNotifier<int>(0);

  /// Transient hover-reveal flag. When the strip is hidden
  /// (`tabBarVisible == false`) the titlebar / strip set this true on
  /// mouse-enter so the host can render the strip as an overlay. A
  /// short delay on peek-out prevents flicker when the cursor moves
  /// between the titlebar and the revealed strip.
  final ValueNotifier<bool> tabBarPeek = ValueNotifier<bool>(false);

  /// Internal-call context flag. `false` (default) = external dispatch
  /// path (outside LLM via MCP) — calls to tools marked as **internal**
  /// (currently `studio.chrome.create_package`, `studio.bundle.install`,
  /// `studio.bundle.activate`, `studio.bundle.uninstall`) reject with
  /// an error response. `true` = internal context (UI tap on the same
  /// `ChromeBridge` slot, or a scenario whose `internal: true` metadata
  /// asked the engine to wrap its run) — the same handlers proceed
  /// normally. The flag is process-local; the host's
  /// [withInternalCalls] helper flips it for the duration of one body
  /// and always restores the previous value (nested wraps stay sane).
  ///
  /// UI tap path is naturally exempt because the chrome buttons call
  /// the bridge slot directly (`bridge.createNewPackage(...)`,
  /// `bridge.activatePackage(...)`, etc.) without going through the
  /// MCP handler, so the guard never runs on a user click.
  bool internalCallsEnabled = false;

  /// Run [body] with [internalCallsEnabled] forced true for its
  /// duration, then restore the previous value (so nested wraps don't
  /// leak `true` back out). Use this around any code path that needs
  /// to dispatch internal MCP tools through `boot.callTool` —
  /// the scenario engine wraps internal scenarios this way, and any
  /// future host-internal automation should do the same.
  Future<T> withInternalCalls<T>(Future<T> Function() body) async {
    final prev = internalCallsEnabled;
    internalCallsEnabled = true;
    try {
      return await body();
    } finally {
      internalCallsEnabled = prev;
    }
  }

  /// Tools-mode sub-tab — `'tool'` / `'domain'` / `'slash'` / `'section'`.
  /// Bound to `BundleToolsView` via `ValueListenableBuilder` so any
  /// caller can flip the sub-tab without reaching into the view's
  /// private state. The universal renderer activator
  /// (`studio.renderer.activate(target: 'tools/<kind>')`) writes here;
  /// the user clicking a top-tab pill also writes here so MCP `current`
  /// queries see the same value the user sees.
  final ValueNotifier<String> toolsSubTab = ValueNotifier<String>('tool');

  /// Universal renderer activator — single entry point to surface any
  /// view in the studio. `target` is a path-like string:
  ///   - `tools/<kind>` — Tools-mode sub-tab (tool/domain/slash/section)
  ///   - `home` — Home tab
  ///   - `bundle/<path>` — switch to (or open) a bundle tab
  ///   - `<mbdNs>/<screen>` — domain DSL screen (Phase 2)
  /// Returns `{ok, target, ...}` so the MCP handler can echo a
  /// structured result. Unknown targets return `{ok: false,
  /// reason: 'unknown-target'}`. The host wires the implementation;
  /// LLM-driven MCP calls and chrome buttons go through the same
  /// entry so the "tool → view" + "view → tool" loops stay symmetric.
  /// args: optional structured arguments tied to the target — e.g.
  /// `project/new` takes `{name, parent}`; `project/open` takes `{path}`.
  /// Targets that don't need args ignore the value. Lets the LLM
  /// drive lifecycle paths that previously required separate MCP
  /// tools through the same single `activate` verb.
  Map<String, dynamic> Function(String target, [Map<String, dynamic>? args])?
  activateView;

  /// Inverse of [activateView] — return a description of the view the
  /// user is currently looking at, using the same path-like scheme.
  /// MCP `studio.renderer.current_view` calls this. Lets the LLM read
  /// → decide → switch → read in a tight loop. Unset (shell not
  /// mounted) → handler reports `{target: 'unknown', reason: ...}`.
  Map<String, dynamic> Function()? currentViewTarget;

  /// Walk the currently visible view's render tree and return one entry
  /// per `MetaData(metaData: {...})` widget: `{type, depth, rect [x,y,
  /// w,h], font?, box?, padding?}`. Lets the MCP-driven LLM read what
  /// the user actually sees without paying for a vision model — much
  /// more accurate than image OCR for layout questions ("is the button
  /// inside the row", "is the title bigger than the body"). Pattern
  /// borrowed from vibe_app_builder's `vibe_layout_snapshot`. Unset
  /// (shell not mounted) → handler reports `{nodes: [], reason}`.
  Future<List<Map<String, dynamic>>?> Function()? captureLayoutSnapshot;

  /// Root key for `studio.renderer.layout_snapshot` — the host walks
  /// the render tree from this key's RenderObject so chrome surfaces
  /// (titlebar / statusbar / activity_bar / project_header) live in
  /// the snapshot, not just the centre body. Standard shell wires
  /// this on mount; hosts that render a custom shell can set it too.
  /// Unset → the snapshot falls back to the host's centre-body root.
  GlobalKey? captureRootKey;

  /// Synchronous element-rect lookup driven by the same MetaData walk
  /// as `captureLayoutSnapshot`. Used by the `OverlayLayer` so an
  /// overlay's `target:{element:"id"}` resolves to a live rect every
  /// paint without forcing the painter onto an async path. `elementId`
  /// uses `<kind>:<key>` form (e.g. `"tool:addTool"`,
  /// `"meta:counter-btn"`). Unset (shell not mounted yet) → null.
  Rect? Function(String elementId)? resolveElementRect;

  /// Capture a PNG screenshot of the shell's RepaintBoundary root.
  /// Returns raw PNG bytes that the caller base64-encodes for transport.
  /// `pixelRatio` controls the rendered density — 1.0 is logical pixels,
  /// 2.0 doubles for retina. `area` (in logical pixels, relative to the
  /// shell root) crops the result via `PictureRecorder.drawImageRect`
  /// — null = full window. Unset (shell not mounted) → null. Pure
  /// Flutter `RepaintBoundary.toImage` — no OS shell commands, no
  /// external tool dependencies, works on every platform Flutter runs.
  Future<Uint8List?> Function({double pixelRatio, Rect? area})?
  captureScreenshot;

  /// Drop a user turn into the chat feed and (optionally) wait for the
  /// agent reply. `tabKey` selects the chat — `null` / `'home'` lands
  /// on the active tab's chat. The chat-automation primitive for
  /// `studio.chat.send` MCP tool. Returns a `Map` with `tabKey`,
  /// `agentId`, and (when `waitForReply: true`) the reply text. Unset
  /// (no shell) → handler reports `sendChat-not-wired`.
  Future<Map<String, dynamic>> Function({
    String? tabKey,
    required String text,
    bool waitForReply,
  })?
  sendChat;

  /// Show a transient toast / snackbar with [message]. Optional
  /// [severity] — `'info'` (default) / `'success'` / `'warning'` /
  /// `'error'`. Bundles reach this through `host.ui.notify` (Phase
  /// 5.6+ atom). When the slot is unset (host hasn't wired a
  /// snackbar) the call is a silent no-op so bundle JS doesn't crash
  /// during early activation / headless tests.
  ///
  /// Implemented as getter/setter (not a plain field) so every call
  /// also lands in [_notifyLog] regardless of who wired the sink —
  /// external LLM debugging then surfaces transient errors through
  /// `studio.debug.notify_log` even after the snackbar fades.
  void Function(String message, {String? severity})? _notifySink;
  void Function(String message, {String? severity})? get notify {
    if (_notifySink == null) return null;
    return _notifyDispatch;
  }

  set notify(void Function(String message, {String? severity})? v) {
    _notifySink = v;
  }

  final List<Map<String, Object?>> _notifyLog = <Map<String, Object?>>[];
  void _notifyDispatch(String message, {String? severity}) {
    _notifyLog.add(<String, Object?>{
      'ts': DateTime.now().toUtc().toIso8601String(),
      'message': message,
      if (severity != null) 'severity': severity,
    });
    if (_notifyLog.length > 100) _notifyLog.removeAt(0);
    _notifySink?.call(message, severity: severity);
  }

  /// Snapshot of the most recent (up to 100) notify calls — for debug
  /// tools that surface transient errors / warnings the user may have
  /// missed (toast fades after a few seconds).
  List<Map<String, Object?>> get notifyLog =>
      List<Map<String, Object?>>.unmodifiable(_notifyLog);

  /// Show a modal informational dialog with [title] / [body]. Resolves
  /// when the user dismisses it. Bundles reach this through
  /// `host.ui.dialog`. Unset = silent no-op (resolves immediately
  /// with `false`).
  Future<bool> Function({required String title, required String body})? dialog;

  /// Show a yes / no confirmation prompt — `[question]` is the body,
  /// `[options]` is the labels (defaults to `['Cancel', 'OK']`).
  /// Resolves with the chosen index, or `-1` on dismiss / when the
  /// slot is unset. Bundles reach this through `host.ui.prompt`.
  Future<int> Function({required String question, List<String>? options})?
  prompt;

  /// Generic lifecycle dispatcher. Chrome surfaces (Home buttons,
  /// Domain toolbars, Tools-mode sub-tab actions) call this with a
  /// conceptual [slot] id (e.g. `'project.new'`, `'project.save'`,
  /// `'project.export'`). The host resolves the slot against the
  /// active bundle's `manifest.wiring.lifecycle[]` and dispatches to
  /// the wired tool. Unset / no wiring for the slot → return
  /// `{ok: false, error: 'not wired'}` so the caller can disable the
  /// surface UI affordance ("registered = exists" principle).
  Future<Map<String, Object?>> Function(String slot, Map<String, dynamic> args)?
  dispatchLifecycle;

  /// Push a flat key/value map into the active DSL runtime's state
  /// tree. Mounted by `DslWorkspaceView` after `MCPUIRuntime` is
  /// initialised. Used for non-navigation state push (e.g.,
  /// `currentProject` after adopting a project). Null when no DSL
  /// workspace is currently mounted.
  void Function(Map<String, dynamic> state)? updateRuntimeState;

  /// Trigger a navigation `push` on the active DSL runtime to the
  /// given route (e.g. `'/tools'`). Mounted by `DslWorkspaceView`
  /// after the runtime is initialised. Used by the
  /// `studio.nav.go({pageId})` primitive so domain wiring (chrome
  /// row 2 icons, external LLM, seed DSL widgets) all funnel into
  /// runtime-native navigation. Null when no DSL workspace is
  /// mounted.
  bool Function(String route)? runtimeNavigate;

  Timer? _peekClearTimer;

  void peekIn() {
    _peekClearTimer?.cancel();
    if (!tabBarPeek.value) tabBarPeek.value = true;
  }

  void peekOut() {
    _peekClearTimer?.cancel();
    _peekClearTimer = Timer(const Duration(milliseconds: 200), () {
      tabBarPeek.value = false;
    });
  }
}

/// Per-tab hooks exposed by a `DslWorkspaceView` so the workspace can
/// route chrome-bridge actions to the currently active tab's runtime.
/// Stops the last-write-wins overwrite problem when several
/// `DslWorkspaceView` instances are alive (one per tab + nested
/// embeds).
class TabRuntimeHooks {
  TabRuntimeHooks({
    required this.navigate,
    required this.updateState,
    required this.readState,
    this.dispatchTool,
  });

  /// Push a route into the tab's runtime (sets `currentRoute` etc.).
  final bool Function(String route) navigate;

  /// Apply a partial state map to the tab's runtime.
  final void Function(Map<String, dynamic> state) updateState;

  /// Read the tab's runtime state snapshot.
  final Map<String, Object?> Function() readState;

  /// Dispatch a tool call through the same default executor the
  /// bundle DSL uses for button clicks. Returns the parsed JSON
  /// response. Side-effect: spec §3.10 auto-merge writes the
  /// response's top-level keys into [readState].
  final Future<Map<String, dynamic>> Function(
    String tool,
    Map<String, dynamic> params,
  )?
  dispatchTool;
}

/// Inherited signal that tells a workspace bundle body whether it owns
/// the foreground tab. `DslWorkspaceView` reads this in `build` and
/// skips `MCPUIRuntime.buildUI()` when inactive — `flutter_mcp_ui_runtime`
/// hard-codes `NavigationService.instance.navigatorKey` (a process
/// singleton), so two runtime widgets in the tree at the same time
/// fight over the same `GlobalKey<NavigatorState>` and Flutter
/// reparents the Navigator from one tab to the other (visible black
/// canvas / swapped contents). Only the active tab attaches the
/// runtime; the inactive tabs' `State` (including the runtime
/// instance) stays alive in the workspace's IndexedStack so the
/// runtime is reused on re-activation. Built-in app mounts (e.g.
/// `_AppBuilderMount`) live on the namespace-forked
/// `vibe_studio_runtime` whose singleton is independent and ignore
/// this scope.
class WorkspaceTabActiveScope extends InheritedWidget {
  const WorkspaceTabActiveScope({
    super.key,
    required this.active,
    required super.child,
  });

  final bool active;

  static bool isActiveOf(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<WorkspaceTabActiveScope>();
    // Default to active when no scope is present so callers that mount
    // outside the workspace tab stack (tests, embedded previews) stay
    // unaffected — the gate only kicks in when the workspace wraps the
    // child with `active: false`.
    return scope?.active ?? true;
  }

  @override
  bool updateShouldNotify(WorkspaceTabActiveScope old) => old.active != active;
}
