import 'package:flutter/material.dart';
import '../core/service_locator.dart';
import '../runtime/widget_registry.dart';
import '../actions/action_handler.dart';
import '../state/state_manager.dart';
import '../utils/mcp_logger.dart';
import '../widgets/widget_factory.dart';
import 'plugin_hooks.dart';

/// Plugin context provided to plugins during initialization
class PluginContext {
  final StateManager stateManager;
  final ServiceLocator serviceLocator;
  final WidgetRegistry widgetRegistry;
  final ActionHandler actionHandler;

  PluginContext({
    required this.stateManager,
    required this.serviceLocator,
    required this.widgetRegistry,
    required this.actionHandler,
  });
}

/// Base class for MCP plugins according to MCP UI DSL v1.0
abstract class MCPPlugin {
  /// Unique plugin name
  String get name;

  /// Plugin version
  String get version;

  /// Plugin description
  String get description => '';

  /// Plugin dependencies (other plugin names)
  List<String> get dependencies => const [];

  /// Custom widgets provided by this plugin
  Map<String, WidgetFactory>? get widgets => null;

  /// Custom action executors provided by this plugin
  Map<String, Future<dynamic> Function(Map<String, dynamic>)>? get actions =>
      null;

  /// Services provided by this plugin
  Map<Type, Service>? get services => null;

  /// Initialize the plugin
  Future<void> initialize(PluginContext context);

  /// Dispose of plugin resources
  Future<void> dispose();

  /// Called when plugin is enabled
  void onEnabled() {}

  /// Called when plugin is disabled
  void onDisabled() {}

  /// Configure the plugin with a configuration map.
  /// Called before initialize() to provide plugin-specific settings.
  void configure(Map<String, dynamic> config) {}
}

/// Plugin manager for loading and managing plugins
class PluginManager {
  static PluginManager? _instance;
  static PluginManager get instance => _instance ??= PluginManager._();

  /// Allow resetting for tests
  static void resetInstance() {
    _instance = null;
  }

  PluginManager._();

  final Map<String, MCPPlugin> _plugins = {};
  final Map<String, bool> _pluginStates = {};
  final Map<String, Map<String, dynamic>> _pluginConfigs = {};
  final List<String> _loadOrder = [];
  final MCPLogger _logger = MCPLogger('PluginManager');

  /// Hook manager for plugin event subscriptions
  final PluginHookManager hookManager = PluginHookManager.instance;

  late StateManager _stateManager;
  late ServiceLocator _serviceLocator;
  late WidgetRegistry _widgetRegistry;
  late ActionHandler _actionHandler;

  /// Initialize the plugin manager
  void initialize({
    required StateManager stateManager,
    required ServiceLocator serviceLocator,
    required WidgetRegistry widgetRegistry,
    required ActionHandler actionHandler,
  }) {
    _stateManager = stateManager;
    _serviceLocator = serviceLocator;
    _widgetRegistry = widgetRegistry;
    _actionHandler = actionHandler;

    _logger.debug('Plugin manager initialized');
  }

  /// Set configuration for a plugin before loading
  void setPluginConfig(String pluginName, Map<String, dynamic> config) {
    _pluginConfigs[pluginName] = config;
  }

  /// Register a plugin
  Future<void> registerPlugin(MCPPlugin plugin) async {
    if (_plugins.containsKey(plugin.name)) {
      throw PluginException('Plugin already registered: ${plugin.name}');
    }

    _plugins[plugin.name] = plugin;
    _pluginStates[plugin.name] = false;

    _logger.debug('Registered plugin: ${plugin.name} v${plugin.version}');
  }

  /// Load a plugin
  Future<void> loadPlugin(String pluginName) async {
    final plugin = _plugins[pluginName];
    if (plugin == null) {
      throw PluginException('Plugin not found: $pluginName');
    }

    if (_pluginStates[pluginName] == true) {
      _logger.warning('Plugin already loaded: $pluginName');
      return;
    }

    // Check dependencies
    for (final dep in plugin.dependencies) {
      if (!_pluginStates.containsKey(dep) || _pluginStates[dep] != true) {
        _logger.debug('Loading dependency: $dep');
        await loadPlugin(dep);
      }
    }

    try {
      // Create plugin context
      final context = PluginContext(
        stateManager: _stateManager,
        serviceLocator: _serviceLocator,
        widgetRegistry: _widgetRegistry,
        actionHandler: _actionHandler,
      );

      // Fire lifecycle hook: initializing
      await hookManager.fireHook(PluginHookType.onLifecycle, data: {
        'pluginName': plugin.name,
        'event': 'initializing',
      });

      // Configure plugin if config is available
      final config = _pluginConfigs[pluginName];
      if (config != null) {
        plugin.configure(config);
      }

      // Initialize plugin
      await plugin.initialize(context);

      // Fire lifecycle hook: initialized
      await hookManager.fireHook(PluginHookType.onLifecycle, data: {
        'pluginName': plugin.name,
        'event': 'initialized',
      });

      // Register widgets
      plugin.widgets?.forEach((type, factory) {
        _widgetRegistry.register(type, factory);
        _logger.debug('Registered widget from ${plugin.name}: $type');
        hookManager.fireHook(PluginHookType.onWidgetRegister, data: {
          'pluginName': plugin.name,
          'widgetType': type,
        });
      });

      // Register actions
      plugin.actions?.forEach((type, executor) {
        _actionHandler.registerToolExecutor(type, executor);
        _logger.debug('Registered action from ${plugin.name}: $type');
        hookManager.fireHook(PluginHookType.onActionRegister, data: {
          'pluginName': plugin.name,
          'actionType': type,
        });
      });

      // Register services
      plugin.services?.forEach((type, service) {
        _serviceLocator.register(service, dependencies: [type]);
        _logger.debug('Registered service from ${plugin.name}: $type');
      });

      // Mark as loaded
      _pluginStates[pluginName] = true;
      _loadOrder.add(pluginName);

      // Call enabled hook
      plugin.onEnabled();

      _logger.debug('Loaded plugin: ${plugin.name} v${plugin.version}');
    } catch (e, stackTrace) {
      _logger.error('Failed to load plugin: ${plugin.name}', e, stackTrace);
      throw PluginException('Failed to load plugin: ${plugin.name} - $e');
    }
  }

  /// Unload a plugin
  Future<void> unloadPlugin(String pluginName) async {
    final plugin = _plugins[pluginName];
    if (plugin == null) {
      throw PluginException('Plugin not found: $pluginName');
    }

    if (_pluginStates[pluginName] != true) {
      _logger.warning('Plugin not loaded: $pluginName');
      return;
    }

    // Check if other plugins depend on this one
    for (final otherPlugin in _plugins.values) {
      if (otherPlugin.name != pluginName &&
          otherPlugin.dependencies.contains(pluginName) &&
          _pluginStates[otherPlugin.name] == true) {
        throw PluginException(
            'Cannot unload plugin $pluginName: ${otherPlugin.name} depends on it');
      }
    }

    try {
      // Call disabled hook
      plugin.onDisabled();

      // Fire lifecycle hook: disposing
      await hookManager.fireHook(PluginHookType.onLifecycle, data: {
        'pluginName': plugin.name,
        'event': 'disposing',
      });

      // Dispose plugin
      await plugin.dispose();

      // Unregister all hooks from this plugin
      hookManager.unregisterPlugin(pluginName);

      // Fire lifecycle hook: disposed
      await hookManager.fireHook(PluginHookType.onLifecycle, data: {
        'pluginName': plugin.name,
        'event': 'disposed',
      });

      // Unregister widgets
      plugin.widgets?.forEach((type, _) {
        _widgetRegistry.unregister(type);
        _logger.debug('Unregistered widget from ${plugin.name}: $type');
      });

      // Unregister actions
      plugin.actions?.forEach((type, _) {
        _actionHandler.unregisterToolExecutor(type);
        _logger.debug('Unregistered action from ${plugin.name}: $type');
      });

      // Unregister services
      plugin.services?.forEach((type, _) {
        _serviceLocator.unregister();
        _logger.debug('Unregistered service from ${plugin.name}: $type');
      });

      // Mark as unloaded
      _pluginStates[pluginName] = false;
      _loadOrder.remove(pluginName);

      _logger.debug('Unloaded plugin: ${plugin.name}');
    } catch (e, stackTrace) {
      _logger.error('Failed to unload plugin: ${plugin.name}', e, stackTrace);
      throw PluginException('Failed to unload plugin: ${plugin.name} - $e');
    }
  }

  /// Load all registered plugins
  Future<void> loadAllPlugins() async {
    final sortedPlugins = _topologicalSort();

    for (final pluginName in sortedPlugins) {
      if (_pluginStates[pluginName] != true) {
        await loadPlugin(pluginName);
      }
    }
  }

  /// Unload all plugins
  Future<void> unloadAllPlugins() async {
    // Unload in reverse order
    for (final pluginName in _loadOrder.reversed.toList()) {
      await unloadPlugin(pluginName);
    }
  }

  /// Get plugin info
  PluginInfo? getPluginInfo(String pluginName) {
    final plugin = _plugins[pluginName];
    if (plugin == null) return null;

    return PluginInfo(
      name: plugin.name,
      version: plugin.version,
      description: plugin.description,
      dependencies: plugin.dependencies,
      isLoaded: _pluginStates[pluginName] ?? false,
      widgetCount: plugin.widgets?.length ?? 0,
      actionCount: plugin.actions?.length ?? 0,
      serviceCount: plugin.services?.length ?? 0,
    );
  }

  /// Get all plugin infos
  List<PluginInfo> getAllPluginInfos() {
    return _plugins.keys.map((name) => getPluginInfo(name)!).toList();
  }

  /// Check if a plugin is loaded
  bool isPluginLoaded(String pluginName) {
    return _pluginStates[pluginName] ?? false;
  }

  /// Topological sort for dependency resolution
  List<String> _topologicalSort() {
    final sorted = <String>[];
    final visited = <String>{};
    final visiting = <String>{};

    void visit(String pluginName) {
      if (visited.contains(pluginName)) return;

      if (visiting.contains(pluginName)) {
        throw PluginException(
            'Circular dependency detected involving: $pluginName');
      }

      visiting.add(pluginName);

      final plugin = _plugins[pluginName];
      if (plugin != null) {
        for (final dep in plugin.dependencies) {
          if (_plugins.containsKey(dep)) {
            visit(dep);
          }
        }
      }

      visiting.remove(pluginName);
      visited.add(pluginName);
      sorted.add(pluginName);
    }

    for (final pluginName in _plugins.keys) {
      visit(pluginName);
    }

    return sorted;
  }
}

/// Plugin information
class PluginInfo {
  final String name;
  final String version;
  final String description;
  final List<String> dependencies;
  final bool isLoaded;
  final int widgetCount;
  final int actionCount;
  final int serviceCount;

  PluginInfo({
    required this.name,
    required this.version,
    required this.description,
    required this.dependencies,
    required this.isLoaded,
    required this.widgetCount,
    required this.actionCount,
    required this.serviceCount,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'version': version,
        'description': description,
        'dependencies': dependencies,
        'isLoaded': isLoaded,
        'widgetCount': widgetCount,
        'actionCount': actionCount,
        'serviceCount': serviceCount,
      };
}

/// Plugin exception
class PluginException implements Exception {
  final String message;

  PluginException(this.message);

  @override
  String toString() => 'PluginException: $message';
}

/// Example plugin implementation
class ExamplePlugin extends MCPPlugin {
  @override
  String get name => 'example';

  @override
  String get version => '1.0.0';

  @override
  String get description => 'Example plugin demonstrating plugin system';

  @override
  Map<String, WidgetFactory> get widgets => {
        'ExampleWidget': ExampleWidgetFactory(),
      };

  @override
  Map<String, Future<dynamic> Function(Map<String, dynamic>)> get actions => {
        'exampleAction': (params) async {
          return {'result': 'Example action executed', 'params': params};
        },
      };

  @override
  Future<void> initialize(PluginContext context) async {
    // Initialize plugin resources
    await Future.delayed(const Duration(milliseconds: 100));
  }

  @override
  Future<void> dispose() async {
    // Clean up plugin resources
  }
}

/// Example widget factory for the plugin
class ExampleWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, context) {
    final properties = extractProperties(definition);
    final text =
        context.resolve<String>(properties['text'] ?? 'Example Widget');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.blue.shade900,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
