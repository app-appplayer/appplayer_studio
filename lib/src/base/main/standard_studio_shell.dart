/// `StandardStudioShell` — chrome auto-wiring widget every domain
/// can drop into its `buildShell` flow. Composes the four standard
/// surfaces (Titlebar + ProjectHeader + ChatPanel + Statusbar) with
/// the LLM adapter / chat controller / bundle install surface the
/// host already wired through [StudioMain]. Domain only fills the
/// centre pane (and, optionally, a right pane / trailing actions /
/// extra settings sections).
///
/// Standalone builders (vibe_app_builder, vibe_knowledge_builder)
/// gain by replacing their hand-rolled shell layouts with this one;
/// the universal `vibe_studio` host gains a chat / settings flow that
/// works from launch without each host re-implementing the wiring.
library;

import 'dart:io' show stderr;
import 'dart:ui' as ui show Image, ImageByteFormat, PictureRecorder;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;

import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' as fb;
import 'package:appplayer_studio/ui.dart';

import 'studio_main.dart' show StudioFrameScope;
import '../agent/agent_host.dart';
import '../agent/agent_profile.dart';
import '../boot/studio_backbone.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_panel.dart';
import '../chat/chat_slash_hint.dart';
import '../chat/chat_turn.dart';
import '../chat/history_dialog.dart';
import '../chat/model_option.dart';
import '../settings/settings_dialog.dart';
import '../settings/vibe_settings.dart';
import '../shell/activity_bar.dart';
import '../shell/project_header.dart';
import '../shell/statusbar.dart';
import '../shell/titlebar.dart';
import '../shell/tokens.dart';
import 'bundle_install_surface.dart';
import 'chrome_bridge.dart';

/// Builds the centre pane. Receives [BuildContext] so the domain can
/// open dialogs / show menus that need a context above the shell.
typedef CenterBuilder = Widget Function(BuildContext context);

/// Optional right pane (properties panel, inspector, …). Null when
/// the domain doesn't ship one.
typedef RightPaneBuilder = Widget Function(BuildContext context);

class StandardStudioShell extends StatefulWidget {
  const StandardStudioShell({
    super.key,
    required this.appLabel,
    required this.backbone,
    required this.chat,
    required this.modelOptions,
    required this.bundles,
    required this.settings,
    required this.transport,
    required this.port,
    required this.center,
    this.rightPane,
    this.trailing = const <HeaderAction>[],
    this.extraSettingsSections = const <SettingsSection>[],
    this.domainSettings,
    this.domainSettingsBuilder,
    this.historyLevelsBuilder,
    this.bundleName,
    this.specVersion = '0.1',
    this.layerColorBuilder,
    this.layerLabelBuilder,
    this.onSettingsSaved,
    this.chromeBridge,
    this.shellOverlay,
  });

  /// Optional chrome-level UI action bridge. When provided, the shell
  /// installs setters for `toggleLeftPanel` / `setLeftPanelVisible`
  /// from inside its `setState`, so the host's MCP tool handlers can
  /// drive the same code path a user click does.
  final ChromeBridge? chromeBridge;

  /// Optional overlay widget mounted INSIDE the shell's RepaintBoundary
  /// and ABOVE the body. Used by the `capture/` module to display
  /// subtitles / arrows / check marks / etc. on top of the chrome so
  /// they appear in screenshots and recorder frames. Host typically
  /// passes `OverlayLayer(controller: captureSurface.overlayController)`.
  final Widget? shellOverlay;

  /// Tool name shown in the Titlebar's left edge (e.g. "AppPlayer
  /// Studio", "AppPlayer Builder", "Knowledge Builder"). Domain passes
  /// its [StudioApp.displayName].
  final String appLabel;

  final StudioBackbone backbone;

  /// Active chat controller. Pass a `ValueNotifier<VibeChatController>`
  /// when the host swaps controllers (e.g. per-tab chat in the
  /// universal host). For single-controller shells, wrap the
  /// controller in `ValueNotifier(controller)` once and reuse.
  final ValueListenable<VibeChatController> chat;
  final List<VibeModelOption> modelOptions;
  final BundleInstallSurface bundles;
  final VibeSettings settings;
  final String transport;
  final int port;

  /// Centre pane builder — the domain's main view (welcome list /
  /// canonical editor / DSL workspace / kb modes).
  final CenterBuilder center;

  /// Optional right pane (properties panel etc.). Hidden on narrow
  /// windows.
  final RightPaneBuilder? rightPane;

  /// Domain-defined Row 2 actions of [ProjectHeader]. Empty by
  /// default — vibe_app_builder ships build / clean / asset verbs,
  /// vkb keeps it empty.
  final List<HeaderAction> trailing;

  /// Studio-tab extras appended below the built-in sections. Rare.
  final List<SettingsSection> extraSettingsSections;

  /// Domain-side panel for the Settings dialog. Pass non-null when an
  /// active bundle / domain is selected to surface its settings under a
  /// dedicated "Domain" tab; null collapses the dialog to a single
  /// Studio pane. Static — resolved once when the shell is built.
  final DomainSettingsPanel? domainSettings;

  /// Dynamic resolver for the Domain panel — called every time the
  /// Settings dialog opens. Use this when the active bundle changes
  /// without rebuilding the shell (e.g. tab switching in the universal
  /// host); takes precedence over [domainSettings] when non-null.
  final DomainSettingsPanel? Function()? domainSettingsBuilder;

  /// Resolver for the History dialog levels — called every time the
  /// history icon fires. Returns the Studio / Package / Project levels
  /// the host wants to surface. Empty / null = the icon stays inert.
  final List<HistoryLevel> Function()? historyLevelsBuilder;

  /// Optional bundle/project name displayed in the Titlebar. Defaults
  /// to a lower-cased copy of [appLabel].
  final String? bundleName;

  /// Spec version pill text. Domains override only when they ship a
  /// versioned DSL.
  final String specVersion;

  /// Optional layer-color/label resolvers for [ChatPanel]'s patch
  /// cards. Domains that don't surface layered patches leave both
  /// null and the shell falls back to neutral tokens.
  final Color Function(Object? layer)? layerColorBuilder;
  final String? Function(Object? layer)? layerLabelBuilder;

  /// Called after the standard Settings dialog saves. Hosts use this
  /// to refresh anything dependent on `settings.llmModel` /
  /// `llmApiKey` / `llmEndpoint` / etc.
  final void Function(VibeSettings updated)? onSettingsSaved;

  @override
  State<StandardStudioShell> createState() => _StandardStudioShellState();
}

class _StandardStudioShellState extends State<StandardStudioShell> {
  late VibeSettings _settings;
  double _chatWidth = VibeTokens.chatPanelWidth;
  bool _leftPanelVisible = true;

  /// Root key for `studio.renderer.layout_snapshot` — wraps the entire
  /// shell so the snapshot walks chrome (titlebar / statusbar / activity
  /// bar / project header) plus the centre body. Published to the
  /// chrome bridge in initState; host's `_captureLayoutSnapshot` reads
  /// it as the preferred root.
  final GlobalKey _shellRootKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _settings = widget.settings;
    if (_settings.chatPanelWidth != null) {
      _chatWidth = _settings.chatPanelWidth!;
    }
    final bridge = widget.chromeBridge;
    if (bridge != null) {
      bridge.toggleLeftPanel = () {
        setState(() => _leftPanelVisible = !_leftPanelVisible);
        return _leftPanelVisible;
      };
      bridge.setLeftPanelVisible = (v) {
        setState(() => _leftPanelVisible = v);
        return _leftPanelVisible;
      };
      bridge.openSettings = _onSettings;
      bridge.openHistory = _onHistory;
      bridge.captureRootKey = _shellRootKey;
      bridge.captureScreenshot = _captureScreenshot;
      bridge.notify = _onNotify;
      bridge.dialog = _onDialog;
      bridge.prompt = _onPrompt;
    }
  }

  @override
  void dispose() {
    final bridge = widget.chromeBridge;
    if (bridge != null) {
      bridge.toggleLeftPanel = null;
      bridge.setLeftPanelVisible = null;
      bridge.openSettings = null;
      bridge.openHistory = null;
      bridge.captureRootKey = null;
      bridge.notify = null;
      bridge.dialog = null;
      bridge.prompt = null;
      bridge.captureScreenshot = null;
    }
    super.dispose();
  }

  /// Lightweight transient toast — uses the ScaffoldMessenger captured
  /// by `_shellRootKey`. Styled to match studio tone (mono font,
  /// surface2 background, severity-tinted left rule). Falls back to
  /// nothing when no Scaffold is reachable.
  void _onNotify(String message, {String? severity}) {
    final ctx = _shellRootKey.currentContext;
    if (ctx == null) return;
    final messenger = ScaffoldMessenger.maybeOf(ctx);
    if (messenger == null) return;
    final c = VbuTokens.colorOf(context);
    final s = VbuTokens.status;
    Color accent;
    switch (severity) {
      case 'error':
        accent = s.error;
        break;
      case 'success':
        accent = s.ok;
        break;
      case 'warn':
      case 'warning':
        accent = s.warn;
        break;
      default:
        accent = s.info;
    }
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: c.surface2,
        elevation: 0,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: c.borderSubtle),
          borderRadius: BorderRadius.circular(4),
        ),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(width: 3, height: 28, color: accent),
            const SizedBox(width: VbuTokens.space3),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: VbuTokens.space2,
                  horizontal: VbuTokens.space1,
                ),
                child: Text(
                  message,
                  style: vbuMono(size: 11, color: c.textPrimary),
                ),
              ),
            ),
            const SizedBox(width: VbuTokens.space3),
          ],
        ),
      ),
    );
  }

  /// Modal info dialog — studio-toned scaffold (`VbuDialogScaffold`)
  /// with [title] / [body] and a single OK action. Resolves true once
  /// dismissed.
  Future<bool> _onDialog({required String title, required String body}) async {
    final ctx = _shellRootKey.currentContext;
    if (ctx == null) return false;
    final c = VbuTokens.colorOf(context);
    await showDialog<void>(
      context: ctx,
      builder:
          (dctx) => VbuDialogScaffold(
            title: title,
            maxWidth: 460,
            maxHeight: 320,
            body: Text(body, style: vbuMono(size: 11, color: c.textPrimary)),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dctx).pop(),
                style: TextButton.styleFrom(foregroundColor: c.mint),
                child: Text(
                  'OK',
                  style: vbuMono(size: 11, weight: FontWeight.w600),
                ),
              ),
            ],
          ),
    );
    return true;
  }

  /// Modal picker — studio-toned scaffold (`VbuDialogScaffold`) with
  /// [question] and a button per [options] entry (defaults to
  /// `['Cancel', 'OK']`). Resolves with the chosen index or -1 on
  /// dismiss / when no UI context is reachable.
  Future<int> _onPrompt({
    required String question,
    List<String>? options,
  }) async {
    final ctx = _shellRootKey.currentContext;
    if (ctx == null) return -1;
    final opts =
        options == null || options.isEmpty ? <String>['Cancel', 'OK'] : options;
    final c = VbuTokens.colorOf(context);
    final picked = await showDialog<int>(
      context: ctx,
      builder:
          (dctx) => VbuDialogScaffold(
            title: 'PROMPT',
            titleStyle: vbuMono(
              size: 11,
              weight: FontWeight.w600,
              color: c.textSecondary,
            ).copyWith(letterSpacing: 1.0),
            maxWidth: 460,
            maxHeight: 320,
            body: Text(
              question,
              style: vbuMono(size: 12, color: c.textPrimary),
            ),
            actions: <Widget>[
              for (var i = 0; i < opts.length; i++)
                TextButton(
                  onPressed: () => Navigator.of(dctx).pop(i),
                  style: TextButton.styleFrom(
                    foregroundColor:
                        i == opts.length - 1 ? c.mint : c.textSecondary,
                  ),
                  child: Text(
                    opts[i],
                    style: vbuMono(
                      size: 11,
                      weight:
                          i == opts.length - 1
                              ? FontWeight.w600
                              : FontWeight.w500,
                    ),
                  ),
                ),
            ],
          ),
    );
    return picked ?? -1;
  }

  Future<void> _onHistory() async {
    final builder = widget.historyLevelsBuilder;
    if (builder == null) return;
    final levels = builder();
    if (levels.isEmpty) return;
    await showChatHistoryDialog(context, levels: levels);
  }

  void _onModelChange(String id) {
    _settings.llmModel = id;
    // ignore: unawaited_futures
    _settings.save(p.join(widget.backbone.configRoot, 'settings.json'));
    widget.onSettingsSaved?.call(_settings);
  }

  /// Per-agent model swap — picker writes to the chat's currently
  /// bound agent (not the global setting). Updates both the
  /// FlowBrain Agent record (ModelSpec) and the in-memory
  /// VibeAgentProfile so studio.agent.list / describe reflect it
  /// immediately. The notifier flip rebuilds the picker label.
  Future<void> _onAgentModelChange(String agentId, String modelId) async {
    final host = AgentHost.shared;
    if (host == null) {
      _onModelChange(modelId);
      return;
    }
    try {
      await host.flowbrain.system.agents.updateAgent(
        agentId,
        model: fb.ModelSpec(provider: modelId, model: modelId),
      );
    } catch (_) {
      // Agent not registered (yet) — fall back to global setting so
      // the picker is never inert.
      _onModelChange(modelId);
      return;
    }
    final idx = host.profiles.indexWhere((p) => p.id == agentId);
    if (idx >= 0) {
      final old = host.profiles[idx];
      host.profiles[idx] = VibeAgentProfile(
        id: old.id,
        displayName: old.displayName,
        modelId: modelId,
        role: old.role,
        systemPrompt: old.systemPrompt,
        toolNames: old.toolNames,
      );
    }
    // Bump the notifier to a fresh string-equal value so the picker
    // ValueListenableBuilder rebuilds and re-reads profile.modelId.
    final bridge = widget.chromeBridge;
    if (bridge != null) {
      final cur = bridge.activeChatAgentId.value;
      bridge.activeChatAgentId.value = '';
      bridge.activeChatAgentId.value = cur;
    }
  }

  Future<void> _onSettings() async {
    final settingsPath = p.join(widget.backbone.configRoot, 'settings.json');
    final domain =
        widget.domainSettingsBuilder?.call() ?? widget.domainSettings;
    final updated = await showVibeSettingsDialog(
      context,
      _settings,
      modelOptions: widget.modelOptions,
      settingsPath: settingsPath,
      extraSections: widget.extraSettingsSections,
      domain: domain,
    );
    if (updated == null) return;
    setState(() => _settings = updated);
    // ignore: unawaited_futures
    updated.save(settingsPath);
    widget.onSettingsSaved?.call(updated);
    // Push into the live `StudioFrame` so its `MaterialApp.themeMode`
    // rebuilds with the new `VibeSettings.themeMode` — flips the
    // chrome brightness without an app restart.
    StudioFrameScope.maybeOf(context)?.updateSettings(updated);
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final bundleName = widget.bundleName ?? widget.appLabel.toLowerCase();
    return RepaintBoundary(
      key: _shellRootKey,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Container(
            color: c.bg,
            child: Column(
              children: <Widget>[
                VibeTitlebar(
                  appLabel: widget.appLabel,
                  bundleName: bundleName,
                  transport: widget.transport,
                  specVersion: widget.specVersion,
                  port: widget.port,
                  chromeBridge: widget.chromeBridge,
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (ctx, constraints) {
                      final showChat =
                          _leftPanelVisible && constraints.maxWidth >= 720;
                      final showRight =
                          widget.rightPane != null &&
                          constraints.maxWidth >= 980;
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          if (showChat) ...<Widget>[
                            SizedBox(
                              width: _chatWidth,
                              child: Column(
                                children: <Widget>[
                                  ValueListenableBuilder<bool>(
                                    valueListenable:
                                        widget.chromeBridge?.homeActive ??
                                        ValueNotifier<bool>(false),
                                    builder: (_, homeActive, __) {
                                      final bridge = widget.chromeBridge;
                                      final newTip =
                                          homeActive
                                              ? 'New package'
                                              : 'New project';
                                      final openTip =
                                          homeActive
                                              ? 'Open package'
                                              : 'Open project folder';
                                      void fire(String slot) {
                                        stderr.writeln(
                                          'shell.fire slot=$slot homeActive=$homeActive '
                                          'dispatchSet=${bridge?.dispatchLifecycleSlot != null}',
                                        );
                                        bridge?.dispatchLifecycleSlot?.call(
                                          slot,
                                          const <String, dynamic>{},
                                        );
                                      }

                                      void onNew() {
                                        if (homeActive) {
                                          // Home — Studio Builder placeholder
                                          // (no active domain to dispatch into).
                                          bridge?.createNewPackage?.call();
                                        } else {
                                          // Every domain (built-in or manifest)
                                          // owns its New flow through the
                                          // standard lifecycle slot. Built-in
                                          // apps register a handler via
                                          // BuiltInAppContext.lifecycleBindings;
                                          // manifest bundles wire it through
                                          // wiring.lifecycle[].
                                          fire('project.new');
                                        }
                                      }

                                      void onOpen() {
                                        if (homeActive) {
                                          bridge?.openPackagePicker?.call();
                                        } else {
                                          fire('project.open');
                                        }
                                      }

                                      return ValueListenableBuilder<
                                        DomainLifecycleState
                                      >(
                                        valueListenable:
                                            bridge?.lifecycleState ??
                                            ValueNotifier<DomainLifecycleState>(
                                              const DomainLifecycleState.empty(),
                                            ),
                                        builder: (_, life, __) {
                                          return ValueListenableBuilder<
                                            List<HeaderAction>
                                          >(
                                            valueListenable:
                                                bridge?.headerActions ??
                                                ValueNotifier<
                                                  List<HeaderAction>
                                                >(const <HeaderAction>[]),
                                            builder:
                                                (_, dyn, __) => ProjectHeader(
                                                  projectName:
                                                      life.projectName ??
                                                      bundleName,
                                                  dirty: life.dirty,
                                                  canUndo: life.canUndo,
                                                  canRedo: life.canRedo,
                                                  hasProject: life.hasProject,
                                                  newTooltip: newTip,
                                                  openTooltip: openTip,
                                                  onNew:
                                                      homeActive ? null : onNew,
                                                  onOpen: onOpen,
                                                  onOpenRecent: (_) {},
                                                  onSave:
                                                      () =>
                                                          fire('project.save'),
                                                  onSaveAs:
                                                      () => fire(
                                                        'project.saveAs',
                                                      ),
                                                  onRevert:
                                                      () => fire(
                                                        'project.revert',
                                                      ),
                                                  onUndo:
                                                      () => fire('edit.undo'),
                                                  onRedo:
                                                      () => fire('edit.redo'),
                                                  onRename:
                                                      () => fire(
                                                        'project.rename',
                                                      ),
                                                  onCloseProject:
                                                      () =>
                                                          fire('project.close'),
                                                  onHistory: _onHistory,
                                                  onSettings: _onSettings,
                                                  // Extra domain actions (Import /
                                                  // Export / Build / Compare / Assets
                                                  // / …) ride the trailing slot —
                                                  // domains publish them through
                                                  // chromeBridge.headerActions and
                                                  // they render to the right of the
                                                  // system buttons.
                                                  trailing: <HeaderAction>[
                                                    ...widget.trailing,
                                                    ...dyn,
                                                  ],
                                                  leftPanelVisible: true,
                                                  onToggleLeftPanel:
                                                      () => setState(
                                                        () =>
                                                            _leftPanelVisible =
                                                                false,
                                                      ),
                                                ),
                                          );
                                        },
                                      );
                                    },
                                  ),
                                  Expanded(
                                    child: ValueListenableBuilder<
                                      VibeChatController
                                    >(
                                      valueListenable: widget.chat,
                                      builder: (_, ctrl, __) {
                                        final bridge = widget.chromeBridge;
                                        if (bridge == null) {
                                          return ChatPanel(
                                            controller: ctrl,
                                            modelOptions: widget.modelOptions,
                                            currentModelId:
                                                _settings.llmModel ??
                                                widget.modelOptions.first.id,
                                            onModelChange: _onModelChange,
                                            layerColorBuilder:
                                                widget.layerColorBuilder ??
                                                ((_) => c.textTertiary),
                                            layerLabelBuilder:
                                                widget.layerLabelBuilder ??
                                                ((_) => null),
                                          );
                                        }
                                        return ValueListenableBuilder<
                                          List<ChatSlashHint>
                                        >(
                                          valueListenable:
                                              bridge.chatSlashHints,
                                          builder:
                                              (
                                                _,
                                                hints,
                                                __,
                                              ) => ValueListenableBuilder<
                                                String
                                              >(
                                                valueListenable:
                                                    bridge.activeChatAgentId,
                                                builder: (_, chatAgentId, __) {
                                                  // Per-agent model picker: read
                                                  // the active chat agent's
                                                  // current modelId; fall back to
                                                  // the global setting / catalog
                                                  // default when the agent is
                                                  // unknown. onModelChange writes
                                                  // back via studio.agent.set_model
                                                  // semantics (host wires it).
                                                  // `declared` = the active
                                                  // agent's manifest model.
                                                  // `effective` = what the kernel
                                                  // actually routes through after
                                                  // the host's adapter-pool lookup
                                                  // (`bridge.effectiveModelIdResolver`
                                                  // mirrors `_resolveLlmFor`'s
                                                  // provider lookup → first-entry
                                                  // fallback). When the two differ
                                                  // the user is being silently
                                                  // fell back; the chip surfaces
                                                  // it inline.
                                                  final declared =
                                                      AgentHost.shared
                                                          ?.profileFor(
                                                            chatAgentId,
                                                          )
                                                          ?.modelId;
                                                  final effective =
                                                      bridge
                                                          .effectiveModelIdResolver
                                                          ?.call(chatAgentId) ??
                                                      declared;
                                                  final currentModel =
                                                      declared ??
                                                      effective ??
                                                      widget
                                                          .modelOptions
                                                          .first
                                                          .id;
                                                  // The host builds `controller
                                                  // .agents` per tab at `_chatFor`
                                                  // time (host_agents.json for Home,
                                                  // built-in seed for app_builder /
                                                  // scene_builder / ops, bundle
                                                  // manifest for user packages), so
                                                  // the chip's roster popup picks up
                                                  // the active domain's agents
                                                  // through the controller — no
                                                  // override needed here.
                                                  return ChatPanel(
                                                    controller: ctrl,
                                                    modelOptions:
                                                        widget.modelOptions,
                                                    currentModelId:
                                                        currentModel,
                                                    effectiveModelId: effective,
                                                    onModelChange:
                                                        (id) =>
                                                            _onAgentModelChange(
                                                              chatAgentId,
                                                              id,
                                                            ),
                                                    layerColorBuilder:
                                                        widget
                                                            .layerColorBuilder ??
                                                        ((_) => c.textTertiary),
                                                    layerLabelBuilder:
                                                        widget
                                                            .layerLabelBuilder ??
                                                        ((_) => null),
                                                    slashHints: hints,
                                                    onSlashCommand:
                                                        bridge
                                                            .runSlashCommandInActive,
                                                    currentAgentIdOverride:
                                                        chatAgentId,
                                                  );
                                                },
                                              ),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            VbuPanelSplitter(
                              color: c.borderDefault,
                              onDrag: (dx) {
                                setState(() {
                                  _chatWidth = (_chatWidth + dx).clamp(
                                    240.0,
                                    600.0,
                                  );
                                });
                              },
                              onDragEnd: () {
                                _settings.chatPanelWidth = _chatWidth;
                                // ignore: unawaited_futures
                                _settings.save(
                                  p.join(
                                    widget.backbone.configRoot,
                                    'settings.json',
                                  ),
                                );
                              },
                            ),
                          ] else ...<Widget>[
                            ValueListenableBuilder<List<HeaderAction>>(
                              valueListenable:
                                  widget.chromeBridge?.headerActions ??
                                  ValueNotifier<List<HeaderAction>>(
                                    const <HeaderAction>[],
                                  ),
                              builder:
                                  (_, dyn, __) => ActivityBar(
                                    onExpand:
                                        () => setState(
                                          () => _leftPanelVisible = true,
                                        ),
                                    onNew: () {},
                                    onOpen: () {},
                                    onSave: () {},
                                    onSaveAs: () {},
                                    onRevert: () {},
                                    onCloseProject: () {},
                                    onSettings: _onSettings,
                                    onUndo: () {},
                                    onRedo: () {},
                                    onHistory: _onHistory,
                                    dirty: false,
                                    hasProject: false,
                                    canUndo: false,
                                    canRedo: false,
                                    trailing: <HeaderAction>[
                                      ...widget.trailing,
                                      ...dyn,
                                    ],
                                  ),
                            ),
                          ],
                          Expanded(child: widget.center(context)),
                          if (showRight) ...<Widget>[
                            Container(width: 1, color: c.borderDefault),
                            SizedBox(
                              width: 320,
                              child: widget.rightPane!(context),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
                if (widget.chromeBridge == null)
                  VibeStatusbar(
                    state: StatusbarState.synced,
                    latencyMs: 0,
                    patches: 0,
                    pages: 0,
                    lastActivity: '—',
                    specVersion: widget.specVersion,
                    chromeBridge: null,
                  )
                else
                  ValueListenableBuilder<int>(
                    valueListenable: widget.chromeBridge!.lintBlocks,
                    builder:
                        (_, lintBlocks, __) => ValueListenableBuilder<int>(
                          valueListenable: widget.chromeBridge!.lintWarns,
                          builder:
                              (_, lintWarns, __) => VibeStatusbar(
                                state: StatusbarState.synced,
                                latencyMs: 0,
                                patches: 0,
                                pages: 0,
                                lastActivity: '—',
                                specVersion: widget.specVersion,
                                chromeBridge: widget.chromeBridge,
                                lintBlocks: lintBlocks,
                                lintWarns: lintWarns,
                                onTapLint:
                                    widget.chromeBridge!.onTapLintInActive,
                              ),
                        ),
                  ),
              ],
            ),
          ),
          if (widget.shellOverlay != null) widget.shellOverlay!,
        ],
      ),
    );
  }

  /// Capture the shell's RepaintBoundary as a PNG. Returns null when the
  /// shell hasn't mounted yet (no currentContext) or the captured render
  /// object isn't a `RenderRepaintBoundary` (defensive — shouldn't happen
  /// given the build() wraps with one). Bridged from
  /// `bridge.captureScreenshot` so the `studio.renderer.screenshot` MCP
  /// tool can return base64-PNG to any MCP client without OS-level shell
  /// commands. When [area] is non-null, crops to that rect via
  /// `PictureRecorder` — pure dart:ui, no external deps.
  Future<Uint8List?> _captureScreenshot({
    double pixelRatio = 1.0,
    Rect? area,
  }) async {
    final ctx = _shellRootKey.currentContext;
    if (ctx == null) return null;
    final ro = ctx.findRenderObject();
    if (ro is! RenderRepaintBoundary) return null;
    final image = await ro.toImage(pixelRatio: pixelRatio);
    try {
      ui.Image finalImage = image;
      if (area != null) {
        finalImage = await _cropImage(image, area, pixelRatio);
      }
      final byteData = await finalImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (area != null) finalImage.dispose();
      return byteData?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  /// Crop [image] to [area] (in logical pixels) via PictureRecorder.
  Future<ui.Image> _cropImage(
    ui.Image image,
    Rect area,
    double pixelRatio,
  ) async {
    final srcRect = Rect.fromLTWH(
      area.left * pixelRatio,
      area.top * pixelRatio,
      area.width * pixelRatio,
      area.height * pixelRatio,
    );
    final dstRect = Rect.fromLTWH(0, 0, srcRect.width, srcRect.height);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(image, srcRect, dstRect, Paint());
    final pic = recorder.endRecording();
    return pic.toImage(srcRect.width.toInt(), srcRect.height.toInt());
  }
}

/// Convenience send-binding that drives [VibeChatController] through
/// the manager agent on a backbone. Domains that want the standard
/// "ask manager" flow with no extra wiring pass the result of this
/// helper to `VibeChatController(send: ...)` inside their
/// [StudioApp.buildChatController].
///
/// When [dispatchTool] is supplied, the helper drives a multi-turn
/// tool-use loop — the LLM's `toolCalls` get dispatched back through
/// [dispatchTool], the results feed the next `ask`, and the cycle
/// repeats until the model returns content with no further calls (or
/// [maxIterations] is hit). Without [dispatchTool] the helper falls
/// back to the single-turn legacy path (caller must dispatch tools
/// themselves).
Future<ChatTurn> standardManagerSend({
  required AgentHost? agentHost,
  required String input,
  String managerAgentId = 'manager',
  String missingKeyMessage = 'Set an LLM API key in Settings to enable chat.',
  Future<String> Function(String name, Map<String, Object?> args)? dispatchTool,
  int maxIterations = 8,
}) async {
  final host = agentHost;
  if (host == null) {
    return ChatTurn(role: 'assistant', text: missingKeyMessage);
  }
  if (dispatchTool == null) {
    final reply = await host.askAgent(managerAgentId, input);
    return ChatTurn(role: 'assistant', text: reply.content);
  }
  var message = input;
  for (var i = 0; i < maxIterations; i++) {
    final reply = await host.askAgent(managerAgentId, message);
    final calls = reply.toolCalls;
    if (calls == null || calls.isEmpty) {
      return ChatTurn(role: 'assistant', text: reply.content);
    }
    final transcript = StringBuffer();
    if (reply.content.isNotEmpty) {
      transcript
        ..writeln(reply.content)
        ..writeln();
    }
    transcript.writeln('Tool results:');
    for (final call in calls) {
      String result;
      try {
        result = await dispatchTool(call.name, call.arguments);
      } catch (e) {
        result = 'error: $e';
      }
      transcript.writeln('- ${call.name}: $result');
    }
    message = transcript.toString();
  }
  return ChatTurn(
    role: 'assistant',
    text: '(tool-use loop hit $maxIterations iterations; aborting)',
  );
}
