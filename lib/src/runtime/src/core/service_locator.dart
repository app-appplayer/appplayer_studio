import 'package:flutter/material.dart';
import '../utils/mcp_logger.dart';

/// Service locator for dependency injection
/// according to MCP UI DSL v1.0 specification
class ServiceLocator {
  static final ServiceLocator _instance = ServiceLocator._internal();
  factory ServiceLocator() => _instance;
  static ServiceLocator get instance => _instance;

  ServiceLocator._internal();

  final Map<Type, dynamic> _services = {};
  final Map<Type, Function> _factories = {};
  final Map<Type, List<Type>> _dependencies = {};
  final MCPLogger _logger = MCPLogger('ServiceLocator');

  /// Register a singleton service
  void register<T>(T service, {List<Type>? dependencies}) {
    _services[T] = service;
    if (dependencies != null) {
      _dependencies[T] = dependencies;
    }
    _logger.debug('Registered service: $T');
  }

  /// Register [service] under a Type known only at run time.
  ///
  /// `register<T>` takes its key from the STATIC type of its argument, which
  /// is right at a call site that names the service and wrong wherever the
  /// type travels as data — a plugin's `Map<Type, Service>`, for one. There
  /// every entry registered under `Service` itself: the first plugin's
  /// service answered every lookup, the second overwrote it, and
  /// `get<MyService>()` found neither.
  void registerByType(Type type, Object service, {List<Type>? dependencies}) {
    _services[type] = service;
    if (dependencies != null) {
      _dependencies[type] = dependencies;
    }
    _logger.debug('Registered service: $type');
  }

  /// Remove a service registered under a run-time [Type].
  ///
  /// The counterpart of [registerByType]; `unregister<T>()` with no type
  /// argument infers `dynamic` and removes nothing.
  void unregisterByType(Type type) {
    _services.remove(type);
    _factories.remove(type);
    _dependencies.remove(type);
    _logger.debug('Unregistered service: $type');
  }

  /// Register a lazy singleton service
  void registerLazy<T>(T Function() factory, {List<Type>? dependencies}) {
    _factories[T] = factory;
    if (dependencies != null) {
      _dependencies[T] = dependencies;
    }
    _logger.debug('Registered lazy service: $T');
  }

  /// Register a factory (creates new instance each time)
  void registerFactory<T>(T Function() factory, {List<Type>? dependencies}) {
    // Use a wrapper to indicate this is a factory, not lazy singleton
    _factories[T] = () => _FactoryWrapper<T>(factory);
    if (dependencies != null) {
      _dependencies[T] = dependencies;
    }
    _logger.debug('Registered factory: $T');
  }

  /// Get a service instance
  T get<T>({bool optional = false}) {
    // Check if already instantiated
    if (_services.containsKey(T)) {
      return _services[T] as T;
    }

    // Check if factory exists
    if (_factories.containsKey(T)) {
      final factory = _factories[T]!;
      final result = factory();

      // If it's a factory wrapper, create new instance each time
      if (result is _FactoryWrapper<T>) {
        return result.factory();
      }

      // Otherwise it's a lazy singleton, cache it
      final instance = result as T;
      _services[T] = instance;
      return instance;
    }

    // Service not found
    if (optional) {
      _logger.warning('Optional service not found: $T');
      // `null as T` throws under sound null safety for every non-nullable T,
      // which is every type a caller actually writes — so the degrade path
      // raised a `type 'Null' is not a subtype of T` cast error instead of
      // answering null, and no caller could handle it. An optional lookup has
      // to be made with a nullable type argument; anything else is asking for
      // a value that cannot represent absence.
      if (null is T) return null as T;
      throw ServiceNotFoundException(
          'Service not found: $T. An optional lookup must name a nullable '
          'type — get<$T?>(optional: true) — because $T cannot hold the '
          'absent case.');
    }

    throw ServiceNotFoundException('Service not found: $T');
  }

  /// Check if a service is registered
  bool isRegistered<T>() {
    return _services.containsKey(T) || _factories.containsKey(T);
  }

  /// Unregister a service
  void unregister<T>() {
    _services.remove(T);
    _factories.remove(T);
    _dependencies.remove(T);
    _logger.debug('Unregistered service: $T');
  }

  /// Clear all services
  void clear() {
    _services.clear();
    _factories.clear();
    _dependencies.clear();
    _logger.debug('Cleared all services');
  }

  /// Get dependencies for a service
  List<Type>? getDependencies<T>() {
    return _dependencies[T];
  }

  /// Validate dependencies (check for circular dependencies)
  void validateDependencies() {
    for (final entry in _dependencies.entries) {
      _checkCircularDependency(entry.key, []);
    }
  }

  void _checkCircularDependency(Type type, List<Type> path) {
    if (path.contains(type)) {
      throw CircularDependencyException(
          'Circular dependency detected: ${[...path, type].join(' -> ')}');
    }

    final deps = _dependencies[type];
    if (deps != null) {
      for (final dep in deps) {
        _checkCircularDependency(dep, [...path, type]);
      }
    }
  }

  /// Create a scoped service locator
  ServiceLocator createScope() {
    final scope = _ScopedServiceLocator(parent: this);
    return scope;
  }
}

/// Scoped service locator for request-scoped services
class _ScopedServiceLocator extends ServiceLocator {
  final ServiceLocator parent;

  _ScopedServiceLocator({required this.parent}) : super._internal();

  @override
  T get<T>({bool optional = false}) {
    // First check in this scope
    if (_services.containsKey(T) || _factories.containsKey(T)) {
      return super.get<T>(optional: optional);
    }

    // Then check in parent
    return parent.get<T>(optional: optional);
  }

  @override
  bool isRegistered<T>() {
    return super.isRegistered<T>() || parent.isRegistered<T>();
  }
}

/// Wrapper for factory functions
class _FactoryWrapper<T> {
  final T Function() factory;

  _FactoryWrapper(this.factory);
}

/// Exception thrown when a service is not found
class ServiceNotFoundException implements Exception {
  final String message;

  ServiceNotFoundException(this.message);

  @override
  String toString() => 'ServiceNotFoundException: $message';
}

/// Exception thrown when circular dependency is detected
class CircularDependencyException implements Exception {
  final String message;

  CircularDependencyException(this.message);

  @override
  String toString() => 'CircularDependencyException: $message';
}

/// Service provider widget for Flutter
class ServiceProvider extends InheritedWidget {
  final ServiceLocator serviceLocator;

  const ServiceProvider({
    super.key,
    required this.serviceLocator,
    required super.child,
  });

  static ServiceLocator of(BuildContext context) {
    final provider =
        context.dependOnInheritedWidgetOfExactType<ServiceProvider>();
    if (provider == null) {
      throw FlutterError('ServiceProvider not found in widget tree');
    }
    return provider.serviceLocator;
  }

  static ServiceLocator? maybeOf(BuildContext context) {
    final provider =
        context.dependOnInheritedWidgetOfExactType<ServiceProvider>();
    return provider?.serviceLocator;
  }

  @override
  bool updateShouldNotify(ServiceProvider oldWidget) {
    return serviceLocator != oldWidget.serviceLocator;
  }
}

/// Mixin to add service locator access to widgets
mixin ServiceLocatorMixin<T extends StatefulWidget> on State<T> {
  late ServiceLocator _serviceLocator;

  ServiceLocator get serviceLocator => _serviceLocator;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _serviceLocator = ServiceProvider.of(context);
  }

  /// Get a service from the locator
  S getService<S>({bool optional = false}) {
    return _serviceLocator.get<S>(optional: optional);
  }
}

/// Service interface for common service operations
abstract class Service {
  /// Initialize the service
  Future<void> initialize();

  /// Dispose of the service
  Future<void> dispose();

  /// Get service status
  ServiceStatus get status;
}

/// Service status
enum ServiceStatus {
  uninitialized,
  initializing,
  ready,
  error,
  disposed,
}

/// Base implementation of Service
abstract class BaseService implements Service {
  ServiceStatus _status = ServiceStatus.uninitialized;

  @override
  ServiceStatus get status => _status;

  @protected
  set status(ServiceStatus value) => _status = value;

  @override
  Future<void> initialize() async {
    if (_status != ServiceStatus.uninitialized) {
      throw StateError('Service already initialized');
    }

    _status = ServiceStatus.initializing;

    try {
      await onInitialize();
      _status = ServiceStatus.ready;
    } catch (e) {
      _status = ServiceStatus.error;
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    if (_status == ServiceStatus.disposed) {
      return;
    }

    await onDispose();
    _status = ServiceStatus.disposed;
  }

  /// Override to implement initialization logic
  @protected
  Future<void> onInitialize();

  /// Override to implement disposal logic
  @protected
  Future<void> onDispose();
}
