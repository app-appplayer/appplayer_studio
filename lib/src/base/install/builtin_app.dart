import 'package:flutter/widgets.dart';

// Import the concrete base source files directly (not the `base.dart`
// barrel) — this file lives inside `base/` and is itself re-exported by
// `base.dart`, so importing the barrel here would create an import cycle
// (base.dart -> builtin_app.dart -> base.dart).
import 'builtin_tool_registry.dart' show BuiltinToolRegistry;
import '../boot/studio_backbone.dart' show StudioBackbone;
import '../shell/project_header.dart' show HeaderAction;
import '../main/studio_workspace.dart' show BuiltInLauncher;
import '../main/chrome_bridge.dart' show ChromeBridge, DomainLifecycleState;
import '../settings/settings_dialog.dart'
    show DomainSettingsPanel, ProjectKindOption;

export '../main/studio_workspace.dart' show BuiltInLauncher;

/// Slash command surfaced through the host chat composer's `/` chip.
/// Mirrors the `chat.slashCommands[]` manifest entries that the
/// manifest-driven domains use; built-in apps return the same shape
/// from [BuiltInApp.slashCommands] so the host can render both kinds
/// through one path.
class SlashCommandSpec {
  const SlashCommandSpec({
    required this.command,
    this.template,
    this.tool,
    this.toolArgs = const <String, dynamic>{},
    this.description,
  });

  /// Trigger text the user types (with the leading slash) — e.g. `/build`.
  final String command;

  /// Optional template that is inserted into the composer when the
  /// chip is picked. Used when the command needs the user to fill in
  /// arguments before sending.
  final String? template;

  /// Optional tool that fires directly on chip select (LLM bypass).
  /// When both [template] and [tool] are set the host prefers the
  /// tool path; the template becomes a hint.
  final String? tool;

  /// Arguments passed to [tool] when it fires directly.
  final Map<String, dynamic> toolArgs;

  /// Short description shown in the chip menu.
  final String? description;
}

/// Lifecycle slot names the host chrome fires through
/// `dispatchLifecycleSlot`. Built-in apps return a function for each
/// slot they want to handle through [BuiltInApp.lifecycleBindings];
/// any slot not present in the map falls through to the manifest path
/// (no-op when manifest absent). Names mirror
/// `wiring.lifecycle[].slot` in studio_builder's manifest so the host
/// keeps one set of slot constants across both kinds of domain.
abstract class LifecycleSlots {
  static const String projectNew = 'project.new';
  static const String projectOpen = 'project.open';
  static const String projectSave = 'project.save';
  static const String projectSaveAs = 'project.saveAs';
  static const String projectRevert = 'project.revert';
  static const String projectClose = 'project.close';
  static const String projectRename = 'project.rename';
  static const String projectExport = 'project.export';
  static const String projectImport = 'project.import';
  static const String historyShow = 'history.show';
  static const String editUndo = 'edit.undo';
  static const String editRedo = 'edit.redo';
  static const String build = 'build.run';
  static const String buildClean = 'build.clean';
  static const String buildSettings = 'build.settings';
  static const String manageAssets = 'assets.manage';
  static const String compareChannels = 'channels.compare';
  static const String settingsShow = 'settings.show';
}

/// Lifecycle binding payload — either a synchronous void function or
/// an async one with arguments. Most built-in slots take no args.
typedef LifecycleHandler = Future<void> Function(BuildContext context);

/// Live handle a mounted built-in app publishes to the registry so the
/// host wiring can reach the app's 4-axis hooks without taking a
/// dependency on the app's widget state. The mount widget creates a
/// [BuiltInAppContext] in initState, assigns the four `*Provider`
/// callbacks (which close over the mount's [State]), then calls
/// [BuiltInAppRegistry.setActive]. On dispose it calls
/// [BuiltInAppRegistry.clearActive] so the providers can no longer
/// fire against a dead state.
///
/// Host wiring reads `BuiltInAppRegistry.instance.activeContext` and
/// invokes whichever providers it needs — `null` means "this axis is
/// not contributed; fall back to the manifest path".
class BuiltInAppContext {
  BuiltInAppContext({
    required this.bundlePath,
    required this.chromeBridge,
    this.inheritedSettings = const <String, Object?>{},
    this.overridesFile = '',
  });

  final String bundlePath;
  final ChromeBridge chromeBridge;

  /// Studio-wide settings snapshot the host passes in at mount time
  /// (e.g. `workspaceDir`, `mcpServerUrl`). Built-in apps use this as
  /// the default value for their domain settings fields — same path
  /// `readManifestSettingsSections` takes for manifest-driven domains
  /// via `loadInheritedSettings(toolId)`. The map is read-only; user
  /// overrides land in [overridesFile], never here.
  final Map<String, Object?> inheritedSettings;

  /// Per-package overrides JSON path the host derives from
  /// `packageOverridesFile(configRoot, pkgPath)`. Passed straight
  /// through to [ManifestFieldList] so per-domain edits persist
  /// independently of the host-wide settings file.
  final String overridesFile;

  /// Row 2 domain icons. Mirrors `wiring.domainActions[]`.
  List<HeaderAction>? Function()? headerActionsProvider;

  /// Project / dirty / undo snapshot the chrome's ProjectHeader
  /// renders. Same code path as [headerActionsProvider] — host wiring
  /// reads through [ChromeBridge.lifecycleStateResolver]; manifest
  /// domains do not implement this provider (they don't carry a
  /// project) so the resolver returns null for them and the chrome
  /// falls back to the empty default (`bundleName` becomes the title).
  DomainLifecycleState? Function()? lifecycleStateProvider;

  /// System area buttons (Row 1 / Row 2 chrome slots). Mirrors
  /// `wiring.lifecycle[]`. Map key is a `LifecycleSlots.*` constant.
  Map<String, LifecycleHandler>? Function()? lifecycleBindingsProvider;

  /// Settings dialog domain panel. Mirrors `settings.sections[]` +
  /// `wiring.settings[]`.
  DomainSettingsPanel? Function()? domainSettingsProvider;

  /// Composer slash chips. Mirrors `chat.slashCommands[]`.
  List<SlashCommandSpec>? Function()? slashCommandsProvider;

  /// Project kinds this built-in can scaffold (e.g. App Builder's
  /// "AppPlayer App" vs "Studio Package"). The host's standard new-project
  /// dialog renders a kind selector from this list and forwards the chosen
  /// [ProjectKindOption.id] to the built-in's scaffolder — so the *domain*
  /// owns the kind list while the *platform* owns the dialog. Empty/null =
  /// no selector (single-kind create). Mirrors a future
  /// `manifest.projectKinds[]`.
  List<ProjectKindOption>? Function()? projectKindsProvider;

  /// In-process MCP server bootstrap the mount uses to register its
  /// built-in tools (vibe_*, etc). Set by the mount during initState.
  /// Host-level passthrough tools (e.g. `app_builder.dispatch_tool`)
  /// read this to dispatch into the active mount's tool surface via
  // `builderBoot` field retired in the builtin-os-cleanup round
  // (2026-05-28). The inner-MCP `dispatch_builder_tool` passthrough is
  // gone — `vibe_*` tools register on the host endpoint directly.
  // Field kept as `dynamic` for any lingering test scaffolding that
  // hasn't migrated yet.
  /// Retained for backwards compatibility — value is always `null` in
  /// the post-cleanup wiring. Reference left so legacy code doesn't
  /// trip on `ctx.builderBoot = ...` assignments during the migration.
  /// `dynamic` so different built-ins can hold different bootstrap
  /// classes (app_builder uses its own `ServerBootstrap`, others may
  /// use `mk.KernelServerHost`) without coupling this file to any one
  /// implementation. Null when the built-in does not stand up its own
  /// boot.
  dynamic builderBoot;
}

/// Contract every built-in app implements so the host can mount them
/// through a single bundleBodyBuilder branch instead of hard-coding
/// per-app `if (...)` switches. New built-in apps register a
/// [BuiltInApp] in [BuiltInAppRegistry] and the host picks the first
/// one whose [canHandle] matches the target bundle path.
///
/// The 4-axis hooks ([headerActions], [lifecycleBindings],
/// [domainSettings], [slashCommands]) let the app surface its actions
/// through the same host chrome paths the manifest-driven domains use
/// (`wiring.domainActions[]`, `wiring.lifecycle[]`, `settings.sections[]`,
/// `chat.slashCommands[]`). See `docs/builtin_apps/INTEGRATION.md`.
///
/// Hooks return null when the app has nothing to contribute for that
/// axis — the host then falls back to the manifest path (no-op when
/// no manifest), matching the "manifest absent ≡ silent" rule of the
/// studio_builder runtime model.
abstract class BuiltInApp {
  const BuiltInApp();

  /// Stable id used for logs / preferences. Lower-snake_case.
  String get id;

  /// Human-readable label — used in titlebar / chrome metadata so the
  /// host can show "App Builder" instead of the bundle path.
  String get label;

  /// Returns `true` when this app should own the body for [bundlePath].
  /// Implementations should be cheap (sync filesystem checks at most).
  bool canHandle(String bundlePath);

  /// Builds the body widget. The host passes everything the app needs
  /// to plug into vibe_studio's chrome + kernel without standing up a
  /// parallel lifecycle.
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
  });

  // The 4-axis hooks live on [BuiltInAppContext] (set by the mount
  // widget) rather than on [BuiltInApp] so the providers can close
  // over the mount's State without leaking it through this interface.

  /// Home-picker launcher card descriptor. Surfaced inside
  /// [StudioWorkspace]'s BUILT-IN APPS section so users have a
  /// click-target to activate the app without going through the
  /// install registry. Implementations typically (1) ensure the app's
  /// marker dir / file exists on disk inside the host's workspace
  /// directory, then (2) ask the chrome bridge to open that path in
  /// the active tab (so `bundleBodyBuilder` lands on [canHandle] and
  /// then [mount]).
  BuiltInLauncher launcher(ChromeBridge chromeBridge, String workspaceDir);

  /// Code-channel knowledge sources the host registers on boot —
  /// alternative to the seed `manifest.knowledge.sources[]` path.
  /// Apps using a seed mbd return an empty list (host's
  /// `_fanOutSeedKnowledgeAsResources` picks them up through the seed
  /// path); apps that prefer a packaged file return the same shape
  /// the manifest uses:
  /// `[{id, title, description, documents: [{id, title, source, content}]}]`.
  /// Implementations typically load a JSON asset packaged inside the
  /// app's dart package (`rootBundle.loadString(...)`). Both channels
  /// feed the same host registry — sources from either land at
  /// `studio://knowledge/<sourceId>/<docId>`.
  Future<List<Map<String, dynamic>>> knowledgeSources() async =>
      const <Map<String, dynamic>>[];

  /// Register the built-in's MCP tools on the host server. Built-in
  /// apps don't ship JS — their tool implementations live in Dart
  /// alongside the Flutter shell. The host invokes this once at boot
  /// (after the MCP server bootstrap exists). Default = no tools;
  /// apps that expose verbs (newProject / convert / build / …) override.
  ///
  /// Per `studio-builder-runtime-model.md §8.5`, every button / action
  /// is a 1:1 MCP tool. Dialog vs headless is discriminated by the
  /// tool's `inputSchema` (named optional args present = programmatic,
  /// absent = open the dialog).
  Future<void> registerHostTools(
    BuiltinToolRegistry server,
    ChromeBridge chromeBridge, {
    StudioBackbone? backbone,
  }) async {}
}

/// Mutable list the host queries on every bundleBodyBuilder call.
/// Kept in apps so new built-in apps register themselves alongside
/// their implementation without reaching into the host package.
///
/// The registry also tracks the currently-active built-in app
/// instance context (set by the app's mount widget in initState,
/// cleared on dispose). Host wiring (`_resolveDomainPanel`,
/// `_syncHeaderActions`, `dispatchLifecycleSlot`) reads the active
/// context to invoke the right hook.
class BuiltInAppRegistry {
  BuiltInAppRegistry._();

  static final BuiltInAppRegistry instance = BuiltInAppRegistry._();

  final List<BuiltInApp> _apps = <BuiltInApp>[];
  // Per-tab mount table keyed by bundle path. A built-in lives in
  // exactly one tab — its mount widget owns the entry through
  // [mount] / [unmount] (initState / dispose). The single `_activeApp`
  // / `_activeContext` getters resolve through `_activePath`, so chrome
  // wiring only sees the built-in that owns the current tab. Without
  // this, switching tabs while a built-in stays mounted left its
  // context "active" and the host chrome showed its actions/slash
  // hints over an unrelated tab.
  final Map<String, _MountEntry> _mounted = <String, _MountEntry>{};
  // `_activePath` resolves [activeContext] — only paths that are
  // currently mounted are valid here. `_intendedActivePath` records
  // the path the host last asked us to make active even when that
  // path's mount entry hasn't shown up yet (the host fires
  // `setActivePath` from `_setActiveContext` *before* the new tab
  // body builds, so its mount widget hasn't called [mount] yet).
  // When the matching mount lands later, [mount] promotes the
  // intent to `_activePath`. Without this two-slot split, mount()
  // would have to either:
  //   (a) auto-set its own path → races with [setActivePath] when a
  //       background tab's State is briefly disposed/remounted
  //       (Flutter GlobalKey reparenting), wrongly stealing focus,
  //       or (b) ignore the intent → first-launch tabs stay
  //       "no active context".
  String? _activePath;
  String? _intendedActivePath;

  /// Snapshot list — iterated by the host on mount lookup.
  List<BuiltInApp> get apps => List.unmodifiable(_apps);

  /// Register a built-in app. Idempotent on [BuiltInApp.id] — calling
  /// twice with the same id replaces the previous entry so a hot
  /// reload that re-runs the registration code doesn't accumulate
  /// duplicates.
  void register(BuiltInApp app) {
    _apps.removeWhere((existing) => existing.id == app.id);
    _apps.add(app);
  }

  /// Returns the first registered app whose [BuiltInApp.canHandle]
  /// matches [bundlePath], or null when none does.
  BuiltInApp? matchFor(String bundlePath) {
    for (final app in _apps) {
      if (app.canHandle(bundlePath)) return app;
    }
    return null;
  }

  /// Currently-active built-in app instance + its mount context, or
  /// null when the active tab is not built-in. Active tab is tracked
  /// via [setActivePath] (called from the host's `_setActiveContext`),
  /// so chrome surfaces match the visible tab — not the most recently
  /// mounted built-in.
  BuiltInApp? get activeApp =>
      _activePath == null ? null : _mounted[_activePath]?.app;
  BuiltInAppContext? get activeContext =>
      _activePath == null ? null : _mounted[_activePath]?.ctx;

  /// Notifier the host listens to so it can refresh chrome surfaces
  /// when the active built-in changes (mount / dispose / tab swap) or
  /// when the active app bumps its own revision after an internal
  /// state change that affects a hook (e.g. dirty bit flipping Save).
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Register the [app] / [context] for the tab whose bundle path is
  /// [bundlePath]. Called from the mount widget's `initState`.
  /// Idempotent — re-mounting the same path replaces the entry (hot
  /// reload or GlobalKey re-attach).
  ///
  /// Only promotes [bundlePath] to [_activePath] when the host had
  /// previously asked for it via [setActivePath]. Without that guard
  /// a background tab whose State briefly disposes / remounts
  /// (Flutter's GlobalKey reparenting under tree corruption) would
  /// silently steal focus from whichever tab the user is actually on.
  void mount(String bundlePath, BuiltInApp app, BuiltInAppContext context) {
    _mounted[bundlePath] = _MountEntry(app, context);
    if (_intendedActivePath == bundlePath) {
      _activePath = bundlePath;
    }
    revision.value = revision.value + 1;
  }

  /// Drop the mount entry for [bundlePath]. Called from the mount
  /// widget's `dispose`. Clears [_activePath] when it pointed at the
  /// removed entry so stale state doesn't leak into the next read.
  void unmount(String bundlePath) {
    final removed = _mounted.remove(bundlePath);
    if (removed == null) return;
    if (_activePath == bundlePath) _activePath = null;
    revision.value = revision.value + 1;
  }

  /// Point the registry at the tab the host just made active. Passes
  /// null when the active tab is not a built-in (or no tab is active)
  /// — the chrome resolvers see `activeContext == null` and skip the
  /// built-in path entirely instead of leaking the previous tab's
  /// hooks.
  ///
  /// Always stamps [_intendedActivePath] so a later [mount] call for
  /// the same path can promote it once its entry lands. `_activePath`
  /// itself only flips to non-null when the path is already mounted.
  void setActivePath(String? bundlePath) {
    _intendedActivePath = bundlePath;
    final next =
        (bundlePath != null && _mounted.containsKey(bundlePath))
            ? bundlePath
            : null;
    if (_activePath == next) return;
    _activePath = next;
    revision.value = revision.value + 1;
  }

  /// Bump the revision so the host re-evaluates hooks. Used by the
  /// active mount when shell-internal state changes (dirty / undo /
  /// project meta) that the hooks consume.
  void bumpRevision() {
    revision.value = revision.value + 1;
  }
}

class _MountEntry {
  const _MountEntry(this.app, this.ctx);
  final BuiltInApp app;
  final BuiltInAppContext ctx;
}
