/// `StudioWorkspace` — centre-pane widget every universal-host studio
/// mounts inside [StandardStudioShell]. Chrome (Titlebar / ProjectHeader
/// / ChatPanel / Statusbar) is wired by the standard shell in base; this
/// widget owns the tab strip, package picker (home), and per-bundle body.
///
/// Lifted from `vibe_studio` host so future studio hosts share the same
/// tab model + activation flow. The bundle UI body (the only part that
/// needs a workspace-aware renderer) is supplied by the caller through
/// [StudioWorkspace.bundleBodyBuilder] so base stays free of
/// `vibe_studio_workspace` (and any other domain renderer) dependencies.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:brain_kernel/mcp_host.dart' as mh;
import 'package:appplayer_studio/ui.dart';

import '../agent/agent_host.dart';
import '../agent/agent_profile.dart';
import '../agent/seed_chat_manager.dart';
import '../chat/chat_slash_hint.dart';
import '../chat/chat_turn.dart';
import '../chat/chat_controller.dart';
import '../install/bundle_loading.dart';
import '../runtime/vbu_widgets.dart' show resolveIconName;
import 'bundle_install_surface.dart';
import '../install/host_bundle_activation.dart';
import '../settings/settings_dialog.dart';
import '../shell/inspect_tag.dart';
import '../shell/package_welcome_panel.dart';
import '../shell/project_header.dart';
import 'chrome_bridge.dart';
import 'domain_actions_reader.dart';
import 'lifecycle_dispatcher.dart';
import 'studio_tab.dart';

/// Read `manifest.name` from the package at [mbdPath]. Returns null
/// when the manifest is missing/unreadable so callers can fall back
/// to a host-side label (registry namespace etc.).
///
/// Top-level so both the in-widget tab/picker code and the MCP tool
/// handlers can enrich entries without crossing widget-state lines.
/// Resolution: `manifest.name` → last dotted segment of `manifest.id`
/// → null.
String? readFriendlyLabel(String mbdPath) {
  try {
    final file = File(p.join(mbdPath, 'manifest.json'));
    if (!file.existsSync()) return null;
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! Map<String, dynamic>) return null;
    final manifest = (raw['manifest'] as Map<String, dynamic>?) ?? raw;
    final name = (manifest['name'] as String?)?.trim();
    if (name != null && name.isNotEmpty) return name;
    final id = (manifest['id'] as String?)?.trim();
    if (id != null && id.isNotEmpty) {
      final dot = id.lastIndexOf('.');
      return dot >= 0 ? id.substring(dot + 1) : id;
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// Centre-pane only — chrome (Titlebar / ProjectHeader / ChatPanel /
/// Statusbar) is wired by [StandardStudioShell] in base. Holds either
/// the bundle picker (welcome) or the activated bundle body supplied by
/// [bundleBodyBuilder].
/// Launcher card for a built-in app exposed in the home picker's
/// "BUILT-IN APPS" section. The host owns the list (typically by
/// reading the apps-area `BuiltInAppRegistry`) and hands it to
/// [StudioWorkspace] so base stays unaware of the apps area.
class BuiltInLauncher {
  const BuiltInLauncher({
    required this.id,
    required this.label,
    required this.iconName,
    required this.launchPath,
    required this.onLaunch,
  });

  /// Stable id (`'app_builder'`) — used for tile keys / preferences.
  final String id;

  /// Display label on the card (`'App Builder'`).
  final String label;

  /// Material icon name resolved via `materialIconByName(...)` —
  /// rendered on the tile. Matches the manifest `wiring.domainActions`
  /// icon vocabulary so launcher tiles stay visually consistent with
  /// the manifest-driven home picker entries.
  final String iconName;

  /// Filesystem path the host activates as a new tab once [onLaunch]
  /// settles. The home picker uses the same activation surface as
  /// installed packages (`_openPackage`) so the path lands as a
  /// regular tab and `bundleBodyBuilder` resolves through
  /// `BuiltInApp.canHandle` → `mount`.
  final String launchPath;

  /// Fired before the host activates [launchPath]. Implementations
  /// ensure the marker dir / file exists on disk so `canHandle`
  /// recognises the path.
  final Future<void> Function() onLaunch;
}

/// A Home-grid entry contributed by a host extension (e.g. the pro tier's
/// marketplace). Rendered as a tile next to the built-in apps; tapping it
/// runs [onTap] (opening an overlay etc.) instead of activating a bundle.
class HomeExtensionEntry {
  const HomeExtensionEntry({
    required this.label,
    required this.icon,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final void Function() onTap;
}

class StudioWorkspace extends StatefulWidget {
  const StudioWorkspace({
    super.key,
    required this.bundles,
    required this.chromeBridge,
    required this.configRoot,
    required this.boot,
    required this.domainStorage,
    required this.onActiveContextChanged,
    required this.chatForKey,
    required this.bundleBodyBuilder,
    required this.seedPathByNamespace,
    this.builtInLaunchers = const <BuiltInLauncher>[],
    this.extensionEntries = const <HomeExtensionEntry>[],
  });

  final BundleInstallSurface bundles;
  final ChromeBridge chromeBridge;
  final String configRoot;

  /// MCP server bootstrap — passed in so the centre's activation
  /// lifecycle can register / unregister bundle tools without
  /// reaching back into the host.
  final mk.KernelServerHost boot;

  /// Per-domain durable storage shared across every activation. Each
  /// bundle's activation context wires its own `manifest.id` as the
  /// namespace so domains can't see each other's state.
  final mk.DomainStorage domainStorage;

  /// Notified whenever the user switches tabs or opens / closes a
  /// project inside the active tab. Both args are null for the home
  /// context; `pkgPath` non-null + `projectPath` null = State B
  /// (package active, project welcome); both non-null = workspace.
  final void Function(String? pkgPath, String? projectPath)
  onActiveContextChanged;

  /// Resolve the chat controller for a given tab key. Wired to the
  /// host's `_chatFor(key)` so `appendChatTurn` can push trace turns
  /// into the active thread without exposing the controller map.
  final VibeChatController Function(String key) chatForKey;

  /// Render the body for a bundle UI tab. The workspace keeps the
  /// `vibe_studio_workspace` (or any other domain renderer) dependency
  /// at the host edge — base doesn't link any concrete renderer. The
  /// builder receives the active tab and the target bundle path (the
  /// path the user is authoring — a freshly created draft, an
  /// installed bundle, or a built-in app's launch path).
  final Widget Function(StudioTab tab, String targetBundlePath)
  bundleBodyBuilder;

  /// Seed namespace → absolute path. Single source of truth supplied
  /// by the host from `StudioApp.seedBundles()` at boot. Workspace uses
  /// keys for "is this a seed?" checks (Home picker filter,
  /// tabs.json reference normalization) and the values for
  /// namespace → path resolve (tabs.json restore). Per SDD §1.4.
  final Map<String, String> seedPathByNamespace;

  /// Built-in app launchers exposed in the home picker's BUILT-IN
  /// APPS section. Independent from the install registry — the host
  /// derives this list from its own built-in app registry (the apps-
  /// area `BuiltInAppRegistry`).
  final List<BuiltInLauncher> builtInLaunchers;

  /// Home-grid entries from host extensions (e.g. pro's Marketplace tile).
  /// Rendered next to the built-in apps; tap runs the entry's callback
  /// (open overlay) rather than activating a bundle. Empty in base build.
  final List<HomeExtensionEntry> extensionEntries;

  @override
  State<StudioWorkspace> createState() => _StudioWorkspaceState();
}

class _StudioWorkspaceState extends State<StudioWorkspace> {
  late Future<List<Map<String, dynamic>>> _entries;
  String? _installStatus;
  Timer? _installStatusTimer;
  bool _installing = false;
  final List<StudioTab> _tabs = <StudioTab>[StudioTab.home()];
  int _active = 0;

  /// Most recent snapshot of the active tab's bundle runtime state,
  /// pushed through `chromeBridge.onRuntimeStateChange` from
  /// `DslWorkspaceView`. Bundle-agnostic — every key the active
  /// bundle declared in `state.initial` (and anything written since)
  /// lands here, and `_syncHeaderActions` forwards the whole map to
  /// `readDomainActionsFromManifest` so the bundle's manifest gets to
  /// pick which keys its `emphasisedWhen` clauses reference. NO
  /// hardcoded keys (`currentRoute` / `editorMode` / …) on the host.
  Map<String, Object?> _runtimeState = const <String, Object?>{};

  /// Active-tab routing for chrome-bridge runtime hooks. Keyed by
  /// tab path (or `'home'`). Populated by `DslWorkspaceView` on boot
  /// + cleared on dispose so the chrome-bridge slots (`runtimeNavigate`
  /// / `updateRuntimeState`) reach the CURRENTLY ACTIVE tab regardless
  /// of which `DslWorkspaceView` instance booted most recently.
  final Map<String, TabRuntimeHooks> _tabRuntimeHooks =
      <String, TabRuntimeHooks>{};

  /// Root key for `studio.renderer.layout_snapshot` — wraps the centre
  /// body so `_captureLayoutSnapshot` can find a `RenderBox` to start
  /// the metadata walk from. vibe_app_builder's pattern.
  final GlobalKey _layoutCaptureKey = GlobalKey();

  String get _tabsFile => p.join(widget.configRoot, 'tabs.json');

  /// Read this bundle's per-package settings overrides JSON.
  /// Returns an empty map when the file is missing / malformed.
  /// Mirrors the path scheme used by `packageOverridesFile` in
  /// `manifest_sections_reader.dart` (kept inline to avoid a host
  /// → install-side import cycle).
  Map<String, dynamic> _readDomainOverrides(String mbdPath) {
    try {
      final safe = mbdPath.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
      final file = File(
        p.join(widget.configRoot, 'package_settings', '$safe.json'),
      );
      if (!file.existsSync()) return const <String, dynamic>{};
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is Map<String, dynamic>) return raw;
      return const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  /// Read `workspaceDir` from `<configRoot>/settings.json`. Returns null
  /// when the file is missing, unreadable, or `workspaceDir` is unset /
  /// empty. Sync-only so file/picker callers don't have to await.
  String? _readWorkspaceDir() {
    try {
      final f = File(p.join(widget.configRoot, 'settings.json'));
      if (!f.existsSync()) return null;
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return null;
      final v = decoded['workspaceDir'];
      if (v is! String || v.isEmpty) return null;
      return v;
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _entries = _enrichedEntries();
    // Tell the titlebar this host renders a tab strip — the show /
    // hide icon appears once this flips. Deferred to the post-frame
    // callback because the titlebar's `ValueListenableBuilder<bool>`
    // is in the same build pass and a synchronous flip here would
    // trigger `setState during build`.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.chromeBridge.hasTabStrip.value = true;
    });
    widget.chromeBridge.selectTab = (i) {
      if (i < 0 || i >= _tabs.length) return -1;
      _selectTab(i);
      return _active;
    };
    widget.chromeBridge.closeTab = (i) {
      if (i < 0 || i >= _tabs.length) return -1;
      if (_tabs[i].isHome) return -1;
      _closeTab(i);
      return _active;
    };
    widget.chromeBridge.closeTabsByMbdPath = (mbdPath) {
      // Walk from the back so indices stay valid as we close. Home
      // can't match (path is null) so the guard above keeps it safe.
      final closed = <String>[];
      for (var i = _tabs.length - 1; i >= 0; i--) {
        final t = _tabs[i];
        if (t.isHome) continue;
        if (t.path != mbdPath) continue;
        closed.add(t.path ?? '');
        _closeTab(i);
      }
      return closed;
    };
    widget.chromeBridge.markActiveTabModified = () {
      if (_active < 0 || _active >= _tabs.length) return;
      final t = _tabs[_active];
      if (t.isHome) return;
      if (t.isModified) return;
      t.isModified = true;
      // Persist the flag so a reboot mid-edit still gates the
      // close-warning dialog on next launch.
      // ignore: unawaited_futures
      _saveTabs();
    };
    widget.chromeBridge.onRuntimeStateChange = (state) {
      // Cache the full snapshot and refresh the header strip — the
      // bundle's manifest decides which keys its emphasisedWhen
      // clauses look at, so we hand the whole map off verbatim.
      _runtimeState = Map<String, Object?>.unmodifiable(state);
      _syncHeaderActions();
    };
    widget.chromeBridge.readActiveRuntimeState = () {
      // Prefer the actual active tab's runtime over the
      // last-listener-wins cache so multi-tab inspection stays
      // accurate even when several `DslWorkspaceView` instances are
      // alive.
      if (_active >= 0 && _active < _tabs.length) {
        final key = _tabs[_active].path ?? 'home';
        final hooks = _tabRuntimeHooks[key];
        if (hooks != null) return hooks.readState();
      }
      return _runtimeState;
    };
    // Per-tab hooks registry — DslWorkspaceView calls back in/out so
    // chrome-bridge routing follows the CURRENTLY active tab instead
    // of whichever DslWorkspaceView booted last.
    widget.chromeBridge.registerTabRuntime = (tabKey, hooks) {
      if (hooks == null) {
        _tabRuntimeHooks.remove(tabKey);
      } else {
        _tabRuntimeHooks[tabKey] = hooks;
        // The tab's runtime just came up — refresh header emphasis so
        // selectGroup icons that depend on the bundle's `state.initial`
        // (which the `onRuntimeStateChange` push misses for values set
        // before our listener attached) light up on first render.
        if (_active >= 0 &&
            _active < _tabs.length &&
            (_tabs[_active].path ?? 'home') == tabKey) {
          _syncHeaderActions();
        }
      }
    };
    widget.chromeBridge.runtimeNavigate = (route) {
      if (_active < 0 || _active >= _tabs.length) return false;
      final key = _tabs[_active].path ?? 'home';
      final hooks = _tabRuntimeHooks[key];
      if (hooks == null) return false;
      return hooks.navigate(route);
    };
    widget.chromeBridge.updateRuntimeState = (state) {
      if (_active < 0 || _active >= _tabs.length) return;
      final key = _tabs[_active].path ?? 'home';
      final hooks = _tabRuntimeHooks[key];
      hooks?.updateState(state);
    };
    widget.chromeBridge.dispatchActiveRuntimeTool = (tool, params) async {
      if (_active < 0 || _active >= _tabs.length) {
        return <String, dynamic>{'ok': false, 'reason': 'no-active-tab'};
      }
      final key = _tabs[_active].path ?? 'home';
      final hooks = _tabRuntimeHooks[key];
      final fn = hooks?.dispatchTool;
      if (fn == null) {
        return <String, dynamic>{
          'ok': false,
          'reason': 'dispatchTool-not-wired',
        };
      }
      return fn(tool, params);
    };
    widget.chromeBridge.listTabs =
        () => <Map<String, dynamic>>[
          for (final t in _tabs)
            <String, dynamic>{
              'key': t.isHome ? 'home' : (t.path ?? ''),
              'name': t.name,
              if (!t.isHome && t.currentProject != null)
                'currentProject': t.currentProject,
            },
        ];
    widget.chromeBridge.newProjectInActive =
        ({required name, required parent}) =>
            _doNewProject(name: name, parent: parent);
    widget.chromeBridge.openProjectInActive = _doOpenProject;
    widget.chromeBridge.closeProjectInActive = _doCloseProject;
    widget.chromeBridge.activatePackage = (mbdPath) async {
      final friendly = readFriendlyLabel(mbdPath) ?? mbdPath;
      // _activateBundle (invoked inside _openPackageAsync) owns the
      // DomainServerManager.attach call now — it needs the resulting
      // instance's boot in scope before registering the bundle's
      // tools/agents. No double-attach here.
      await _openPackageAsync(mbdPath, friendly);
      final t = _tabs[_active];
      return <String, dynamic>{
        'active': _active,
        'key': t.path ?? 'home',
        'name': t.name,
      };
    };
    widget.chromeBridge.dispatchBundleTool = (mbdPath, toolShort, args) async {
      // Resolve the activated bundle's exposed namespace from our tab
      // model — bridges that bind tools (settings menu, future slash
      // dispatch) only know the package path. Falls back to the bare
      // tool name when no activation is found, so chrome-level builtins
      // (`studio.*`) still resolve.
      String? exposed;
      for (final t in _tabs) {
        if (!t.isHome && t.path == mbdPath) {
          exposed = t.activation?.exposedShortId;
          break;
        }
      }
      final fullName =
          exposed != null && exposed.isNotEmpty
              ? '$exposed.$toolShort'
              : toolShort;
      await widget.boot.callTool(fullName, args);
    };
    widget.chromeBridge.debugTabs =
        () => <Map<String, dynamic>>[
          for (var i = 0; i < _tabs.length; i++) _debugTabSnapshot(i, _tabs[i]),
        ];
    widget.chromeBridge.debugActivation = _debugActivation;
    widget.chromeBridge.debugRuntimes = _debugRuntimes;
    widget.chromeBridge.debugChat = _debugChat;
    widget.chromeBridge.activateView = _activateView;
    widget.chromeBridge.currentViewTarget = _currentViewTarget;
    widget.chromeBridge.captureLayoutSnapshot = _captureLayoutSnapshot;
    widget.chromeBridge.resolveElementRect = _resolveElementRect;
    widget.chromeBridge.debugConfig =
        () => <String, dynamic>{
          'configRoot': widget.configRoot,
          'tabsFile': _tabsFile,
        };
    widget.chromeBridge.activeProjectInfo = () {
      final t = _tabs[_active];
      return <String, dynamic>{
        if (!t.isHome) ...<String, dynamic>{
          'packageName': t.name,
          'packagePath': t.path,
        },
        if (t.currentProject != null) ...<String, dynamic>{
          'projectPath': t.currentProject,
          'projectName': p.basename(t.currentProject!),
        },
      };
    };
    widget.chromeBridge.openPackagePicker = _installFromPicker;
    widget.chromeBridge.createNewPackage = _createNewPackage;
    widget.chromeBridge.newProjectDialog = _newProject;
    widget.chromeBridge.openProjectDialog = _openProject;
    widget.chromeBridge.setActiveTabProject = _setActiveTabProjectFromBuiltin;
    widget.chromeBridge.reloadTab = _reloadTab;
    widget.chromeBridge.sendChat = _sendChat;
    widget.chromeBridge.openOnboarding = _showOnboarding;
    widget.chromeBridge.openAgents = _showAgents;
    widget.chromeBridge.openSeed = _openOrFocusSeed;
    widget.chromeBridge.appendChatTurn = _appendActiveChatTurn;
    widget.chromeBridge.dispatchLifecycle = _dispatchLifecycle;
    _loadTabs();
    _syncHomeActive();
  }

  void _syncHomeActive() {
    final v = _active >= 0 && _active < _tabs.length && _tabs[_active].isHome;
    // Flutter rebuilds a listener's State when its notifier emits, but
    // an emit fired during the same frame the listener is still being
    // mounted can miss the schedule. Bouncing through addPostFrameCallback
    // guarantees the value lands after the build settles.
    final bridge = widget.chromeBridge;
    if (bridge.homeActive.value != v) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        bridge.homeActive.value = v;
      });
    }
    _syncSlashHints();
    _syncChatAgent();
    _syncHeaderActions();
  }

  /// Push the active domain's icon actions into
  /// chromeBridge.headerActions. Called on every DOMAIN CHANGE (tab
  /// switch / bundle activate / bundle deactivate / package create) —
  /// trigger is domain identity, NOT editor-mode toggle. Row 2 entries
  /// are entirely domain-owned — the host reads the active bundle's
  /// `manifest.wiring.domainActions[]` and renders whatever the
  /// manifest declares (including Import / Export verbs when the
  /// domain wants them). Home tab and inert app-mode tabs clear the
  /// slot. Standard shell listens via ValueListenableBuilder; expanded
  /// ProjectHeader Row 2 and collapsed ActivityBar trailing group both
  /// re-render.
  void _syncHeaderActions() {
    final bridge = widget.chromeBridge;
    final hasTab = _active >= 0 && _active < _tabs.length;
    if (!hasTab) {
      bridge.headerActions.value = const <HeaderAction>[];
      bridge.lifecycleState.value = const DomainLifecycleState.empty();
      bridge.titlebarText.value = '';
      bridge.statusbarText.value = '';
      bridge.bundleVersion.value = '';
      return;
    }
    final t = _tabs[_active];
    if (t.isHome) {
      // Home has no bundle — empty chrome. Every other tab renders
      // whatever its manifest declares via `wiring.domainActions[]`.
      // vibe_studio is the platform; the bundle decides — no host-side
      // mode classification (`workspaceMode == 'builder'` etc.) gating.
      bridge.headerActions.value = const <HeaderAction>[];
      bridge.lifecycleState.value = const DomainLifecycleState.empty();
      bridge.titlebarText.value = '';
      bridge.statusbarText.value = '';
      bridge.bundleVersion.value = '';
      return;
    }
    // Prefer the active tab's runtime state read directly from its
    // hooks. The `_runtimeState` cache is fed by `onRuntimeStateChange`
    // which only fires when `stateManager.notifyListeners()` runs —
    // values written by `state.initial` BEFORE our listener attaches
    // are present in `stateManager.state` but never emitted, so the
    // cache misses them until the user's first interactive change.
    // Reading through hooks is synchronous and always current.
    final key = t.path ?? 'home';
    final hooks = _tabRuntimeHooks[key];
    final liveState = hooks != null ? hooks.readState() : _runtimeState;
    // Lifecycle state (project name / dirty / undo / redo) — resolver
    // pattern mirrors [headerActionsResolver]. Built-in apps return
    // their per-tab snapshot through [lifecycleStateResolver]; manifest
    // domains declare a `wiring.lifecycleStateBindings` block that maps
    // their runtime state keys onto the same DomainLifecycleState
    // fields. Both paths land in the single chrome slot below; the
    // ProjectHeader's `bundleName` fallback only triggers when neither
    // channel produces a value.
    final lifecycle =
        bridge.lifecycleStateResolver?.call(t.path ?? '') ??
        _readManifestLifecycleBindings(t.path ?? '', liveState);
    bridge.lifecycleState.value =
        lifecycle ?? const DomainLifecycleState.empty();
    // Titlebar + statusbar user-zone payloads + bundle version.
    // Resolved BEFORE the resolver early-return so built-in app tabs
    // (which short-circuit row-2 via headerActionsResolver) still see
    // their seed manifest's titlebar / statusbar / version reflected
    // in the chrome. Reads through the typed `WiringSection`
    // (mcp_bundle ≥ 0.3.3 with §6.4a `wiring.titlebar`/`statusbar`
    // fields) — mutator round-trip preserves these now.
    final mbd = _resolveManifestPath(t.path ?? '');
    final bundleAtTab = readBundleAt(mbd);
    final tbTpl = bundleAtTab?.wiring?.titlebar;
    final sbTpl = bundleAtTab?.wiring?.statusbar;
    bridge.titlebarText.value =
        tbTpl == null ? '' : _interpolate(tbTpl, liveState);
    bridge.statusbarText.value =
        sbTpl == null ? '' : _interpolate(sbTpl, liveState);
    bridge.bundleVersion.value = bundleAtTab?.manifest.version ?? '';

    // Resolver-first: non-manifest domains (built-in apps) plug their
    // own actions through `chromeBridge.headerActionsResolver`. Non-
    // null result wins; null falls back to the manifest reader so
    // manifest-driven bundles stay untouched.
    final resolverResult = bridge.headerActionsResolver?.call(
      t.path ?? '',
      liveState,
    );
    if (resolverResult != null) {
      bridge.headerActions.value = resolverResult;
      return;
    }
    // Row 2 of the ProjectHeader is entirely domain-owned. The host
    // does NOT inject any built-in icons here — every entry comes from
    // the active bundle's `manifest.wiring.domainActions[]`. Bundles
    // that want Import / Export verbs declare them in their manifest.
    bridge.headerActions.value = readDomainActionsFromManifest(
      mbdPath: t.path ?? '',
      invokeTool: (fullName, args) async {
        await widget.boot.callTool(fullName, args);
        // Mode-toggle actions mutate `editorMode` via the renderer —
        // refresh the strip so the new emphasis lands.
        _syncHeaderActions();
      },
      exposedNs: t.activation?.exposedShortId,
      bridge: widget.chromeBridge,
      // Forward the bundle's runtime-state snapshot verbatim — the
      // manifest's `emphasisedWhen.key` selects whichever key it
      // declared (no host-side translation, no allow-list).
      state: liveState,
    );
  }

  /// Map a tab's `path` to the directory that holds `manifest.json`.
  /// Manifest-driven tabs return [tabPath] unchanged; built-in app
  /// tabs (path = workspace marker dir) resolve to their seed mbd via
  /// [widget.builtInLaunchers] + [widget.seedPathByNamespace] so the
  /// chrome reads the same manifest the user authors.
  String _resolveManifestPath(String tabPath) {
    if (tabPath.isEmpty) return tabPath;
    if (File(p.join(tabPath, 'manifest.json')).existsSync()) return tabPath;
    for (final launcher in widget.builtInLaunchers) {
      if (launcher.launchPath == tabPath) {
        final seed = widget.seedPathByNamespace[launcher.id];
        if (seed != null) return seed;
      }
    }
    return tabPath;
  }

  /// Resolve `{{path}}` tokens inside [template] against a flat state
  /// map. Nested paths (`{{a.b.c}}`) walk the map; missing keys leave
  /// the placeholder empty. Plain string interpolation — no DSL
  /// expressions / arithmetic / function calls.
  String _interpolate(String template, Map<String, Object?> state) {
    return template.replaceAllMapped(RegExp(r'\{\{([^}]+)\}\}'), (m) {
      final raw = m.group(1)?.trim() ?? '';
      if (raw.isEmpty) return '';
      Object? cursor = state;
      for (final seg in raw.split('.')) {
        if (cursor is Map) {
          cursor = cursor[seg];
        } else {
          cursor = null;
          break;
        }
      }
      return cursor == null ? '' : cursor.toString();
    });
  }

  /// Re-cache the snapshot from the currently-active tab's runtime so
  /// header-action emphasis matches the right tab's state right after
  /// a tab switch. Reading from `_tabRuntimeHooks` is synchronous —
  /// no need to wait for the next `onRuntimeStateChange` callback.
  void _rebindRuntimeStateObserver() {
    if (_active < 0 || _active >= _tabs.length) {
      _runtimeState = const <String, Object?>{};
      return;
    }
    final key = _tabs[_active].path ?? 'home';
    final hooks = _tabRuntimeHooks[key];
    if (hooks == null) {
      _runtimeState = const <String, Object?>{};
    } else {
      _runtimeState = Map<String, Object?>.unmodifiable(hooks.readState());
    }
  }

  /// Compute the chat panel's slash hints for the currently active
  /// tab. Home → universal-host defaults. Bundle tab → ONLY the
  /// bundle's `manifest.chat.slashCommands[]` (empty strip when the
  /// bundle declares none). Home defaults and bundle commands are
  /// mutually exclusive — bundles are responsible for declaring their
  /// own commands and don't inherit the host's. Updates
  /// chromeBridge.chatSlashHints; ChatPanel listens and re-renders.
  void _syncSlashHints() {
    final bridge = widget.chromeBridge;
    List<ChatSlashHint> out;
    if (_active < 0 || _active >= _tabs.length || _tabs[_active].isHome) {
      out = const <ChatSlashHint>[
        ChatSlashHint('/help', null, 'List available chat commands.'),
        ChatSlashHint(
          '/agents',
          null,
          'Show the registered agents and which are dispatchable.',
        ),
        ChatSlashHint(
          '/clear',
          null,
          'Clear the current chat thread (manager context).',
        ),
      ];
    } else {
      final t = _tabs[_active];
      // Resolver-first: non-manifest domains (built-in apps) supply
      // their chips through `chromeBridge.chatSlashHintsResolver`.
      final resolved =
          t.path == null ? null : bridge.chatSlashHintsResolver?.call(t.path!);
      if (resolved != null) {
        out = resolved;
      } else {
        out =
            t.path == null
                ? const <ChatSlashHint>[]
                : _slashHintsForBundle(t.path!);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      bridge.chatSlashHints.value = out;
    });
  }

  /// Parse the bundle's manifest.chat.slashCommands[] (when present)
  /// into [ChatSlashHint]s. Schema:
  ///   manifest.chat.slashCommands: [
  ///     { command: '/foo', template: 'bar', description: '...' }
  ///   ]
  List<ChatSlashHint> _slashHintsForBundle(String mbdPath) {
    try {
      final file = File(p.join(mbdPath, 'manifest.json'));
      if (!file.existsSync()) return const <ChatSlashHint>[];
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) return const <ChatSlashHint>[];
      final chat = raw['chat'];
      if (chat is! Map<String, dynamic>) return const <ChatSlashHint>[];
      final cmds = chat['slashCommands'];
      if (cmds is! List) return const <ChatSlashHint>[];
      return <ChatSlashHint>[
        for (final c in cmds)
          if (c is Map<String, dynamic> && c['command'] is String)
            ChatSlashHint(
              c['command'] as String,
              c['template'] as String?,
              c['description'] as String?,
              c['tool'] as String?,
              (c['arguments'] is Map)
                  ? Map<String, dynamic>.from(c['arguments'] as Map)
                  : null,
            ),
      ];
    } catch (_) {
      return const <ChatSlashHint>[];
    }
  }

  @override
  void dispose() {
    _installStatusTimer?.cancel();
    widget.chromeBridge.hasTabStrip.value = false;
    widget.chromeBridge.selectTab = null;
    widget.chromeBridge.closeTab = null;
    widget.chromeBridge.closeTabsByMbdPath = null;
    widget.chromeBridge.markActiveTabModified = null;
    widget.chromeBridge.onRuntimeStateChange = null;
    widget.chromeBridge.readActiveRuntimeState = null;
    widget.chromeBridge.registerTabRuntime = null;
    widget.chromeBridge.runtimeNavigate = null;
    widget.chromeBridge.updateRuntimeState = null;
    widget.chromeBridge.listTabs = null;
    widget.chromeBridge.newProjectInActive = null;
    widget.chromeBridge.openProjectInActive = null;
    widget.chromeBridge.closeProjectInActive = null;
    widget.chromeBridge.activatePackage = null;
    widget.chromeBridge.debugTabs = null;
    widget.chromeBridge.debugActivation = null;
    widget.chromeBridge.debugRuntimes = null;
    widget.chromeBridge.debugChat = null;
    widget.chromeBridge.sendChat = null;
    widget.chromeBridge.activeProjectInfo = null;
    widget.chromeBridge.debugConfig = null;
    widget.chromeBridge.openPackagePicker = null;
    widget.chromeBridge.createNewPackage = null;
    widget.chromeBridge.newProjectDialog = null;
    widget.chromeBridge.openProjectDialog = null;
    widget.chromeBridge.reloadTab = null;
    widget.chromeBridge.openOnboarding = null;
    widget.chromeBridge.openAgents = null;
    widget.chromeBridge.openSeed = null;
    widget.chromeBridge.appendChatTurn = null;
    widget.chromeBridge.dispatchLifecycle = null;
    widget.chromeBridge.homeActive.value = false;
    widget.chromeBridge.chatSlashHints.value = const <ChatSlashHint>[];
    super.dispose();
  }

  /// Generic lifecycle dispatcher — chrome surfaces call this with a
  /// conceptual [slot] id (e.g. `'project.new'`). The host resolves
  /// the seed bundle's `mbdPath` (studio_seed / studio_knowledge entry)
  /// and delegates lookup + tool invocation to base's
  /// `dispatchLifecycleSlot`. Returns the tool's decoded JSON result,
  /// or a `{ok: false, error}` envelope when the seed is missing / the
  /// slot isn't wired / the dispatch failed.
  Future<Map<String, Object?>> _dispatchLifecycle(
    String slot,
    Map<String, dynamic> args,
  ) async {
    // Lifecycle dispatch targets the active tab's bundle. The R26
    // cleanup retires the studio_builder seed (unified-builder, 2026-
    // 05-19) and strips wiring/lifecycle from the remaining built-in
    // seeds (knowledge-only — `docs/03_DDD/host.md` MOD-HOST-007), so
    // there is no seed-side fallback to fall back to. When no tab is
    // active we surface an error per [feedback_no_fallback_anywhere].
    String? mbdPath;
    if (_active >= 0 && _active < _tabs.length) {
      mbdPath = _tabs[_active].path;
    }
    if (mbdPath == null) {
      return <String, Object?>{
        'ok': false,
        'error': 'no active bundle for lifecycle dispatch',
      };
    }
    return dispatchLifecycleSlot(
      mbdPath: mbdPath,
      slot: slot,
      args: args,
      callTool: widget.boot.callTool,
    );
  }

  /// Universal renderer activator — wired to `chromeBridge.activateView`
  /// so MCP `studio.renderer.activate(target: ...)` + chrome buttons
  /// share one entry point. Parses the path-like [target] and dispatches
  /// to the appropriate chromeBridge slot or sub-tab notifier. Returns
  /// a structured `{ok, target, ...}` so the MCP handler can echo it.
  ///
  /// Recognised targets (Phase 1):
  ///   - `tools/<kind>` — Tools-mode sub-tab. kind ∈ tool/domain/slash/section.
  ///   - `home` — Home tab.
  ///   - `bundle/<path>` — switch to (or open) a bundle tab by mbdPath.
  /// Domain DSL targets (`<mbdNs>/<screen>`) land in Phase 2.
  Map<String, dynamic> _activateView(
    String target, [
    Map<String, dynamic>? args,
  ]) {
    if (target == 'home') {
      // Home tab = index 0 by convention. selectTab uses the bridge's
      // own callback so the activation runs the same teardown logic
      // user-clicks trigger.
      if (_tabs.isNotEmpty) {
        setState(() {
          _active = 0;
        });
        _syncHomeActive();
        _notifyContext();
        return <String, dynamic>{'ok': true, 'target': target};
      }
      return <String, dynamic>{
        'ok': false,
        'target': target,
        'reason': 'no-tabs',
      };
    }
    // Editor mode / sub-tab page navigation was previously handled
    // here with host-hardcoded `p_<mode>` / `s_<kind>` boolean flag
    // pushes. Removed — the domain (seed manifest + DSL routes) now
    // owns navigation. Use `studio.nav.go({pageId})` (base primitive
    // that bridges to runtime native navigation) for page switches.
    // Tab targets — select / close a tab by index. The activator does
    // NOT do path-based bundle lookup here (that's `bundle/<path>`);
    // index-based switching matches the user clicking a tab pill.
    if (target.startsWith('tab/')) {
      final rest = target.substring('tab/'.length);
      String? action;
      String idxStr;
      if (rest.startsWith('close/')) {
        action = 'close';
        idxStr = rest.substring('close/'.length);
      } else {
        action = 'select';
        idxStr = rest;
      }
      final idx = int.tryParse(idxStr);
      if (idx == null) {
        return <String, dynamic>{
          'ok': false,
          'target': target,
          'reason': 'invalid-tab-index',
        };
      }
      if (action == 'close') {
        final fn = widget.chromeBridge.closeTab;
        if (fn == null) {
          return <String, dynamic>{
            'ok': false,
            'target': target,
            'reason': 'closeTab-not-wired',
          };
        }
        final after = fn(idx);
        return <String, dynamic>{'ok': true, 'target': target, 'active': after};
      }
      final fn = widget.chromeBridge.selectTab;
      if (fn == null) {
        return <String, dynamic>{
          'ok': false,
          'target': target,
          'reason': 'selectTab-not-wired',
        };
      }
      final after = fn(idx);
      return <String, dynamic>{'ok': true, 'target': target, 'active': after};
    }
    if (target == 'reload') {
      final fn = widget.chromeBridge.reloadTab;
      if (fn == null) {
        return <String, dynamic>{
          'ok': false,
          'target': target,
          'reason': 'reloadTab-not-wired',
        };
      }
      fn(null);
      return <String, dynamic>{'ok': true, 'target': target};
    }
    if (target == 'project/new') {
      // With args → programmatic path (newProjectInActive); without →
      // dialog path. LLM picks: pass `{name, parent}` to skip the
      // dialog, omit args to let the user fill it in.
      final name = args?['name']?.toString();
      final parent = args?['parent']?.toString();
      if (name != null && parent != null) {
        final fn = widget.chromeBridge.newProjectInActive;
        if (fn == null) {
          return <String, dynamic>{
            'ok': false,
            'target': target,
            'reason': 'newProjectInActive-not-wired',
          };
        }
        // ignore: unawaited_futures
        fn(name: name, parent: parent);
        return <String, dynamic>{
          'ok': true,
          'target': target,
          'name': name,
          'parent': parent,
        };
      }
      final fn = widget.chromeBridge.newProjectDialog;
      if (fn == null) {
        return <String, dynamic>{
          'ok': false,
          'target': target,
          'reason': 'newProjectDialog-not-wired',
        };
      }
      // ignore: unawaited_futures
      fn();
      return <String, dynamic>{'ok': true, 'target': target};
    }
    if (target == 'project/open') {
      // With args.path → programmatic open (openProjectInActive);
      // without → dialog.
      final path = args?['path']?.toString();
      if (path != null && path.isNotEmpty) {
        final fn = widget.chromeBridge.openProjectInActive;
        if (fn == null) {
          return <String, dynamic>{
            'ok': false,
            'target': target,
            'reason': 'openProjectInActive-not-wired',
          };
        }
        // ignore: unawaited_futures
        fn(path);
        return <String, dynamic>{'ok': true, 'target': target, 'path': path};
      }
      final fn = widget.chromeBridge.openProjectDialog;
      if (fn == null) {
        return <String, dynamic>{
          'ok': false,
          'target': target,
          'reason': 'openProjectDialog-not-wired',
        };
      }
      // ignore: unawaited_futures
      fn();
      return <String, dynamic>{'ok': true, 'target': target};
    }
    if (target == 'project/close') {
      final fn = widget.chromeBridge.closeProjectInActive;
      if (fn == null) {
        return <String, dynamic>{
          'ok': false,
          'target': target,
          'reason': 'closeProjectInActive-not-wired',
        };
      }
      final summary = fn();
      return <String, dynamic>{'ok': true, 'target': target, ...summary};
    }
    if (target == 'project/info') {
      // Read-only — echoes the active tab's project info without
      // touching any state. Composes naturally with the lifecycle
      // targets: open / new → info → check what's loaded.
      final fn = widget.chromeBridge.activeProjectInfo;
      if (fn == null) {
        return <String, dynamic>{
          'ok': false,
          'target': target,
          'reason': 'activeProjectInfo-not-wired',
        };
      }
      final info = fn();
      return <String, dynamic>{'ok': true, 'target': target, ...info};
    }
    if (target == 'package/new') {
      // Home-tab Create Package. With args.name → programmatic
      // scaffold (no dialog); without args → dialog flow. The
      // bridge's createNewPackage routes both branches.
      final fn = widget.chromeBridge.createNewPackage;
      if (fn == null) {
        return <String, dynamic>{
          'ok': false,
          'target': target,
          'reason': 'createNewPackage-not-wired',
        };
      }
      final name = args?['name']?.toString();
      final parent = args?['parent']?.toString();
      final id = args?['id']?.toString();
      // ignore: unawaited_futures
      fn(name: name, parent: parent, id: id);
      return <String, dynamic>{
        'ok': true,
        'target': target,
        if (name != null) 'name': name,
      };
    }
    if (target == 'package/open') {
      // Home-tab Install / Open Package — runs the host's package
      // picker (rooted at workspaceDir when set). Programmatic
      // install by path uses the separate `studio.bundle.install`
      // tool; this target is the dialog entry only.
      final fn = widget.chromeBridge.openPackagePicker;
      if (fn == null) {
        return <String, dynamic>{
          'ok': false,
          'target': target,
          'reason': 'openPackagePicker-not-wired',
        };
      }
      // ignore: unawaited_futures
      fn();
      return <String, dynamic>{'ok': true, 'target': target};
    }
    if (target.startsWith('bundle/')) {
      final path = target.substring('bundle/'.length);
      if (path.isEmpty) {
        return <String, dynamic>{
          'ok': false,
          'target': target,
          'reason': 'missing-path',
        };
      }
      // Defer to the existing bridge slot so install/activation logic
      // stays in one place.
      final ap = widget.chromeBridge.activatePackage;
      if (ap == null) {
        return <String, dynamic>{
          'ok': false,
          'target': target,
          'reason': 'activatePackage-not-wired',
        };
      }
      // Run the async activation without awaiting (renderer activator
      // is a synchronous slot) — the caller can query current view via
      // a follow-up MCP call. Returning ok=true means "request accepted",
      // not "activation complete".
      // ignore: unawaited_futures
      ap(path);
      return <String, dynamic>{'ok': true, 'target': target};
    }
    if (target.startsWith('chrome/')) {
      // Chrome action targets — funnel ChromeBridge's standalone
      // callbacks (openSettings / openHistory / toggleLeftPanel / ...)
      // through the renderer's single entry so the LLM uses one verb
      // for everything: `studio.renderer.activate({target: ...})`.
      final action = target.substring('chrome/'.length);
      final bridge = widget.chromeBridge;
      switch (action) {
        case 'settings':
          final fn = bridge.openSettings;
          if (fn == null) {
            return <String, dynamic>{
              'ok': false,
              'target': target,
              'reason': 'openSettings-not-wired',
            };
          }
          // ignore: unawaited_futures
          fn();
          return <String, dynamic>{'ok': true, 'target': target};
        case 'history':
          final fn = bridge.openHistory;
          if (fn == null) {
            return <String, dynamic>{
              'ok': false,
              'target': target,
              'reason': 'openHistory-not-wired',
            };
          }
          // ignore: unawaited_futures
          fn();
          return <String, dynamic>{'ok': true, 'target': target};
        case 'onboarding':
          final fn = bridge.openOnboarding;
          if (fn == null) {
            return <String, dynamic>{
              'ok': false,
              'target': target,
              'reason': 'openOnboarding-not-wired',
            };
          }
          // ignore: unawaited_futures
          fn();
          return <String, dynamic>{'ok': true, 'target': target};
        case 'agents':
          final fn = bridge.openAgents;
          if (fn == null) {
            return <String, dynamic>{
              'ok': false,
              'target': target,
              'reason': 'openAgents-not-wired',
            };
          }
          // ignore: unawaited_futures
          fn();
          return <String, dynamic>{'ok': true, 'target': target};
        case 'left_panel/toggle':
          final fn = bridge.toggleLeftPanel;
          if (fn == null) {
            return <String, dynamic>{
              'ok': false,
              'target': target,
              'reason': 'toggleLeftPanel-not-wired',
            };
          }
          final visible = fn();
          return <String, dynamic>{
            'ok': true,
            'target': target,
            'visible': visible,
          };
        case 'left_panel/show':
          final fn = bridge.setLeftPanelVisible;
          if (fn == null) {
            return <String, dynamic>{
              'ok': false,
              'target': target,
              'reason': 'setLeftPanelVisible-not-wired',
            };
          }
          final visible = fn(true);
          return <String, dynamic>{
            'ok': true,
            'target': target,
            'visible': visible,
          };
        case 'left_panel/hide':
          final fn = bridge.setLeftPanelVisible;
          if (fn == null) {
            return <String, dynamic>{
              'ok': false,
              'target': target,
              'reason': 'setLeftPanelVisible-not-wired',
            };
          }
          final visible = fn(false);
          return <String, dynamic>{
            'ok': true,
            'target': target,
            'visible': visible,
          };
        default:
          return <String, dynamic>{
            'ok': false,
            'target': target,
            'reason': 'unknown-chrome-action',
            'expected': const <String>[
              'settings',
              'history',
              'onboarding',
              'agents',
              'left_panel/toggle',
              'left_panel/show',
              'left_panel/hide',
            ],
          };
      }
    }
    // Route fallback — any target starting with `/` is forwarded to
    // the runtime as a DSL navigation push. The domain (seed mbd)
    // owns its page list / route names; base just pushes the route
    // string through `chromeBridge.runtimeNavigate` so the DSL's
    // `routes` / `VbuRouter` reacts.
    if (target.startsWith('/')) {
      final fn = widget.chromeBridge.runtimeNavigate;
      if (fn == null) {
        return <String, dynamic>{
          'ok': false,
          'target': target,
          'reason': 'runtimeNavigate-not-wired',
        };
      }
      final ok = fn(target);
      // _currentRoute / header emphasis is refreshed by the
      // runtime-state observer (see `chromeBridge.onRuntimeStateChange`
      // wiring in `DslWorkspaceView`) — `runtimeNavigate` writes
      // `currentRoute` into the bundle's stateManager which fires the
      // listener, so we don't need to mirror anything here.
      return <String, dynamic>{'ok': ok, 'target': target, 'route': target};
    }
    return <String, dynamic>{
      'ok': false,
      'target': target,
      'reason': 'unknown-target',
    };
  }

  /// Inverse of [_activateView] — describe what the user is *now*
  /// looking at using the same target-path scheme. Home tab → `home`;
  /// bundle tab in tools editor mode → `tools/<subTab>`; other editor
  /// modes return their mode id (`ui` / `knowledge` / `manifest`) or
  /// `bundle/<path>` as the coarsest fallback.
  Map<String, dynamic> _currentViewTarget() {
    if (_active < 0 || _active >= _tabs.length) {
      return <String, dynamic>{'target': 'home'};
    }
    final t = _tabs[_active];
    if (t.isHome) {
      return <String, dynamic>{'target': 'home'};
    }
    // Read the active route from the bundle's runtime state at the
    // chrome↔bundle convention path (`currentRoute` top-level — see
    // `DslWorkspaceView.navigate` for the contract).
    final raw = _runtimeState['currentRoute'];
    final String route = raw is String ? raw : '';
    final stripped = route.startsWith('/') ? route.substring(1) : route;
    if (stripped == 'tools') {
      final sub = widget.chromeBridge.toolsSubTab.value;
      return <String, dynamic>{'target': 'tools/$sub', 'bundlePath': t.path};
    }
    if (stripped.isNotEmpty) {
      return <String, dynamic>{'target': stripped, 'bundlePath': t.path};
    }
    return <String, dynamic>{'target': 'bundle/${t.path ?? ""}'};
  }

  /// Walk the centre body's render tree and produce one entry per
  /// `MetaData(metaData: <Map<String, dynamic>>)` node — pattern lifted
  /// from `vibe_app_builder`'s `vibe_layout_snapshot`. Lets MCP-driven
  /// LLMs read what the user sees (rect + rendered font / box /
  /// padding) without paying for a vision model. Returns null when the
  /// capture root isn't attached yet (relaunch right after boot, etc.)
  /// so the MCP handler can answer `{nodes: [], reason: ...}`.
  /// Synchronous element-rect lookup — walks the same MetaData tree
  /// the layout-snapshot tool uses, returns the first hit's rect (in
  /// shell-root coords). Used by `OverlayLayer` so overlay targets
  /// like `{element: "tool:addTool"}` resolve every paint without an
  /// async hop. `elementId` format: `<type>:<key>` where `<type>`
  /// matches the MetaData node's `type` field and `<key>` matches its
  /// `id` / `text` / `label` / `title` field.
  Rect? _resolveElementRect(String elementId) {
    // Two accepted shapes, in priority order:
    //
    //   1. `<type>:<key>` — strict form. `<type>` matches the MetaData
    //      node's `type`; `<key>` matches one of `id`/`text`/`label`/
    //      `title`. Use this when two distinct widget types share the
    //      same id/label text (rare but possible — e.g. a chip with the
    //      same label as a header action).
    //
    //   2. `<key>` (no colon) — id-only form. Matches the FIRST node
    //      whose `id` / `text` / `label` / `title` equals the key,
    //      regardless of `type`. This is the natural form for the
    //      "snapshot the layout, copy an id, tap it" workflow that
    //      `studio.renderer.layout_snapshot` produces — the snapshot
    //      emits a bare `id` field per node, so callers can paste it
    //      straight into `studio.ui.tap({elementId: ...})` without
    //      having to also extract and prefix the type.
    final colon = elementId.indexOf(':');
    final String? wantType;
    final String wantKey;
    if (colon < 1) {
      wantType = null;
      wantKey = elementId;
    } else {
      wantType = elementId.substring(0, colon);
      wantKey = elementId.substring(colon + 1);
    }
    final keys = <GlobalKey>[
      if (widget.chromeBridge.captureRootKey != null)
        widget.chromeBridge.captureRootKey!,
      _layoutCaptureKey,
    ];
    for (final k in keys) {
      final ro = k.currentContext?.findRenderObject();
      if (ro is RenderBox && ro.attached && ro.hasSize) {
        final found = _findMetaRect(ro, ro, wantType, wantKey);
        if (found != null) return found;
      }
    }
    return null;
  }

  Rect? _findMetaRect(
    RenderBox root,
    RenderObject node,
    String? wantType,
    String wantKey,
  ) {
    if (node is RenderMetaData) {
      final meta = node.metaData;
      if (meta is Map<String, dynamic> && node.hasSize && node.attached) {
        final type = meta['type']?.toString() ?? '';
        // `wantType == null` = id-only form: skip the type filter so
        // any node whose id/text/label/title equals `wantKey` matches.
        if (wantType == null || type == wantType) {
          for (final keyField in const <String>[
            'id',
            'text',
            'label',
            'title',
          ]) {
            final v = meta[keyField];
            if (v is String && v == wantKey) {
              final transform = node.getTransformTo(root);
              return MatrixUtils.transformRect(
                transform,
                Offset.zero & node.size,
              );
            }
          }
        }
      }
    }
    Rect? hit;
    node.visitChildren((c) {
      if (hit != null) return;
      hit = _findMetaRect(root, c, wantType, wantKey);
    });
    return hit;
  }

  Future<List<Map<String, dynamic>>?> _captureLayoutSnapshot() async {
    // Start from the chrome shell root when wired so the rect transform
    // is anchored at the same origin every snapshot. Walks recursively;
    // any RenderMetaData inside the inner-bundle runtime / inspector
    // tree shows up automatically. Dialog overlays live inside the
    // MaterialApp's Navigator (sibling of the shell RepaintBoundary, not
    // a descendant), so we additionally walk every currently-active
    // OverlayState reachable through the host's `rootNavigatorKey` so
    // `showDialog` content is also surfaced.
    RenderBox? primaryRoot;
    final keys = <GlobalKey>[
      if (widget.chromeBridge.captureRootKey != null)
        widget.chromeBridge.captureRootKey!,
      _layoutCaptureKey,
    ];
    for (final k in keys) {
      final ro = k.currentContext?.findRenderObject();
      if (ro is RenderBox && ro.attached && ro.hasSize) {
        primaryRoot = ro;
        break;
      }
    }
    if (primaryRoot == null) return null;
    final out = _walkLayoutSnapshot(primaryRoot);
    final overlayRoots = _activeOverlayRenderObjects(primaryRoot);
    for (final overlayRoot in overlayRoots) {
      out.addAll(_walkLayoutSnapshot(overlayRoot, anchor: primaryRoot));
    }
    return out;
  }

  /// Collect render objects of every active overlay child that lives
  /// outside [primaryRoot]'s subtree — typically `showDialog` content
  /// hosted by the host MaterialApp's Navigator. The traversal walks
  /// the entire widget tree (rooted at [WidgetsBinding.rootElement])
  /// looking for `RenderMetaData`s whose meta map carries a
  /// `dialog_action` / `dialog_root` tag, which `inspectTag` paints on
  /// every dialog button — once we find one we promote its nearest
  /// surrounding `Overlay`-owned subtree so the walker enumerates the
  /// whole dialog body, not just the button.
  ///
  /// Best effort: if we can't locate the dialog subtree we just return
  /// an empty list and the snapshot falls back to the shell scope.
  List<RenderBox> _activeOverlayRenderObjects(RenderBox primaryRoot) {
    final out = <RenderBox>[];
    final seen = <RenderObject>{};
    void visit(RenderObject ro) {
      if (ro is RenderMetaData) {
        final meta = ro.metaData;
        if (meta is Map<String, dynamic> && ro.hasSize && ro.attached) {
          if (!_isDescendantOf(ro, primaryRoot) && ro is RenderBox) {
            if (seen.add(ro)) out.add(ro);
          }
        }
      }
      ro.visitChildren(visit);
    }

    final bindingRoot = WidgetsBinding.instance.rootElement?.renderObject;
    if (bindingRoot != null) {
      bindingRoot.visitChildren(visit);
    }
    return out;
  }

  bool _isDescendantOf(RenderObject node, RenderObject ancestor) {
    RenderObject? cur = node;
    while (cur != null) {
      if (identical(cur, ancestor)) return true;
      cur = cur.parent;
    }
    return false;
  }

  List<Map<String, dynamic>> _walkLayoutSnapshot(
    RenderBox root, {
    RenderBox? anchor,
  }) {
    final out = <Map<String, dynamic>>[];
    // `anchor` reframes the emitted rects against a different ancestor —
    // used when walking dialog overlays so the dialog button rects land
    // in the same coordinate space as the shell's RenderMetaData
    // entries (the shell RepaintBoundary, not the dialog's own root).
    final coordRoot = anchor ?? root;
    void visit(RenderObject ro, int depth) {
      if (ro is RenderMetaData) {
        final meta = ro.metaData;
        if (meta is Map<String, dynamic> && ro.hasSize && ro.attached) {
          final box = ro;
          final transform = box.getTransformTo(coordRoot);
          final rect = MatrixUtils.transformRect(
            transform,
            Offset.zero & box.size,
          );
          final entry = <String, dynamic>{
            'type': meta['type']?.toString() ?? '?',
            'depth': depth,
            'rect': <double>[rect.left, rect.top, rect.width, rect.height],
          };
          for (final key in const <String>['id', 'text', 'label', 'title']) {
            final v = meta[key];
            if (v is String && v.isNotEmpty) entry[key] = v;
          }
          _scrapeRenderedStyle(ro, entry);
          out.add(entry);
        }
      }
      ro.visitChildren((child) => visit(child, depth + 1));
    }

    visit(root, 0);
    return out;
  }

  /// Pull whatever rendered-style hints we can from a metadata node's
  /// subtree without crossing the next metadata boundary. Best effort;
  /// missing data is silently skipped.
  void _scrapeRenderedStyle(RenderObject root, Map<String, dynamic> entry) {
    void walk(RenderObject ro, int sinceMeta) {
      if (sinceMeta > 0 && ro is RenderMetaData) return;
      if (ro is RenderParagraph) {
        final style = ro.text.style;
        if (style != null) {
          final font = <String, dynamic>{};
          if (style.fontSize != null) font['size'] = style.fontSize;
          if (style.fontWeight != null) {
            font['weight'] = style.fontWeight!.value;
          }
          if (style.fontFamily != null && style.fontFamily!.isNotEmpty) {
            font['family'] = style.fontFamily;
          }
          if (style.color != null) {
            font['color'] = _hexOfColor(style.color!);
          }
          if (style.height != null) font['lineHeight'] = style.height;
          if (font.isNotEmpty) entry['font'] = font;
        }
      }
      if (ro is RenderDecoratedBox) {
        final dec = ro.decoration;
        if (dec is BoxDecoration) {
          final box = <String, dynamic>{};
          if (dec.color != null) box['color'] = _hexOfColor(dec.color!);
          final br = dec.borderRadius;
          if (br is BorderRadius) {
            box['radius'] = <String, double>{
              'tl': br.topLeft.x,
              'tr': br.topRight.x,
              'bl': br.bottomLeft.x,
              'br': br.bottomRight.x,
            };
          }
          if (dec.border != null) {
            box['borderTop'] = dec.border!.top.width;
            box['borderColor'] = _hexOfColor(dec.border!.top.color);
          }
          if (box.isNotEmpty) entry['box'] = box;
        }
      }
      if (ro is RenderPadding) {
        final pad = ro.padding;
        entry['padding'] = <String, double>{
          'l': pad.resolve(TextDirection.ltr).left,
          't': pad.resolve(TextDirection.ltr).top,
          'r': pad.resolve(TextDirection.ltr).right,
          'b': pad.resolve(TextDirection.ltr).bottom,
        };
      }
      ro.visitChildren((child) => walk(child, sinceMeta + 1));
    }

    root.visitChildren((c) => walk(c, 0));
  }

  String _hexOfColor(Color c) {
    final r = (c.r * 255).round() & 0xff;
    final g = (c.g * 255).round() & 0xff;
    final b = (c.b * 255).round() & 0xff;
    final a = (c.a * 255).round() & 0xff;
    final base =
        '#${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}';
    return a == 0xff ? base : '$base${a.toRadixString(16).padLeft(2, '0')}';
  }

  /// Build a per-tab debug snapshot — index, key, friendly name,
  /// project path (if any), and chat message count for the tab's
  /// chat controller.
  Map<String, dynamic> _debugTabSnapshot(int i, StudioTab t) {
    final key = _chatKeyForTab(t);
    return <String, dynamic>{
      'index': i,
      'active': i == _active,
      'key': key,
      'name': t.name,
      'isHome': t.isHome,
      if (!t.isHome) ...<String, dynamic>{
        'isDraft': t.isDraft,
        'isModified': t.isModified,
      },
      if (t.currentProject != null) 'currentProject': t.currentProject,
    };
  }

  /// Active tab's activation context — bundle identity + the MCP names
  /// it exposes. `tools` / `agents` come straight off the registered
  /// ServerBootstrap / AgentHost surfaces, filtered to the bundle's
  /// `exposedShortId` prefix so the LLM sees only what's reachable
  /// against this tab. Used by `studio.debug.activation`.
  Map<String, dynamic> _debugActivation() {
    if (_active < 0 || _active >= _tabs.length) {
      return <String, dynamic>{'ok': false, 'reason': 'no-active-tab'};
    }
    final t = _tabs[_active];
    if (t.isHome) {
      return <String, dynamic>{'ok': true, 'tab': 'home'};
    }
    final ctx = t.activation;
    final exposed = ctx?.exposedShortId ?? '';
    final defs = widget.boot.toolDefinitions;
    final tools = <String>[
      for (final d in defs)
        if (exposed.isNotEmpty && d.name.startsWith('$exposed.')) d.name,
    ];
    final agents = <Map<String, dynamic>>[];
    final host = AgentHost.shared;
    if (host != null && exposed.isNotEmpty) {
      for (final p in host.profiles) {
        if (p.id.startsWith('$exposed.')) {
          agents.add(<String, dynamic>{
            'id': p.id,
            'displayName': p.displayName,
            'role': p.role.name,
            'modelId': p.modelId,
            'toolCount': p.toolNames.length,
          });
        }
      }
    }
    return <String, dynamic>{
      'ok': true,
      'tabKey': t.path,
      'bundleShortId': ctx?.bundle.shortId,
      'exposedNs': exposed.isEmpty ? null : exposed,
      'bundlePath': t.path,
      'currentProject': t.currentProject,
      'tools': tools,
      'agents': agents,
    };
  }

  /// Per-tab runtime state snapshot — calls each tab's hooks directly
  /// so multi-tab inspection sees fresh state. Used by
  /// `studio.debug.runtimes`.
  List<Map<String, dynamic>> _debugRuntimes() {
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < _tabs.length; i++) {
      final t = _tabs[i];
      if (t.isHome) continue;
      final key = t.path ?? '';
      final hooks = _tabRuntimeHooks[key];
      out.add(<String, dynamic>{
        'index': i,
        'active': i == _active,
        'tabKey': key,
        'name': t.name,
        'hooksAttached': hooks != null,
        if (hooks != null) 'state': hooks.readState(),
        if (t.currentProject != null) 'currentProject': t.currentProject,
      });
    }
    return out;
  }

  /// Drop a user turn into the chat for [tabKey] (or active tab) and
  /// trigger the agent reply. Used by `studio.chat.send` MCP tool for
  /// scenario-driven demos. When [waitForReply] is true (default) the
  /// returned future resolves only after the assistant turn lands.
  /// Per-unit chat controller key — `pkgPath::currentProject` (matches the
  /// UI's `_setActiveContext`) so the MCP send path, dispatch-trace append,
  /// debug snapshot, and the visible chat panel ALL address the SAME
  /// controller + persistence file. Keying by the bare tab path routes turns
  /// to a per-tab file while the UI uses a per-unit one — they diverge for any
  /// builtin that sets `t.currentProject` (Scene/Ops). `currentProject` is the
  /// active unit (project for Scene, the active workspace's bundle dir for
  /// Ops, set via `setActiveTabProject`).
  String _chatKeyForTab(StudioTab t) {
    if (t.isHome) return 'home';
    final pkg = t.path ?? 'home';
    final cp = t.currentProject;
    return (cp != null && cp.isNotEmpty) ? '$pkg::$cp' : pkg;
  }

  Future<Map<String, dynamic>> _sendChat({
    String? tabKey,
    required String text,
    bool waitForReply = true,
  }) async {
    String chatKey;
    StudioTab tab;
    if (tabKey != null && tabKey.isNotEmpty) {
      final idx =
          tabKey == 'home' ? 0 : _tabs.indexWhere((t) => t.path == tabKey);
      if (idx < 0) {
        return <String, dynamic>{
          'ok': false,
          'error': 'tab not found: $tabKey',
        };
      }
      tab = _tabs[idx];
      chatKey = tabKey == 'home' ? 'home' : _chatKeyForTab(tab);
    } else {
      if (_active < 0 || _active >= _tabs.length) {
        return <String, dynamic>{'ok': false, 'error': 'no active tab'};
      }
      tab = _tabs[_active];
      chatKey = _chatKeyForTab(tab);
    }
    final controller = widget.chatForKey(chatKey);
    // Report the effective manager — the per-unit scoped override (App
    // Builder / Scene per-project manager) when set, else the tab's base
    // manager. `controller.ask` routes through the same resolution.
    final effectiveAgentId =
        widget.chromeBridge.chatManagerOverride.value ?? tab.chatAgentId;
    final before = controller.turns.length;
    final ask = controller.ask(text);
    if (!waitForReply) {
      // Fire and forget — caller signed up for the user-turn-only ack.
      // ignore: unawaited_futures
      ask;
      return <String, dynamic>{
        'tabKey': chatKey,
        'agentId': effectiveAgentId,
        'waitedReply': false,
      };
    }
    await ask;
    final after = controller.turns;
    final reply = after.length > before ? after.last : null;
    return <String, dynamic>{
      'tabKey': chatKey,
      'agentId': effectiveAgentId,
      'waitedReply': true,
      if (reply != null) ...<String, dynamic>{
        'replyRole': reply.role,
        'replyTextPreview':
            reply.text.length > 600
                ? '${reply.text.substring(0, 600)}…'
                : reply.text,
      },
    };
  }

  /// Active tab's chat surface snapshot — agent + recent N turns.
  /// Used by `studio.debug.chat`.
  Map<String, dynamic> _debugChat(int limit) {
    if (_active < 0 || _active >= _tabs.length) {
      return <String, dynamic>{'ok': false, 'reason': 'no-active-tab'};
    }
    final t = _tabs[_active];
    final chatKey = t.isHome ? 'home' : (t.path ?? '');
    final controller = widget.chatForKey(chatKey);
    final all = controller.turns;
    final tail = all.length > limit ? all.sublist(all.length - limit) : all;
    return <String, dynamic>{
      'ok': true,
      'tabKey': chatKey,
      'agentId': t.chatAgentId,
      'turnCount': all.length,
      'turns': <Map<String, dynamic>>[
        for (final turn in tail)
          <String, dynamic>{
            'role': turn.role,
            'content':
                turn.text.length > 600
                    ? '${turn.text.substring(0, 600)}…'
                    : turn.text,
          },
      ],
    };
  }

  Future<void> _loadTabs() async {
    final file = File(_tabsFile);
    if (!await file.exists()) {
      widget.chromeBridge.recordBootEvent(
        'tabs.json not present — starting with Home only',
      );
      return;
    }
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final saved = <StudioTab>[];
      final seen = <String, int>{};
      // Snapshot the install registry once so per-entry verification
      // doesn't hammer the bundle store. TAB-LIFECYCLE.md §4 G2.
      final installedSnap = await widget.bundles.list();
      final installedPaths = <String>{
        for (final entry in installedSnap) entry['mbdPath'] as String? ?? '',
      };
      var droppedSeed = 0;
      var droppedInstalled = 0;
      var droppedDraft = 0;
      for (final e
          in (json['tabs'] as List<dynamic>? ?? const <dynamic>[])
              .whereType<Map<String, dynamic>>()) {
        // TAB-LIFECYCLE.md §1: three kinds (seed / installed / draft).
        // Each kind has a different validity proof — verify here so
        // a stale tabs.json can't sneak unsupported entries past the
        // chrome strip.
        String? path;
        final kind = (e['kind'] as String?) ?? '';
        if (kind == 'seed') {
          final ns = (e['namespace'] as String?) ?? '';
          // R21/R25 — seed namespace resolves through the host seed
          // map OR the BuiltIn launcher path table. `_loadTabs` and
          // `_saveTabs` use the same `_resolveSeedNamespacePath` /
          // `_seedNamespaceForPath` pair so a BuiltIn tab saved as
          // `kind:"seed"` round-trips back to the launcher.launchPath
          // on the next boot.
          path = ns.isEmpty ? null : _resolveSeedNamespacePath(ns);
          if (path == null) {
            droppedSeed++;
            continue;
          }
        } else {
          final persisted = (e['path'] as String?) ?? '';
          if (persisted.isEmpty) continue;
          // Legacy migration (SDD §1.4.4): if the persisted absolute
          // path matches a known seed by basename (.mbd dirname), use
          // the current seed path. The stored absolute path may have
          // gone stale due to package reorg; the seed's canonical
          // location is the host-supplied one.
          final base = p.basename(persisted);
          String? migrated;
          for (final entry in widget.seedPathByNamespace.entries) {
            if (p.basename(entry.value) == base) {
              migrated = entry.value;
              break;
            }
          }
          path = migrated ?? persisted;
          // Lifecycle invariant — non-seed entries must be either in
          // the install registry (installed) or on disk as a draft
          // `.mbd/manifest.json`. Anything else is stale and drops.
          final inRegistry = installedPaths.contains(path);
          final draftManifest = File(p.join(path, 'manifest.json'));
          final isDraftOnDisk = draftManifest.existsSync();
          if (!inRegistry && !isDraftOnDisk) {
            droppedInstalled++;
            continue;
          }
          if (!inRegistry && isDraftOnDisk) {
            // Draft path on disk but not registered — keep as draft
            // (author scratch) only when the persisted entry already
            // claimed draft kind. Otherwise we'd resurrect leftover
            // scratch packages every reboot.
            final wasDraft = (e['isDraft'] as bool?) ?? false;
            if (!wasDraft) {
              droppedDraft++;
              continue;
            }
          }
        }
        // Re-resolve from manifest so old persisted tabs that saved
        // the namespace as their label upgrade to the friendly name
        // on the next launch. Fall back to persisted value.
        final friendly = readFriendlyLabel(path);
        final base = friendly ?? (e['name'] as String?) ?? 'package';
        // Re-disambiguate fresh — two packages might have shared a
        // friendly name and the persisted label was already #2, but
        // we're rebuilding from scratch so honour current order.
        final n = (seen[base] ?? 0) + 1;
        seen[base] = n;
        final label = n == 1 ? base : '$base #$n';
        final tab = StudioTab.pkg(
          path,
          label,
          currentProject: e['currentProject'] as String?,
        );
        final persistedMode = (e['editorMode'] as String?) ?? 'ui';
        // Legacy 5th-mode 'settings' coerced to 'tools' — settings is now
        // a sub-surface inside Tools mode, not a top-level mode.
        tab.editorMode = persistedMode == 'settings' ? 'tools' : persistedMode;
        tab.isDraft = (e['isDraft'] as bool?) ?? false;
        tab.isModified = (e['isModified'] as bool?) ?? false;
        // Built-in app restore — the chat agent default does not
        // persist in tabs.json, so re-resolve via the chrome bridge
        // so the unified builder routing survives restart. Manifest
        // bundles still let `_activateBundle` overwrite this later
        // through `_resolveChatAgentId(manifest.chat.agent)`.
        final builtInAgent = widget.chromeBridge.defaultChatAgentResolver?.call(
          path,
        );
        if (builtInAgent != null && builtInAgent.isNotEmpty) {
          tab.chatAgentId = builtInAgent;
        }
        saved.add(tab);
      }
      final active = (json['active'] as int?) ?? 0;
      if (!mounted) return;
      setState(() {
        _tabs
          ..clear()
          ..add(StudioTab.home())
          ..addAll(saved);
        _active = active.clamp(0, _tabs.length - 1);
      });
      // Reset the runtime-state cache — the active tab's
      // DslWorkspaceView will emit a fresh snapshot through the
      // `onRuntimeStateChange` bridge slot once its runtime boots.
      _rebindRuntimeStateObserver();
      _syncHeaderActions();
      _syncHomeActive();
      _notifyContext();
      widget.chromeBridge.recordBootEvent(
        'tabs.json restored: ${saved.length} tab(s), active=$active'
        '${(droppedSeed + droppedInstalled + droppedDraft) > 0 ? " (dropped: seed=$droppedSeed installed=$droppedInstalled draft=$droppedDraft)" : ""}',
      );
      // Re-run activation for every restored package tab — manifests
      // are read fresh so any post-restart changes (added tools,
      // renamed agents, etc.) take effect. Once activation completes
      // (tools / agents registered), fire `domain.activate` exactly
      // once per tab so manifest seeds can resolve their JS handler
      // for one-time activation work (e.g. restore-last-project verbs
      // that read kb to reopen the previously active project).
      for (final t in saved) {
        final b = readBundleAt(t.path!);
        if (b == null) {
          widget.chromeBridge.recordBootEvent(
            'tab "${t.name}" path missing or unreadable: ${t.path}',
          );
          continue;
        }
        // ignore: unawaited_futures
        _activateBundle(t, b);
      }
      // Studio Builder is a built-in surface reached through the
      // chrome (the user closes the tab, the chrome can re-summon it).
      // We don't auto-open it on restore — that would override an
      // explicit close from the previous session.

      // Persist immediately so any legacy entries (path-only seed
      // tabs, stale absolute paths) get rewritten in the new
      // `{kind:"seed", namespace}` form — SDD §1.4.4.
      // ignore: unawaited_futures
      _saveTabs();
    } catch (e) {
      widget.chromeBridge.recordBootEvent('tabs.json restore failed: $e');
      // Corrupt tabs.json — start fresh, ignore.
    }
  }

  /// Reverse `seedPathByNamespace` + built-in launcher paths for a
  /// single path — returns the namespace when `path` matches either
  /// a registered seed bundle directory **or** a BuiltInLauncher's
  /// `launchPath` (R21 invariant — BuiltIn entry is the launcher path,
  /// not the seed path, so `_saveTabs` must annotate BuiltIn tabs as
  /// `kind:"seed"` to keep `_loadTabs` restore symmetric). Compares
  /// absolute paths so callers that hold either form match. Returns
  /// null when `path` is neither.
  String? _seedNamespaceForPath(String? path) {
    if (path == null || path.isEmpty) return null;
    final abs = File(path).absolute.path;
    for (final e in widget.seedPathByNamespace.entries) {
      if (File(e.value).absolute.path == abs) return e.key;
    }
    for (final l in widget.builtInLaunchers) {
      if (File(l.launchPath).absolute.path == abs) return l.id;
    }
    return null;
  }

  /// Resolve a `kind:"seed"` namespace back to its on-disk path —
  /// checks the host seed map first (e.g. studio), then falls
  /// back to BuiltInLauncher.launchPath when the namespace points at
  /// a built-in app. Returns null when the namespace is unknown to
  /// the host (the saved tab is then dropped by `_loadTabs`).
  String? _resolveSeedNamespacePath(String ns) {
    // R21 alignment — launcher.launchPath (`<workspaces>/<id>`) takes
    // precedence. The `BuiltInApp.canHandle` marker (`.builtin_<id>`)
    // exists only inside the launcher path, not under the seed/ absolute
    // path, so resolving with the old seed-first order makes
    // `BuiltInAppRegistry.matchFor` return null → the host falls back to
    // DslWorkspaceView's 'Empty bundle' placeholder (root cause of the
    // reported "Empty screen after relaunch"). seedPathByNamespace is
    // responsible only for the last-resort fallback for host assets whose
    // ns the launcher does not expose (e.g. knowledge-only seeds the user
    // does not mount directly, like the studio seed).
    for (final l in widget.builtInLaunchers) {
      if (l.id == ns) return l.launchPath;
    }
    return widget.seedPathByNamespace[ns];
  }

  Future<void> _saveTabs() async {
    // Snapshot the install registry once — per-tab kind annotation
    // checks against this to distinguish `installed` (in registry)
    // from `draft` (workspace-local scratch).
    List<Map<String, dynamic>> installedSnap;
    try {
      installedSnap = await widget.bundles.list();
    } catch (_) {
      installedSnap = const <Map<String, dynamic>>[];
    }
    final installedPaths = <String>{
      for (final entry in installedSnap) entry['mbdPath'] as String? ?? '',
    };
    final pkgTabs = <Map<String, dynamic>>[
      for (final t in _tabs.where((t) => !t.isHome))
        () {
          // TAB-LIFECYCLE.md §1: three kinds annotated explicitly.
          // Seed wins (host-internal); installed checks registry;
          // draft is the fallback (workspace scratch, not registered).
          final seedNs = _seedNamespaceForPath(t.path);
          final inRegistry = t.path != null && installedPaths.contains(t.path);
          final Map<String, dynamic> kindMap;
          if (seedNs != null) {
            kindMap = <String, dynamic>{'kind': 'seed', 'namespace': seedNs};
          } else if (inRegistry) {
            kindMap = <String, dynamic>{'kind': 'installed', 'path': t.path};
          } else {
            kindMap = <String, dynamic>{'kind': 'draft', 'path': t.path};
          }
          return <String, dynamic>{
            ...kindMap,
            'name': t.name,
            'editorMode': t.editorMode,
            'isDraft': t.isDraft,
            'isModified': t.isModified,
            if (t.currentProject != null) 'currentProject': t.currentProject,
          };
        }(),
    ];
    final payload = <String, dynamic>{'active': _active, 'tabs': pkgTabs};
    try {
      final file = File(_tabsFile);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(payload));
    } catch (_) {
      // Persistence is best-effort — failure shouldn't break the UI.
    }
  }

  /// Built-in apps (Ops / Scene) that own their project lifecycle call this
  /// via `chromeBridge.setActiveTabProject` after binding so the host's tab
  /// model + chat panel re-key to the project — the same side effect
  /// `_doOpenProject` gives manifest-domain tabs. Operates on the active tab
  /// only (the project-open contract requires the owning tab to be active),
  /// and no-ops for Home / unchanged project.
  void _setActiveTabProjectFromBuiltin(String? projectPath) {
    if (!mounted) return;
    final t = _tabs[_active];
    if (t.isHome) return;
    final next =
        (projectPath != null && projectPath.isEmpty) ? null : projectPath;
    if (t.currentProject == next) return;
    setState(() => t.currentProject = next);
    // Re-keys the chat to `<tabPath>::<project>` via onActiveContextChanged.
    _notifyContext();
    // ignore: unawaited_futures
    _saveTabs();
  }

  void _notifyContext() {
    final t = _tabs[_active];
    widget.onActiveContextChanged(
      t.isHome ? null : t.path,
      t.isHome ? null : t.currentProject,
    );
    // Mirror AppPlayer's "one buildWidget at a time" lifecycle —
    // publish the active tab key so DslWorkspaceView instances on
    // other tabs stop calling `runtime.buildUI()`. Without this the
    // `vibe_studio_runtime` fork's `NavigationService.instance.navigatorKey`
    // gets grabbed by every alive instance and Flutter reparents the
    // Navigator, blanking the visible tab.
    //
    // Two-phase publish: clear the key first, then schedule the new
    // value on the next microtask. Without the gap the outgoing tab
    // and the incoming tab swap in the same build frame — outgoing
    // still holds the process-singleton navigatorKey when incoming
    // mounts, Flutter rejects the duplicate, and the previous tab's
    // rendered content lingers visibly. The intermediate null frame
    // lets the outgoing runtime unmount and release the key before
    // the incoming one tries to claim it. (Going through Home works
    // for the same reason — Home has no DslWorkspaceView, so the key
    // gets released between transitions.)
    // Two-phase publish: clear the key first, then schedule the new
    // value on the next post-frame callback so the outgoing tab's
    // widget tree paints its placeholder before the incoming tab's
    // MaterialApp tries to grab the process-singleton navigatorKey.
    final newKey = t.isHome ? null : t.path;
    final bridge = widget.chromeBridge;
    if (bridge.activeTabKey.value == newKey) return;
    bridge.activeTabKey.value = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      bridge.activeTabKey.value = newKey;
    });
  }

  void _openPackage(String path, String fallbackName) {
    // Fire-and-forget — UI tap path doesn't need to await activation.
    // ignore: unawaited_futures
    _openPackageAsync(path, fallbackName);
  }

  /// Same as [_openPackage] but awaits the activation contract so
  /// callers (MCP `studio.bundle.activate`) only return once tools /
  /// agents are wired.
  Future<void> _openPackageAsync(
    String path,
    String fallbackName, {
    bool isDraft = false,
  }) async {
    final probe = readBundleAt(path);
    final existing = _tabs.indexWhere((t) => t.path == path);
    if (existing >= 0) {
      setState(() {
        _active = existing;
        if (isDraft) _tabs[existing].isDraft = true;
      });
      _syncHomeActive();
      _notifyContext();
      _syncHeaderActions();
      // ignore: unawaited_futures
      _saveTabs();
      return;
    }
    final bundle = probe;
    final friendly = bundle?.displayLabel ?? fallbackName;
    final uniqueLabel = _disambiguateLabel(friendly);
    final newTab = StudioTab.pkg(path, uniqueLabel)..isDraft = isDraft;
    // Built-in app routing — manifest-driven bundles resolve their
    // chat agent inside `_activateBundle` (reads
    // `manifest.chat.agent`). Built-in apps carry no manifest at the
    // workspace path, so the host asks the chrome bridge's resolver —
    // app_builder routes to `builder.manager` (unified builder agent
    // pool), other built-ins keep the `studio.manager` default by
    // returning null from their `defaultChatAgentId` override.
    final builtInAgent = widget.chromeBridge.defaultChatAgentResolver?.call(
      path,
    );
    if (builtInAgent != null && builtInAgent.isNotEmpty) {
      newTab.chatAgentId = builtInAgent;
    }
    setState(() {
      _tabs.add(newTab);
      _active = _tabs.length - 1;
    });
    _syncHomeActive();
    _notifyContext();
    _syncHeaderActions();
    _syncChatAgent();
    // ignore: unawaited_futures
    _saveTabs();
    if (bundle != null) {
      await _activateBundle(newTab, bundle);
    }
  }

  /// Open the activation contract for [tab] — wire bundle tools /
  /// agents / UI into the host. tools (Phase 2.2 mcp dispatch) +
  /// agents (Phase 4 catalog registration) wired now; UI (Phase 3)
  /// is read in `_bodyForActive` directly via the bundle.
  ///
  /// Phase 5.5 — gates on `requires.builtinTools`: if any required
  /// host tool is missing the activation aborts before any tool /
  /// agent is registered. The context is still attached to the tab
  /// so UI can read [HostBundleActivationContext.missingBuiltinTools]
  /// and surface the dependency gap.
  Future<void> _activateBundle(StudioTab tab, mb.McpBundle bundle) async {
    final exposedShortId = _disambiguateShortId(bundle.shortId);
    widget.chromeBridge.recordBootEvent(
      'activating bundle "${bundle.shortId}" → exposedNs=$exposedShortId',
    );

    // Resolve which server instance this bundle's tools land on by
    // running the bundle through the DomainServerManager. inherit=ON
    // (or OFF + URL matching the system) → system boot. inherit=OFF
    // + new URL → spawn a new instance and use its boot, so the
    // bundle's tools register onto its own MCP server rather than
    // the studio-wide one.
    //
    // attach failure (URL already in use externally) means the
    // domain MCP server is disabled — fall back to *no tool
    // registration at all* for the bundle. We do NOT silently
    // attach to the system; the user-visible toast plus the
    // `failed` entry in studio.debug.servers tells the operator
    // why their bundle's tools didn't appear.
    var bootForBundle = widget.boot;
    final mgr = widget.chromeBridge.domainServerManager;
    var attachOk = true;
    if (mgr != null && tab.path != null && tab.path!.isNotEmpty) {
      final overrides = _readDomainOverrides(tab.path!);
      final inherit = overrides['inheritFromSystem'] != false;
      final url = overrides['mcpServerUrl'] as String?;
      final outcome = await mgr.attach(
        tab.path!,
        inheritFromSystem: inherit,
        url: url,
      );
      if (!outcome.ok) {
        attachOk = false;
        widget.chromeBridge.notify?.call(
          'Domain MCP server at ${outcome.url} unavailable — '
          '${outcome.error}. Tools / knowledge for '
          '"${bundle.shortId}" not registered. Change the URL '
          'or stop the conflicting process.',
          severity: 'error',
        );
      } else {
        final inst = mgr.findByUrl(outcome.url);
        if (inst != null) bootForBundle = inst.boot;
      }
    }

    final ctx = HostBundleActivationContext(
      boot: bootForBundle,
      tabKey: tab.path ?? '',
      bundle: bundle,
      exposedShortId: exposedShortId,
      chromeBridge: widget.chromeBridge,
      knowledgeEngine: widget.bundles.knowledgeEngine,
      domainStorage: widget.domainStorage,
      sessionBridge: widget.chromeBridge.sessionBridge,
    );
    tab.activation = ctx;
    if (!attachOk) {
      // Manager already surfaced the toast; skip tool / agent
      // registration so the bundle sits inert in the tab list.
      return;
    }
    if (!ctx.validateBuiltinTools()) {
      widget.chromeBridge.recordBootEvent(
        'activation aborted for "${bundle.shortId}": builtin atom validation failed',
      );
      // Required host tool(s) missing — leave the context attached
      // (so the UI can render the gap) but skip registering anything
      // that would interact with the broken dependency surface.
      return;
    }
    // Fan out the bundle's knowledge entries as MCP resources on
    // its server instance. URI namespaces by exposedShortId so two
    // bundles attached to the same instance (URL-grouping multiplex)
    // don't collide. Inert when the bundle has no knowledge.
    for (final src in bundle.knowledge?.sources ?? const []) {
      for (final doc in src.documents ?? const <mk.KnowledgeDocument>[]) {
        final docId = doc.id;
        if (docId == null || docId.isEmpty) continue;
        final docContent = doc.content;
        final title = doc.title ?? docId;
        final description = src.description ?? src.name;
        final uri = 'studio://$exposedShortId/knowledge/${src.id}/$docId';
        try {
          bootForBundle.addResource(
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
                      text: docContent,
                    ),
                  ],
                ),
          );
        } on mh.McpError {
          // Re-activation of the same bundle (idempotent re-attach)
          // hits the duplicate-URI guard. Safe to swallow — the
          // resource is already exposed.
        }
      }
    }
    for (final tool in bundle.tools?.tools ?? const <mb.ToolEntry>[]) {
      await ctx.registerTool(tool);
    }
    // Knowledge-operations §6 — 4-axis + fact + flow activation. The
    // register* methods stub-fail (`ok:false`) when their underlying
    // facade/runtime isn't wired yet; activation continues so the
    // tab still gets tools + agents + UI working surface.
    for (final skill in bundle.skills?.modules ?? const <mb.SkillModule>[]) {
      await ctx.registerSkill(skill);
    }
    for (final profile
        in bundle.profiles?.profiles ?? const <mb.ProfileDefinition>[]) {
      await ctx.registerProfile(profile);
    }
    for (final philosophy
        in bundle.philosophy?.philosophies ?? const <mb.Philosophy>[]) {
      await ctx.registerPhilosophy(philosophy);
    }
    // Facts come in two shapes: `bundle.facts.facts` (mb.Fact, simple
    // subject/predicate/object triples) vs
    // `bundle.factGraphSection.embedded.facts` (mb.EmbeddedFact,
    // L0 fact-graph entries). interface `registerFact(mb.Fact)`
    // covers the first shape only — EmbeddedFact wiring lands in a
    // later round once the FactRecord adapter (subject/predicate/
    // object → entity/type/content) is settled.
    for (final fact in bundle.facts?.facts ?? const <mb.Fact>[]) {
      await ctx.registerFact(fact);
    }
    for (final flow in bundle.flow?.flows ?? const <mb.FlowDefinition>[]) {
      await ctx.registerFlow(flow);
    }
    for (final agent in bundle.agents?.agents ?? const <mb.AgentDefinition>[]) {
      await ctx.registerAgent(agent);
    }
    // Every domain bundle ends up with a `<shortId>.manager` agent so
    // its tab always has a working chat surface — even bundles that
    // didn't declare an agents section. If the bundle declared an
    // agent with id="manager" (canonical fold-in path) we keep that;
    // otherwise synthesise a sensible default manager.
    final defaultManagerId = '$exposedShortId.manager';
    final host = AgentHost.shared;
    if (host != null && host.profileFor(defaultManagerId) == null) {
      final label = bundle.displayLabel;
      final synthetic = mb.AgentDefinition(
        id: 'manager',
        name: '$label Manager',
        role: 'manager',
        systemPrompt:
            'You are the manager agent for $label. Help the user '
            "drive this bundle's surface — use studio.knowledge.query "
            'for context, studio.agent.list / studio.agent.dispatch '
            'to delegate to bundle specialists when one is needed, '
            "and the bundle's own tools (under prefix '$exposedShortId.') "
            'to execute. Ask the user for clarification when intent is '
            'ambiguous.',
        model: const mb.AgentModelConfig(
          provider: 'anthropic',
          model: 'claude-opus-4-7',
        ),
        tools: const <String>[
          'bk.knowledge.query',
          'bk.agent.list',
          'bk.agent.dispatch',
          'studio.meta.list_tools',
          'studio.meta.describe_tool',
        ],
      );
      await ctx.registerAgent(synthetic);
    }
    // Resolve the bundle's chat agent — explicit manifest.chat.agent
    // wins; otherwise the synthesised (or declared) <shortId>.manager.
    tab.chatAgentId = _resolveChatAgentId(
      tab.path,
      exposedShortId,
      defaultManagerId,
    );
    _syncChatAgent();
    final toolsCount = bundle.tools?.tools.length ?? 0;
    final agentsCount = bundle.agents?.agents.length ?? 0;
    widget.chromeBridge.recordBootEvent(
      'activated "${bundle.shortId}": $toolsCount tool(s), $agentsCount agent(s), chat=${tab.chatAgentId}',
    );
  }

  /// Studio convention — the chat agent for any bundle is the first
  /// `role: manager` entry in its `manifest.json#/agents`. No separate
  /// `chat.agent` field; no host-side hard-coded fallback. Returns the
  /// passed-in [defaultManagerId] (always `<shortId>.manager`) when the
  /// manifest is missing / unreadable / has no manager — that id is
  /// guaranteed registered by `_activateBundle`'s synthesise path.
  String _resolveChatAgentId(
    String? mbdPath,
    String exposedShortId,
    String defaultManagerId,
  ) {
    if (mbdPath == null) return defaultManagerId;
    final manager = readSeedChatManager(
      manifestPath: p.join(mbdPath, 'manifest.json'),
      exposedShortId: exposedShortId,
    );
    return manager ?? defaultManagerId;
  }

  /// Append a turn into the currently-active chat thread. Used by
  /// `studio.agent.dispatch` to emit inline trace turns ("→ specialist
  /// dispatched") so the user sees the manager's chain.
  void _appendActiveChatTurn(ChatTurn turn) {
    final tab =
        (_active >= 0 && _active < _tabs.length) ? _tabs[_active] : null;
    if (tab == null) return;
    final key = _chatKeyForTab(tab);
    widget.chatForKey(key).appendTurn(turn);
  }

  void _syncChatAgent() {
    final bridge = widget.chromeBridge;
    var id =
        (_active >= 0 && _active < _tabs.length)
            ? _tabs[_active].chatAgentId
            : '';
    if (id.isEmpty) {
      // No manager wired yet — ask the host resolver to derive one
      // from the active tab's seed manifest (`role: manager`).
      final tab =
          (_active >= 0 && _active < _tabs.length) ? _tabs[_active] : null;
      final lookup = tab == null ? null : (tab.isHome ? 'home' : tab.path);
      if (lookup != null) {
        id = bridge.defaultChatAgentResolver?.call(lookup) ?? '';
        if (id.isNotEmpty && tab != null) tab.chatAgentId = id;
      }
    }
    if (bridge.activeChatAgentId.value != id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        bridge.activeChatAgentId.value = id;
      });
    }
  }

  /// Append ` #N` when [base] collides with an existing tab label.
  /// First instance keeps the plain label (option C from the design
  /// notes — single-instance is the 90% case so don't pay the noise
  /// cost there). Second collision becomes ` #2`, third ` #3`, etc.
  String _disambiguateLabel(String base) {
    if (!_tabs.any((t) => t.name == base)) return base;
    var n = 2;
    while (_tabs.any((t) => t.name == '$base #$n')) {
      n++;
    }
    return '$base #$n';
  }

  /// Same option-C rule applied to [shortId] for the MCP tool prefix.
  /// First active bundle of a given shortId stays plain; later ones
  /// get `_2` / `_3`. Walks active activations (not tabs) so an
  /// inactive tab whose context was torn down doesn't reserve a
  /// slot.
  String _disambiguateShortId(String base) {
    bool inUse(String candidate) => _tabs.any(
      (t) => t.activation != null && t.activation!.exposedShortId == candidate,
    );
    if (!inUse(base)) return base;
    var n = 2;
    while (inUse('${base}_$n')) {
      n++;
    }
    return '${base}_$n';
  }

  void _closeTab(int i) {
    if (i < 0 || i >= _tabs.length) return;
    if (_tabs[i].isHome) return;
    final closing = _tabs[i];
    // Drafts get their own three-way prompt (Discard / Save for later
    // / Cancel) — they live under drafts/ and may need to survive past
    // the tab close.
    if (closing.isDraft) {
      // ignore: unawaited_futures
      _confirmCloseDraft(i);
      return;
    }
    // Non-draft tabs that the user has touched (chat sent, builder
    // mutator executed, …) get a lighter Cancel / Close-anyway prompt
    // so the close action doesn't quietly drop work or chat history.
    if (closing.isModified) {
      // ignore: unawaited_futures
      _confirmCloseModified(i);
      return;
    }
    _doCloseTab(i);
  }

  /// Apply the actual tab teardown — separated from [_closeTab] so the
  /// draft confirmation handler can call it after the user's choice.
  void _doCloseTab(int i) {
    if (i < 0 || i >= _tabs.length) return;
    final closing = _tabs[i];
    final ctx = closing.activation;
    if (ctx != null) {
      // ignore: unawaited_futures
      ctx.unregisterAll();
      closing.activation = null;
    }
    // Wipe the tab's chat thread — closing the tab is the user's
    // signal that the conversation is over, so we don't want it to
    // reappear next time the same bundle is opened. `clear()` also
    // fires the controller's `onClearLog` so any persisted chat.jsonl
    // is removed alongside the in-memory feed.
    final chatKey = closing.path ?? 'home';
    // ignore: unawaited_futures
    widget.chatForKey(chatKey).clear();
    setState(() {
      _tabs.removeAt(i);
      // Closing a tab left of the active one shifts the active index
      // down by one — without this the index keeps pointing to its
      // old slot, which now holds the *next* tab, so the chrome
      // silently switches active domains (e.g. AppBuilder → pkg_y),
      // clears the previous domain's lifecycle wiring, and shows
      // "no project" even though the user only closed a sibling tab.
      if (i < _active) {
        _active -= 1;
      } else if (_active >= _tabs.length) {
        _active = _tabs.length - 1;
      }
      if (_active < 0) _active = 0;
    });
    _syncHomeActive();
    _notifyContext();
    // Re-push the new active tab's header actions + lifecycle state
    // into the chrome bridge. Without this, the bridge keeps the
    // closed tab's resolver result (or an empty fallback), so the
    // ProjectHeader shows "no project" for the surviving active tab
    // until the user touches another tab and comes back.
    _syncHeaderActions();
    // ignore: unawaited_futures
    _saveTabs();
  }

  /// Confirmation dialog shown when the user closes a tab that has
  /// been touched (chat sent, builder mutator run, etc.). Two exits:
  /// Cancel (no-op), Close anyway (apply teardown + wipe chat).
  Future<void> _confirmCloseModified(int i) async {
    final c = VbuTokens.colorOf(context);
    final tab = _tabs[i];
    final result = await showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: c.surface2,
            title: Text(
              'Close "${tab.name}"?',
              style: TextStyle(
                fontFamily: VbuTokens.fontSans,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: c.textPrimary,
              ),
            ),
            content: Text(
              'This tab has unsaved changes — chat history and any '
              'in-progress authoring will be discarded when the tab '
              'closes.',
              style: TextStyle(
                fontFamily: VbuTokens.fontSans,
                fontSize: 12,
                color: c.textSecondary,
                height: 1.5,
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('cancel'),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('close'),
                child: const Text('Close anyway'),
              ),
            ],
          ),
    );
    if (!mounted) return;
    if (result == 'close') {
      _doCloseTab(i);
    }
  }

  /// Confirmation dialog shown when the user closes a draft tab. The
  /// draft hasn't been Exported / Installed, so closing it silently
  /// would lose work. Three exits: Cancel (no-op), Save for later
  /// (close the tab but leave the mbd in drafts/ so a future
  /// "Resume drafts" menu can re-open it), Discard (delete the mbd
  /// + close the tab). Export wiring is stubbed for the next round.
  Future<void> _confirmCloseDraft(int i) async {
    final c = VbuTokens.colorOf(context);
    final tab = _tabs[i];
    // Builder tabs editing a draft are dual-natured: `tab.path` points
    // at the seed (the builder bundle itself, MUST NEVER be deleted)
    // while `tab.currentProject` points at the draft being authored.
    // For these the discard target is the draft, and the builder tab
    // itself stays open after reset — closing the builder is a
    // separate user gesture.
    // A seed tab editing a draft is dual-natured (tab.path = seed,
    // tab.currentProject = draft). Detect by checking whether the tab's
    // path matches a known seed namespace (SDD §1.4) — no host-side
    // mode flag.
    final isBuilderDraft =
        _seedNamespaceForPath(tab.path) != null && tab.currentProject != null;
    final discardTarget = isBuilderDraft ? tab.currentProject : tab.path;
    final draftLabel =
        isBuilderDraft ? p.basename(tab.currentProject!) : tab.name;
    final result = await showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: c.surface2,
            title: Text(
              'Close draft "$draftLabel"?',
              style: TextStyle(
                fontFamily: VbuTokens.fontSans,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: c.textPrimary,
              ),
            ),
            content: Text(
              'This package is a draft — it has not been Exported or '
              'Installed yet. Closing the tab without exporting will '
              'either keep it under drafts/ (so a future "Resume drafts" '
              'menu can re-open it) or discard it entirely.',
              style: TextStyle(
                fontFamily: VbuTokens.fontSans,
                fontSize: 12,
                color: c.textSecondary,
                height: 1.5,
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('cancel'),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('discard'),
                child: const Text('Discard'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('save'),
                child: const Text('Save for later'),
              ),
              TextButton(
                onPressed: null, // Export wiring lands in next round.
                child: const Text('Export'),
              ),
            ],
          ),
    );
    if (result == null || result == 'cancel') return;
    if (result == 'discard') {
      if (isBuilderDraft) {
        // Reset the builder tab back to fresh (no draft) — DO NOT
        // close the tab and DO NOT touch `tab.path` (= seed).
        setState(() {
          tab.currentProject = null;
          tab.isDraft = false;
        });
        try {
          widget.chromeBridge.updateRuntimeState?.call(<String, dynamic>{
            'currentProject': '',
          });
        } catch (_) {
          /* swallow — non-fatal */
        }
        // ignore: unawaited_futures
        _saveTabs();
      } else {
        _doCloseTab(i);
      }
      if (discardTarget != null) {
        try {
          await Directory(discardTarget).delete(recursive: true);
        } catch (_) {
          /* swallow — directory may be gone already */
        }
      }
      return;
    }
    // 'save' — keep the mbd on disk, just close the draft surface.
    // For builder tabs this resets the tab to fresh (draft stays in
    // workspace/); for free-floating draft tabs we close the tab.
    if (isBuilderDraft) {
      setState(() {
        tab.currentProject = null;
        tab.isDraft = false;
      });
      try {
        widget.chromeBridge.updateRuntimeState?.call(<String, dynamic>{
          'currentProject': '',
        });
      } catch (_) {
        /* swallow — non-fatal */
      }
      // ignore: unawaited_futures
      _saveTabs();
    } else {
      _doCloseTab(i);
    }
  }

  void _selectTab(int i) {
    setState(() => _active = i);
    // Swap the runtime-state observer onto the new active tab — its
    // bundle's state drives header emphasis. The host doesn't know
    // which keys the bundle uses for emphasisedWhen; it just mirrors
    // whatever the active tab's runtime says.
    _rebindRuntimeStateObserver();
    // [_notifyContext] before [_syncHeaderActions] — `_notifyContext`
    // calls the host's `_setActiveContext` which re-points the
    // built-in registry's `activeContext` to the new tab. The header
    // / lifecycle resolvers read that singleton, so without this
    // ordering the resolver still sees the previous tab's ctx and
    // returns null for the new tab's path — chrome ProjectHeader
    // collapses to the empty default ("no project") even when the
    // new tab's built-in has a project loaded.
    _notifyContext();
    _syncHeaderActions();
    _syncHomeActive();
    // ignore: unawaited_futures
    _saveTabs();
  }

  /// Manifest-side chrome lifecycle channel — mirrors what a built-in
  /// app exposes through [BuiltInAppContext.lifecycleStateProvider],
  /// but driven by binding expressions declared in the bundle's
  /// `manifest.wiring.lifecycleStateBindings` block.
  ///
  /// Shape on disk:
  /// ```json
  /// "wiring": {
  ///   "lifecycleStateBindings": {
  ///     "projectName": "{{currentProject}}",
  ///     "hasProject": "{{currentProject != ''}}",
  ///     "dirty": "{{isDirty}}",
  ///     "canUndo": "{{canUndo}}",
  ///     "canRedo": "{{canRedo}}"
  ///   }
  /// }
  /// ```
  /// Each value is resolved against [liveState] (the active tab's
  /// runtime state map). Bindings using `{{...}}` are evaluated as
  /// pure-state expressions — the same shape the runtime engine
  /// applies to widget props. Missing keys fall through to the
  /// `DomainLifecycleState.empty()` defaults. Returns `null` when the
  /// bundle declares no bindings so the caller stays on the empty
  /// state path.
  DomainLifecycleState? _readManifestLifecycleBindings(
    String mbdPath,
    Map<String, Object?> liveState,
  ) {
    if (mbdPath.isEmpty) return null;
    Map<String, dynamic>? bindings;
    try {
      final file = File(p.join(mbdPath, 'manifest.json'));
      if (!file.existsSync()) return null;
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) return null;
      final wiring = raw['wiring'];
      if (wiring is! Map<String, dynamic>) return null;
      final block = wiring['lifecycleStateBindings'];
      if (block is! Map<String, dynamic>) return null;
      bindings = block;
    } catch (_) {
      return null;
    }
    if (bindings.isEmpty) return null;

    String? readString(String key) {
      final raw = bindings![key];
      if (raw is! String) return raw?.toString();
      return _evalBinding(raw, liveState)?.toString();
    }

    bool readBool(String key) {
      final raw = bindings![key];
      if (raw is bool) return raw;
      if (raw is! String) return false;
      final v = _evalBinding(raw, liveState);
      if (v is bool) return v;
      if (v is String) return v.isNotEmpty && v != 'false' && v != '0';
      if (v is num) return v != 0;
      return v != null;
    }

    return DomainLifecycleState(
      hasProject: readBool('hasProject'),
      dirty: readBool('dirty'),
      canUndo: readBool('canUndo'),
      canRedo: readBool('canRedo'),
      canCompareChannels: readBool('canCompareChannels'),
      projectName: readString('projectName'),
    );
  }

  /// Evaluate a single binding expression against [state]. Supports
  /// either a bare `{{key}}` lookup or a `{{a != ''}}` / `{{!key}}`
  /// style negation / inequality check. Falls back to returning the
  /// raw string (with no `{{...}}` wrapper) untouched when no template
  /// is detected.
  Object? _evalBinding(String src, Map<String, Object?> state) {
    final trimmed = src.trim();
    final m = RegExp(r'^\{\{(.+)\}\}$').firstMatch(trimmed);
    if (m == null) return trimmed;
    final expr = m.group(1)!.trim();
    // `key != ''` / `key == ''`
    final neq = RegExp(r"^(\w+)\s*!=\s*''$").firstMatch(expr);
    if (neq != null) {
      final v = state[neq.group(1)!];
      if (v == null) return false;
      if (v is String) return v.isNotEmpty;
      return true;
    }
    final eq = RegExp(r"^(\w+)\s*==\s*''$").firstMatch(expr);
    if (eq != null) {
      final v = state[eq.group(1)!];
      if (v == null) return true;
      if (v is String) return v.isEmpty;
      return false;
    }
    // `!key`
    if (expr.startsWith('!')) {
      final key = expr.substring(1).trim();
      final v = state[key];
      if (v == null || v == false || v == '' || v == 0) return true;
      return false;
    }
    // Plain key lookup.
    return state[expr];
  }

  /// External LLM onboarding panel — shows the studio's MCP endpoint
  /// URL + ready-to-paste config snippets for Claude Desktop, Claude
  /// Code, and a generic curl probe, each with a copy button. Mounted
  /// to chromeBridge.openOnboarding so the
  /// `studio.chrome.open_onboarding` MCP tool + Settings can both
  /// trigger it.
  Future<void> _showOnboarding() async {
    // Studio's canonical default port — VibeStudioHostApp.defaultPort.
    // A future round can thread the actual runtime port through the
    // chrome bridge for hosts that override; today 7830 is universal.
    const port = 7830;
    const endpoint = 'http://127.0.0.1:$port/mcp';
    final desktopConfig = const JsonEncoder.withIndent('  ').convert(
      <String, dynamic>{
        'mcpServers': <String, dynamic>{
          'vibe_studio': <String, dynamic>{
            'transport': <String, dynamic>{
              'type': 'streamable_http',
              'url': endpoint,
            },
          },
        },
      },
    );
    final codeCmd = 'claude mcp add vibe_studio --transport http $endpoint';
    final curlProbe =
        'curl -s -X POST $endpoint \\\n'
        "  -H 'Content-Type: application/json' \\\n"
        "  -H 'Accept: application/json, text/event-stream' \\\n"
        '  -d \'{"jsonrpc":"2.0","id":1,"method":"initialize",'
        '"params":{"protocolVersion":"2024-11-05","clientInfo":'
        '{"name":"probe","version":"0"},"capabilities":{}}}\'';
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final c = VbuTokens.colorOf(context);
        return Dialog(
          backgroundColor: c.surface2,
          child: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(VbuTokens.space4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    'Connect an external LLM',
                    style: TextStyle(
                      fontFamily: VbuTokens.fontSans,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                  ),
                  const SizedBox(height: VbuTokens.space2),
                  Text(
                    'AppPlayer Studio exposes every tool surface as an '
                    'MCP server. Point your external client at the '
                    'endpoint below — once connected, the LLM sees all '
                    '${(_mcpToolCount() ?? '?')} tools and can drive the '
                    'studio just like the built-in manager agent.',
                    style: TextStyle(
                      fontFamily: VbuTokens.fontSans,
                      fontSize: 12,
                      color: c.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: VbuTokens.space4),
                  _OnboardingRow(label: 'MCP endpoint', value: endpoint),
                  const SizedBox(height: VbuTokens.space3),
                  _OnboardingBlock(
                    title:
                        'Claude Desktop — '
                        '~/Library/Application Support/Claude/'
                        'claude_desktop_config.json',
                    body: desktopConfig,
                  ),
                  const SizedBox(height: VbuTokens.space3),
                  _OnboardingBlock(title: 'Claude Code (CLI)', body: codeCmd),
                  const SizedBox(height: VbuTokens.space3),
                  _OnboardingBlock(
                    title: 'Generic — initialize probe (curl)',
                    body: curlProbe,
                  ),
                  const SizedBox(height: VbuTokens.space4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Close'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Agent surface view — lists every registered agent so the user
  /// (or external client) can see who the manager can dispatch to.
  /// Reads from AgentHost.shared.profiles directly so activated
  /// bundle agents appear without a separate refresh.
  Future<void> _showAgents() async {
    final host = AgentHost.shared;
    final profiles = host == null ? const <VibeAgentProfile>[] : host.profiles;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final c = VbuTokens.colorOf(context);
        return Dialog(
          backgroundColor: c.surface2,
          child: SizedBox(
            width: 760,
            height: 560,
            child: Padding(
              padding: const EdgeInsets.all(VbuTokens.space4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    'Agents (${profiles.length})',
                    style: TextStyle(
                      fontFamily: VbuTokens.fontSans,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                  ),
                  const SizedBox(height: VbuTokens.space2),
                  Text(
                    'Studio defaults plus agents contributed by '
                    'activated bundles. Manager dispatches to any of '
                    'these via studio.agent.dispatch.',
                    style: TextStyle(
                      fontFamily: VbuTokens.fontSans,
                      fontSize: 11,
                      color: c.textSecondary,
                    ),
                  ),
                  const SizedBox(height: VbuTokens.space3),
                  Expanded(
                    child: ListView.separated(
                      itemCount: profiles.length,
                      separatorBuilder:
                          (_, __) => const SizedBox(height: VbuTokens.space2),
                      itemBuilder: (_, i) => _AgentCard(profile: profiles[i]),
                    ),
                  ),
                  const SizedBox(height: VbuTokens.space3),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Close'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  int? _mcpToolCount() {
    try {
      return widget.boot.toolDefinitions.length;
    } catch (_) {
      return null;
    }
  }

  Future<void> _reloadTab(int? indexOrNull) async {
    final i = indexOrNull ?? _active;
    if (i < 0 || i >= _tabs.length || _tabs[i].isHome) return;
    final t = _tabs[i];
    final path = t.path;
    if (path != null) {
      // Tear down the activation context (unregisters tools / agents)
      // and rebuild fresh from disk so manifest edits (added tools, new
      // ui section, patched description) take effect.
      final old = t.activation;
      if (old != null) {
        // ignore: unawaited_futures
        old.unregisterAll();
        t.activation = null;
      }
      final freshBundle = readBundleAt(path);
      if (freshBundle != null) {
        await _activateBundle(t, freshBundle);
      }
    }
    setState(() => t.reloadCounter++);
    // Reload re-reads manifest, which may have new wiring.domainActions.
    // Push fresh header actions so the left panel surface catches up.
    _syncHeaderActions();
  }

  Future<Map<String, dynamic>> _doNewProject({
    required String name,
    required String parent,
  }) async {
    final t = _tabs[_active];
    if (t.isHome) {
      return <String, dynamic>{'ok': false, 'error': 'no active package tab'};
    }
    final dir = Directory(p.join(parent, name));
    try {
      await dir.create(recursive: true);
    } catch (e) {
      return <String, dynamic>{'ok': false, 'error': '$e'};
    }
    setState(() => t.currentProject = dir.path);
    _notifyContext();
    // ignore: unawaited_futures
    _saveTabs();
    // ignore: unawaited_futures
    widget.chromeBridge.recordRecentProject?.call(dir.path);
    return <String, dynamic>{'ok': true, 'projectPath': dir.path};
  }

  Future<Map<String, dynamic>> _doOpenProject(String path) async {
    final t = _tabs[_active];
    if (t.isHome) {
      return <String, dynamic>{'ok': false, 'error': 'no active package tab'};
    }
    if (path.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': 'path required'};
    }
    // Scene Builder projects use `scene.json` as their root marker
    // instead of `manifest.json` — recognise those directly so the
    // chrome's New/Open lifecycle works the same for builder + scene
    // tabs without forcing scene projects through the `.mbd` schema.
    String? resolved;
    if (File(p.join(path, 'scene.json')).existsSync()) {
      resolved = path;
    } else {
      resolved = _resolveBundlePath(path);
    }
    if (resolved == null) {
      return <String, dynamic>{
        'ok': false,
        'error':
            'no manifest.json or scene.json found under $path '
            '(expected `<path>/manifest.json`, a project meta '
            'file pointing at a `.mbd` subdir, or a `scene.json` '
            'marker for a Scene Builder project)',
      };
    }
    setState(() => t.currentProject = resolved);
    _notifyContext();
    // Push currentProject into the active DSL runtime so seed bindings
    // (`{{currentProject}}` on VbuBundleToolsEditor / VbuBundleEmbed /
    // VbuBundleKnowledgeView / VbuBundleManifestView) update immediately.
    // Same runtime-state push the `_createNewPackage` flow uses after
    // dropping the App Builder marker, so the open-project path and
    // the create-new-project path land on identical runtime state.
    widget.chromeBridge.updateRuntimeState?.call(<String, dynamic>{
      'currentProject': resolved,
    });
    // ignore: unawaited_futures
    _saveTabs();
    // ignore: unawaited_futures
    widget.chromeBridge.recordRecentProject?.call(resolved);
    return <String, dynamic>{'ok': true, 'projectPath': resolved};
  }

  /// Resolve [picked] (the folder the user pointed at) to the actual
  /// `.mbd/` bundle directory the editors should read against. Three
  /// cases:
  ///   1. `<picked>/manifest.json` exists → the picked path IS the mbd.
  ///   2. `<picked>` carries a project meta file (`*.sbproj` /
  ///      `*.apbproj`) with a `bundle` (or active-channel `subdir`)
  ///      field → resolve relative to picked.
  ///   3. `<picked>` has exactly one `*.mbd` sub-directory →
  ///      auto-resolve to it (no meta required).
  /// Returns null when none of the three resolve to an existing
  /// `manifest.json`.
  String? _resolveBundlePath(String picked) {
    final dir = Directory(picked);
    if (!dir.existsSync()) return null;
    // Case 1 — picked IS the mbd.
    if (File(p.join(picked, 'manifest.json')).existsSync()) {
      return picked;
    }
    // Case 2 — read project meta if present.
    File? metaFile;
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path);
      if (ext == '.sbproj' || ext == '.apbproj') {
        metaFile = entity;
        break;
      }
    }
    if (metaFile != null) {
      try {
        final raw = jsonDecode(metaFile.readAsStringSync());
        if (raw is Map<String, dynamic>) {
          String? sub = raw['bundle']?.toString();
          if (sub == null || sub.isEmpty) {
            final channels = raw['channels'];
            final active = raw['activeChannel']?.toString() ?? 'main';
            if (channels is Map && channels[active] is Map) {
              sub = (channels[active] as Map)['subdir']?.toString();
            }
          }
          if (sub != null && sub.isNotEmpty) {
            final mbd = p.join(picked, sub);
            if (File(p.join(mbd, 'manifest.json')).existsSync()) {
              return mbd;
            }
          }
        }
      } catch (_) {
        /* fall through to case 3 */
      }
    }
    // Case 3 — single .mbd subdir.
    final mbds = <Directory>[
      for (final e in dir.listSync())
        if (e is Directory && p.extension(e.path) == '.mbd') e,
    ];
    if (mbds.length == 1 &&
        File(p.join(mbds.first.path, 'manifest.json')).existsSync()) {
      return mbds.first.path;
    }
    return null;
  }

  Map<String, dynamic> _doCloseProject() {
    final t = _tabs[_active];
    if (t.isHome) {
      return <String, dynamic>{'ok': false, 'error': 'no active package tab'};
    }
    if (t.currentProject == null) {
      return <String, dynamic>{'ok': true, 'closed': false};
    }
    setState(() => t.currentProject = null);
    // Mirror to the running runtime so DSL bindings on
    // `{{currentProject}}` reset to empty — without this the workspace
    // body keeps showing the just-closed project until tab reload.
    try {
      widget.chromeBridge.updateRuntimeState?.call(<String, dynamic>{
        'currentProject': '',
      });
    } catch (_) {
      /* swallow — non-fatal */
    }
    _notifyContext();
    // ignore: unawaited_futures
    _saveTabs();
    return <String, dynamic>{'ok': true, 'closed': true};
  }

  Future<void> _newProject() async {
    final workspaceDir = _readWorkspaceDir();
    final input = await promptForNewProject(
      context,
      defaultParent:
          workspaceDir ??
          p.join(Platform.environment['HOME'] ?? '/tmp', 'AppPlayerProjects'),
    );
    if (input == null) return;
    await _doNewProject(name: input.name, parent: input.parent);
  }

  Future<void> _openProject() async {
    final workspaceDir = _readWorkspaceDir();
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Open project folder',
      initialDirectory: workspaceDir,
    );
    if (picked == null) return;
    final result = await _doOpenProject(picked);
    if (result['ok'] != true) {
      final err = result['error']?.toString() ?? 'open failed';
      widget.chromeBridge.notify?.call(
        'Open project failed: $err',
        severity: 'error',
      );
    }
  }

  /// Scaffold a new `.mbd` package directory and install it into the
  /// registry. Bootstrap-grade — emits a minimal manifest + ui/app.json
  /// stub so the new bundle is renderable immediately. Full
  /// Studio-Builder authoring lands in a later round.
  /// Single create-package code path shared by the Home "Create
  /// package" button and the `studio.chrome.create_package` MCP tool.
  /// Args:
  ///   - all null → opens the dialog (UI button path);
  ///   - name + (optional parent / id) → programmatic create, no
  ///     dialog (MCP / external LLM path).
  /// Returns `{ok, mbdPath, name, namespace}` on success or
  /// `{ok: false, error}` on failure.
  Future<Map<String, dynamic>> _createNewPackage({
    String? name,
    String? parent,
    String? id,
  }) async {
    // Parent dir preference: studio-wide `workspaceDir` setting (when
    // set) > `<configRoot>/drafts/` fallback. The drafts/ fallback
    // keeps Create Package working before the user picks a workspace.
    final workspaceDir = _readWorkspaceDir();
    final defaultRoot = workspaceDir ?? p.join(widget.configRoot, 'drafts');
    String resolvedName;
    String resolvedParent;
    if (name == null || name.trim().isEmpty) {
      final input = await promptForNewProject(
        context,
        defaultParent: defaultRoot,
        kind: 'package',
      );
      if (input == null) {
        return <String, dynamic>{'ok': false, 'error': 'cancelled'};
      }
      resolvedName = input.name;
      resolvedParent = input.parent.isEmpty ? defaultRoot : input.parent;
    } else {
      resolvedName = name;
      resolvedParent = parent ?? defaultRoot;
    }
    await Directory(resolvedParent).create(recursive: true);
    final slug = resolvedName.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9_]+'),
      '_',
    );
    final mbdDir = Directory(p.join(resolvedParent, '$slug.mbd'));
    if (await mbdDir.exists()) {
      widget.chromeBridge.notify?.call(
        'Package "$resolvedName" already exists at ${mbdDir.path}',
        severity: 'warning',
      );
      return <String, dynamic>{
        'ok': false,
        'error': 'already exists',
        'mbdPath': mbdDir.path,
      };
    }
    await mbdDir.create(recursive: true);
    // Starter scaffold — manifest + an application envelope + a single
    // home page so the user sees the package's identity immediately
    // and has a place for chat-driven authoring to land. Builder
    // specialists fill in the page body via studio.builder.writeUI /
    // addTool / addKnowledge*. Single-page bundles still keep the
    // `application` envelope so theme / templates / settings have a
    // place to live (canonical mcp_ui 1.3 application structure).
    final manifest = <String, dynamic>{
      'manifest': <String, dynamic>{
        'id': id ?? 'com.example.$slug',
        'name': resolvedName,
        'version': '0.1.0',
        'description': 'New package scaffold.',
      },
      'requires': <String, dynamic>{'builtinAtoms': <String>[]},
      'ui': <String, dynamic>{'kind': 'mcp_ui_dsl', 'path': 'ui/app.json'},
    };
    await File(
      p.join(mbdDir.path, 'manifest.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
    final uiDir = Directory(p.join(mbdDir.path, 'ui'));
    await uiDir.create();
    // `ui/app.json` — application envelope. Routes a single `/home`
    // entry at the canonical `ui://pages/home` URI. The host's
    // pageLoader resolves that URI back to `ui/pages/home.json`
    // (see DslWorkspaceView). Theme / templates / settings layers
    // attach here without disturbing page content.
    final appUi = <String, dynamic>{
      'type': 'application',
      'title': resolvedName,
      'initialRoute': '/home',
      'routes': <String, dynamic>{'/home': 'ui://pages/home'},
    };
    await File(
      p.join(uiDir.path, 'app.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(appUi));
    // `ui/pages/home.json` — the home page body. Every new package
    // opens with a VbuTitleBar chrome strip (canonical atom, registered
    // via registerVbuWidgets) and an empty body. Authors / LLM
    // specialists fill the body via studio.builder.writeUI. Using the
    // registered atom keeps the tone identical across every package —
    // DO NOT hand-roll box+linear+text here; extend VbuTitleBar (or
    // add a sibling atom) instead.
    final pagesDir = Directory(p.join(uiDir.path, 'pages'));
    await pagesDir.create();
    final homePage = <String, dynamic>{
      'type': 'page',
      'title': resolvedName,
      'content': <String, dynamic>{
        'type': 'linear',
        'direction': 'vertical',
        'crossAxisAlignment': 'stretch',
        'children': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'VbuTitleBar', 'title': resolvedName},
          <String, dynamic>{
            'type': 'expanded',
            'child': <String, dynamic>{
              'type': 'box',
              'padding': 24,
              'child': <String, dynamic>{
                'type': 'linear',
                'direction': 'vertical',
                'gap': 12,
                'mainAxisAlignment': 'center',
                'crossAxisAlignment': 'center',
                'children': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'type': 'text',
                    'value':
                        'Starter scaffold — describe what to build in chat.',
                    'variant': 'bodyMedium',
                  },
                ],
              },
            },
          },
        ],
      },
    };
    await File(
      p.join(pagesDir.path, 'home.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(homePage));
    // Draft adoption — mark the draft as an App Builder project by
    // dropping the App Builder marker file. The BuiltInAppRegistry's
    // `canHandle` then matches naturally when the host opens the
    // draft (no hardcoded `seedPathByNamespace[...]` lookup or
    // namespace literal — see DDD apps.md §0.3a + MOD-APPS-002's
    // matching invariant), so the draft mounts inside the App Builder
    // chrome via `_openPackageAsync` → `BuiltInAppRegistry.matchFor`.
    // unified-builder collapsed Studio Builder + App Builder into the
    // App Builder BuiltInApp (2026-05-19); this is the replacement
    // for the retired studio_builder.mbd-seed-tab adopt flow.
    await File(p.join(mbdDir.path, '.builtin_app_builder')).writeAsString('');
    await _openPackageAsync(mbdDir.path, resolvedName, isDraft: true);
    final namespace =
        (manifest['manifest'] as Map<String, dynamic>)['id']?.toString();
    return <String, dynamic>{
      'ok': true,
      'mbdPath': mbdDir.path,
      'name': resolvedName,
      'namespace': namespace,
      'draft': true,
    };
  }

  Future<void> _refresh() async {
    setState(() {
      _entries = _enrichedEntries();
    });
  }

  /// Pull the registry list and enrich each entry with `name` (the
  /// friendly manifest label) so the picker UI can render it without
  /// re-reading the manifest per row. Built-in app seeds (app_builder,
  /// scene_builder, makemind_ops) and host-docs seeds are filtered
  /// out — they reach the user through chrome surfaces (BuiltInApp
  /// launcher tiles), not the installed-app picker.
  Future<List<Map<String, dynamic>>> _enrichedEntries() async {
    final raw = await widget.bundles.list();
    // Raw registry entries don't carry `shortId` (that field is
    // computed by the MCP enrichment step). For the Home filter we
    // need it too, so read the bundle once per entry — same call the
    // MCP handler makes via `_enrichBundleEntry`.
    // Per SDD §1.4.3: seed identification uses the host-supplied
    // namespace set, never a hardcoded literal.
    final seedNs = widget.seedPathByNamespace.keys.toSet();
    bool isSeed(Map<String, dynamic> e) {
      final ns = (e['namespace'] ?? '').toString();
      return seedNs.contains(ns);
    }

    return <Map<String, dynamic>>[
      for (final e in raw)
        if (!isSeed(e))
          <String, dynamic>{
            ...e,
            if (readFriendlyLabel(
                  (e['mbdPath'] ?? e['path'] ?? '').toString(),
                ) !=
                null)
              'name':
                  readFriendlyLabel(
                    (e['mbdPath'] ?? e['path'] ?? '').toString(),
                  )!,
          },
    ];
  }

  static const _nativePickerChannel = MethodChannel(
    'vibe_studio/native_picker',
  );

  Future<void> _installFromPicker() async {
    if (_installing) return;
    final workspaceDir = _readWorkspaceDir();
    String? path;
    if (Platform.isMacOS) {
      try {
        path = await _nativePickerChannel.invokeMethod<String?>(
          'pickFileOrPackage',
          <String, dynamic>{
            'title': 'Pick a .mcpb or .mbd package',
            'extensions': <String>['mcpb', 'mbd'],
            if (workspaceDir != null) 'initialDirectory': workspaceDir,
          },
        );
      } on PlatformException {
        path = null;
      }
    } else {
      final picked = await FilePicker.platform.pickFiles(
        dialogTitle: 'Pick a .mcpb or .mbd package',
        type: FileType.custom,
        allowedExtensions: const <String>['mcpb', 'mbd'],
        allowMultiple: false,
        initialDirectory: workspaceDir,
      );
      path = picked?.files.singleOrNull?.path;
    }
    if (path == null) return;
    setState(() {
      _installing = true;
      _installStatus = null;
    });
    final result = await widget.bundles.install(path);
    final ok = result['ok'] == true;
    setState(() {
      _installing = false;
      _installStatus =
          ok
              ? 'installed · ${result['namespace']}'
              : 'failed · ${result['error'] ?? 'unknown'}';
    });
    _installStatusTimer?.cancel();
    _installStatusTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _installStatus = null);
    });
    if (ok) await _refresh();
  }

  Future<void> _uninstallFromPicker(
    String mbdPath,
    String namespace,
    String label,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text('Uninstall $label?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'Removes the bundle from the host registry. The .mbd '
                  'directory stays on disk.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  namespace,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Uninstall'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    final result = await widget.bundles.uninstall(mbdPath);
    final ok = result['ok'] == true;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Uninstalled · $namespace'
              : 'Uninstall failed · ${result['error'] ?? 'unknown'}',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
    if (ok) await _refresh();
  }

  Widget _strip() => VbuTabStrip(
    tabs: <VbuTab>[
      for (final t in _tabs)
        VbuTab(
          // Label / icon come from the tab's own bundle: name from
          // the persisted display label (set on open via
          // readBundleAt.displayLabel), icon from manifest.icon when
          // declared (SDD §1.3 — host classification forbidden).
          label: t.isHome ? t.name : t.name,
          icon:
              t.isHome
                  ? Icons.home_outlined
                  : resolveIconName(
                    t.path == null
                        ? null
                        : readBundleAt(t.path!)?.manifest.icon,
                    fallback: Icons.extension_outlined,
                  ),
          closable: !t.isHome,
        ),
    ],
    activeIndex: _active,
    onSelect: _selectTab,
    onClose: _closeTab,
  );

  @override
  Widget build(BuildContext context) {
    final bridge = widget.chromeBridge;
    return ValueListenableBuilder<bool>(
      valueListenable: bridge.tabBarVisible,
      builder: (_, visible, __) {
        if (visible) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[_strip(), Expanded(child: _bodyStack())],
          );
        }
        // Hidden — render the body full-height; overlay the strip on
        // peek (titlebar hover). Strip's own MouseRegion keeps the
        // peek alive while the cursor is over it.
        return Stack(
          children: <Widget>[
            Positioned.fill(child: _bodyStack()),
            ValueListenableBuilder<bool>(
              valueListenable: bridge.tabBarPeek,
              builder:
                  (_, peek, __) => AnimatedSlide(
                    offset: peek ? Offset.zero : const Offset(0, -1),
                    duration: const Duration(milliseconds: 140),
                    curve: Curves.easeOutCubic,
                    child: AnimatedOpacity(
                      opacity: peek ? 1 : 0,
                      duration: const Duration(milliseconds: 120),
                      child: MouseRegion(
                        onEnter: (_) => bridge.peekIn(),
                        onExit: (_) => bridge.peekOut(),
                        child: Material(
                          elevation: 4,
                          color: Colors.transparent,
                          child: _strip(),
                        ),
                      ),
                    ),
                  ),
            ),
          ],
        );
      },
    );
  }

  /// Render every tab's body once and stack them — IndexedStack shows
  /// the active one and keeps the rest mounted off-screen. Without
  /// this the workspace runtime (state, scroll position, in-flight
  /// tool results) would tear down on every tab switch — matches the
  /// AppPlayer convention where re-entering a tab finds it as you
  /// left it.
  Widget _bodyStack() {
    final activeIndex = _active.clamp(0, _tabs.length - 1);
    return KeyedSubtree(
      key: _layoutCaptureKey,
      child: IndexedStack(
        index: activeIndex,
        sizing: StackFit.expand,
        children: <Widget>[
          for (var i = 0; i < _tabs.length; i++)
            KeyedSubtree(
              key: ValueKey('tab::${_tabs[i].isHome ? "home" : _tabs[i].path}'),
              // `WorkspaceTabActiveScope` tells DslWorkspaceView whether
              // to call `runtime.buildUI()` — only the active tab
              // attaches its runtime to the widget tree, so multiple
              // workspace tabs no longer fight over the
              // `flutter_mcp_ui_runtime` singleton `navigatorKey`. The
              // inactive tabs' State (and their MCPUIRuntime
              // instances) stay alive in the IndexedStack so re-entry
              // reuses the same runtime — same pattern AppPlayer's
              // `RuntimeManager` uses for app re-entry.
              child: WorkspaceTabActiveScope(
                active: i == activeIndex,
                child: _bodyForTab(_tabs[i]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bodyForTab(StudioTab t) {
    if (t.isHome) return _homeBody();
    return _bodyForBundleUI(t);
  }

  /// Per-package settings overrides file. Mirrors the host class's
  /// `_packageOverridesFile` (keeps the same on-disk path so the
  /// inline workspace settings panel and the legacy gear-icon dialog
  /// read/write the same overrides file).
  String _overridesFileFor(String pkgPath) {
    final safe = pkgPath.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    return p.join(widget.configRoot, 'package_settings', '$safe.json');
  }

  Widget _bodyForBundleUI(StudioTab t) {
    // SDD §1.3 — every bundle renders its own `ui/app.json`. Where the
    // bundle's UI needs to embed another project (e.g. a seed whose
    // page binds `{{currentProject}}` to a VbuBundleEmbed), the bundle
    // handles that internally via state. Host never swaps the rendered
    // path based on host-side mode classification.
    return widget.bundleBodyBuilder(t, t.path!);
  }

  Widget _homeBody() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _entries,
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final list = snap.data!;
        final hasInstalled = list.isNotEmpty;
        final hasBuiltIns = widget.builtInLaunchers.isNotEmpty;
        final Widget body =
            (!hasInstalled && !hasBuiltIns)
                ? PackageWelcomePanel(
                  onInstall: _installFromPicker,
                  onCreate: () => _createNewPackage(),
                )
                : _PackagePickerView(
                  entries: list,
                  builtInLaunchers: widget.builtInLaunchers,
                  extensionEntries: widget.extensionEntries,
                  onActivate: _openPackage,
                  onUninstall: _uninstallFromPicker,
                );
        // Built-in apps now have their own BUILT-IN APPS card row, so
        // the top-right always-on seed launcher icons are redundant
        // (and visually clutter the Home view). Removed — re-entry to
        // built-ins is via the BUILT-IN APPS tile + MCP
        // `studio.chrome.open_seed`.
        return Stack(
          children: <Widget>[
            Positioned.fill(child: body),
            if (_installStatus != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 24,
                child: Center(child: _StatusPill(text: _installStatus!)),
              ),
          ],
        );
      },
    );
  }

  /// Focus an existing tab for the seed identified by [namespace], or
  /// mount the seed as a new tab when none is up. Per SDD §1.4 the
  /// namespace is the seed's single identifier — `widget.seedPathByNamespace`
  /// resolves the current absolute path. Seeds are filtered out of the
  /// Home picker (see `isSeed` in `_enrichedEntries`), so chrome
  /// surfaces (Home affordance, MCP `studio.chrome.open_seed`) own
  /// re-entry.
  Future<bool> _openOrFocusSeed(String namespace) async {
    // Home-card click route — match the launcher's `launchPath`
    // (workspaces/<id> marker dir), NOT the raw seed bundle. The seed
    // path lives inside the package tree and mounts the legacy author
    // shell; the launcher path is the writable working copy the user
    // actually drives. They differ for every built-in (app_builder /
    // scene_builder / makemind_ops). Without this match, MCP callers
    // of `studio.chrome.open_seed` would land on the deprecated shell
    // while the home-card click — same intent — landed on the user
    // surface. See TAB-LIFECYCLE.md §3 + the R21 round notes.
    BuiltInLauncher? launcher;
    for (final l in widget.builtInLaunchers) {
      if (l.id == namespace) {
        launcher = l;
        break;
      }
    }
    final target =
        launcher?.launchPath ?? widget.seedPathByNamespace[namespace];
    if (target == null) {
      widget.chromeBridge.notify?.call(
        'Built-in "$namespace" not declared by host',
        severity: 'error',
      );
      return false;
    }
    final abs = File(target).absolute.path;
    for (var i = 0; i < _tabs.length; i++) {
      final t = _tabs[i];
      if (t.isHome) continue;
      final tp = t.path == null ? null : File(t.path!).absolute.path;
      if (tp == abs) {
        setState(() => _active = i);
        _syncHomeActive();
        _notifyContext();
        // ignore: unawaited_futures
        _saveTabs();
        return true;
      }
    }
    // Mirror the home-card click — fire the launcher's eager setup
    // (it already wrote the marker via `launcher()`), then open the
    // package the same way the picker does.
    try {
      await launcher?.onLaunch();
    } catch (_) {
      /* swallow — marker already on disk */
    }
    final probe = readBundleAt(target);
    final label = launcher?.label ?? probe?.displayLabel ?? namespace;
    await _openPackageAsync(target, label);
    return true;
  }
}

// ─────────────────────────────────────────────────────────────────────
// Private dependent widgets — used only by [_StudioWorkspaceState].
// ─────────────────────────────────────────────────────────────────────

class _AgentCard extends StatelessWidget {
  const _AgentCard({required this.profile});
  final VibeAgentProfile profile;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final roleLabel = profile.role.name;
    final preview =
        profile.systemPrompt.length > 240
            ? '${profile.systemPrompt.substring(0, 240)}…'
            : profile.systemPrompt;
    return Container(
      padding: const EdgeInsets.all(VbuTokens.space3),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
        border: Border.all(color: c.borderDefault),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  profile.displayName,
                  style: TextStyle(
                    fontFamily: VbuTokens.fontSans,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: c.textPrimary,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: VbuTokens.space2,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: c.surface2,
                  borderRadius: BorderRadius.circular(VbuTokens.radiusFull),
                  border: Border.all(color: c.borderDefault),
                ),
                child: Text(
                  roleLabel,
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 10,
                    color: c.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: VbuTokens.space1),
          Text(
            '${profile.id}  ·  ${profile.modelId}',
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 11,
              color: c.textTertiary,
            ),
          ),
          const SizedBox(height: VbuTokens.space2),
          Text(
            preview,
            style: TextStyle(
              fontFamily: VbuTokens.fontSans,
              fontSize: 11,
              color: c.textSecondary,
              height: 1.4,
            ),
          ),
          if (profile.toolNames.isNotEmpty) ...<Widget>[
            const SizedBox(height: VbuTokens.space2),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: <Widget>[
                for (final t in profile.toolNames)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: c.surface2,
                      borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
                    ),
                    child: Text(
                      t,
                      style: TextStyle(
                        fontFamily: VbuTokens.fontMono,
                        fontSize: 10,
                        color: c.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _OnboardingRow extends StatelessWidget {
  const _OnboardingRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Row(
      children: <Widget>[
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
              color: c.textTertiary,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 12,
              color: c.textPrimary,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Copy',
          iconSize: 16,
          icon: const Icon(Icons.copy),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: value));
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              const SnackBar(
                content: Text('Copied'),
                duration: Duration(seconds: 1),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _OnboardingBlock extends StatelessWidget {
  const _OnboardingBlock({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontFamily: VbuTokens.fontMono,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.0,
                  color: c.textTertiary,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Copy',
              iconSize: 16,
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: body));
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  const SnackBar(
                    content: Text('Copied'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: VbuTokens.space1),
        Container(
          padding: const EdgeInsets.all(VbuTokens.space3),
          decoration: BoxDecoration(
            color: c.surface3,
            borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
          ),
          child: SelectableText(
            body,
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 11,
              color: c.textPrimary,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VbuTokens.space3,
        vertical: VbuTokens.space2,
      ),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(VbuTokens.radiusFull),
        border: Border.all(color: c.borderStrong),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: VbuTokens.fontMono,
          fontSize: 11,
          color: c.textPrimary,
        ),
      ),
    );
  }
}

/// Picker shown when at least one package is installed but the user
/// hasn't activated one yet. Lists installed packages with an Install
/// More affordance. Visual tone aligned with vbu atoms (same surface
/// palette + spacing scale used by Settings + welcome panels).
class _PackagePickerView extends StatelessWidget {
  const _PackagePickerView({
    required this.entries,
    required this.builtInLaunchers,
    required this.extensionEntries,
    required this.onActivate,
    required this.onUninstall,
  });

  final List<Map<String, dynamic>> entries;
  final List<BuiltInLauncher> builtInLaunchers;
  final List<HomeExtensionEntry> extensionEntries;
  final void Function(String path, String name) onActivate;
  final Future<void> Function(String mbdPath, String namespace, String label)
  onUninstall;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Container(
      color: c.bg,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          VbuTokens.space5,
          VbuTokens.space5,
          VbuTokens.space5,
          VbuTokens.space5,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (builtInLaunchers.isNotEmpty ||
                extensionEntries.isNotEmpty) ...<Widget>[
              Row(
                children: <Widget>[
                  _sectionHeader('BUILT-IN APPS'),
                  const Spacer(),
                  // Extension entries (e.g. pro's Marketplace) — icon
                  // buttons to the right of the section title.
                  for (final e in extensionEntries) _extensionHeaderIcon(e),
                ],
              ),
              const SizedBox(height: VbuTokens.space3),
              Wrap(
                spacing: VbuTokens.space3,
                runSpacing: VbuTokens.space3,
                children: <Widget>[
                  for (final l in builtInLaunchers) _builtInTile(l),
                ],
              ),
              const SizedBox(height: VbuTokens.space5),
            ],
            if (entries.isNotEmpty) ...<Widget>[
              _sectionHeader('INSTALLED APPS'),
              const SizedBox(height: VbuTokens.space3),
              Wrap(
                spacing: VbuTokens.space3,
                runSpacing: VbuTokens.space3,
                children: <Widget>[
                  for (final entry in entries) _tileFor(entry),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String label) {
    final c = VbuTokens.color;
    return Text(
      label,
      style: TextStyle(
        fontFamily: VbuTokens.fontMono,
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.0,
        color: c.textTertiary,
      ),
    );
  }

  Widget _tileFor(Map<String, dynamic> entry) {
    final ns = (entry['namespace'] ?? entry['id'] ?? 'unknown').toString();
    final friendly = (entry['name'] as String?) ?? ns;
    final mbd = (entry['mbdPath'] ?? entry['path'] ?? '').toString();
    return _LauncherTile(
      label: friendly,
      namespace: ns,
      mbdPath: mbd,
      onActivate: () => onActivate(mbd, friendly),
      onUninstall: () => onUninstall(mbd, ns, friendly),
    );
  }

  Widget _builtInTile(BuiltInLauncher l) {
    return _LauncherTile(
      label: l.label,
      namespace: l.id,
      mbdPath: l.launchPath,
      onActivate: () async {
        // Ensure the marker dir / file is in place before the host
        // opens the path — `canHandle` checks the marker, and the
        // generic activation reads from disk.
        await l.onLaunch();
        onActivate(l.launchPath, l.label);
      },
      onUninstall: null,
      iconOverride: materialIconByName(l.iconName),
    );
  }

  /// Icon button for a host-extension Home entry (e.g. pro's Marketplace),
  /// shown to the right of the BUILT-IN APPS section title. Tap runs the
  /// entry's callback (open overlay).
  Widget _extensionHeaderIcon(HomeExtensionEntry e) {
    final c = VbuTokens.color;
    return IconButton(
      icon: Icon(e.icon, size: 18),
      tooltip: e.label,
      color: c.textSecondary,
      hoverColor: c.mint.withValues(alpha: 0.12),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      onPressed: e.onTap,
    );
  }
}

/// Icon launcher tile for the Home grid — Mirrors AppPlayer Pro's
/// `AppLauncherTile` pattern (64x76 column with a 44x44 rounded icon
/// box on top of a one-line label).
///
/// Right-click / long-press surfaces a popup menu with package-level
/// actions (Open · Show info · Uninstall). Single click activates the
/// package as a tab — same code path as the LLM-driven
/// `studio.bundle.activate` MCP tool.
class _LauncherTile extends StatefulWidget {
  const _LauncherTile({
    required this.label,
    required this.namespace,
    required this.mbdPath,
    required this.onActivate,
    this.onUninstall,
    this.iconOverride,
  });

  final String label;
  final String namespace;
  final String mbdPath;
  final VoidCallback onActivate;
  final Future<void> Function()? onUninstall;

  /// Optional icon to draw inside the rounded box. Built-in launcher
  /// tiles pass a per-app icon here; installed-package tiles leave it
  /// null and fall back to the generic puzzle-piece glyph.
  final IconData? iconOverride;

  @override
  State<_LauncherTile> createState() => _LauncherTileState();
}

class _LauncherTileState extends State<_LauncherTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return inspectTag(
      type: 'launcher_tile',
      id: widget.namespace,
      label: widget.label,
      child: Builder(
        builder:
            (anchor) => MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onActivate,
                onSecondaryTapDown:
                    (details) =>
                        _showContextMenu(anchor, details.globalPosition),
                onLongPress:
                    () => _showContextMenu(
                      anchor,
                      (anchor.findRenderObject()! as RenderBox).localToGlobal(
                        Offset.zero,
                      ),
                    ),
                child: SizedBox(
                  width: 96,
                  height: 110,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      AnimatedContainer(
                        duration: VbuTokens.durFast,
                        curve: VbuTokens.easeStandard,
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: _hovered ? c.surface3 : c.surface2,
                          borderRadius: BorderRadius.circular(
                            VbuTokens.radiusLg,
                          ),
                          border: Border.all(
                            color: _hovered ? c.borderStrong : c.borderSubtle,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          widget.iconOverride ?? Icons.extension_outlined,
                          size: 28,
                          color: c.mint,
                        ),
                      ),
                      const SizedBox(height: VbuTokens.space2),
                      SizedBox(
                        width: 92,
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 11, color: c.textPrimary),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
      ),
    );
  }

  Future<void> _showContextMenu(BuildContext anchor, Offset globalPos) async {
    final overlay = Overlay.of(anchor).context.findRenderObject() as RenderBox;
    // Built-in apps cannot be uninstalled — the host owns their
    // lifecycle. Package settings live inside the active tab once the
    // tile is launched, so neither item belongs on a pre-tab launcher
    // menu.
    final canUninstall = widget.onUninstall != null;
    final selected = await showMenu<String>(
      context: anchor,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPos.dx, globalPos.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<String>>[
        const PopupMenuItem<String>(
          value: 'open',
          height: 32,
          child: Row(
            children: <Widget>[
              Icon(Icons.open_in_new, size: 14),
              SizedBox(width: 8),
              Text('Open', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'info',
          height: 32,
          child: Row(
            children: <Widget>[
              Icon(Icons.info_outline, size: 14),
              SizedBox(width: 8),
              Text('Show info', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        if (canUninstall) ...<PopupMenuEntry<String>>[
          const PopupMenuDivider(height: 4),
          const PopupMenuItem<String>(
            value: 'uninstall',
            height: 32,
            child: Row(
              children: <Widget>[
                Icon(Icons.delete_outline, size: 14),
                SizedBox(width: 8),
                Text('Uninstall', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
        ],
      ],
    );
    if (!mounted) return;
    switch (selected) {
      case 'open':
        widget.onActivate();
        break;
      case 'info':
        _showInfo();
        break;
      case 'uninstall':
        final cb = widget.onUninstall;
        if (cb != null) await cb();
        break;
    }
  }

  void _showInfo() {
    showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text(widget.label),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('Namespace', style: TextStyle(fontSize: 11)),
                SelectableText(
                  widget.namespace,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                const SizedBox(height: 12),
                const Text('Bundle path', style: TextStyle(fontSize: 11)),
                SelectableText(
                  widget.mbdPath,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
    );
  }
}
