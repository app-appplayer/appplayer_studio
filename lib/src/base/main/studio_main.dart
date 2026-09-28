/// `StudioMain.run` — single Flutter entry every domain main.dart
/// delegates to. Standardises the boot sequence:
///
///   1. `WidgetsFlutterBinding.ensureInitialized()`
///   2. parse `--project / --transport / --port` (the three flags every
///      builder shares; domain-specific flags can be parsed inside the
///      [StudioAppFactory]).
///   3. reject `--transport=stdio` — Flutter shells block on `runApp`.
///   4. ask the [StudioAppFactory] for a domain `StudioApp` instance
///      (it may open the project, load domain settings, etc).
///   5. load `~/.config/<configRootName ?? toolId>/settings.json`.
///   6. boot the kernel-backed backbone (StudioBoot.start).
///   7. build the bundle install surface against the backbone +
///      `<configRoot>/installed/`.
///   8. ask the StudioApp to build server + tools + LLM + chat.
///   9. start the MCP transport in the background (domain owns the
///      flavour: streamable-http or SSE).
///  10. `runApp(StudioFrame(...))` — `MaterialApp` + dark theme +
///      `Scaffold` framing the domain's `ShellBlueprint`.
///
/// The factory pattern keeps StudioApp instances closure-free: hosts
/// pre-load any state they want to inject (project handle, dispatcher,
/// recorder, ...) and capture it as fields on their concrete
/// implementation.
library;

import 'dart:io';

import 'package:appplayer_secure/appplayer_secure.dart'
    show FlutterSecureStorageBackend;
import 'package:args/args.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/runtime.dart' as studio_rt;
import 'package:appplayer_studio/src/base/main/runtime_log_bridge.dart'
    show installRuntimeLogBridge;
import 'package:appplayer_studio/src/base/main/studio_navigator.dart'
    show studioRootNavigatorKey;
import 'package:appplayer_studio/ui.dart' as ui;

import '../boot/studio_boot.dart';
import '../chat/chat_controller.dart';
import '../settings/llm_key_store.dart';
import '../settings/third_party_licenses.dart';
import '../settings/vibe_settings.dart';
import '../shell/app_theme.dart';
import 'bundle_install_surface.dart';
import 'shell_blueprint.dart';
import 'studio_app.dart';

/// Constructs a [StudioApp] from parsed CLI args. The factory may
/// perform async work (project open, settings load, dispatcher init)
/// before returning the `StudioApp` instance.
typedef StudioAppFactory = Future<StudioApp> Function(ArgResults args);

class StudioMain {
  StudioMain._();

  /// Standard Flutter entry. Domain `main(List<String> args) =>
  /// StudioMain.run(rawArgs: args, factory: ...)`.
  static Future<void> run({
    required List<String> rawArgs,
    required StudioAppFactory factory,
  }) async {
    WidgetsFlutterBinding.ensureInitialized();

    final parser =
        ArgParser()
          ..addOption('project', abbr: 'p')
          ..addOption('workspace', abbr: 'w')
          ..addOption('transport', defaultsTo: null)
          ..addOption('instance', abbr: 'i', defaultsTo: null)
          ..addOption('port', defaultsTo: null);
    final args = parser.parse(rawArgs);

    final explicitTransport = args['transport'] as String?;
    if (explicitTransport == 'stdio') {
      stderr.writeln(
        'Studio Flutter shell does not support stdio. '
        'Use the dart entry binary if a stdio transport is required.',
      );
      exit(64);
    }
    final transport = explicitTransport == 'sse' ? 'sse' : 'http';

    final app = await factory(args);

    // Global async-error backstop. A long-running agent turn (e.g. the Claude
    // Code fallback subprocess) can surface an error from a stream / timer /
    // unawaited callback OUTSIDE any tool-handler `await` chain; without a
    // top-level handler such an uncaught async error can take the whole host
    // process down mid-run (the reported `agent_ask` disconnect that left the
    // process dead). Log via stderr (the host's boot/transport channel) and
    // keep the process alive — per-tool errors are still returned to callers by
    // the tool wrapper's own try/catch, so this only swallows the out-of-band
    // class that would otherwise be fatal.
    WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
      stderr.writeln(
        '${app.toolId}: uncaught async error (host kept alive) — $error',
      );
      return true;
    };
    final prevFlutterOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      stderr.writeln(
        '${app.toolId}: flutter error — ${details.exceptionAsString()}',
      );
      // Framework assertions raised inside a widget's build carry no stack
      // in the default dump; name the studio frames so the owning widget
      // can be found from the log alone.
      final stack = details.stack;
      if (stack != null) {
        final own = stack
            .toString()
            .split('\n')
            .where((l) => l.contains('package:appplayer_studio/'))
            .take(3);
        for (final line in own) {
          stderr.writeln('${app.toolId}:   at ${line.trim()}');
        }
      }
      prevFlutterOnError?.call(details);
    };

    final baseConfigRootName = app.configRootName ?? app.toolId;

    // Instance profile — lets the same build run as several fully independent
    // processes. `--instance N` pins a profile explicitly; absent the flag,
    // the launcher auto-claims the first free slot (1, then 2, …) so a plain
    // second launch lands on its OWN profile instead of colliding with
    // instance 1 on config root + port. Each instance N routes to config root
    // `<base>-N` (own settings / keys / tabs / plugins; N == 1 keeps the bare
    // `<base>`, so a single launch is unchanged) and, absent `--port`, its own
    // main port. Projects stay portable — any instance opens any project via
    // `--project` or the UI; the profile is a window identity, not a project
    // binding. Cross-platform: liveness uses Dart's `RandomAccessFile` advisory
    // lock (fcntl / LockFileEx), released by the OS on exit so a crashed slot
    // frees itself.
    final explicitInstance = int.tryParse((args['instance'] as String?) ?? '');
    final instance = _resolveInstance(baseConfigRootName, explicitInstance);

    // Instance N routes to its own config root `<base>-N` and its own main-port
    // band (`defaultPort + (N-1)*100`). See [instanceConfigRootName] /
    // [instancePortOffset].
    final portOffset = instancePortOffset(instance);
    final configRootName = instanceConfigRootName(baseConfigRootName, instance);
    final configRoot = p.join(_homeDir(), '.config', configRootName);
    final settingsPath = p.join(configRoot, 'settings.json');
    // Native libraries and bundled fonts join the Dart package licenses.
    registerThirdPartyLicenses();
    // LLM keys are read from and written to the OS keychain.
    LlmKeyStore.storage ??= FlutterSecureStorageBackend();
    final settings = await VibeSettings.load(settingsPath);
    // Hint the host app at the config root before the first
    // `agentProfiles` read — host_agents.json sits there and must be
    // resolvable before `StudioBoot.start` calls the getter.
    try {
      (app as dynamic).configRootHint = configRoot;
    } catch (_) {
      /* hosts without the hint accept their baseline */
    }
    // Configured model hint — seed / host agents that declare no model
    // inherit `settings.llmModel` instead of a hardcoded id.
    try {
      (app as dynamic).defaultModelHint = settings.llmModel;
    } catch (_) {
      /* hosts without the hint accept their baseline */
    }

    // Port resolution: CLI `--port` > Studio Settings `mcpServerUrl`
    // (parse port from URL) > host's hard-coded [StudioApp.defaultPort]
    // shifted by the instance offset (so instance N > 1 picks a distinct
    // port without an explicit flag). The listen socket binds once at
    // boot, so a Settings change requires a restart.
    int? portFromSettingsUrl;
    final settingsUrl = settings.mcpServerUrl;
    if (settingsUrl != null && settingsUrl.isNotEmpty) {
      final parsed = Uri.tryParse(settingsUrl);
      if (parsed != null && parsed.hasPort) portFromSettingsUrl = parsed.port;
    }
    final port =
        int.tryParse((args['port'] as String?) ?? '') ??
        portFromSettingsUrl ??
        (app.defaultPort + portOffset);

    final backbone = await StudioBoot.start(
      toolId: app.toolId,
      configRoot: configRoot,
      agentProfiles: app.agentProfiles,
      fetchAllToolDefinitions: app.fetchAllToolDefinitions,
      models: <({String id, String? provider})>[
        for (final m in app.modelCatalog) (id: m.id, provider: m.provider),
      ],
      llmApiKey: settings.llmApiKey,
      llmEndpoint: settings.llmEndpoint,
      keyForProvider: settings.keyFor,
      seedBundles: app.seedBundles(),
      workspaceId: app.toolId,
      resolveAgentId: app.resolveAgentId,
      // Configured model (Settings → LLM) — agents created without an
      // explicit ModelSpec inherit this instead of the stub port.
      defaultModelId: settings.llmModel,
    );

    final bundles = BundleInstallSurface(
      bundleRegistry: backbone.bundleRegistry,
      knowledgeEngine: backbone.knowledgeEngine,
      installedCacheDir: p.join(configRoot, 'installed'),
    );

    final server = app.buildServer(backbone: backbone, bundles: bundles);
    app.registerMcpTools(server: server, backbone: backbone, bundles: bundles);

    // Background transport boot — fail-loud via stderr but never block
    // GUI startup.
    // ignore: unawaited_futures
    app
        .startTransport(server: server, transport: transport, port: port)
        .catchError((Object e) {
          stderr.writeln('${app.toolId}: MCP transport failed — $e');
        });
    stderr.writeln(
      '${app.toolId}: MCP listening at $transport://127.0.0.1:$port',
    );

    final llm = app.buildLlmAdapter(
      backbone: backbone,
      settings: settings,
      server: server,
    );
    final chat = await app.buildChatController(
      backbone: backbone,
      settings: settings,
      llm: llm,
      server: server,
    );

    // ThemeManager is a process-singleton inside the
    // `vibe_studio_runtime` fork (see runtime_engine.dart's
    // `_themeManager = ThemeManager()` factory). Inject the studio's
    // M3 tone ONCE at host boot so every `MCPUIRuntime` instance —
    // multiple alive workspace tabs included — reads the same
    // ThemeDefinition. Per-mount injection drove the singleton's
    // `_definition` / `_stateManager` through repeated overwrites,
    // leaving the last-mounted bundle's theme winning across all
    // tabs (visible regression: returning to an earlier tab lost
    // its text styling).
    studio_rt.ThemeManager.instance.setTheme(ui.VbuTheme.studioRuntimeTheme());

    // The runtime's author-facing diagnostics reach only a host that installs
    // a sink. Without this the studio — an authoring tool — swallowed exactly
    // the messages an author needs (a widget placed under a key its type does
    // not declare is dropped silently). Installed once, process-wide.
    installRuntimeLogBridge();

    runApp(
      StudioFrame(
        app: app,
        backbone: backbone,
        bundles: bundles,
        server: server,
        llm: llm,
        chat: chat,
        settings: settings,
        transport: transport,
        port: port,
      ),
    );
  }

  static String _homeDir() {
    return Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
  }

  /// Advisory lock held for the whole process lifetime to keep this instance's
  /// slot claimed. Never closed — the OS releases it on exit (fcntl on POSIX,
  /// LockFileEx on Windows), so a crashed instance's slot is reclaimed
  /// automatically. Stored on a static field so it is not garbage-collected.
  // ignore: unused_field
  static RandomAccessFile? _instanceLock;

  /// Resolve this launch's instance number. When [explicit] is set
  /// (`--instance N`) it is honoured as-is. Otherwise auto-claim the first
  /// FREE slot (1, then 2, …): for each candidate, take a cross-platform
  /// advisory lock on `<base>.locks/instance-<n>.lock`; the first lock that
  /// succeeds is this instance, and the handle is held for the process
  /// lifetime so the slot stays claimed until exit. The coordination dir holds
  /// only ephemeral locks — no user data. Falls back to [explicit] ?? 1 if the
  /// dir is unusable or (implausibly) every slot is busy.
  static int _resolveInstance(String baseConfigRootName, int? explicit) {
    final lockDir = Directory(
      p.join(_homeDir(), '.config', '$baseConfigRootName.locks'),
    );
    final claimed = claimInstanceSlot(lockDir, explicit);
    _instanceLock = claimed.lock; // hold for the process lifetime
    return claimed.instance;
  }

  /// Config-root directory NAME for [instance] — instance 1 keeps the bare
  /// [base] (single-launch unchanged); N > 1 gets `<base>-N`.
  @visibleForTesting
  static String instanceConfigRootName(String base, int instance) =>
      instance <= 1 ? base : '$base-$instance';

  /// Per-instance main-port band stride. 100 (not 1) so an instance's
  /// per-domain server sweep (`defaultPort + 1` upward, `DomainServerManager`)
  /// stays inside its own band instead of colliding with the next instance's
  /// main port.
  @visibleForTesting
  static const int kInstancePortStride = 100;

  /// Main-port offset for [instance] — `defaultPort + offset` is the instance's
  /// port. Instance 1 = 0 (default port unchanged); N > 1 = `(N-1) * stride`.
  @visibleForTesting
  static int instancePortOffset(int instance) =>
      instance <= 1 ? 0 : (instance - 1) * kInstancePortStride;

  /// Claim an instance slot under [lockDir] via a cross-platform advisory lock.
  /// [explicit] is honoured as-is (best-effort lock); otherwise the first FREE
  /// slot (1, 2, …) is chosen. Returns the slot number and the OPEN lock handle
  /// — the caller MUST hold the handle for the process lifetime (never close
  /// it) so the slot stays claimed; the OS releases it on exit. `lock` is null
  /// when [lockDir] is unusable or (implausibly) every slot is busy.
  @visibleForTesting
  static ({int instance, RandomAccessFile? lock}) claimInstanceSlot(
    Directory lockDir,
    int? explicit,
  ) {
    try {
      lockDir.createSync(recursive: true);
    } catch (_) {
      return (
        instance: (explicit != null && explicit >= 1) ? explicit : 1,
        lock: null,
      );
    }

    ({int instance, RandomAccessFile? lock})? claim(int n) {
      final f = File(p.join(lockDir.path, 'instance-$n.lock'));
      RandomAccessFile raf;
      try {
        raf = f.openSync(mode: FileMode.write);
      } catch (_) {
        // On Windows a live holder can deny the open outright — treat as busy.
        return null;
      }
      try {
        // Non-blocking exclusive lock: throws if another live instance holds
        // it. Do NOT close on success — the open handle keeps the slot.
        raf.lockSync(FileLock.exclusive);
        return (instance: n, lock: raf);
      } on FileSystemException {
        raf.closeSync();
        return null;
      }
    }

    if (explicit != null && explicit >= 1) {
      // Honour the explicit number regardless; keep the lock if we got it.
      return (instance: explicit, lock: claim(explicit)?.lock);
    }
    for (var n = 1; n <= 99; n++) {
      final c = claim(n);
      if (c != null) return c;
    }
    return (instance: 1, lock: null); // all busy (implausible) — proceed
  }
}

/// Top-level Flutter widget every domain shell mounts inside. Frames
/// `MaterialApp` + theme (light/dark/system) + `Scaffold` and dispatches
/// the [ShellBlueprint] returned by [StudioApp.buildShell]. Stateful so
/// the Studio Settings dialog (which mutates `settings.themeMode`) can
/// flip the chrome brightness without an app restart.
class StudioFrame extends StatefulWidget {
  const StudioFrame({
    super.key,
    required this.app,
    required this.backbone,
    required this.bundles,
    required this.server,
    required this.llm,
    required this.chat,
    required this.settings,
    required this.transport,
    required this.port,
  });

  final StudioApp app;
  final dynamic backbone;
  final BundleInstallSurface bundles;
  final Object server;
  final Object llm;
  final VibeChatController chat;
  final VibeSettings settings;
  final String transport;
  final int port;

  @override
  State<StudioFrame> createState() => _StudioFrameState();
}

class _StudioFrameState extends State<StudioFrame> {
  late VibeSettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.settings;
  }

  void updateSettings(VibeSettings updated) {
    if (!mounted) return;
    setState(() => _settings = updated);
  }

  @override
  Widget build(BuildContext context) {
    return _StudioFrameScope(
      state: this,
      child: MaterialApp(
        // The shell's Navigator, so a document that brings no app of its own
        // still has somewhere to put a dialog (see studio_navigator.dart).
        navigatorKey: studioRootNavigatorKey,
        // No DEBUG ribbon — the studio ships its own chrome; the banner is
        // just noise even in debug builds.
        debugShowCheckedModeBanner: false,
        title: widget.app.displayName,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        // Settings-driven chrome brightness — `'system'` follows OS,
        // `'light'` / `'dark'` pin the shell to that mode. Defaults to
        // system so first-run honours the user's OS preference. State-
        // backed so a Settings dialog save flips theme without restart.
        themeMode: switch (_settings.themeMode) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        },
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              final blueprint = widget.app.buildShell(
                context: ctx,
                backbone: widget.backbone,
                chat: widget.chat,
                llm: widget.llm,
                server: widget.server,
                bundles: widget.bundles,
                settings: _settings,
                transport: widget.transport,
                port: widget.port,
              );
              switch (blueprint) {
                case WidgetShellBlueprint():
                  return Builder(builder: blueprint.builder);
                case DslShellBlueprint():
                  // Round B will mount vibe_studio_runtime here. Until
                  // then, a placeholder so DSL-shaped builders fail soft.
                  return const _DslShellPlaceholder();
              }
            },
          ),
        ),
      ),
    );
  }
}

/// InheritedWidget that exposes the live [_StudioFrameState] to any
/// descendant. Chrome's Settings save handler looks this up via
/// [StudioFrameScope.of] and calls `updateSettings(updated)` so the
/// shell's `themeMode` flips light/dark without an app restart.
class _StudioFrameScope extends InheritedWidget {
  const _StudioFrameScope({required this.state, required super.child});
  final _StudioFrameState state;

  @override
  bool updateShouldNotify(_StudioFrameScope old) => state != old.state;
}

/// Public scope handle — descendants call
/// `StudioFrameScope.of(context).updateSettings(updated)` from a
/// Settings dialog save callback to flip the shell theme.
class StudioFrameScope {
  StudioFrameScope._(this._state);
  final _StudioFrameState _state;

  /// Push a freshly saved [VibeSettings] into the live shell. Triggers
  /// a `setState` so the surrounding MaterialApp rebuilds with the new
  /// [VibeSettings.themeMode].
  void updateSettings(VibeSettings updated) => _state.updateSettings(updated);

  static StudioFrameScope? maybeOf(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_StudioFrameScope>();
    return scope == null ? null : StudioFrameScope._(scope.state);
  }
}

class _DslShellPlaceholder extends StatelessWidget {
  const _DslShellPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'DSL shell pending vibe_studio_runtime (Round B).',
        style: TextStyle(fontFamily: 'monospace'),
      ),
    );
  }
}
