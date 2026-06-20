import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart'
    show
        BuiltInApp,
        BuiltInAppContext,
        BuiltInAppRegistry,
        BuiltInLauncher,
        BuiltinToolRegistry,
        ChatSlashHint,
        ChromeBridge,
        DomainLifecycleState,
        DomainSettingsPanel,
        HeaderAction,
        LifecycleHandler,
        LifecycleSlots,
        ManifestFieldList,
        SettingsSection,
        SlashCommandSpec,
        StudioBackbone,
        VibeChatController,
        bakeInheritedFields,
        materialIconByName;
// Builtin = OS-level app — uses host wrapper API only.
// Zero direct `package:brain_kernel` imports (aligned with builtin-os-cleanup Phase 4).
import 'package:appplayer_studio/builtin_api.dart'
    as mk
    show KernelContent, KernelTextContent, KernelToolResult;

import 'conv/dart_converter.dart';
import 'conv/embed_converter.dart';
import 'conv/self_ui_converter.dart';
import 'core/layer_projection.dart';
import 'core/patch_pipeline.dart';
import 'core/spec_validator.dart';
import 'core/vibe_project.dart';
import 'core/workspace_canonical.dart';
import 'feat/shell_layout.dart';
import 'infra/server_bootstrap.dart';
import 'infra/vibe_server_bridge.dart';
import 'infra/vibe_settings.dart';
import 'infra/workspace_fs_port.dart';
import 'theme/tokens.dart';

/// App Builder as a vibe_studio built-in app.
///
/// * [canHandle] — a folder with a `project.apbproj` marker file at
///   its root is treated as an App Builder project.
/// * [mount] — boots an in-memory editor stack (canonical / pipeline
///   / bridge / server bootstrap with no transport) and mounts the
///   shared [VibeShell] inside a wrapper widget that registers all of
///   the shell's chrome actions onto the host's
///   [ChromeBridge.headerActions] notifier. The host's ProjectHeader /
///   ActivityBar then renders those actions through the same path it
///   uses for `app_builder.mbd` (and any future builder-family seed)
///   — no app-specific
///   chrome lives in the host code.
///
/// Note: lifecycle wiring (canonical / pipeline / chat) is the next
/// step. This first cut keeps the app's own canonical and a
/// placeholder chat controller so the integration boots end-to-end and
/// the host chrome surfaces the actions; the next pass swaps both for
/// the kernel-owned versions so undo / save / chat all flow through a
/// single host lifecycle.
class AppBuilderBuiltInApp extends BuiltInApp {
  const AppBuilderBuiltInApp();

  @override
  String get id => 'app_builder';

  @override
  String get label => 'App Builder';

  /// Built-in directory marker — file written by [launcher.onLaunch]
  /// so [canHandle] recognises the launch path even before the user
  /// runs New/Open to set up a real `.apbproj` project.
  static const String _builtInMarker = '.builtin_app_builder';

  @override
  Future<List<Map<String, dynamic>>> knowledgeSources() async {
    // No code-channel knowledge. app_builder's knowledge lives entirely
    // in the seed bundle (`seed/app_builder.mbd` manifest.knowledge.
    // sources), registered through BundleActivation like ops / scene.
    // The former JSON-asset channel (`knowledge/knowledge.json`) was a
    // pre-spec duplicate the host already swallowed as a URI collision
    // against the seed; dropped for a single source of truth.
    return const <Map<String, dynamic>>[];
  }

  @override
  bool canHandle(String bundlePath) {
    // The host hands us a path twice: from the launcher (built-in
    // marker present, no `.apbproj` yet) and from the user dropping
    // an existing project folder (no built-in marker, `.apbproj`
    // present). Accept either — `_AppBuilderMount` boots in welcome
    // state when the `.apbproj` marker is missing.
    final dir = Directory(bundlePath);
    if (!dir.existsSync()) return false;
    if (File(p.join(bundlePath, _builtInMarker)).existsSync()) return true;
    return File(p.join(bundlePath, VibeProject.projectFile)).existsSync();
  }

  @override
  BuiltInLauncher launcher(ChromeBridge chromeBridge, String workspaceDir) {
    // Default App Builder workspace location inside the host's
    // workspace directory. Marker dir + file are created eagerly here
    // (every host build) instead of lazily inside `onLaunch` — the
    // tile's `onTap` is a `VoidCallback`, so an async `onLaunch`
    // would race the host's `_openPackage` call that happens on the
    // same tap. Eager creation keeps `canHandle` honest by the time
    // bundleBodyBuilder fires. The actual project / bundle is still
    // created lazily through app_builder's own `_onNewProject` flow
    // when the user picks New / Open from the chrome.
    final defaultDir = p.join(workspaceDir, 'app_builder');
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
      iconName: 'build',
      launchPath: defaultDir,
      onLaunch: () async {
        /* marker already exists from `launcher()` */
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
    // Resolve the host's per-tab chat controller now (typed via
    // `as VibeChatController` since the host signature reads as
    // `dynamic` to keep the [BuiltInApp] interface free of a hard
    // dependency on the base chat surface). The shell shares one
    // chat thread per (package, project) tab with the host's chat
    // panel.
    final chat = chatLookup(tabKey) as VibeChatController;
    return _AppBuilderMount(
      key: ValueKey('app_builder::$bundlePath'),
      app: this,
      bundlePath: bundlePath,
      chromeBridge: chromeBridge,
      chat: chat,
      server: server,
      backbone: backbone,
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
    // app_builder.newAppProject — 1:1 with the Project Header "New"
    // button. Per §8.5 dialog vs programmatic is discriminated by the
    // presence of args. With `name`: route to chromeBridge.onNewProject
    // headless (existing Flutter scaffold path used by VibeProject.
    // openAt). Without `name`: fire the lifecycle slot so the shell
    // opens its existing native dialog — same UI flow a click would
    // produce. Both converge on the same Flutter creation logic.
    server.addTool(
      name: 'app_builder.newAppProject',
      description:
          'Scaffold a new App Builder project. With `name`+`parent` '
          'set: programmatic create (no dialog). Without: opens the '
          'native New Project dialog in the active App Builder tab. '
          'parent defaults to settings.workspaceDir when omitted. '
          'Same code path as clicking the Project Header "New" button.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'name': <String, dynamic>{
            'type': 'string',
            'description': 'Optional. Omit to open the dialog.',
          },
          'parent': <String, dynamic>{
            'type': 'string',
            'description':
                'Optional. Defaults to settings.workspaceDir when '
                'omitted.',
          },
        },
      },
      handler: (args) async {
        final name = args['name'];
        // Headless path — programmatic when `name` is provided. Route
        // through the existing host primitive `studio.project.new`
        // (which already handles parent fallback to
        // settings.workspaceDir and runs the scaffold via the bridge's
        // `newProjectInActive` slot). Keeps the dual surface (UI
        // button + MCP) on one host primitive.
        if (name is String && name.isNotEmpty) {
          // Headless — route through `studio.project.new`. When App
          // Builder is mounted it has wired
          // `chromeBridge.newProjectInActive` to its own scaffolder
          // (VibeProject.openAt — template copy + preview attach), so
          // calling the host primitive runs the same full setup the
          // UI "New" button uses.
          final newParams = <String, dynamic>{'name': name};
          final parent = args['parent'];
          if (parent is String && parent.isNotEmpty) {
            newParams['parent'] = parent;
          }
          return server.callTool('studio.project.new', newParams);
        }
        // Dialog path — no name. Fire the lifecycle slot so the active
        // built-in's wired handler opens its native dialog (same UI
        // flow as the Project Header "New" button).
        final dispatch = chromeBridge.dispatchLifecycleSlot;
        if (dispatch == null) {
          return mk.KernelToolResult(
            content: <mk.KernelContent>[
              mk.KernelTextContent(
                text: '{"ok":false,"error":"chrome not mounted"}',
              ),
            ],
            isError: true,
          );
        }
        dispatch('project.new', const <String, dynamic>{});
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text:
                  '{"ok":true,"dialog":true,"note":"native New Project '
                  'dialog opened in the active App Builder tab"}',
            ),
          ],
        );
      },
    );

    // `app_builder.dispatch_builder_tool` retired in the builtin-os-cleanup
    // round (2026-05-28). External LLMs now call `vibe_*` tools directly
    // on the host endpoint — each App Builder mount registers its own
    // surface via `BuiltinToolRegistry`, no inner-MCP passthrough needed.

    // `vibe_*` 151 mirror loop retired in the builtin-os-cleanup round
    // (2026-05-28). App Builder no longer stands up its own
    // `mcp.Server`; each mount registers its `vibe_*` (+ categorized
    // alias) tools directly on the host endpoint via the
    // `BuiltinToolRegistry` facade — see `infra/server_bootstrap.dart`
    // `register()` for the new path. Removed code:
    //   - transient `ServerBootstrap` boot-time enumeration
    //   - `dispatchToActive` mirror handler
    //   - alias double-registration per tool
    // Each App Builder tab mount calls `register()` itself; the host
    // endpoint sees the live set tied to the active mount. Future
    // refinement (multi-mount conflict, dispose-time unregister) layers
    // on top of `BuiltinToolRegistry.removeTool`.
  }
}

class _AppBuilderMount extends StatefulWidget {
  const _AppBuilderMount({
    super.key,
    required this.app,
    required this.bundlePath,
    required this.chromeBridge,
    required this.chat,
    required this.server,
    this.backbone,
    this.inheritedSettings = const <String, Object?>{},
    this.overridesFile = '',
  });

  final AppBuilderBuiltInApp app;
  final String bundlePath;
  final ChromeBridge chromeBridge;
  final VibeChatController chat;

  /// Host endpoint facade. The mount hands this straight to its
  /// `ServerBootstrap` so every `vibe_*` tool lands on the host
  /// endpoint — App Builder no longer hosts its own MCP transport
  /// (cleanup 2026-05-28).
  final BuiltinToolRegistry server;

  /// Host StudioBackbone — used to wire `_bridge.listKnowledgeBundles`
  /// etc to the host-shared `KnowledgeBundleRegistry` /
  /// `KnowledgeQueryEngine`. Null in standalone test contexts.
  final StudioBackbone? backbone;
  final Map<String, Object?> inheritedSettings;
  final String overridesFile;

  @override
  State<_AppBuilderMount> createState() => _AppBuilderMountState();
}

class _AppBuilderMountState extends State<_AppBuilderMount> {
  final GlobalKey<VibeShellState> _shellKey = GlobalKey<VibeShellState>();
  late final BuiltInAppContext _ctx;

  // Kept here so the in-process MCP shim still has a port for the
  // few code paths that haven't migrated to kernel yet (asset loaders,
  // sidecar persistence). Production reads route through the kernel
  // canonical via [WorkspaceCanonicalImpl].
  // ignore: unused_field
  late final FileWorkspaceFsPort _fsPort;
  late final SpecValidatorImpl _validator;
  late final WorkspaceCanonicalImpl _canonical;
  late final PatchPipelineImpl _pipeline;
  late final VibeServerBridge _bridge;
  // Held for lifetime of mount; ServerBootstrap has no tear-down hook
  // today. Phase 2 routes through the host MCP server instead.
  // ignore: unused_field
  late final ServerBootstrap _boot;
  VibeProject? _project;
  // Phase 2 will share the host's settings instance.
  // ignore: unused_field
  VibeSettings? _settings;
  LayerProjection _projection = LayerProjection.fromJson(<String, dynamic>{});
  bool _booting = true;
  Object? _bootError;

  @override
  void initState() {
    super.initState();
    _fsPort = FileWorkspaceFsPort();
    _validator = SpecValidatorImpl();
    // Lifecycle backed by the host vibe_studio kernel — open / save /
    // saveAs / revert / draft autosave / dirty tracking all flow
    // through `mk.Canonical` so the built-in shares the host's single
    // canonical machinery instead of standing up a parallel store.
    // Undo / redo + JSON-Patch + dry-run validation stay in the
    // adapter because the kernel exposes a raw `applyAtomic` only.
    _canonical = WorkspaceCanonicalImpl(validator: _validator, fsPort: _fsPort);
    _pipeline = PatchPipelineImpl(canonical: _canonical, validator: _validator);
    _bridge = VibeServerBridge();
    // Single-instance liveness: this mount is now the live App Builder.
    // A re-mount swaps it; dispose clears it only-if-mine. `vibe_*`
    // handlers resolve through this so a re-mounted mount answers from the
    // live bridge, never a torn-down one.
    VibeServerBridge.markLive(_bridge);
    // Wire knowledge-bundle callbacks against the host's shared
    // KnowledgeBundleRegistry / KnowledgeQueryEngine, exposed through
    // the StudioBackbone the host hands us at mount time. Without
    // this, the four `vibe_knowledge_*` tools (list / query / install
    // / uninstall) hit "registry not wired" errors in built-in mode.
    final hostBackbone = widget.backbone;
    if (hostBackbone != null) {
      final kbr = hostBackbone.bundleRegistry;
      final kqe = hostBackbone.knowledgeEngine;
      _bridge.listKnowledgeBundles = () async {
        final entries = await kbr.list();
        return entries.map((e) => e.toJson()).toList();
      };
      _bridge.uninstallKnowledgeBundle = (String mbdPath) async {
        final removed = await kbr.remove(mbdPath);
        return <String, dynamic>{'ok': true, 'removed': removed};
      };
      _bridge.installKnowledgeBundle = (String mbdPath) async {
        try {
          final manifestFile = File(p.join(mbdPath, 'manifest.json'));
          if (!await manifestFile.exists()) {
            return <String, dynamic>{
              'ok': false,
              'error': 'manifest.json not found at $mbdPath',
            };
          }
          final raw = await manifestFile.readAsString();
          final decoded = jsonDecode(raw);
          String namespace = '';
          if (decoded is Map) {
            final m = decoded['manifest'];
            if (m is Map && m['id'] is String) {
              namespace = m['id'] as String;
            } else if (decoded['id'] is String) {
              namespace = decoded['id'] as String;
            }
          }
          if (namespace.isEmpty) {
            return <String, dynamic>{
              'ok': false,
              'error': 'manifest.id not found — cannot derive namespace',
            };
          }
          await kbr.upsert(mbdPath: mbdPath, namespace: namespace);
          return <String, dynamic>{'ok': true, 'namespace': namespace};
        } catch (e) {
          return <String, dynamic>{'ok': false, 'error': '$e'};
        }
      };
      _bridge.knowledgeQuery = (
        String query, {
        int topK = 5,
        String? namespace,
        String? sourceId,
      }) async {
        final hits = await kqe.query(
          query,
          topK: topK,
          namespace: namespace,
          sourceId: sourceId,
        );
        return hits.map((h) => h.toJson()).toList();
      };
      // Agent dispatch — wire the bridge's agent slots to the host
      // KnowledgeSystem agents facade (parity with ops `agent_ask` /
      // `agent_get_history`). Spec alignment: agent execution routes
      // through the backbone facade, not a parallel app-builder path —
      // this replaces the previous null slots that returned
      // "agent host not wired".
      //
      // `listAgents` resolves the boot workspaceId from
      // `hostBackbone.agentHost.workspaceId` (StudioBackbone exposes it —
      // no kernel getter needed). `askAgent` / `agentHistory` are
      // agentId-direct so they need no workspaceId.
      final agentSys = hostBackbone.app.system;
      _bridge.askAgent = (agentId, message) async {
        if (!agentSys.isAgentSubsystemActivated) {
          return <String, dynamic>{'error': 'Agent Subsystem not activated'};
        }
        final reply = await agentSys.agents.ask(agentId, message);
        return <String, dynamic>{
          'agentId': reply.agentId,
          'content': reply.content,
          'model': reply.model,
          if (reply.finishReason != null) 'finishReason': reply.finishReason,
        };
      };
      _bridge.agentHistory = (agentId, {int limit = 20}) async {
        if (!agentSys.isAgentSubsystemActivated) {
          return const <Map<String, dynamic>>[];
        }
        final history = await agentSys.agents.getHistory(agentId, limit: limit);
        return <Map<String, dynamic>>[
          for (final t in history)
            <String, dynamic>{
              'userMessage': t.userMessage,
              'assistantReply': t.assistantReply,
              'model': t.model,
              'timestamp': t.timestamp.toIso8601String(),
            },
        ];
      };
      _bridge.listAgents = () async {
        if (!agentSys.isAgentSubsystemActivated) {
          return const <Map<String, dynamic>>[];
        }
        final agents = await agentSys.agents.listAgents(
          workspaceId: hostBackbone.agentHost?.workspaceId,
        );
        return <Map<String, dynamic>>[
          for (final a in agents)
            <String, dynamic>{
              'id': a.id,
              'displayName': a.displayName,
              'role': a.role.name,
              'model': a.model.model,
            },
        ];
      };
    }
    _boot = ServerBootstrap(
      server: widget.server,
      canonical: _canonical,
      pipeline: _pipeline,
      dartConv: DartConverterImpl(),
      embedConv: EmbedConverterImpl(),
      selfUiConv: SelfUiConverterImpl(),
      bridge: _bridge,
    )..register();
    // Publish our 4-axis hooks to the registry so host wiring
    // (`_resolveDomainPanel`, `_syncHeaderActions`, `dispatchLifecycleSlot`,
    // composer slash) can reach the same providers regardless of
    // which file they live in. Hooks close over `_shellKey` so they
    // always see the live shell state.
    _ctx =
        BuiltInAppContext(
            bundlePath: widget.bundlePath,
            chromeBridge: widget.chromeBridge,
            inheritedSettings: widget.inheritedSettings,
            overridesFile: widget.overridesFile,
          )
          ..headerActionsProvider = _provideHeaderActions
          ..lifecycleStateProvider = _provideLifecycleState
          ..lifecycleBindingsProvider = _provideLifecycleBindings
          ..domainSettingsProvider = _provideDomainSettings
          ..slashCommandsProvider = _provideSlashCommands
          ..projectKindsProvider = (() => appBuilderProjectKinds)
    // `builderBoot` field also retired — inner-MCP passthrough is gone.
    ;
    BuiltInAppRegistry.instance.mount(widget.bundlePath, widget.app, _ctx);
    // Seed the trailing actions on the next frame — writing to
    // `chromeBridge.headerActions.value` synchronously inside
    // initState fires the ValueListenableBuilder's setState while
    // the host chrome is still building, which Flutter (rightly)
    // asserts on. Post-frame defer keeps the first-frame paint of
    // the domain icons without breaking the build pass.
    //
    // No `BuiltInAppRegistry.revision` listener attached here on
    // purpose — the workspace's `_syncHeaderActions` re-resolves on
    // every tab switch through the bridge resolvers, so the
    // rising-edge "you are active again" call already lands. Adding
    // a self-listener that called `_refreshHeaderActions` made
    // `bumpRevision()` (fired from inside `_refreshHeaderActions`)
    // re-enter the same handler — infinite recursion / stack
    // overflow on tab close.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshHeaderActions();
    });
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      // Two settings concerns, kept distinct:
      //   * Studio config (workspace / MCP / LLM) — host-owned. Read from
      //     `BuiltInAppContext.inheritedSettings`; edited via the host's
      //     standard settings dialog. App Builder no longer forks its own
      //     copy of these.
      //   * App-Builder session state (last project, recent projects,
      //     panel widths) — App Builder's own, persisted in its sidecar
      //     store. The host knows nothing about it, so it must NOT be
      //     dropped (it's what reopens the last project on boot).
      final own = await VibeSettings.load(
        VibeSettings.defaultPath('app_builder_vibe'),
      );
      final inh = widget.inheritedSettings;
      final settings = VibeSettings(
        // Studio config from the host (falls back to the sidecar value
        // when the host hasn't set it).
        workspaceDir: (inh['workspaceDir'] as String?) ?? own.workspaceDir,
        mcpServerUrl: inh['mcpServerUrl'] as String?,
        mcpTransport: (inh['mcpTransport'] as String?) ?? 'http',
        llmApiKey: inh['llmApiKey'] as String?,
        llmModel: inh['llmModel'] as String?,
        llmEndpoint: inh['llmEndpoint'] as String?,
        // App Builder session state from its own sidecar store.
        lastProjectPath: own.lastProjectPath,
        recentProjects: own.recentProjects,
        chatPanelWidth: own.chatPanelWidth,
        propsPanelWidth: own.propsPanelWidth,
      );
      // Project resolution mirrors the standalone app_builder's
      // `_resolveBootProjectPath`:
      //   1. bundlePath itself holds an `.apbproj` marker → open it.
      //   2. otherwise reopen `settings.lastProjectPath` when it is
      //      still a valid project on disk.
      //   3. else null → VibeShell renders its welcome panel.
      String? resolvedPath;
      final selfMarker = File(
        p.join(widget.bundlePath, VibeProject.projectFile),
      );
      if (await selfMarker.exists()) {
        resolvedPath = widget.bundlePath;
      } else {
        final last = settings.lastProjectPath;
        if (last != null && last.isNotEmpty) {
          final dir = Directory(last);
          if (await dir.exists()) {
            final hasNew =
                await File(p.join(last, VibeProject.projectFile)).exists();
            final hasLegacy =
                await File(
                  p.join(last, VibeProject.legacyProjectFile),
                ).exists();
            if (hasNew || hasLegacy) resolvedPath = last;
          }
        }
      }
      VibeProject? project;
      if (resolvedPath != null) {
        project = await VibeProject.openAt(
          projectDir: resolvedPath,
          canonical: _canonical,
        );
        settings.bumpRecent(project.projectPath);
        // ignore: unawaited_futures
        settings.save(VibeSettings.defaultPath('app_builder_vibe'));
      }
      final projection =
          project == null
              ? LayerProjection.fromJson(<String, dynamic>{})
              : LayerProjection.fromJson(_canonical.currentJson);
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _project = project;
        _projection = projection;
        _booting = false;
      });
      // First registration once the shell is mounted in the next
      // frame. Subsequent updates come through the shell's
      // chromeStateRevision listener wired in didChangeDependencies.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _refreshHeaderActions();
        _shellKey.currentState?.chromeStateRevision.addListener(
          _refreshHeaderActions,
        );
      });
    } catch (e) {
      // Surface — a swallowed boot failure leaves the shell stuck on an
      // empty/welcome state with no clue why (parse-masking class).
      if (!mounted) return;
      setState(() {
        _bootError = e;
        _booting = false;
      });
    }
  }

  @override
  void dispose() {
    _shellKey.currentState?.chromeStateRevision.removeListener(
      _refreshHeaderActions,
    );
    // No direct bridge clear — `BuiltInAppRegistry.unmount` drops our
    // entry and the workspace's next tab-switch sync re-resolves
    // header actions + lifecycle through the resolvers (which then
    // return null for our path → empty defaults). Writing here would
    // race the workspace re-sync.
    BuiltInAppRegistry.instance.unmount(widget.bundlePath);
    // Detach from the DomainServerManager so a domainSpawned boot
    // (created when this built-in was set to inheritFromSystem=false)
    // tears down when no other domain is attached. Without this, the
    // spawned server lingers across tab close (resource leak — gap G-3
    // in MOD-INFRA-010 §10.7). System wrapper tools stay registered
    // and gracefully return "no active mount" until a future mount.
    widget.chromeBridge.domainServerManager?.detach(widget.bundlePath);
    // Single-instance liveness: stop being the live App Builder bridge
    // (only-if-mine — a re-mount may have swapped it already). The standard
    // registry's replace-on-remount handles tool re-registration; nothing
    // to unregister here.
    VibeServerBridge.clearLiveIfMine(_bridge);
    // chat controller is owned by the host (`_chatFor` cache); do not
    // dispose it here — other tabs / future mounts may still bind it.
    super.dispose();
  }

  // ---------------------------------------------------------------
  // 4-axis hook providers — invoked by host wiring through the
  // registry's activeContext. Returning null when the shell state
  // is not yet attached lets the host fall back gracefully.
  // ---------------------------------------------------------------

  List<HeaderAction>? _provideHeaderActions() {
    final actions = _buildHeaderActions();
    return actions;
  }

  Map<String, LifecycleHandler>? _provideLifecycleBindings() {
    final state = _shellKey.currentState;
    if (state == null) return null;
    // Use the state's OWN BuildContext (below MaterialApp) — the
    // dispatcher's rootCtx is the root element which has no
    // MaterialLocalizations ancestor, so showDialog throws from there.
    BuildContext ctx() => state.context;
    return <String, LifecycleHandler>{
      LifecycleSlots.projectNew: (_) => state.executeNew(ctx()),
      LifecycleSlots.projectOpen: (_) => state.executeOpen(ctx()),
      LifecycleSlots.projectSave: (_) => state.executeSave(ctx()),
      LifecycleSlots.projectSaveAs: (_) => state.executeSaveAs(ctx()),
      LifecycleSlots.projectRevert: (_) => state.executeRevert(ctx()),
      LifecycleSlots.projectClose: (_) async => state.executeCloseProject(),
      LifecycleSlots.projectRename: (_) => state.executeRename(ctx()),
      LifecycleSlots.projectExport: (_) => state.executeExportBundle(ctx()),
      LifecycleSlots.projectImport: (_) => state.executeImportBundle(ctx()),
      LifecycleSlots.historyShow: (_) => state.executeHistory(ctx()),
      LifecycleSlots.editUndo: (_) async => state.executeUndo(),
      LifecycleSlots.editRedo: (_) async => state.executeRedo(),
      LifecycleSlots.build: (_) => state.executeBuild(ctx()),
      LifecycleSlots.buildClean: (_) => state.executeCleanBuild(ctx()),
      LifecycleSlots.buildSettings: (_) => state.executeBuildSettings(ctx()),
      LifecycleSlots.manageAssets: (_) => state.executeManageAssets(ctx()),
      LifecycleSlots.compareChannels:
          (_) => state.executeCompareChannels(ctx()),
      LifecycleSlots.settingsShow: (_) => state.executeSettings(ctx()),
    };
  }

  DomainSettingsPanel? _provideDomainSettings() {
    // Built-in apps register their settings sections in code — no
    // manifest read. The host's MCP-server section is auto-prepended
    // by `_resolveDomainPanel`, so we only contribute the
    // domain-specific entries here. Mirror the manifest field shape
    // (`ManifestFieldList(fields: [...])`) so the renderer treats the
    // built-in and manifest paths identically. Inherited values come
    // from the host's studio-wide settings (passed in via
    // `BuiltInAppContext.inheritedSettings`); per-domain edits land
    // in `BuiltInAppContext.overridesFile`.
    final inherited = _ctx.inheritedSettings;
    final overridesFile = _ctx.overridesFile;
    return DomainSettingsPanel(
      name: 'App Builder',
      sections: <SettingsSection>[
        SettingsSection(
          label: 'Workspace',
          body: ManifestFieldList(
            fields: bakeInheritedFields(const <Map<String, dynamic>>[
              <String, dynamic>{
                'key': 'workspaceDir',
                'label': 'Workspace folder',
                'type': 'folder',
                'description':
                    'Parent directory where new App Builder projects '
                    'land. Inherits from Studio Settings; per-package '
                    'override may be set here.',
              },
            ], inherited),
            overridesFile: overridesFile,
          ),
        ),
        SettingsSection(
          label: 'General',
          body: ManifestFieldList(
            fields: bakeInheritedFields(const <Map<String, dynamic>>[
              <String, dynamic>{
                'key': 'defaultDeviceSize',
                'label': 'Default device size',
                'type': 'menu',
                'options': <String>[
                  '390x844',
                  '412x915',
                  '768x1024',
                  '1024x768',
                ],
                'value': '390x844',
              },
              <String, dynamic>{
                'key': 'autoReloadPreview',
                'label': 'Auto-reload preview on edit',
                'type': 'toggle',
                'value': true,
              },
            ], inherited),
            overridesFile: overridesFile,
          ),
        ),
        SettingsSection(
          label: 'Build',
          body: ManifestFieldList(
            fields: bakeInheritedFields(const <Map<String, dynamic>>[
              <String, dynamic>{
                'key': 'defaultTarget',
                'label': 'Default convert target',
                'type': 'menu',
                'options': <String>['dart', 'embed-lvgl', 'embed-qt'],
                'value': 'dart',
              },
              <String, dynamic>{
                'key': 'outputDir',
                'label': 'Build output directory',
                'type': 'folder',
                'value': 'build',
              },
            ], inherited),
            overridesFile: overridesFile,
          ),
        ),
      ],
    );
  }

  List<SlashCommandSpec>? _provideSlashCommands() {
    // Mirrors `_runSlashCommand` in `feat/shell_layout.dart` —
    // that switch is the source of truth for what the chat composer
    // accepts. The chip catalogue surfaces the same set so users see
    // the available verbs at a glance. All entries are template-only
    // (no `tool`) because dispatch goes through `_runSlashCommand`,
    // not direct MCP call; the chip just inserts the command into the
    // composer.
    return const <SlashCommandSpec>[
      SlashCommandSpec(command: '/health', description: 'Full health check.'),
      SlashCommandSpec(command: '/grade', description: 'Letter A–F + rubric.'),
      SlashCommandSpec(
        command: '/release',
        template: '/release ',
        description: 'Multi-stage release verdict (append `dry` for dry-run).',
      ),
      SlashCommandSpec(
        command: '/audit',
        template: '/audit ',
        description: 'a11y audit (defaults to focused page).',
      ),
      SlashCommandSpec(
        command: '/routes',
        description: 'route ↔ page ↔ initialRoute audit.',
      ),
      SlashCommandSpec(
        command: '/find',
        template: '/find ',
        description: 'find references (template / state / route / asset).',
      ),
      SlashCommandSpec(
        command: '/graph',
        description: 'dependency graph (page → template / asset / state).',
      ),
      SlashCommandSpec(
        command: '/tokens',
        description: 'hardcoded values audit on the focused page.',
      ),
      SlashCommandSpec(
        command: '/desc',
        template: '/desc ',
        description: 'tree outline rooted at a JSON pointer.',
      ),
      SlashCommandSpec(
        command: '/lint',
        description: 'widget_lint on the focused page.',
      ),
      SlashCommandSpec(
        command: '/extract',
        template: '/extract ',
        description: 'extract focused widget to a template by id.',
      ),
      SlashCommandSpec(
        command: '/fix',
        description: 'auto-fix a11y on the focused page.',
      ),
      SlashCommandSpec(
        command: '/preset',
        template: '/preset ',
        description: 'apply a layout preset to the focused selection.',
      ),
      SlashCommandSpec(
        command: '/recipe',
        template: '/recipe ',
        description: 'apply a structural recipe.',
      ),
      SlashCommandSpec(
        command: '/critique',
        description: 'multimodal design review.',
      ),
      SlashCommandSpec(
        command: '/help',
        description: 'list all slash commands.',
      ),
    ];
  }

  void _refreshHeaderActions() {
    // The chrome bridge is shared across every tab — writing
    // directly while a different tab is active would clobber its
    // actions until the workspace's own sync runs again. When we are
    // not the active built-in there is nothing to publish; the
    // workspace's next tab-switch sync calls our resolver if/when
    // we become active again.
    if (!_isActiveTab) return;
    final actions = _buildHeaderActions();
    if (actions != null) {
      widget.chromeBridge.headerActions.value = actions;
    }
    // Lifecycle (project / dirty / undo / redo) — write directly so
    // the chrome's ProjectHeader flips Save / Undo enablement the
    // instant the shell's state changes. The lifecycle resolver
    // serves the tab-switch fallback path; this path covers the
    // already-active-tab internal updates.
    widget.chromeBridge.lifecycleState.value = _provideLifecycleState();
    // Slash command chips — workspace's _syncSlashHints picks up the
    // resolver result only on tab-switch / active-tab change. On the
    // very first mount (App Builder is the first active tab right at
    // boot) the workspace already ran its initial sync before our
    // context was attached, so the chips never appear until the user
    // switches tabs and comes back. Publish directly here to close
    // the gap.
    final slash = _provideSlashCommands();
    if (slash != null) {
      widget.chromeBridge.chatSlashHints.value = <ChatSlashHint>[
        for (final s in slash)
          ChatSlashHint(
            s.command,
            s.template,
            s.description,
            s.tool,
            s.toolArgs.isEmpty ? null : s.toolArgs,
          ),
      ];
    }
  }

  /// Snapshot the shell's project / undo / dirty bits. Reused by both
  /// the direct bridge write in [_refreshHeaderActions] (active tab,
  /// internal flip) and the [BuiltInAppContext.lifecycleStateProvider]
  /// resolver the workspace's tab-switch sync calls. Returns an empty
  /// state until the shell key attaches so the chrome's ProjectHeader
  /// falls back to `bundleName`.
  DomainLifecycleState _provideLifecycleState() {
    final state = _shellKey.currentState;
    if (state == null) return const DomainLifecycleState.empty();
    return DomainLifecycleState(
      hasProject: state.hasProject,
      dirty: state.dirty,
      canUndo: state.canUndo,
      canRedo: state.canRedo,
      canCompareChannels: state.canCompareChannels,
      projectName: state.projectName,
    );
  }

  /// True when this mount owns the current foreground tab — the
  /// registry's active path equals our bundle path. Used to gate
  /// every direct write into the shared chrome bridge so a mount
  /// kept alive in a background tab cannot leak its state on top of
  /// the visible tab.
  bool get _isActiveTab =>
      BuiltInAppRegistry.instance.activeContext?.bundlePath ==
      widget.bundlePath;

  List<HeaderAction>? _buildHeaderActions() {
    final state = _shellKey.currentState;
    // Even before the shell attaches we still want the trailing row
    // populated so users see the domain icons immediately. Disable
    // every entry until the shell binds — the icons themselves are
    // independent of the live state.
    final has = state?.hasProject ?? false;
    final canUndo = state?.canUndo ?? false;
    final canRedo = state?.canRedo ?? false;
    final dirty = state?.dirty ?? false;
    final canCompareChannels = state?.canCompareChannels ?? false;
    final BuildContext? ctx = state?.context;
    if (!mounted) return null;
    // Row 2 (trailing) — domain-specific actions only. Lifecycle
    // verbs (New / Open / Save / SaveAs / Revert / Undo / Redo /
    // Rename / Close / History / Settings) live in the host's
    // ProjectHeader Row 1 system area and dispatch through
    // `chromeBridge.dispatchLifecycleSlot` → our
    // `lifecycleBindingsProvider`. Duplicating them here would
    // double-render every chrome icon.
    final actions = <HeaderAction>[
      HeaderAction(
        // Mirror feat/project_header.dart Row 2 — file_download_outlined
        // for Import / file_upload_outlined for Export (standalone
        // app_builder's exact icons + tooltips).
        tooltip: 'Import .mbd into this project',
        icon: Icons.file_download_outlined,
        onTap:
            has && ctx != null && state != null
                ? () => state.executeImportBundle(ctx)
                : null,
        elementId: 'import_bundle',
      ),
      HeaderAction(
        tooltip: 'Export .mbd from this project',
        icon: Icons.file_upload_outlined,
        onTap:
            has && ctx != null && state != null
                ? () => state.executeExportBundle(ctx)
                : null,
        elementId: 'export_bundle',
      ),
      HeaderAction(
        tooltip: 'Manage assets…',
        icon: materialIconByName('image'),
        onTap:
            has && ctx != null && state != null
                ? () => state.executeManageAssets(ctx)
                : null,
        elementId: 'manage_assets',
      ),
      HeaderAction(
        tooltip: 'Compare channels…',
        icon: materialIconByName('graph'),
        onTap:
            has && canCompareChannels && ctx != null && state != null
                ? () => state.executeCompareChannels(ctx)
                : null,
        elementId: 'compare_channels',
      ),
      HeaderAction(
        tooltip: 'Build',
        icon: materialIconByName('build'),
        onTap:
            has && ctx != null && state != null
                ? () => state.executeBuild(ctx)
                : null,
        divider: true,
        elementId: 'build',
      ),
      HeaderAction(
        tooltip: 'Build settings…',
        icon: materialIconByName('tune'),
        onTap:
            has && ctx != null && state != null
                ? () => state.executeBuildSettings(ctx)
                : null,
        elementId: 'build_settings',
      ),
    ];
    // Suppress unused_local_variable analyzer warnings for read-only
    // flags consumed only by tooltip / enablement logic above.
    canUndo;
    canRedo;
    dirty;
    return actions;
  }

  @override
  Widget build(BuildContext context) {
    if (_booting) {
      return Container(
        color: VibeTokens.colorOf(context).bg,
        alignment: Alignment.center,
        child: const CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_bootError != null) {
      return Container(
        color: VibeTokens.colorOf(context).bg,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Text(
          'App Builder failed to boot:\n$_bootError',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: VibeTokens.colorOf(context).textPrimary,
            fontSize: 12,
          ),
        ),
      );
    }
    return VibeShell(
      key: _shellKey,
      projection: _projection,
      canonical: _canonical,
      pipeline: _pipeline,
      chat: widget.chat,
      // Pass our overridden settings instance so the shell doesn't
      // do its own VibeSettings.load(VibeSettings.defaultPath('app_builder_vibe')) and miss the host's
      // workspaceDir override. _bootstrap guarantees `_settings` is
      // set before this build path runs (booting=false branch).
      settings: _settings!,
      project: _project,
      bridge: _bridge,
      // Plumb the Studio host's chrome bridge into the shell so
      // bundle-mode cards (Tools, Agents) can wire host base
      // authoring views — `BundleToolsView` needs the bridge for
      // its dispatch / reload calls. Built-in apps already receive
      // the bridge via [widget.chromeBridge].
      studioChromeBridge: widget.chromeBridge,
      // Forward this built-in's tab key so the embedded
      // DslWorkspaceView (Studio Package preview) gates its
      // `buildUI()` on AppBuilder's tab activeness, not on the
      // embedded bundle's own path.
      hostTabKey: widget.bundlePath,
    );
  }
}
