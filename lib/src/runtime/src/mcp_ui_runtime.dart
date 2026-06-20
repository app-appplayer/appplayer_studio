/// MCP UI Runtime - Core runtime implementation
///
/// ## Navigation System Overview
///
/// The runtime supports two navigation paradigms that work together:
///
/// ### 1. Route-based Navigation (Traditional Flutter)
/// - Used when navigationDefinition is null
/// - Creates MaterialApp with named routes
/// - Navigation actions use route names directly
/// - Works with standard Flutter Navigator
///
/// ### 2. Index-based Navigation (ApplicationShell)
/// - Used when navigationDefinition exists (drawer/tabs/bottom)
/// - Creates MaterialApp with home widget (ApplicationShell)
/// - Navigation is managed by index internally
/// - Navigation actions are converted from routes to indices
///
/// ### How Navigation Actions Work
///
/// When a button triggers a navigation action:
/// 1. NavigationActionExecutor receives the action
/// 2. It checks for navigation handlers in order:
///    - Context handler (highest priority)
///    - Renderer handler
///    - Global handler (set by ApplicationShell)
/// 3. ApplicationShell's handler converts route to index
/// 4. The UI updates to show the new page
///
/// This design allows navigation actions to work consistently
/// regardless of the navigation type (drawer/tabs/bottom/routes).
library mcp_ui_runtime;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'optimization/widget_cache.dart';
import 'runtime/runtime_engine.dart';
import 'utils/icon_resolver.dart';
import 'widgets/widget_factory.dart';
import 'actions/action_handler.dart';
import 'state/state_manager.dart';
import 'renderer/render_context.dart';
import 'renderer/renderer.dart' show RenderInspector;
import 'routing/page_state_scope.dart';
import 'theme/theme_manager.dart';
import 'utils/mcp_logger.dart';
import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart' as core
    show
        ApplicationDefinition,
        DashboardConfig,
        PageDefinition,
        validateMcpUiDslWidget;
import 'models/ui_definition.dart';
import 'models/app_metadata.dart';
import 'services/navigation_service.dart';
import 'binding/binding_engine.dart';
import 'channels/channel_manager.dart';
import 'permissions/permission_manager.dart';
import 'permissions/trust_level.dart';
import 'form_factor/form_factor.dart';

/// Wraps [child] with a [FormFactorScope] derived from the current window
/// width via [MediaQuery]. The scope makes [FormFactor.of] (and the
/// `AppSpacing` / `AppTypography` / `AppIconSizes` / `AppDensity` token
/// accessors that depend on it) resolve correctly throughout the tree —
/// without it the responsive token sets fall back to compact-mobile
/// values regardless of actual window size.
Widget _withFormFactor(BuildContext context, Widget child) {
  final width = MediaQuery.of(context).size.width;
  final ff = FormFactor.fromWidth(width);
  return FormFactorScope(formFactor: ff, child: child);
}

/// Main MCP UI Runtime class that provides the entry point for using the runtime
class MCPUIRuntime {
  MCPUIRuntime({
    this.enableDebugMode = kDebugMode,
  })  : _logger = MCPLogger('MCPUIRuntime', enableLogging: enableDebugMode),
        _engine = RuntimeEngine(enableDebugMode: enableDebugMode);

  /// Inspector entry point for editor tooling. Each rendered widget is
  /// paired with its source JSON node via [widgetWrapper] so the host can
  /// hit-test back from the rendered tree to the canonical document. The
  /// production `MCPUIRuntime()` constructor never sees this hook — the
  /// renderer's fast path is unchanged when no wrapper is supplied.
  MCPUIRuntime.withInspector({
    required RenderInspector widgetWrapper,
    this.enableDebugMode = kDebugMode,
  })  : _logger = MCPLogger('MCPUIRuntime', enableLogging: enableDebugMode),
        _engine = RuntimeEngine(
          enableDebugMode: enableDebugMode,
          widgetWrapper: widgetWrapper,
        );

  final bool enableDebugMode;
  final MCPLogger _logger;

  /// Engine is eagerly initialized in constructor so managers are always accessible
  final RuntimeEngine _engine;
  bool _isInitialized = false;

  /// Gets the runtime engine instance (always non-null, initialized in constructor)
  RuntimeEngine get engine => _engine;

  /// Gets whether the runtime is initialized
  bool get isInitialized => _isInitialized;

  /// Whether engine is ready for rendering
  bool get isReady => _engine.isReady;

  /// Gets the state manager (accessible before initialize, returns uninitialized manager)
  StateManager get stateManager => _engine.stateManager;

  /// Gets the theme manager (accessible before initialize, returns uninitialized manager)
  ThemeManager get themeManager => _engine.themeManager;

  /// Observable application metadata (spec §11). `value` is null before
  /// `initialize` completes or when the DSL is a standalone page.
  /// Listeners fire when the cache is replaced — for example after a
  /// `ui://app/info` resource-update notification.
  ValueListenable<DslAppMetadata?> get appMetadata => _engine.appMetadata;

  /// Gets the UI definition
  Map<String, dynamic>? getUIDefinition() {
    return _engine.uiDefinition;
  }

  /// Renders the UI widget
  Widget render() {
    return buildUI();
  }

  /// Initializes the runtime with the provided definition.
  ///
  /// [validateSchema] runs the generated widget-registry JSON Schema over
  /// the DSL before wiring up services. **On by default** — the schema is
  /// now complete enough (see `specs/mcp_ui_dsl/schema/widgets.schema.json`
  /// and `widgets_schema.g.dart`) that every spec-conformant DSL passes,
  /// and violations throw [StateError] with precise JSON paths. Pass
  /// `validateSchema: false` to opt out — primarily for negative-path tests
  /// that deliberately feed invalid DSL to exercise fallback behaviour.
  ///
  /// Additional enforcement channels outside the runtime:
  ///
  /// 1. `dart run tools/spec_codegen/bin/validate_bundle.dart <paths>` —
  ///    author-side linter for JSON bundles.
  /// 2. `dart run tools/spec_codegen/bin/conformance.dart` — CI gate that
  ///    verifies spec ↔ factory drift is zero.
  Future<void> initialize(
    Map<String, dynamic> definition, {
    Function(String)? pageLoader,
    bool useCache = true,
    bool validateSchema = true,
  }) async {
    if (_isInitialized) {
      throw StateError('MCP UI Runtime is already initialized');
    }

    if (validateSchema) {
      final issues = _collectSchemaIssues(definition);
      if (issues.isNotEmpty) {
        final summary = issues.take(5).join('\n  ');
        throw StateError(
          'MCP UI DSL schema validation failed '
          '(${issues.length} error(s)):\n  $summary',
        );
      }
    }

    await _engine.initialize(
      definition: definition,
      pageLoader: pageLoader,
      useCache: useCache,
    );
    _isInitialized = true;

    // Apply a trust level that the host set before `initialize` ran.
    final pendingTrust = _pendingTrustLevel;
    if (pendingTrust != null) {
      final pm = _engine.actionHandler.permissionManager;
      if (pm != null) {
        pm.trustLevel = pendingTrust;
        _pendingTrustLevel = null;
      }
    }

    _logger.info('Initialized successfully');
  }

  /// Walks the loaded definition and validates every widget subtree against
  /// the generated registry schema. Returns a flat list of error strings
  /// suitable for surfacing to DSL authors.
  List<String> _collectSchemaIssues(Map<String, dynamic> definition) {
    final issues = <String>[];

    void validateNode(Object? node, String where) {
      if (node is Map<String, dynamic>) {
        final result = core.validateMcpUiDslWidget(node);
        if (!result.isValid) {
          for (final e in result.errors) {
            issues.add('$where ${e.path}: ${e.message}');
          }
        }
      }
    }

    // PageDefinition: `content` is the widget tree.
    final content = definition['content'];
    if (content is Map<String, dynamic>) validateNode(content, 'content');

    // ApplicationDefinition: `dashboard.content` + route targets.
    final dashboard = definition['dashboard'];
    if (dashboard is Map<String, dynamic>) {
      final dc = dashboard['content'];
      if (dc is Map<String, dynamic>) validateNode(dc, 'dashboard.content');
    }
    return issues;
  }

  /// Initialize runtime from a strongly-typed ApplicationDefinition
  /// Converts to JSON internally for backward compatibility with the existing pipeline.
  Future<void> initializeFromDefinition(
    core.ApplicationDefinition definition, {
    Function(String)? pageLoader,
    bool useCache = true,
  }) async {
    await initialize(
      definition.toJson(),
      pageLoader: pageLoader,
      useCache: useCache,
    );
  }

  /// Initialize runtime from a strongly-typed PageDefinition
  Future<void> initializeFromPageDefinition(
    core.PageDefinition definition, {
    Function(String)? pageLoader,
    bool useCache = true,
  }) async {
    await initialize(
      definition.toJson(),
      pageLoader: pageLoader,
      useCache: useCache,
    );
  }

  /// Builds the UI widget from the runtime configuration
  Widget buildUI({
    BuildContext? context,
    Map<String, dynamic>? initialState,
    Function(String, Map<String, dynamic>)? onToolCall,
    Function(String, String)? onResourceSubscribe,
    Function(String)? onResourceUnsubscribe,
    VoidCallback? onExit,
    ValueListenable<Brightness>? hostBrightness,
  }) {
    if (!_isInitialized) {
      throw StateError('MCP UI Runtime must be initialized before building UI');
    }

    final uiDefinition = _engine.uiDefinition;
    if (uiDefinition == null) {
      throw StateError('No UI definition found in runtime configuration');
    }

    return MCPRuntimeWidget(
      engine: _engine,
      uiDefinition: uiDefinition,
      initialState: initialState,
      onToolCall: onToolCall,
      onResourceSubscribe: onResourceSubscribe,
      onResourceUnsubscribe: onResourceUnsubscribe,
      onExit: onExit,
      hostBrightness: hostBrightness,
    );
  }

  /// Spec §11.9 dashboard rendering entry point.
  ///
  /// Returns a widget that hosts the `dashboard.content` tree when the
  /// initialised DSL declares a `dashboard` block; returns `null` when no
  /// dashboard view is provided (embedders should fall back to a card
  /// built from [appMetadata]'s icon / title per §11.9.1).
  ///
  /// `content` is rendered with the same binding / action / theme context
  /// as full render mode — templates (§9), app state, channel payloads
  /// and resource bindings all resolve normally (§11.9.4). When the DSL
  /// specifies `refreshInterval`, the widget periodically invalidates
  /// bindings to force re-evaluation.
  Widget? buildDashboard({
    BuildContext? context,
    Function(String, Map<String, dynamic>)? onToolCall,
    Function(String, String)? onResourceSubscribe,
    Function(String)? onResourceUnsubscribe,
    VoidCallback? onExit,
    void Function(String? appId, String? route)? onOpenApp,
    ValueListenable<Brightness>? hostBrightness,
  }) {
    if (!_isInitialized) {
      throw StateError('MCP UI Runtime must be initialized before building UI');
    }
    final appDef = _engine.applicationDefinition;
    final dashboard = appDef?.dashboard;
    if (dashboard == null) return null;
    return _DashboardHost(
      engine: _engine,
      dashboard: dashboard,
      onToolCall: onToolCall,
      onResourceSubscribe: onResourceSubscribe,
      onResourceUnsubscribe: onResourceUnsubscribe,
      onExit: onExit,
      onOpenApp: onOpenApp,
      hostBrightness: hostBrightness,
    );
  }

  /// Returns true when the initialised DSL provides a `dashboard` block
  /// (§11.9). Host embedders use this to decide between rendering
  /// [buildDashboard] and the icon-only fallback tile.
  bool get hasDashboard => _engine.applicationDefinition?.dashboard != null;

  /// Handles MCP notification
  Future<void> handleNotification(
    Map<String, dynamic> notification, {
    Function(String)? resourceReader,
  }) async {
    if (!_isInitialized) {
      _logger.warning('Cannot handle notification - runtime not initialized');
      return;
    }

    _logger.debug('Handling notification: $notification');

    // Check notification method
    final method = notification['method'] as String?;
    final params = notification['params'] as Map<String, dynamic>?;

    if (method == 'notifications/resources/updated' && params != null) {
      // Handle resource update notification
      await _engine
          .handleMCPNotification(params, resourceReader: resourceReader);
    } else {
      _logger.debug('Ignoring notification with method: $method');
    }
  }

  /// Register resource subscription for tracking
  void registerResourceSubscription(String uri, String binding) {
    if (!_isInitialized) {
      throw StateError('Runtime must be initialized');
    }
    _engine.registerResourceSubscription(uri, binding);
  }

  /// Unregister resource subscription
  void unregisterResourceSubscription(String uri) {
    if (!_isInitialized) {
      throw StateError('Runtime must be initialized');
    }
    _engine.unregisterResourceSubscription(uri);
  }

  /// Get binding for a URI
  String? getBindingForUri(String uri) {
    if (!_isInitialized) {
      return null;
    }
    return _engine.getBindingForUri(uri);
  }

  /// Update state directly (for manual state updates)
  void updateState(String binding, dynamic value) {
    if (!_isInitialized) {
      throw StateError('Runtime must be initialized');
    }
    _engine.stateManager.set(binding, value);
  }

  /// Handle error
  void handleError(String error) {
    _logger.error(error);
  }

  /// Register a tool executor function
  void registerToolExecutor(String toolName, Function executor) {
    if (!_isInitialized) {
      throw StateError(
          'Runtime must be initialized before registering tool executors');
    }
    _engine.actionHandler.registerToolExecutor(toolName, executor);
  }

  /// Register a custom widget factory
  void registerWidget(String type, WidgetFactory factory) {
    if (!_isInitialized) {
      throw StateError(
          'Runtime must be initialized before registering widgets');
    }
    _engine.widgetRegistry.register(type, factory);
  }

  /// Register a custom action handler
  void registerAction(String type, ActionExecutor executor) {
    if (!_isInitialized) {
      throw StateError(
          'Runtime must be initialized before registering actions');
    }
    _engine.actionHandler.registerExecutor(type, executor);
  }

  /// Register navigation handler with 3-parameter callback returning bool (v1.1)
  void registerNavigationHandler(
    bool Function(String action, String route, Map<String, dynamic> params)
        handler,
  ) {
    if (!_isInitialized) {
      throw StateError(
          'Runtime must be initialized before registering navigation handler');
    }
    _engine.actionHandler.registerNavigationHandler(handler);
  }

  /// Register permission handler for custom permission prompts (v1.1)
  void registerPermissionHandler(Function handler) {
    if (!_isInitialized) {
      throw StateError(
          'Runtime must be initialized before registering permission handler');
    }
    _engine.permissionHandler = handler;
  }

  /// Register client action handler for custom client action execution (v1.1)
  /// [actionType] specifies the action type for precise dispatch (e.g. 'client')
  void registerClientActionHandler(String actionType, Function handler) {
    if (!_isInitialized) {
      throw StateError(
          'Runtime must be initialized before registering client action handler');
    }
    _engine.actionHandler.registerToolExecutor(actionType, handler);
  }

  /// Gets the permission manager (v1.1)
  PermissionManager? get permissionManager {
    if (!_isInitialized) {
      return null;
    }
    return _engine.actionHandler.permissionManager;
  }

  /// Sets the trust level that governs which client actions the runtime
  /// will even consider attempting (v1.1). The host grants a trust
  /// level per app; the runtime's `PermissionManager` then refuses any
  /// action whose required level exceeds the grant, before checking
  /// the DSL's declared `permissions` config.
  ///
  /// Mapping: `basic` → system info / notification / clipboard-read;
  /// `elevated` → also file-read / HTTP / clipboard-write; `full` →
  /// also file-write / shell exec. `untrusted` blocks everything.
  ///
  /// Safe to call before or after `initialize`. No-op if the action
  /// handler is not yet wired (calls after `initialize` are reliable).
  void setTrustLevel(TrustLevel level) {
    if (!_isInitialized) {
      _pendingTrustLevel = level;
      return;
    }
    final pm = _engine.actionHandler.permissionManager;
    if (pm != null) {
      pm.trustLevel = level;
    } else {
      _pendingTrustLevel = level;
    }
  }

  TrustLevel? _pendingTrustLevel;

  /// Gets the channel manager (v1.1)
  ChannelManager? get channelManager {
    if (!_isInitialized) {
      return null;
    }
    return _engine.channelManager;
  }

  /// Dispose runtime resources (alias for destroy for spec compliance)
  Future<void> dispose() async {
    await destroy();
  }

  /// Destroys the runtime and cleans up resources
  Future<void> destroy() async {
    if (!_isInitialized) return;

    await _engine.destroy();
    _isInitialized = false;

    // Clear global navigation handler to prevent state leaking between instances
    NavigationActionExecutor.clearGlobalNavigationHandler();

    // Reset NavigationService singleton state
    await NavigationService.instance.onDispose();

    // Reset theme manager singleton
    ThemeManager.instance.reset();

    // Clear BindingEngine static caches
    BindingEngine.clearStaticCaches();

    // Clear singleton WidgetCache so cached widget instances from this
    // session do not leak their event-handler closures (which still
    // capture the destroyed engine's RenderContext / StateManager) into
    // the next session.
    WidgetCache.instance.clear();

    _logger.info('Destroyed');
  }
}

/// Widget that renders the MCP UI using the runtime engine
class MCPRuntimeWidget extends StatefulWidget {
  const MCPRuntimeWidget({
    super.key,
    required this.engine,
    required this.uiDefinition,
    this.initialState,
    this.onToolCall,
    this.onResourceSubscribe,
    this.onResourceUnsubscribe,
    this.onExit,
    this.hostBrightness,
  });

  final RuntimeEngine engine;
  final Map<String, dynamic> uiDefinition;
  final Map<String, dynamic>? initialState;
  final Function(String, Map<String, dynamic>)? onToolCall;
  final Function(String, String)? onResourceSubscribe;
  final Function(String)? onResourceUnsubscribe;

  /// Host callback invoked when exitApp navigation action is triggered
  /// or when the app title is tapped.
  final VoidCallback? onExit;

  /// Host-provided brightness feed that resolves `mode: 'system'`
  /// against the embedder's theme choice rather than the OS directly.
  /// When null, `mode: 'system'` falls back to platform brightness.
  /// Declared `mode: 'light'` / `mode: 'dark'` on the DSL are unaffected.
  final ValueListenable<Brightness>? hostBrightness;

  @override
  State<MCPRuntimeWidget> createState() => _MCPRuntimeWidgetState();
}

class _MCPRuntimeWidgetState extends State<MCPRuntimeWidget>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();

    // Add lifecycle observer
    WidgetsBinding.instance.addObserver(this);

    // Register onToolCall callback if provided
    if (widget.onToolCall != null) {
      widget.engine.actionHandler
          .registerToolExecutor('default', widget.onToolCall!);
    }

    // Register resource handlers if provided
    widget.engine.setResourceHandlers(
      onResourceSubscribe: widget.onResourceSubscribe,
      onResourceUnsubscribe: widget.onResourceUnsubscribe,
    );

    // Wire host brightness injection (spec §5.2 — embedder-driven
    // system mode resolution).
    if (widget.hostBrightness != null) {
      widget.hostBrightness!.addListener(_applyHostBrightness);
      _applyHostBrightness();
    }

    // Register onExit callback for exitApp navigation action and title tap
    if (widget.onExit != null) {
      NavigationActionExecutor.setOnExitCallback(widget.onExit!);
    }

    // Initialize state if provided
    if (widget.initialState != null) {
      widget.engine.stateManager.setState(widget.initialState!);
    }

    // Mark runtime as ready
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.engine.markReady();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.hostBrightness?.removeListener(_applyHostBrightness);
    widget.engine.themeManager.setHostBrightness(null);
    super.dispose();
  }

  void _applyHostBrightness() {
    final value = widget.hostBrightness?.value;
    widget.engine.themeManager.setHostBrightness(value);
  }

  @override
  void didUpdateWidget(covariant MCPRuntimeWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hostBrightness != widget.hostBrightness) {
      oldWidget.hostBrightness?.removeListener(_applyHostBrightness);
      if (widget.hostBrightness != null) {
        widget.hostBrightness!.addListener(_applyHostBrightness);
        _applyHostBrightness();
      } else {
        widget.engine.themeManager.setHostBrightness(null);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
        widget.engine.pause();
        break;
      case AppLifecycleState.resumed:
        widget.engine.resume();
        break;
      case AppLifecycleState.detached:
        widget.engine.destroy();
        break;
      default:
        break;
    }
  }

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    // Spec §5.2 — in `system` mode the runtime MUST switch scheme without
    // requiring a shell re-render. Forward the platform event so the
    // ThemeManager re-resolves and notifies its listeners.
    widget.engine.themeManager.notifyBrightnessChanged();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.engine,
      builder: (context, child) {
        if (!widget.engine.isReady) {
          return const Center(
            child: CircularProgressIndicator(),
          );
        }

        // Inject host environment theme for client.theme.* bindings.
        // Theme.of(context) here captures the embedding app's theme,
        // before the runtime creates its own MaterialApp.
        final hostTheme = Theme.of(context);
        widget.engine.bindingEngine.clientBindingResolver
            .setHostTheme(hostTheme);

        try {
          // Check if this is an application type
          if (widget.engine.isApplication &&
              widget.engine.routeManager != null) {
            // Build application with routing and navigation
            final appDefinition = widget.engine.applicationDefinition!;

            if (widget.engine.enableDebugMode) {
              MCPLogger('MCPRuntimeWidget').debug(
                  'Building application with navigation: ${appDefinition.navigationDefinition?.type}');
            }

            if (appDefinition.navigationDefinition != null) {
              // Build with navigation wrapper
              final navKey = NavigationService.instance.navigatorKey;
              MCPLogger('MCPRuntimeWidget').debug(
                  'Creating MaterialApp with navigatorKey for ApplicationShell: $navKey');

              return MaterialApp(
                navigatorKey:
                    navKey, // Essential for dialogs and navigation to work
                title: appDefinition.title,
                theme: widget.engine.themeManager.toFlutterTheme(),
                darkTheme:
                    widget.engine.themeManager.toFlutterTheme(isDark: true),
                themeMode: widget.engine.themeManager.flutterThemeMode,
                debugShowCheckedModeBanner: false,
                builder: (ctx, child) =>
                    _withFormFactor(ctx, child ?? const SizedBox.shrink()),
                home: _ApplicationShell(
                  engine: widget.engine,
                  appDefinition: appDefinition,
                  onToolCall: widget.onToolCall,
                  onResourceSubscribe: widget.onResourceSubscribe,
                  onResourceUnsubscribe: widget.onResourceUnsubscribe,
                ),
              );
            } else {
              // Build simple routing without navigation wrapper
              final navKey = NavigationService.instance.navigatorKey;
              MCPLogger('MCPRuntimeWidget').debug(
                  'Creating MaterialApp with navigatorKey for routing: $navKey');

              return MaterialApp(
                navigatorKey:
                    navKey, // Essential for dialogs and navigation to work
                title: appDefinition.title,
                theme: widget.engine.themeManager.toFlutterTheme(),
                darkTheme:
                    widget.engine.themeManager.toFlutterTheme(isDark: true),
                themeMode: widget.engine.themeManager.flutterThemeMode,
                debugShowCheckedModeBanner: false,
                builder: (ctx, child) =>
                    _withFormFactor(ctx, child ?? const SizedBox.shrink()),
                initialRoute: widget.engine.routeManager!.initialRoute,
                routes: widget.engine.routeManager!.generateRoutes(context),
              );
            }
          } else {
            // Render single page UI
            // Check if UI definition has appBar and body at top level
            final hasAppBar = widget.uiDefinition.containsKey('appBar');
            final hasBody = widget.uiDefinition.containsKey('body');

            if (hasAppBar || hasBody) {
              // Auto-create scaffold for platform-independent UI definitions
              final renderContext = _createRenderContext();
              return Scaffold(
                appBar: hasAppBar
                    ? widget.engine.renderer.renderWidget(
                        widget.uiDefinition['appBar'], renderContext) as AppBar?
                    : null,
                body: hasBody
                    ? widget.engine.renderer.renderWidget(
                        widget.uiDefinition['body'], renderContext)
                    : Container(),
              );
            } else {
              // Use modern renderer for page content
              if (widget.engine.parsedUIDefinition?.type ==
                  UIDefinitionType.page) {
                return widget.engine.renderer
                    .renderPage(widget.engine.parsedUIDefinition!.toJson());
              } else {
                // Render as widget using modern renderer
                return widget.engine.renderer
                    .renderWidget(widget.uiDefinition, _createRenderContext());
              }
            }
          }
        } catch (error) {
          if (widget.engine.enableDebugMode) {
            MCPLogger('MCPRuntimeWidget').error('Error rendering UI', error);
          }

          return ErrorWidget(error);
        }
      },
    );
  }

  /// Creates a render context for the modern renderer
  RenderContext _createRenderContext() {
    return RenderContext(
      renderer: widget.engine.renderer,
      stateManager: widget.engine.stateManager,
      bindingEngine: widget.engine.bindingEngine,
      actionHandler: widget.engine.actionHandler,
      themeManager: ThemeManager(), // Create a basic theme manager
      buildContext: context,
      engine: widget.engine,
    );
  }

  /// Creates a render context for the modern renderer
}

/// Application shell widget that handles navigation
///
/// This widget manages navigation for applications with drawer, tabs, or bottom navigation.
/// It bridges two navigation systems:
///
/// 1. **Index-based navigation**: Used internally by drawer/tabs/bottom navigation
///    - Tracks current page by index (_currentIndex)
///    - Updates UI by changing the displayed page widget
///
/// 2. **Route-based navigation**: Used by navigation actions from buttons
///    - Uses route names (e.g., '/home', '/settings')
///    - Handled through NavigationActionExecutor
///
/// The bridge works as follows:
/// - When the app starts, a navigation handler is registered
/// - This handler intercepts route-based navigation actions
/// - It converts route names to indices and updates _currentIndex
/// - The UI rebuilds to show the new page
///
/// This allows buttons with navigation actions to work seamlessly with
/// drawer/tab/bottom navigation, even though they use different systems.

class _ApplicationShell extends StatefulWidget {
  final RuntimeEngine engine;
  final ApplicationDefinition appDefinition;
  final Function(String, Map<String, dynamic>)? onToolCall;
  final Function(String, String)? onResourceSubscribe;
  final Function(String)? onResourceUnsubscribe;

  const _ApplicationShell({
    required this.engine,
    required this.appDefinition,
    this.onToolCall,
    this.onResourceSubscribe,
    this.onResourceUnsubscribe,
  });

  @override
  State<_ApplicationShell> createState() => _ApplicationShellState();
}

class _ApplicationShellState extends State<_ApplicationShell> {
  int _currentIndex = 0;
  final Map<String, PageDefinition> _pageDefinitionCache = {};

  /// Builds the host-inserted close button for the shell AppBar's `actions`
  /// slot per spec §2.8.1 / §4.3.2. Returns `null` when `onExit` is not
  /// registered. Shell AppBar is always on the root route, so the route-level
  /// check is implicit here.
  List<Widget>? _shellAppBarActions() {
    if (!NavigationActionExecutor.hasOnExit) return null;
    return <Widget>[
      IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Close',
        onPressed: NavigationActionExecutor.invokeOnExit,
      ),
    ];
  }

  @override
  void initState() {
    super.initState();

    // Find initial route index based on the application's initial route
    if (widget.appDefinition.navigationDefinition != null) {
      final initialRoute = widget.appDefinition.initialRoute;
      final index = widget.appDefinition.navigationDefinition!.items
          .indexWhere((item) => item.route == initialRoute);
      if (index >= 0) {
        _currentIndex = index;
      }
    }

    // Check if there's a saved navigation state in StateManager
    final savedIndex = widget.engine.stateManager.get<int>('runtime.navigation.currentIndex');
    if (savedIndex != null && 
        widget.appDefinition.navigationDefinition != null &&
        savedIndex >= 0 && 
        savedIndex < widget.appDefinition.navigationDefinition!.items.length) {
      _currentIndex = savedIndex;
    }

    // Defer navigation state update to avoid setState during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Save initial navigation state to StateManager
      _updateNavigationState(_currentIndex);
    });

    // Register a navigation handler that converts route-based navigation to index-based
    // This allows navigation actions from buttons to work with the ApplicationShell's
    // index-based navigation system
    _registerNavigationHandler();
  }

  /// Update navigation state in StateManager
  void _updateNavigationState(int index) {
    if (widget.appDefinition.navigationDefinition != null &&
        index >= 0 &&
        index < widget.appDefinition.navigationDefinition!.items.length) {
      // Save current index
      widget.engine.stateManager.set('runtime.navigation.currentIndex', index);
      
      // Save current route
      final currentRoute = widget.appDefinition.navigationDefinition!.items[index].route;
      widget.engine.stateManager.set('runtime.navigation.currentRoute', currentRoute);
    }
  }

  Future<PageDefinition> _loadPageDefinition(String route) async {
    // Check cache first
    if (_pageDefinitionCache.containsKey(route)) {
      return _pageDefinitionCache[route]!;
    }

    try {
      // Get page URI from route
      final pageUri = widget.appDefinition.routes[route];
      if (pageUri == null) {
        throw Exception('No page URI found for route: $route');
      }

      // Load page definition
      final pageJson = await widget.engine.routeManager!.pageLoader(pageUri);
      final uiDef = UIDefinition.fromJson(pageJson as Map<String, dynamic>);
      final pageDefinition = PageDefinition.fromUIDefinition(uiDef);

      // Cache the page definition only
      _pageDefinitionCache[route] = pageDefinition;

      return pageDefinition;
    } catch (e) {
      throw Exception('Error loading page: $e');
    }
  }

  /// Registers a navigation handler that bridges route-based navigation actions
  /// with the ApplicationShell's index-based navigation system
  void _registerNavigationHandler() {
    // Create a navigation handler that converts routes to indices
    bool navigationHandler(
        String action, String route, Map<String, dynamic> params) {
      // Only handle navigation actions for this ApplicationShell
      if (action != 'push' && action != 'replace') {
        return false; // Let other handlers process this
      }

      // Find the index for the given route
      final navItems = widget.appDefinition.navigationDefinition?.items ?? [];
      final targetIndex = navItems.indexWhere((item) => item.route == route);

      if (targetIndex >= 0) {
        // Route found, update the current index to navigate
        if (mounted) {
          setState(() {
            _currentIndex = targetIndex;
          });
          // Update navigation state in StateManager
          _updateNavigationState(targetIndex);
        }
        return true; // Navigation handled successfully
      }

      // Route not found in navigation items
      return false;
    }

    // Register the handler with the action handler
    widget.engine.actionHandler.registerNavigationHandler(navigationHandler);
  }

  @override
  void dispose() {
    // Clean up page definition cache when disposing
    _pageDefinitionCache.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final navigation = widget.appDefinition.navigationDefinition;

    if (navigation == null) {
      // No navigation, just show the initial route
      return FutureBuilder<PageDefinition>(
        future: _loadPageDefinition(widget.appDefinition.initialRoute),
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            // Wrap in AnimatedBuilder to listen to StateManager changes
            return AnimatedBuilder(
              animation: widget.engine.stateManager,
              builder: (context, child) {
                return MCPPageWidget(
                  pageDefinition: snapshot.data!,
                  runtimeEngine: widget.engine,
                );
              },
            );
          } else if (snapshot.hasError) {
            return _buildErrorPage(snapshot.error);
          } else {
            return _buildLoadingPage();
          }
        },
      );
    }

    // Get current route
    final currentRoute = navigation.items[_currentIndex].route;

    switch (navigation.type) {
      case 'tabs':
        return DefaultTabController(
          length: navigation.items.length,
          initialIndex: _currentIndex,
          child: Builder(
            builder: (context) {
              final TabController? tabController = DefaultTabController.of(context);
              // Listen to tab changes
              tabController?.addListener(() {
                if (!tabController.indexIsChanging && 
                    tabController.index != _currentIndex) {
                  setState(() {
                    _currentIndex = tabController.index;
                  });
                  _updateNavigationState(tabController.index);
                }
              });
              
              return Scaffold(
                appBar: AppBar(
                  title: Text(widget.appDefinition.title),
                  actions: _shellAppBarActions(),
                  bottom: TabBar(
                    tabs: navigation.items
                        .map((item) => Tab(
                              text: item.title,
                              icon: item.icon != null
                                  ? Icon(_getIconData(item.icon!))
                                  : null,
                            ))
                        .toList(),
                  ),
                ),
            body: TabBarView(
              children: navigation.items.map((navItem) {
                final route = navItem.route;
                return FutureBuilder<PageDefinition>(
                  key: ValueKey(route),
                  future: _loadPageDefinition(route),
                  builder: (context, snapshot) {
                    if (snapshot.hasData) {
                      // Wrap in AnimatedBuilder to listen to StateManager changes
                      return AnimatedBuilder(
                        animation: widget.engine.stateManager,
                        builder: (context, child) {
                          return MCPPageWidget(
                            pageDefinition: snapshot.data!,
                            runtimeEngine: widget.engine,
                          );
                        },
                      );
                    } else if (snapshot.hasError) {
                      return _buildErrorPage(snapshot.error);
                    } else {
                      return _buildLoadingPage();
                    }
                  },
                );
              }).toList(),
            ),
              );
            },
          ),
        );

      case 'rail':
        // Spec § 1.2.1 NavigationConfig.type: rail — vertical rail
        // beside the body. Author's declared type, not adaptive.
        //
        // Hit-area parity: Material's NavigationRail wraps each
        // destination in an indicator-pill InkResponse that swallows
        // hits over the entire tile but only fires when the tap
        // lands on the icon column — taps on the label region read
        // as no-op. Drawer (ListTile), bottomBar
        // (BottomNavigationBarItem), and tabs (Tab) accept taps on
        // icon AND label, so rail must too. We render a custom
        // Column of InkWell tiles instead of `NavigationRail` so
        // each tile's full bounds (icon + label + padding) is one
        // single tap target.
        final railSelected = _currentIndex
            .clamp(0, navigation.items.length - 1)
            .toInt();
        void selectRail(int index) {
          setState(() => _currentIndex = index);
          _updateNavigationState(index);
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(widget.appDefinition.title),
            actions: _shellAppBarActions(),
          ),
          body: Row(
            children: [
              _CustomRail(
                selectedIndex: railSelected,
                onSelect: selectRail,
                items: navigation.items
                    .map((item) => _CustomRailItem(
                          icon: _getIconData(item.icon ?? 'home'),
                          label: item.title,
                        ))
                    .toList(),
              ),
              const VerticalDivider(thickness: 1, width: 1),
              Expanded(
                child: FutureBuilder<PageDefinition>(
                  key: ValueKey(currentRoute),
                  future: _loadPageDefinition(currentRoute),
                  builder: (context, snapshot) {
                    if (snapshot.hasData) {
                      return AnimatedBuilder(
                        animation: widget.engine.stateManager,
                        builder: (context, child) => MCPPageWidget(
                          pageDefinition: snapshot.data!,
                          runtimeEngine: widget.engine,
                        ),
                      );
                    } else if (snapshot.hasError) {
                      return _buildErrorPage(snapshot.error);
                    }
                    return _buildLoadingPage();
                  },
                ),
              ),
            ],
          ),
        );

      case 'bottomBar':
      // Legacy aliases — canonical per spec § 1.2.1 is `bottomBar`.
      case 'bottomNavigation':
      case 'bottom':
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.appDefinition.title),
            actions: _shellAppBarActions(),
          ),
          body: FutureBuilder<PageDefinition>(
            key: ValueKey(currentRoute),
            future: _loadPageDefinition(currentRoute),
            builder: (context, snapshot) {
              if (snapshot.hasData) {
                // Wrap in AnimatedBuilder to listen to StateManager changes
                return AnimatedBuilder(
                  animation: widget.engine.stateManager,
                  builder: (context, child) {
                    return MCPPageWidget(
                      pageDefinition: snapshot.data!,
                      runtimeEngine: widget.engine,
                    );
                  },
                );
              } else if (snapshot.hasError) {
                return _buildErrorPage(snapshot.error);
              } else {
                return _buildLoadingPage();
              }
            },
          ),
          bottomNavigationBar: BottomNavigationBar(
            type: BottomNavigationBarType.fixed,
            currentIndex: _currentIndex,
            onTap: (index) {
              setState(() {
                _currentIndex = index;
              });
              // Update navigation state in StateManager
              _updateNavigationState(index);
            },
            items: navigation.items
                .map((item) => BottomNavigationBarItem(
                      icon: Icon(_getIconData(item.icon ?? 'home')),
                      label: item.title,
                    ))
                .toList(),
          ),
        );

      default:
        // Drawer navigation — render exactly what the bundle declares.
        // Adaptive form-factor switching (rail / permanent drawer) is
        // intentionally NOT performed here: per spec § 1.2 the author's
        // declared `navigation.type` is authoritative, and per-form-factor
        // variants are author-driven via ResponsiveValue (spec § 14.2).
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.appDefinition.title),
            actions: _shellAppBarActions(),
          ),
          drawer: Drawer(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                DrawerHeader(
                  decoration: BoxDecoration(
                    color: Theme.of(context).primaryColor,
                  ),
                  child: Text(
                    widget.appDefinition.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                    ),
                  ),
                ),
                ...navigation.items.asMap().entries.map((entry) {
                  final index = entry.key;
                  final item = entry.value;
                  return ListTile(
                    leading: item.icon != null
                        ? Icon(_getIconData(item.icon!))
                        : null,
                    title: Text(item.title),
                    selected: index == _currentIndex,
                    onTap: () {
                      setState(() {
                        _currentIndex = index;
                      });
                      // Update navigation state in StateManager
                      _updateNavigationState(index);
                      Navigator.pop(context);
                    },
                  );
                }),
              ],
            ),
          ),
          body: FutureBuilder<PageDefinition>(
            key: ValueKey(currentRoute),
            future: _loadPageDefinition(currentRoute),
            builder: (context, snapshot) {
              if (snapshot.hasData) {
                // Wrap in AnimatedBuilder to listen to StateManager changes
                return AnimatedBuilder(
                  animation: widget.engine.stateManager,
                  builder: (context, child) {
                    return MCPPageWidget(
                      pageDefinition: snapshot.data!,
                      runtimeEngine: widget.engine,
                    );
                  },
                );
              } else if (snapshot.hasError) {
                return _buildErrorPage(snapshot.error);
              } else {
                return _buildLoadingPage();
              }
            },
          ),
        );
    }
  }

  Widget _buildLoadingPage() {
    return const Center(
      child: CircularProgressIndicator(),
    );
  }

  Widget _buildErrorPage(dynamic error) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.error_outline,
            size: 64,
            color: Colors.red,
          ),
          const SizedBox(height: 16),
          const Text(
            'Failed to load page',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            error.toString(),
            style: const TextStyle(fontSize: 16),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  IconData _getIconData(String iconName) => resolveIconData(iconName);
}

/// Convenience functions for quick runtime usage
class MCPUIRuntimeHelper {
  /// Renders an MCP UI specification directly
  static Widget render(
    Map<String, dynamic> definition, {
    Map<String, dynamic>? initialState,
    Function(String, Map<String, dynamic>)? onToolCall,
  }) {
    return FutureBuilder<MCPUIRuntime>(
      future: () async {
        final runtime = MCPUIRuntime();
        await runtime.initialize(definition, pageLoader: null);
        return runtime;
      }(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ErrorWidget(snapshot.error!);
        }

        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        return snapshot.data!.buildUI(
          context: context,
          initialState: initialState,
          onToolCall: onToolCall,
        );
      },
    );
  }
}

/// Widget that hosts `dashboard.content` rendering for spec §11.9.
/// Wires the same tool / resource / brightness injection points as
/// [MCPRuntimeWidget] but renders only the dashboard subtree, and drives
/// a periodic rebuild when `dashboard.refreshInterval` is set.
class _DashboardHost extends StatefulWidget {
  const _DashboardHost({
    required this.engine,
    required this.dashboard,
    this.onToolCall,
    this.onResourceSubscribe,
    this.onResourceUnsubscribe,
    this.onExit,
    this.onOpenApp,
    this.hostBrightness,
  });

  final RuntimeEngine engine;
  final core.DashboardConfig dashboard;
  final Function(String, Map<String, dynamic>)? onToolCall;
  final Function(String, String)? onResourceSubscribe;
  final Function(String)? onResourceUnsubscribe;
  final VoidCallback? onExit;
  final void Function(String? appId, String? route)? onOpenApp;
  final ValueListenable<Brightness>? hostBrightness;

  @override
  State<_DashboardHost> createState() => _DashboardHostState();
}

class _DashboardHostState extends State<_DashboardHost>
    with WidgetsBindingObserver {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    if (widget.onToolCall != null) {
      widget.engine.actionHandler
          .registerToolExecutor('default', widget.onToolCall!);
    }
    widget.engine.setResourceHandlers(
      onResourceSubscribe: widget.onResourceSubscribe,
      onResourceUnsubscribe: widget.onResourceUnsubscribe,
    );
    if (widget.onExit != null) {
      NavigationActionExecutor.setOnExitCallback(widget.onExit!);
    }
    if (widget.onOpenApp != null) {
      NavigationActionExecutor.setOnOpenAppCallback(widget.onOpenApp!);
    }
    if (widget.hostBrightness != null) {
      widget.hostBrightness!.addListener(_applyHostBrightness);
      _applyHostBrightness();
    }
    _startRefreshTimer();
    // Fire onReady lifecycle hooks after the dashboard mounts so DSL
    // authors can auto-start resource subscriptions that drive live
    // streaming bindings (`{{temperature}}`, etc.). Handlers above are
    // already registered, so subscribe actions reach the host.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.engine.markReady();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.hostBrightness?.removeListener(_applyHostBrightness);
    widget.engine.themeManager.setHostBrightness(null);
    if (widget.onOpenApp != null) {
      NavigationActionExecutor.clearOnOpenAppCallback();
    }
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    widget.engine.themeManager.notifyBrightnessChanged();
  }

  void _applyHostBrightness() {
    widget.engine.themeManager.setHostBrightness(widget.hostBrightness?.value);
  }

  @override
  void didUpdateWidget(covariant _DashboardHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-register host callbacks when the host passes fresh closures
    // across rebuilds. The runtime stores these as static fields, so a
    // stale closure captured at initState would keep pointing at a
    // BuildContext that may be unmounted after round-trips through
    // `context.push('/app/:id')`.
    if (!identical(widget.onOpenApp, oldWidget.onOpenApp)) {
      if (widget.onOpenApp != null) {
        NavigationActionExecutor.setOnOpenAppCallback(widget.onOpenApp!);
      } else {
        NavigationActionExecutor.clearOnOpenAppCallback();
      }
    }
    if (!identical(widget.onExit, oldWidget.onExit) &&
        widget.onExit != null) {
      NavigationActionExecutor.setOnExitCallback(widget.onExit!);
    }
  }

  /// Spec §11.9.3: when `refreshInterval` is present, bindings referenced
  /// by `dashboard.content` must be re-evaluated at that cadence. The
  /// simplest implementation is a tick that forces a rebuild of the
  /// subtree — bindings are pure functions of state at render time.
  void _startRefreshTimer() {
    final ms = widget.dashboard.refreshInterval;
    if (ms == null || ms <= 0) return;
    _refreshTimer = Timer.periodic(Duration(milliseconds: ms), (_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    // Re-assert host callbacks on every build. The runtime stores them
    // as static fields, so another runtime mount (e.g. AppRendererScreen
    // pushed on top and later popped) may overwrite or clear them.
    // Re-registering here guarantees the dashboard's `openApp` /
    // `exitApp` handlers are live whenever the dashboard is visible.
    if (widget.onOpenApp != null) {
      NavigationActionExecutor.setOnOpenAppCallback(widget.onOpenApp!);
    }
    if (widget.onExit != null) {
      NavigationActionExecutor.setOnExitCallback(widget.onExit!);
    }
    return AnimatedBuilder(
      animation: widget.engine,
      builder: (context, _) {
        final renderContext =
            widget.engine.renderer.createRootContext(context);
        final tree = widget.engine.renderer
            .renderWidget(widget.dashboard.content, renderContext);
        final onTap = widget.dashboard.onTap;
        if (onTap == null) return tree;
        // Spec §11.9.3: `onTap` is invoked when the dashboard card is
        // tapped. GestureDetector here covers empty regions of the
        // subtree; interactive descendants still consume their own taps.
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => widget.engine.actionHandler.execute(onTap, renderContext),
          child: tree,
        );
      },
    );
  }
}

/// Single rail item — icon + label paired into one tap surface.
class _CustomRailItem {
  const _CustomRailItem({required this.icon, required this.label});
  final IconData icon;
  final String label;
}

/// Custom vertical rail navigation. Each item is one tappable tile
/// covering icon + label + padding, so taps anywhere on the tile
/// trigger selection (parity with drawer / tabs / bottomBar).
class _CustomRail extends StatelessWidget {
  const _CustomRail({
    required this.selectedIndex,
    required this.onSelect,
    required this.items,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final List<_CustomRailItem> items;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      child: SizedBox(
        width: 80,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: items.asMap().entries.map((entry) {
            final idx = entry.key;
            final item = entry.value;
            final isSelected = idx == selectedIndex;
            return InkWell(
              onTap: () => onSelect(idx),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                color: isSelected
                    ? cs.secondaryContainer.withValues(alpha: 0.6)
                    : null,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      item.icon,
                      color: isSelected
                          ? cs.onSecondaryContainer
                          : cs.onSurfaceVariant,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.label,
                      style: TextStyle(
                        fontSize: 12,
                        color: isSelected
                            ? cs.onSecondaryContainer
                            : cs.onSurfaceVariant,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.normal,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
