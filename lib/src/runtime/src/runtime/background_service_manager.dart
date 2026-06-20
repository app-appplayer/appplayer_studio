import 'dart:async';
import '../models/ui_definition.dart';
import '../actions/action_handler.dart';
import '../state/state_manager.dart';
import '../utils/mcp_logger.dart';

/// Manages background services for the runtime
class BackgroundServiceManager {
  final bool enableDebugMode;
  final Map<String, BackgroundServiceRunner> _runningServices = {};
  final ActionHandler? actionHandler;
  final StateManager? stateManager;
  final MCPLogger _logger;
  bool _isDisposed = false;

  BackgroundServiceManager({
    this.enableDebugMode = false,
    this.actionHandler,
    this.stateManager,
  }) : _logger = MCPLogger('BackgroundServiceManager',
            enableLogging: enableDebugMode) {
    _logger.debug('BackgroundServiceManager initialized');
  }

  /// Start background services from definition
  Future<void> startServices(
      Map<String, BackgroundServiceDefinition> services) async {
    if (_isDisposed) return;

    for (final entry in services.entries) {
      await startService(entry.key, entry.value);
    }
  }

  /// Start a single background service
  Future<void> startService(
      String id, BackgroundServiceDefinition definition) async {
    if (_isDisposed) return;

    // Stop existing service with same ID
    await stopService(id);

    final runner = BackgroundServiceRunner(
      definition: definition,
      enableDebugMode: enableDebugMode,
      actionHandler: actionHandler,
      stateManager: stateManager,
    );

    _runningServices[id] = runner;
    await runner.start();

    if (enableDebugMode) {
      _logger.debug('Started service "$id"');
    }
  }

  /// Stop a background service
  Future<void> stopService(String id) async {
    final runner = _runningServices.remove(id);
    if (runner != null) {
      await runner.stop();

      if (enableDebugMode) {
        _logger.debug('Stopped service "$id"');
      }
    }
  }

  /// Stop all background services
  Future<void> stopAllServices() async {
    final runners = List<BackgroundServiceRunner>.from(_runningServices.values);
    _runningServices.clear();

    for (final runner in runners) {
      await runner.stop();
    }

    if (enableDebugMode) {
      _logger.debug('Stopped all services');
    }
  }

  /// Get running service IDs
  List<String> get runningServices => _runningServices.keys.toList();

  /// Check if service is running
  bool isRunning(String id) => _runningServices.containsKey(id);

  /// Dispose and cleanup
  Future<void> dispose() async {
    _isDisposed = true;
    await stopAllServices();
  }
}

/// Runs a single background service
class BackgroundServiceRunner {
  final BackgroundServiceDefinition definition;
  final bool enableDebugMode;
  final ActionHandler? actionHandler;
  final StateManager? stateManager;
  final MCPLogger _logger;

  Timer? _timer;
  StreamSubscription? _eventSubscription;
  bool _isRunning = false;
  int _retryCount = 0;
  final int _maxRetries = 3;

  BackgroundServiceRunner({
    required this.definition,
    this.enableDebugMode = false,
    this.actionHandler,
    this.stateManager,
  }) : _logger = MCPLogger('BackgroundService[${definition.id}]',
            enableLogging: enableDebugMode);

  /// Start the service
  Future<void> start() async {
    if (_isRunning) return;

    _isRunning = true;

    switch (definition.type) {
      case BackgroundServiceType.periodic:
        _startPeriodicService();
        break;
      case BackgroundServiceType.scheduled:
        _startScheduledService();
        break;
      case BackgroundServiceType.continuous:
        _startContinuousService();
        break;
      case BackgroundServiceType.event:
        _startEventService();
        break;
      case BackgroundServiceType.oneoff:
        _startOneoffService();
        break;
    }
  }

  /// Stop the service
  Future<void> stop() async {
    _isRunning = false;
    _timer?.cancel();
    _timer = null;
    _eventSubscription?.cancel();
    _eventSubscription = null;
    _retryCount = 0;
  }

  void _startPeriodicService() {
    final interval = definition.interval;
    if (interval == null || interval <= 0) {
      if (enableDebugMode) {
        _logger.error(
            'Invalid interval for periodic service ${definition.id}');
      }
      return;
    }

    _timer = Timer.periodic(Duration(milliseconds: interval), (timer) {
      if (!_isRunning) {
        timer.cancel();
        return;
      }
      _executeToolAsync();
    });
  }

  void _startScheduledService() {
    // Simple implementation: parse schedule pattern and set up timer
    final schedule = definition.schedule;
    if (schedule == null) {
      _logger
          .error('Scheduled service ${definition.id} missing schedule pattern');
      return;
    }

    // For now, support simple interval-based scheduling
    // Format: "every <number> <unit>" where unit is seconds/minutes/hours
    final match = RegExp(r'every\s+(\d+)\s+(second|minute|hour)s?')
        .firstMatch(schedule.toLowerCase());
    if (match != null) {
      final amount = int.parse(match.group(1)!);
      final unit = match.group(2)!;

      int intervalMs;
      switch (unit) {
        case 'second':
          intervalMs = amount * 1000;
          break;
        case 'minute':
          intervalMs = amount * 60 * 1000;
          break;
        case 'hour':
          intervalMs = amount * 60 * 60 * 1000;
          break;
        default:
          intervalMs = amount * 1000;
      }

      _timer = Timer.periodic(Duration(milliseconds: intervalMs), (timer) {
        if (!_isRunning) {
          timer.cancel();
          return;
        }
        _executeToolAsync();
      });

      _logger.debug('Started scheduled service with interval: ${intervalMs}ms');
    } else {
      _logger.error('Unsupported schedule pattern: $schedule');
    }
  }

  void _startContinuousService() {
    // Run continuously with minimal delay
    _timer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!_isRunning) {
        timer.cancel();
        return;
      }
      _executeToolAsync();
    });
  }

  void _startEventService() {
    // Listen to state changes that match the event pattern
    final eventPattern = definition.event;
    if (eventPattern == null) {
      _logger.error('Event service ${definition.id} missing event pattern');
      return;
    }

    if (stateManager != null) {
      // Subscribe to state changes
      _eventSubscription = stateManager!.stream.listen((event) {
        if (_isRunning && _matchesEventPattern(event, eventPattern)) {
          _executeToolAsync();
        }
      });

      _logger.debug('Started event service listening for: $eventPattern');
    } else {
      _logger.error('Event service requires StateManager');
    }
  }

  bool _matchesEventPattern(StateChangeEvent event, String pattern) {
    // Simple pattern matching: "state.path.changed" or "state.*.changed"
    if (pattern.contains('*')) {
      final regex = RegExp(pattern.replaceAll('*', '.*'));
      return regex.hasMatch(event.path);
    }
    return event.path == pattern;
  }

  void _startOneoffService() {
    final delay = definition.interval ?? 0;
    _timer = Timer(Duration(milliseconds: delay), () {
      if (_isRunning) {
        _executeToolAsync();
      }
      _isRunning = false;
    });
  }

  Future<void> _executeToolAsync() async {
    _executeTool();
  }

  Future<void> _executeTool() async {
    try {
      _logger.debug('Executing tool "${definition.tool}"');

      if (actionHandler == null) {
        _logger.error('No ActionHandler available for tool execution');
        return;
      }

      // For background services, execute the tool directly
      // We bypass the normal action handler flow since we don't have a full render context

      // Get the tool executor directly
      final toolExecutors = actionHandler!.toolExecutors;
      final toolExecutor =
          toolExecutors[definition.tool] ?? toolExecutors['default'];

      if (toolExecutor == null) {
        _logger.error('Tool executor not found: ${definition.tool}');
        return;
      }

      // Execute the tool with the params
      final result = await toolExecutor(definition.params ?? {});

      _logger.debug('Tool execution completed: $result');
      _retryCount = 0; // Reset retry count on success

      // Store result in state if configured
      if (definition.resultPath != null && stateManager != null) {
        stateManager!.set(definition.resultPath!, result);
      }
    } catch (error, stackTrace) {
      _logger.error('Error executing tool', error, stackTrace);
      _handleExecutionError(error);
    }
  }

  void _handleExecutionError(dynamic error) {
    _retryCount++;

    if (_retryCount <= _maxRetries && definition.retryOnError == true) {
      final retryDelay = definition.retryDelay ?? 5000;
      _logger.debug(
          'Retrying tool execution in ${retryDelay}ms (attempt $_retryCount/$_maxRetries)');

      Future.delayed(Duration(milliseconds: retryDelay), () {
        if (_isRunning) {
          _executeTool();
        }
      });
    } else {
      _logger.error('Max retries exceeded or retry disabled');

      // Optionally stop service on persistent errors
      if (definition.stopOnError == true) {
        _logger.debug('Stopping service due to persistent errors');
        stop();
      }
    }
  }
}
