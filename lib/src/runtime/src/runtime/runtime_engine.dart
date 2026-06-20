import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../renderer/render_context.dart';
import '../renderer/renderer.dart';
import 'lifecycle_manager.dart';
import 'service_registry.dart';
import 'cache_manager.dart';
import 'widget_registry.dart';
import 'default_widgets.dart';
import '../binding/binding_engine.dart';
import '../actions/action_handler.dart';
import '../state/state_manager.dart';
import '../services/navigation_service.dart';
import '../services/dialog_service.dart';
import '../services/notification_service.dart';
import '../notifications/notification_manager.dart';
import '../models/ui_definition.dart';
import '../models/app_metadata.dart';
import '../routing/route_manager.dart';
import 'background_service_manager.dart';
import '../theme/theme_manager.dart';
import '../utils/mcp_logger.dart';
import '../state/computed_manager.dart';
import '../channels/channel_manager.dart';
import '../templates/template_registry.dart';
import '../responsive/responsive_resolver.dart';
import '../events/event_system.dart';
import '../offline/sync_manager.dart';
import '../offline/connectivity_manager.dart';
import '../offline/offline_queue.dart';
import '../plugins/plugin_system.dart';
import '../animations/animation_service.dart';
import '../permissions/permission_manager.dart';

/// The main runtime engine that manages the MCP UI Runtime lifecycle
/// and coordinates all runtime services.
class RuntimeEngine with ChangeNotifier {
  RuntimeEngine({
    this.enableDebugMode = kDebugMode,
    RenderInspector? widgetWrapper,
  })  : _widgetWrapper = widgetWrapper,
        _logger = MCPLogger('RuntimeEngine', enableLogging: enableDebugMode) {
    // Initialize core components in constructor so they're available immediately
    _initializeCoreComponents();
  }

  final bool enableDebugMode;
  final RenderInspector? _widgetWrapper;
  final MCPLogger _logger;

  // Core components
  late final LifecycleManager _lifecycleManager;
  late final ServiceRegistry _serviceRegistry;
  late final NotificationManager _notificationManager;
  late final CacheManager _cacheManager;
  late final BackgroundServiceManager _backgroundServiceManager;
  late final ChannelManager _channelManager;
  late final TemplateRegistry _templateRegistry;

  // v1.1 services
  late final ResponsiveResolver _responsiveResolver;
  late final EventBus _eventBus;
  late final ConnectivityManager _connectivityManager;
  late final OfflineQueue _offlineQueue;
  late final SyncManager _syncManager;
  late final PluginManager _pluginManager;
  late final AnimationService _animationService;

  // Modern rendering system
  late final WidgetRegistry _widgetRegistry;
  late final BindingEngine _bindingEngine;
  late final ActionHandler _actionHandler;
  late final StateManager _stateManager;
  late final Renderer _renderer;
  late final ThemeManager _themeManager;

  /// Tear-off of [notifyListeners] registered on [_themeManager] in
  /// `initialize()` so ThemeManager mutations forward to engine
  /// listeners. Held here so `destroy()` can pass the exact same
  /// reference to `removeListener` — avoids the singleton-listener
  /// leak that would otherwise outlive a destroyed engine.
  VoidCallback? _themeListener;
  late final ComputedManager _computedManager;

  // Public getters for page rendering
  Renderer get renderer => _renderer;
  StateManager get stateManager => _stateManager;
  CacheManager get cacheManager => _cacheManager;
  BindingEngine get bindingEngine => _bindingEngine;
  ActionHandler get actionHandler => _actionHandler;
  ThemeManager get themeManager => _themeManager;
  ChannelManager get channelManager => _channelManager;
  TemplateRegistry get templateRegistry => _templateRegistry;
  LifecycleManager get lifecycle => _lifecycleManager;
  ResponsiveResolver get responsiveResolver => _responsiveResolver;
  EventBus get eventBus => _eventBus;
  ConnectivityManager get connectivityManager => _connectivityManager;
  OfflineQueue get offlineQueue => _offlineQueue;
  SyncManager get syncManager => _syncManager;
  PluginManager get pluginManager => _pluginManager;
  AnimationService get animationService => _animationService;

  /// Permission manager for runtime permission checks
  PermissionManager? get permissionManager => _actionHandler.permissionManager;
  BackgroundServiceManager get backgroundServiceManager => _backgroundServiceManager;
  ComputedManager get computedManager => _computedManager;

  // Runtime state
  bool _isInitialized = false;
  bool _isReady = false;
  Map<String, dynamic>? _runtimeConfig;
  Map<String, dynamic>? _uiDefinition;

  // Application support
  UIDefinition? _parsedUIDefinition;
  ApplicationDefinition? _applicationDefinition;
  RouteManager? _routeManager;
  Function(String)? _pageLoader;

  // App metadata (spec §11): cached snapshot exposed as a ValueListenable.
  // Populated during `initialize` from the parsed ApplicationDefinition
  // and replaced when `ui://app/info` notifies a change.
  final ValueNotifier<DslAppMetadata?> _appMetadataNotifier =
      ValueNotifier<DslAppMetadata?>(null);

  // Resource handlers
  Function(String, String)? _onResourceSubscribe;
  Function(String)? _onResourceUnsubscribe;

  // Spec §4.5: separate one-shot `read` / `list` callbacks. Optional;
  // when null, the runtime falls back to `_onResourceSubscribe` for
  // backward compatibility with existing host implementations.
  Function(String, String)? _onResourceRead;
  Function(String, String)? _onResourceList;

  /// Permission handler for custom permission prompts
  Function? permissionHandler;

  // Resource subscription tracking
  final Map<String, String> _resourceSubscriptions = {}; // URI -> binding

  // Getters
  bool get isInitialized => _isInitialized;
  bool get isReady => _isReady;
  ServiceRegistry get services => _serviceRegistry;
  NotificationManager get notifications => _notificationManager;
  CacheManager get cache => _cacheManager;
  Map<String, dynamic>? get runtimeConfig => _runtimeConfig;
  Map<String, dynamic>? get uiDefinition => _uiDefinition;
  UIDefinition? get parsedUIDefinition => _parsedUIDefinition;
  ApplicationDefinition? get applicationDefinition => _applicationDefinition;
  RouteManager? get routeManager => _routeManager;
  bool get isApplication => _applicationDefinition != null;
  WidgetRegistry get widgetRegistry => _widgetRegistry;

  /// Observable snapshot of the current application metadata
  /// (spec §11). `value` is null before `initialize` completes and
  /// whenever the runtime holds a non-application (page-only) DSL.
  /// Listeners fire whenever the cache is replaced — for example
  /// when `ui://app/info` emits a resource-update notification.
  ValueListenable<DslAppMetadata?> get appMetadata => _appMetadataNotifier;

  // Resource handler getters
  Function(String, String)? get onResourceSubscribe => _onResourceSubscribe;
  Function(String)? get onResourceUnsubscribe => _onResourceUnsubscribe;

  /// Optional one-shot `read` callback (spec §4.5). Null when the host did
  /// not register one; callers fall back to `onResourceSubscribe`.
  Function(String, String)? get onResourceRead => _onResourceRead;

  /// Optional one-shot `list` callback (spec §4.5). Null when the host did
  /// not register one; callers fall back to `onResourceSubscribe`.
  Function(String, String)? get onResourceList => _onResourceList;

  // Set resource handlers
  void setResourceHandlers({
    Function(String, String)? onResourceSubscribe,
    Function(String)? onResourceUnsubscribe,
    Function(String, String)? onResourceRead,
    Function(String, String)? onResourceList,
  }) {
    _onResourceSubscribe = onResourceSubscribe;
    _onResourceUnsubscribe = onResourceUnsubscribe;
    _onResourceRead = onResourceRead;
    _onResourceList = onResourceList;
  }

  // Register a resource subscription
  void registerResourceSubscription(String uri, String binding) {
    _resourceSubscriptions[uri] = binding;
    _logger.debug('Registered subscription: $uri -> $binding');
  }

  // Unregister a resource subscription
  void unregisterResourceSubscription(String uri) {
    final binding = _resourceSubscriptions.remove(uri);
    if (binding != null) {
      _logger.debug('Unregistered subscription: $uri -> $binding');
    }
  }

  // Get binding for a URI
  String? getBindingForUri(String uri) {
    return _resourceSubscriptions[uri];
  }

  // Handle resource notification from MCP (spec §4.5).
  //
  // The raw `content` payload is stored verbatim at the subscribed binding.
  // The previous heuristic that unwrapped `content[binding]` when the
  // content happened to contain a field matching the binding name was
  // outside spec §4.5 — it conflated authored payload shape with binding
  // path semantics. Hosts must shape the resource payload so the runtime
  // can store it as-is at the declared binding path.
  void handleResourceNotification(String uri, Map<String, dynamic> data) {
    _logger.debug('=== RUNTIME NOTIFICATION ===');
    _logger.debug('URI: $uri');
    _logger.debug('Subscriptions: $_resourceSubscriptions');

    // Find the binding for this URI
    final binding = getBindingForUri(uri);
    _logger.debug('Binding found: $binding');

    if (binding != null) {
      // Spec §4.5: store the raw content at the subscribed binding.
      final content = data['content'];

      if (content != null) {
        _logger.debug('Updating state: $binding = $content');
        _stateManager.set(binding, content, source: 'subscription');
        _logger.debug('State updated via StateManager listener');
      } else {
        _logger.warning('No content in notification data');
      }
    } else {
      _logger.warning('No binding found for URI: $uri');
    }
    _logger.debug('=== RUNTIME NOTIFICATION END ===');
  }

  /// Initializes the runtime engine with the provided configuration
  Future<void> initialize({
    required Map<String, dynamic> definition,
    RenderContext? context,
    bool useCache = true,
    Function(String)? pageLoader,
  }) async {
    if (_isInitialized) {
      throw StateError('Runtime engine is already initialized');
    }

    try {
      if (enableDebugMode) {
        _logger.info('Initializing...');
      }

      // Try to load from cache if enabled
      Map<String, dynamic> finalDefinition = definition;
      if (useCache) {
        final cachedApp = await _tryLoadFromCache(definition);
        if (cachedApp != null) {
          finalDefinition = cachedApp;
        }
      }

      // Store page loader if provided
      _pageLoader = pageLoader;

      // Initialize with the definition
      await _initializeWithDefinition(finalDefinition, context);

      // Cache the app after successful initialization
      if (useCache) {
        await _cacheApp(finalDefinition);
      }

      _isInitialized = true;

      if (enableDebugMode) {
        _logger.info('Initialization complete');
      }

      // onReady is fired from the mounting widget (MCPRuntimeWidget /
      // _DashboardHost) after resource / tool / brightness handlers are
      // registered. Firing here would run onReady's resource.subscribe
      // before handlers exist → silently dropped subscription.
    } catch (error, stackTrace) {
      if (enableDebugMode) {
        _logger.error('Initialization failed', error, stackTrace);
      }
      rethrow;
    }
  }

  /// Initializes with the MCP runtime definition
  Future<void> _initializeWithDefinition(
    Map<String, dynamic> definition,
    RenderContext? context,
  ) async {
    // Check if this is a new v1.0 format (application or page)
    // Accept 'screen' as alias for 'page' per design spec
    if (definition['type'] == 'screen') {
      final normalized = Map<String, dynamic>.from(definition);
      normalized['type'] = 'page';
      await _initializeV1Format(normalized, context);
      return;
    }
    if (definition['type'] == 'application' || definition['type'] == 'page') {
      await _initializeV1Format(definition, context);
      return;
    }

    // v1.0 spec only supports application or page types
    throw ArgumentError('Definition must be a valid application or page type');
  }

  /// Initializes with v1.0 format (application or page)
  Future<void> _initializeV1Format(
    Map<String, dynamic> definition,
    RenderContext? context,
  ) async {
    // Parse UI definition
    _parsedUIDefinition = UIDefinition.fromJson(definition);

    // Store the appropriate UI definition based on type
    if (_parsedUIDefinition!.type == UIDefinitionType.page) {
      // For page type, store the full definition but extract content for rendering
      _uiDefinition = definition;
    } else {
      // For application type and others, store the raw definition
      _uiDefinition = definition;
    }

    // Apply sandbox configuration from definition if present
    final sandboxConfig = definition['sandbox'] as Map<String, dynamic>?;
    if (sandboxConfig != null) {
      _bindingEngine.sandbox = ExpressionSandbox.fromJson(sandboxConfig);
    }

    // Set the state manager in theme manager for custom theme values
    _themeManager.setStateManager(_stateManager);

    // Set up state change forwarding to trigger UI rebuilds
    _stateManager.addListener(() {
      _logger.debug('StateManager change detected, forwarding to UI...');
      notifyListeners(); // Forward state changes to UI
    });

    // Forward ThemeManager mutations to engine listeners so the
    // outer `AnimatedBuilder(animation: engine)` in `MCPRuntimeWidget`
    // rebuilds whenever `setTheme` / `setThemeDefinition` /
    // `setThemeMode` / `setHostBrightness` / `applyOverride` fire.
    // Spec `mcp_ui_dsl/spec/1.3/05_Theme.md` §L56 mandates re-render on
    // theme change; this wire is the engine's contribution. Hosts that
    // want to suppress / gate the propagation can do so on their own
    // side (e.g. active-tab gate in the host shell) — the package
    // ships the spec-conformant default and the host decides whether
    // to consume it. The named tear-off (`_themeListener =
    // notifyListeners`) is held on the engine so `destroy()` can
    // `removeListener` cleanly; ThemeManager is process-singleton, so
    // an unreleased listener would outlive a destroyed engine and
    // fire `notifyListeners` on a disposed receiver. The cross-tab
    // render thrash that motivated a brief disable
    // (`cherry/inbox/navigation-service-singleton-multi-instance-2026-05-21.md`)
    // is rooted in `NavigationService` singleton + multi-instance
    // `MaterialApp(navigatorKey: …)` collision — a separate refactor
    // track (`cherry/tracks/runtime-singleton-removal-plan-2026-05-20.md`
    // Phase 1). Suppressing this forwarder is the wrong fix; doing so
    // breaks `setHostBrightness` mode toggles (host bridge alone has
    // no path to engine.notifyListeners), which is far more critical
    // than a tab-swap thrash window.
    _themeListener = notifyListeners;
    _themeManager.addListener(_themeListener!);

    // Register all default widgets
    DefaultWidgets.registerAll(_widgetRegistry);

    // Register DSL-supplied templates so the `use` widget can resolve
    // `{ "type": "use", "template": "<name>" }` references at render
    // time. Application-root definitions land in TemplateScope.application
    // (visible to every page), standalone page definitions land in
    // TemplateScope.screen (cleared on page switch).
    //
    // Per the DSL spec a template entry MUST carry a `content` widget tree;
    // entries without it are malformed and skipped (no legacy aliases).
    final templatesBlock = definition['templates'];
    if (templatesBlock is Map) {
      final scope = _parsedUIDefinition!.type == UIDefinitionType.page
          ? TemplateScope.screen
          : TemplateScope.application;
      templatesBlock.forEach((name, entry) {
        if (name is! String ||
            entry is! Map<String, dynamic> ||
            entry['content'] is! Map<String, dynamic>) {
          return;
        }
        _templateRegistry.registerScoped(name, entry, scope: scope);
      });
    }

    // Create modern renderer
    _renderer = Renderer(
      widgetRegistry: _widgetRegistry,
      bindingEngine: _bindingEngine,
      actionHandler: _actionHandler,
      stateManager: _stateManager,
      engine: this,
      widgetWrapper: _widgetWrapper,
    );

    // Register core services
    await _registerCoreServices();

    // Wire ChannelManager to ActionHandler unconditionally. Channels may
    // be declared either at application root or at page scope; either way
    // the dispatch path (ChannelActionExecutor.channelManager) needs the
    // manager reference, so the wire-up is a one-time infrastructure step
    // rather than a feature-gated concern.
    _actionHandler.setChannelManager(_channelManager);

    // v1.1: Wire permissions config to ActionHandler for client actions
    if (_parsedUIDefinition!.permissions != null) {
      _actionHandler.setPermissionsConfig(_parsedUIDefinition!.permissions);

      // Wire system.info permission to ClientBindingResolver for env bindings
      _bindingEngine.clientBindingResolver.setSystemInfoPermission(
        _parsedUIDefinition!.permissions!.systemInfo == true,
      );
    }

    // v1.1: Wire channel event handlers unconditionally. Channels may be
    // declared at application root (parsed into _parsedUIDefinition.channels
    // and registered here) or at page scope (registered by PageStateScope
    // when the page mounts). Either way, config is looked up through the
    // ChannelManager registry so both scopes dispatch `onData` / `onError`
    // uniformly.
    _channelManager.onData = (channelId, data) {
      final channelConfig = _channelManager.getConfig(channelId);
      if (channelConfig == null) return;

      if (channelConfig.statePath != null) {
        _stateManager.set(channelConfig.statePath!, data);
      }

      if (channelConfig.onData != null) {
        final rootContext = _renderer
            .createRootContext(null)
            .createChildContext(variables: {
          'data': data,
          'channelId': channelId,
        });
        _actionHandler.execute(channelConfig.onData!, rootContext);
      }
    };

    _channelManager.onError = (channelId, error) {
      _logger.error('Channel "$channelId" error: $error');
      final channelConfig = _channelManager.getConfig(channelId);
      if (channelConfig?.onError != null) {
        final rootContext = _renderer
            .createRootContext(null)
            .createChildContext(variables: {
          'error': error.toString(),
          'channelId': channelId,
        });
        _actionHandler.execute(channelConfig!.onError!, rootContext);
      }
    };

    // Spec § 8.6.4 onConnect / onDisconnect — fired when the channel
    // transitions to `connected` / `disconnected`. ChannelManager owns
    // the state machine; the engine routes through to the per-channel
    // callbacks declared on ChannelDefinition.
    _channelManager.onConnect = (channelId) {
      final channelConfig = _channelManager.getConfig(channelId);
      if (channelConfig?.onConnect != null) {
        final rootContext = _renderer
            .createRootContext(null)
            .createChildContext(variables: {'channelId': channelId});
        _actionHandler.execute(channelConfig!.onConnect!, rootContext);
      }
    };
    _channelManager.onDisconnect = (channelId) {
      final channelConfig = _channelManager.getConfig(channelId);
      if (channelConfig?.onDisconnect != null) {
        final rootContext = _renderer
            .createRootContext(null)
            .createChildContext(variables: {'channelId': channelId});
        _actionHandler.execute(channelConfig!.onDisconnect!, rootContext);
      }
    };

    if (_parsedUIDefinition!.channels != null) {
      await _channelManager.initializeChannels(_parsedUIDefinition!.channels);
    }

    // Set up lifecycle manager with action handler and render context
    final rootContext = _renderer.createRootContext(null);
    _lifecycleManager.setActionHandler(_actionHandler, rootContext);

    // Handle application type
    if (_parsedUIDefinition!.type == UIDefinitionType.application) {
      if (_pageLoader == null) {
        throw ArgumentError('Page loader is required for application type');
      }

      _applicationDefinition =
          ApplicationDefinition.fromUIDefinition(_parsedUIDefinition!);

      // Seed the metadata cache from the DSL root (spec §11).
      if (_applicationDefinition!.metadata != null) {
        _appMetadataNotifier.value = _applicationDefinition!.metadata;
      }

      // Create route manager
      _routeManager = RouteManager(
        appDefinition: _applicationDefinition!,
        pageLoader: _pageLoader!,
        runtimeEngine: this,
      );

      // Initialize theme from application definition
      if (_applicationDefinition!.theme != null) {
        _themeManager.setTheme(_applicationDefinition!.theme!);
      }

      // Check for theme in runtime.services.theme (MCP UI DSL standard location)
      final runtimeServices = definition['runtime']?['services'];
      if (runtimeServices != null && runtimeServices['theme'] != null) {
        _logger.debug('Setting theme from runtime.services.theme');
        _themeManager
            .setTheme(runtimeServices['theme'] as Map<String, dynamic>);
      }

      // Initialize global app state
      if (_applicationDefinition!.initialState != null) {
        _stateManager.setState(_applicationDefinition!.initialState!);
        _logger.debug(
            'Initialized app state in StateManager with ${_applicationDefinition!.initialState!.length} keys');
      }

      // Initialize services from application definition
      if (_applicationDefinition!.servicesDefinition != null) {
        await _initializeServicesV1(
            _applicationDefinition!.servicesDefinition!);

        // Start background services
        if (_applicationDefinition!.servicesDefinition!.backgroundServices !=
            null) {
          await _startBackgroundServices(
              _applicationDefinition!.servicesDefinition!.backgroundServices!);
        }
      }

      // Set runtime config for lifecycle compatibility
      _runtimeConfig = {
        'lifecycle': _applicationDefinition!.lifecycleDefinition != null
            ? _lifecycleToJson(_applicationDefinition!.lifecycleDefinition!)
            : null,
        'services': _applicationDefinition!.servicesDefinition != null
            ? _servicesToJson(_applicationDefinition!.servicesDefinition!)
            : null,
      };
    } else {
      // Handle page type
      final pageDefinition =
          PageDefinition.fromUIDefinition(_parsedUIDefinition!);

      // Initialize state from page definition (state.initial format)
      if (pageDefinition.initialState != null &&
          pageDefinition.initialState!.isNotEmpty) {
        _stateManager.initialize(pageDefinition.initialState!);
        _logger.debug('Page state initialized from state.initial');
      }

      // Initialize services from page runtime definition if present
      final runtimeServices =
          definition['runtime']?['services'] as Map<String, dynamic>?;
      if (runtimeServices != null) {
        // Initialize state if present (overrides state.initial)
        final stateConfig = runtimeServices['state'] as Map<String, dynamic>?;
        if (stateConfig != null && stateConfig['initialState'] != null) {
          final initialState =
              stateConfig['initialState'] as Map<String, dynamic>;

          // Initialize StateManager directly (this is what the renderer uses)
          _stateManager.initialize(initialState);

          _logger.debug('Page state initialized from runtime services');
        }
      }

      // Set runtime config for lifecycle compatibility
      _runtimeConfig = {
        'lifecycle': pageDefinition.lifecycleDefinition != null
            ? _lifecycleToJson(pageDefinition.lifecycleDefinition!)
            : null,
        'services': runtimeServices,
      };
    }

    // Execute lifecycle hooks
    final lifecycle = _parsedUIDefinition!.type == UIDefinitionType.application
        ? _applicationDefinition?.lifecycleDefinition
        : (_parsedUIDefinition!.type == UIDefinitionType.page
            ? PageDefinition.fromUIDefinition(_parsedUIDefinition!)
                .lifecycleDefinition
            : null);

    if (lifecycle != null && lifecycle.onInitialize != null) {
      await _lifecycleManager.executeLifecycleHooks(
        LifecycleEvent.initialize,
        lifecycle.onInitialize!,
      );
    }
  }

  /// Initialize services for v1.0 format
  Future<void> _initializeServicesV1(ServicesDefinition services) async {
    // Initialize state
    if (services.state != null) {
      final initialState =
          services.state!['initialState'] as Map<String, dynamic>?;
      if (initialState != null) {
        _stateManager.setState(initialState);
        _logger.debug('Initialized service state in StateManager');
      }

      // Set up computed properties
      final computed = services.state!['computed'] as Map<String, dynamic>?;
      if (computed != null) {
        _initializeComputedProperties(computed);
      }

      // Set up watchers
      final watchers = services.state!['watchers'] as List<dynamic>?;
      if (watchers != null) {
        _initializeWatchers(watchers);
      }
    }

    // Initialize navigation service
    if (services.navigation != null) {
      final navService = _serviceRegistry.get<NavigationService>('navigation');
      if (navService != null) {
        // TODO: Configure navigation service
      }
    }

    // Initialize other services...
  }

  /// Start background services
  Future<void> _startBackgroundServices(
      Map<String, dynamic> servicesConfig) async {
    final services = <String, BackgroundServiceDefinition>{};

    for (final entry in servicesConfig.entries) {
      final serviceId = entry.key;
      final serviceConfig = entry.value as Map<String, dynamic>;

      try {
        final serviceDef =
            BackgroundServiceDefinition.fromJson(serviceId, serviceConfig);
        services[serviceId] = serviceDef;
      } catch (error) {
        if (enableDebugMode) {
          _logger.error('Error parsing background service "$serviceId"', error);
        }
      }
    }

    if (services.isNotEmpty) {
      await _backgroundServiceManager.startServices(services);
    }
  }

  /// Public getter for NavigationService
  NavigationService? get navigationService =>
      _serviceRegistry.get<NavigationService>('navigation');

  /// Loads a page by route using the registered page loader.
  ///
  /// Executes lifecycle hooks in the correct order:
  /// 1. onLeave hooks of the current page
  /// 2. onDestroy hooks of the current page
  /// 3. Load the new page
  /// 4. Initialize page state
  /// 5. onEnter hooks of the new page
  /// 6. onInit hooks of the new page
  Future<void> loadPage(String route) async {
    if (_pageLoader == null) {
      throw StateError('No page loader registered. Cannot load page: $route');
    }

    _logger.debug('Loading page for route: $route');

    // Step 1: Execute onLeave hooks for the current page
    final currentLifecycle =
        _parsedUIDefinition?.type == UIDefinitionType.page
            ? PageDefinition.fromUIDefinition(_parsedUIDefinition!)
                .lifecycleDefinition
            : null;

    if (currentLifecycle?.onLeave != null) {
      await _lifecycleManager.executeOnLeave(currentLifecycle!.onLeave!);
    }

    // Step 2: Execute onDestroy hooks for the current page
    if (currentLifecycle?.onDestroy != null) {
      await _lifecycleManager.executeLifecycleHooks(
        LifecycleEvent.destroy,
        currentLifecycle!.onDestroy!,
      );
    }

    // Step 3: Load the new page
    await _pageLoader!(route);

    // Step 4-6: State initialization, onEnter and onInit hooks are executed
    // by the page loader callback (which calls initialize on the new page)
    // onEnter is wired in page_state_scope.dart _initializePage()
  }

  /// Handles MCP notification for resource updates
  void handleNotification(String uri, Map<String, dynamic> data) {
    _logger.debug(
        'RuntimeEngine handling notification for URI: $uri with data: $data');

    // Forward to notification manager for additional processing
    // Notification manager is initialized during runtime setup

    // Update state based on notification (spec §3.11 source = 'subscription').
    final binding = data['binding'] as String?;
    if (binding != null) {
      final value = data['value'];
      _logger.debug('Updating binding $binding with value: $value');
      _stateManager.set(binding, value, source: 'subscription');
    }
  }

  /// Handles MCP notification with automatic mode detection
  /// Supports both standard (URI only) and extended (URI + content) modes
  Future<void> handleMCPNotification(
    Map<String, dynamic> params, {
    Function(String)? resourceReader,
  }) async {
    _logger.debug('=== MCP NOTIFICATION ===');
    _logger.debug('Params: $params');

    final uri = params['uri'] as String?;
    if (uri == null) {
      _logger.warning('No URI in notification params');
      return;
    }

    // Well-known `ui://app/info` updates feed the appMetadata cache
    // (spec §11.6). Handled independently of DSL-declared bindings so
    // embedders see new icon / publisher / timestamps without the
    // author having to declare the resource in the page.
    if (uri == 'ui://app/info') {
      await _refreshDslAppMetadataFromNotification(params,
          resourceReader: resourceReader);
      return;
    }

    // Find binding for this URI
    final binding = getBindingForUri(uri);
    if (binding == null) {
      _logger.warning('No binding found for URI: $uri');
      return;
    }

    _logger.debug('Binding found: $binding');

    // Spec §4.5: store the resource payload at the subscribed binding as-is.
    // The previous heuristic that unwrapped `content[binding]` when the
    // content happened to contain a field matching the binding name was
    // outside spec §4.5. Hosts must shape the resource payload so the
    // runtime can store it as-is at the declared binding path.

    // Check if content is included (extended mode)
    if (params.containsKey('content')) {
      // Extended mode: content included in notification
      _logger.debug('Extended mode detected - using content from notification');

      final contentData = params['content'];
      _logger.debug('Content data type: ${contentData.runtimeType}');
      _logger.debug('Content data: $contentData');

      if (contentData is Map<String, dynamic>) {
        // ResourceContentInfo wrapper: `{ text: <json>, ... }`. Parse the
        // inner JSON and store the parsed value at the binding.
        if (contentData.containsKey('text')) {
          final text = contentData['text'] as String?;
          if (text != null) {
            try {
              final parsedData = jsonDecode(text);
              _logger.debug('Parsed text content: $parsedData');
              _logger.debug('Updating state: $binding = $parsedData');
              _stateManager.set(binding, parsedData, source: 'subscription');
            } catch (e) {
              _logger.error('Failed to parse text content: $e');
            }
          }
        } else {
          // Direct content (no text wrapper) — store as-is.
          _logger.debug('Updating state: $binding = $contentData');
          _stateManager.set(binding, contentData, source: 'subscription');
        }

        // Update notification count if it exists in state
        final currentCount = _stateManager.get('notificationCount');
        if (currentCount != null && currentCount is int) {
          _stateManager.set('notificationCount', currentCount + 1,
              source: 'subscription');
        }

        notifyListeners();
      }
    } else {
      // Standard mode: need to read resource
      _logger.debug('Standard mode detected - reading resource');

      if (resourceReader != null) {
        try {
          final resourceContent = await resourceReader(uri);
          final data = jsonDecode(resourceContent);

          _logger.debug('Updating state: $binding = $data');
          _stateManager.set(binding, data, source: 'subscription');

          // Update notification count if it exists in state
          final currentCount = _stateManager.get('notificationCount');
          if (currentCount != null && currentCount is int) {
            _stateManager.set('notificationCount', currentCount + 1,
                source: 'subscription');
          }

          notifyListeners();
        } catch (e) {
          _logger.error('Failed to read resource: $e');
        }
      } else {
        _logger.warning('Standard mode but no resource reader provided');
      }
    }

    _logger.debug('=== MCP NOTIFICATION END ===');
  }

  /// Handle `notifications/resources/updated` for `ui://app/info`.
  ///
  /// Supports both Standard mode (URI only → runtime re-reads) and
  /// Extended mode (content included in the notification payload) per
  /// spec §6.4. New metadata is published through the [appMetadata]
  /// notifier; equal snapshots are suppressed to avoid needless
  /// listener churn.
  Future<void> _refreshDslAppMetadataFromNotification(
    Map<String, dynamic> params, {
    Function(String)? resourceReader,
  }) async {
    Map<String, dynamic>? payload;

    if (params.containsKey('content')) {
      final content = params['content'];
      if (content is Map<String, dynamic>) {
        if (content['text'] is String) {
          try {
            final decoded = jsonDecode(content['text'] as String);
            if (decoded is Map<String, dynamic>) {
              payload = decoded;
            }
          } catch (e) {
            _logger.error('Failed to decode ui://app/info content: $e');
          }
        } else {
          payload = content;
        }
      }
    } else if (resourceReader != null) {
      try {
        final raw = await resourceReader('ui://app/info');
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          payload = decoded;
        }
      } catch (e) {
        _logger.error('Failed to re-read ui://app/info: $e');
      }
    } else {
      _logger.warning(
          'ui://app/info updated but no resource reader available');
      return;
    }

    if (payload == null) return;
    final next = DslAppMetadata.fromJson(payload);
    if (_appMetadataNotifier.value == next) return;
    _appMetadataNotifier.value = next;
  }

  /// Marks the runtime as ready and executes onReady lifecycle hooks
  Future<void> markReady() async {
    if (!_isInitialized) {
      throw StateError(
          'Runtime engine must be initialized before marking ready');
    }

    if (_isReady) return;

    _isReady = true;

    if (enableDebugMode) {
      _logger.info('Marked as ready');
    }

    // Execute onReady lifecycle hooks
    final lifecycle = _parsedUIDefinition?.type == UIDefinitionType.application
        ? _applicationDefinition?.lifecycleDefinition
        : (_parsedUIDefinition?.type == UIDefinitionType.page
            ? PageDefinition.fromUIDefinition(_parsedUIDefinition!)
                .lifecycleDefinition
            : null);

    if (lifecycle != null && lifecycle.onReady != null) {
      await _lifecycleManager.executeLifecycleHooks(
        LifecycleEvent.ready,
        lifecycle.onReady!,
      );
    } else if (_runtimeConfig?['lifecycle']?['onReady'] != null) {
      // Fallback to runtime config for legacy format
      await _lifecycleManager.executeLifecycleHooks(
        LifecycleEvent.ready,
        _runtimeConfig!['lifecycle']['onReady'] as List<dynamic>,
      );
    }

    notifyListeners();
  }

  /// Handles application pause events
  Future<void> pause() async {
    if (!_isReady) return;

    if (enableDebugMode) {
      _logger.info('Paused');
    }

    // Execute onPause lifecycle hooks
    if (_runtimeConfig?['lifecycle']?['onPause'] != null) {
      await _lifecycleManager.executeLifecycleHooks(
        LifecycleEvent.pause,
        _runtimeConfig!['lifecycle']['onPause'] as List<dynamic>,
      );
    }
  }

  /// Handles application resume events
  Future<void> resume() async {
    if (!_isReady) return;

    if (enableDebugMode) {
      _logger.info('Resumed');
    }

    // Execute onResume lifecycle hooks
    if (_runtimeConfig?['lifecycle']?['onResume'] != null) {
      await _lifecycleManager.executeLifecycleHooks(
        LifecycleEvent.resume,
        _runtimeConfig!['lifecycle']['onResume'] as List<dynamic>,
      );
    }
  }

  /// Destroys the runtime and cleans up resources
  Future<void> destroy() async {
    if (!_isInitialized) return;

    if (enableDebugMode) {
      _logger.info('Destroying...');
    }

    // Unsubscribe from all active resource subscriptions before destroying
    if (_resourceSubscriptions.isNotEmpty && _onResourceUnsubscribe != null) {
      _logger.debug('Unsubscribing from ${_resourceSubscriptions.length} active resources');
      final urisToUnsubscribe = List<String>.from(_resourceSubscriptions.keys);

      for (final uri in urisToUnsubscribe) {
        try {
          _logger.debug('Unsubscribing from resource: $uri');
          await _onResourceUnsubscribe!(uri);
        } catch (e) {
          _logger.warning('Failed to unsubscribe from $uri: $e');
        }
      }

      // Clear all subscriptions after unsubscribing
      _resourceSubscriptions.clear();
      _logger.debug('All resource subscriptions cleared');
    }

    // Execute onDestroy lifecycle hooks
    if (_runtimeConfig?['lifecycle']?['onDestroy'] != null) {
      await _lifecycleManager.executeLifecycleHooks(
        LifecycleEvent.destroy,
        _runtimeConfig!['lifecycle']['onDestroy'] as List<dynamic>,
      );
    }

    // Cleanup services
    await _channelManager.dispose();
    await _backgroundServiceManager.dispose();
    await _serviceRegistry.dispose();
    await _notificationManager.dispose();
    _lifecycleManager.dispose();

    // Cleanup v1.1 services
    _syncManager.dispose();
    _connectivityManager.dispose();
    _eventBus.dispose();
    _animationService.dispose();

    // Detach the ThemeManager forward — process-singleton, so a
    // leaked listener would fire `notifyListeners` on a disposed
    // engine on the next theme mutation.
    final tl = _themeListener;
    if (tl != null) {
      _themeManager.removeListener(tl);
      _themeListener = null;
    }

    _isInitialized = false;
    _isReady = false;
    _runtimeConfig = null;
    _uiDefinition = null;
    _appMetadataNotifier.value = null;

    if (enableDebugMode) {
      _logger.info('Destroyed');
    }

    notifyListeners();
  }

  /// Registers core runtime services
  Future<void> _registerCoreServices() async {
    // Note: StateService is no longer registered as we use StateManager directly
    // This is kept for backward compatibility with services that might expect it
    // TODO: Remove this comment after verifying no services depend on StateService

    // Register NavigationService
    _serviceRegistry.register(
      'navigation',
      NavigationService(enableDebugMode: enableDebugMode),
    );

    // Register DialogService
    _serviceRegistry.register(
      'dialogs',
      DialogService(enableDebugMode: enableDebugMode),
    );

    // Register NotificationService
    _serviceRegistry.register(
      'notifications',
      NotificationService(
        notificationManager: _notificationManager,
        enableDebugMode: enableDebugMode,
      ),
    );
  }

  /// Tries to load app from cache
  Future<Map<String, dynamic>?> _tryLoadFromCache(
      Map<String, dynamic> definition) async {
    try {
      // v1.0 format: application type has properties at top level
      if (definition['type'] == 'application') {
        final domain = definition['domain'] as String?;
        final id = definition['id'] as String?;
        final version = definition['version'] as String?;

        if (domain == null || id == null || version == null) {
          return null;
        }

        final cachedApp = _cacheManager.getCachedApp(domain, id);
        if (cachedApp != null) {
          // Check if we need to update
          if (_cacheManager.isUpdateAvailable(domain, id, version)) {
            if (enableDebugMode) {
              _logger.info('Update available for $domain:$id');
            }
            // Still use cached version but mark for update
            // In production, you might want to trigger an update check
          }

          // Load cached state if available
          final appKey = '$domain:$id';
          // Load persisted state first
          await _cacheManager.loadPersistedState(appKey);
          final cachedState = _cacheManager.getCachedState(appKey);
          if (cachedState != null) {
            // Merge cached state into StateManager
            _stateManager.setState(cachedState);
            _logger.debug('Loaded cached state into StateManager');
          }

          return cachedApp.definition;
        }
      }
    } catch (error) {
      if (enableDebugMode) {
        _logger.error('Error loading from cache', error);
      }
    }

    return null;
  }

  /// Caches the app definition
  Future<void> _cacheApp(Map<String, dynamic> definition) async {
    try {
      final cachedApp = CachedApp.fromDefinition(definition);
      await _cacheManager.cacheApp(cachedApp);

      // Also cache the current state
      final appKey = '${cachedApp.domain}:${cachedApp.id}';
      await _cacheManager.cacheState(appKey, _stateManager.getState());
      _logger.debug('Cached current state from StateManager');
    } catch (error) {
      if (enableDebugMode) {
        _logger.error('Error caching app', error);
      }
    }
  }

  @override
  void dispose() {
    if (_isInitialized) {
      destroy().catchError((error) {
        // Ignore errors during disposal
        if (enableDebugMode) {
          _logger.error('Error during disposal', error);
        }
      });
    }
    super.dispose();
  }

  /// Convert LifecycleDefinition to JSON
  Map<String, dynamic> _lifecycleToJson(LifecycleDefinition lifecycle) {
    return {
      if (lifecycle.onInitialize != null)
        'onInitialize': lifecycle.onInitialize,
      if (lifecycle.onReady != null) 'onReady': lifecycle.onReady,
      if (lifecycle.onMount != null) 'onMount': lifecycle.onMount,
      if (lifecycle.onUnmount != null) 'onUnmount': lifecycle.onUnmount,
      if (lifecycle.onDestroy != null) 'onDestroy': lifecycle.onDestroy,
      if (lifecycle.onEnter != null) 'onEnter': lifecycle.onEnter,
      if (lifecycle.onLeave != null) 'onLeave': lifecycle.onLeave,
      if (lifecycle.onResume != null) 'onResume': lifecycle.onResume,
      if (lifecycle.onPause != null) 'onPause': lifecycle.onPause,
    };
  }

  /// Convert ServicesDefinition to JSON
  Map<String, dynamic> _servicesToJson(ServicesDefinition services) {
    return {
      if (services.state != null) 'state': services.state,
      if (services.navigation != null) 'navigation': services.navigation,
      if (services.dialog != null) 'dialog': services.dialog,
      if (services.notification != null) 'notification': services.notification,
      if (services.backgroundServices != null)
        'backgroundServices': services.backgroundServices,
    };
  }

  /// Initialize computed properties
  void _initializeComputedProperties(Map<String, dynamic> computed) {
    for (final entry in computed.entries) {
      final key = entry.key;
      final config = entry.value as Map<String, dynamic>;

      final expression = config['expression'] as String?;
      final dependencies =
          (config['dependencies'] as List?)?.cast<String>() ?? [];

      if (expression != null) {
        _computedManager.registerComputed(
          key,
          ComputedConfig(
            expression: expression,
            dependencies: dependencies,
          ),
        );
      }
    }
  }

  /// Initialize watchers
  /// Accepts both DSL spec keys (watch/condition/actions) and implementation keys (path/handler/immediate/deep)
  void _initializeWatchers(List<dynamic> watchers) {
    for (final watcherDef in watchers) {
      if (watcherDef is Map<String, dynamic>) {
        // Accept both DSL spec keys and implementation keys
        final path = watcherDef['watch'] as String? ??
            watcherDef['path'] as String?;
        // Support both List and Map for actions (P6 backward compatibility)
        final rawActions = watcherDef['actions'] ?? watcherDef['handler'];
        final List<Map<String, dynamic>> actionsList;
        if (rawActions is List) {
          actionsList = rawActions.whereType<Map<String, dynamic>>().toList();
        } else if (rawActions is Map<String, dynamic>) {
          actionsList = [rawActions];
        } else {
          actionsList = [];
        }
        final condition = watcherDef['condition'] as String?;
        final immediate = watcherDef['immediate'] as bool? ?? false;
        final deep = watcherDef['deep'] as bool? ?? false;

        if (path != null && actionsList.isNotEmpty) {
          _computedManager.registerWatcher(
            path,
            WatcherConfig(
              handler: (value, oldValue) {
                // Build context with current value and old value
                final watchContext =
                    renderer.createRootContext(null).createChildContext(
                  variables: {
                    'value': value,
                    'oldValue': oldValue,
                  },
                );

                // Evaluate condition expression if provided
                if (condition != null) {
                  final conditionResult =
                      _bindingEngine.resolve<dynamic>(condition, watchContext);
                  if (!_isTruthy(conditionResult)) {
                    return;
                  }
                }

                // Execute each action in the list
                for (final action in actionsList) {
                  _actionHandler.execute(action, watchContext);
                }
              },
              immediate: immediate,
              deep: deep,
            ),
          );
        }
      }
    }
  }

  /// Check if a value is truthy (non-null, non-false, non-zero, non-empty)
  bool _isTruthy(dynamic value) {
    if (value == null) return false;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value.isNotEmpty;
    if (value is List) return value.isNotEmpty;
    if (value is Map) return value.isNotEmpty;
    return true;
  }

  /// Initialize core components that need to be available immediately
  void _initializeCoreComponents() {
    // Initialize these components so they're available before initialize() is called
    _lifecycleManager = LifecycleManager(
      enableDebugMode: enableDebugMode,
    );

    _serviceRegistry = ServiceRegistry(
      enableDebugMode: enableDebugMode,
    );

    _widgetRegistry = WidgetRegistry();
    _bindingEngine = BindingEngine();
    _actionHandler = ActionHandler();
    _stateManager = StateManager();
    _themeManager = ThemeManager();
    _computedManager = ComputedManager(
      stateManager: _stateManager,
      bindingEngine: _bindingEngine,
    );

    _channelManager = ChannelManager();
    _templateRegistry = TemplateRegistry();

    // v1.1 services
    _responsiveResolver = ResponsiveResolver();
    _eventBus = EventBus();
    _connectivityManager = ConnectivityManager();
    _offlineQueue = OfflineQueue();
    _syncManager = SyncManager(_offlineQueue, _connectivityManager);
    _pluginManager = PluginManager.instance;
    _animationService = AnimationService();

    // Register template widgets (v1.1 TM-01)
    DefaultWidgets.registerTemplateWidgets(_widgetRegistry, _templateRegistry);

    _notificationManager = NotificationManager(
      enableDebugMode: enableDebugMode,
    );

    _cacheManager = CacheManager(
      enableDebugMode: enableDebugMode,
    );

    _backgroundServiceManager = BackgroundServiceManager(
      enableDebugMode: enableDebugMode,
      actionHandler: _actionHandler,
      stateManager: _stateManager,
    );
  }
}
