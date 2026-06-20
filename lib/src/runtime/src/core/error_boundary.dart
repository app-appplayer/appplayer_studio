import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../utils/mcp_logger.dart';

/// Error boundary widget for catching and handling errors
/// according to MCP UI DSL v1.0 specification
class ErrorBoundary extends StatefulWidget {
  final Widget child;
  final Widget Function(Object error, StackTrace? stackTrace)? errorBuilder;
  final void Function(Object error, StackTrace? stackTrace)? onError;
  final bool showErrorInDebug;
  final bool catchAsync;

  const ErrorBoundary({
    super.key,
    required this.child,
    this.errorBuilder,
    this.onError,
    this.showErrorInDebug = true,
    this.catchAsync = true,
  });

  @override
  State<ErrorBoundary> createState() => _ErrorBoundaryState();
}

class _ErrorBoundaryState extends State<ErrorBoundary> {
  Object? _error;
  StackTrace? _stackTrace;
  final MCPLogger _logger = MCPLogger('ErrorBoundary');

  @override
  void initState() {
    super.initState();

    if (widget.catchAsync) {
      // Catch async errors
      FlutterError.onError = (FlutterErrorDetails details) {
        _handleError(details.exception, details.stack);

        // Call original error handler if in debug mode
        if (widget.showErrorInDebug) {
          FlutterError.presentError(details);
        }
      };
    }
  }

  void _handleError(Object error, StackTrace? stackTrace) {
    _logger.error('Error caught by ErrorBoundary', error, stackTrace);

    // Call error callback
    widget.onError?.call(error, stackTrace);

    // Update state to show error widget
    if (mounted) {
      setState(() {
        _error = error;
        _stackTrace = stackTrace;
      });
    }
  }

  void _resetError() {
    setState(() {
      _error = null;
      _stackTrace = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return widget.errorBuilder?.call(_error!, _stackTrace) ??
          _defaultErrorWidget(_error!, _stackTrace);
    }

    // Wrap child in error widget to catch sync errors
    return _ErrorWidget(
      onError: _handleError,
      child: widget.child,
    );
  }

  Widget _defaultErrorWidget(Object error, StackTrace? stackTrace) {
    return Material(
      child: Container(
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                color: Colors.red.shade400,
                size: 64,
              ),
              const SizedBox(height: 16),
              Text(
                'An error occurred',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Colors.red.shade700,
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Error Details:',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.red.shade800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      error.toString(),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: Colors.red.shade700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _resetError,
                icon: const Icon(Icons.refresh),
                label: const Text('Try Again'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade600,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Internal error widget to catch synchronous errors
class _ErrorWidget extends StatelessWidget {
  final Widget child;
  final void Function(Object error, StackTrace? stackTrace) onError;

  const _ErrorWidget({
    required this.child,
    required this.onError,
  });

  @override
  Widget build(BuildContext context) {
    ErrorWidget.builder = (FlutterErrorDetails details) {
      onError(details.exception, details.stack);
      return const SizedBox.shrink();
    };

    return child;
  }
}

/// Error recovery strategies
enum ErrorRecoveryStrategy {
  /// Retry the operation
  retry,

  /// Reset to initial state
  reset,

  /// Navigate to error page
  navigate,

  /// Ignore and continue
  ignore,

  /// Show error dialog
  dialog,
}

/// Error recovery widget with multiple strategies
class ErrorRecovery extends StatefulWidget {
  final Widget child;
  final ErrorRecoveryStrategy strategy;
  final int maxRetries;
  final Duration retryDelay;
  final String? errorRoute;
  final Widget Function(Object error, StackTrace? stackTrace)? errorBuilder;
  final Future<void> Function()? onReset;
  final void Function(Object error, StackTrace? stackTrace)? onError;

  const ErrorRecovery({
    super.key,
    required this.child,
    this.strategy = ErrorRecoveryStrategy.retry,
    this.maxRetries = 3,
    this.retryDelay = const Duration(seconds: 1),
    this.errorRoute,
    this.errorBuilder,
    this.onReset,
    this.onError,
  });

  @override
  State<ErrorRecovery> createState() => _ErrorRecoveryState();
}

class _ErrorRecoveryState extends State<ErrorRecovery> {
  Object? _error;
  StackTrace? _stackTrace;
  int _retryCount = 0;
  bool _isRecovering = false;
  final MCPLogger _logger = MCPLogger('ErrorRecovery');

  void _handleError(Object error, StackTrace? stackTrace) async {
    _logger.error('Error in ErrorRecovery', error, stackTrace);

    // Call error callback
    widget.onError?.call(error, stackTrace);

    setState(() {
      _error = error;
      _stackTrace = stackTrace;
      _isRecovering = true;
    });

    // Apply recovery strategy
    switch (widget.strategy) {
      case ErrorRecoveryStrategy.retry:
        await _retryStrategy();
        break;
      case ErrorRecoveryStrategy.reset:
        await _resetStrategy();
        break;
      case ErrorRecoveryStrategy.navigate:
        _navigateStrategy();
        break;
      case ErrorRecoveryStrategy.dialog:
        _dialogStrategy();
        break;
      case ErrorRecoveryStrategy.ignore:
        _ignoreStrategy();
        break;
    }
  }

  Future<void> _retryStrategy() async {
    if (_retryCount < widget.maxRetries) {
      _retryCount++;
      _logger.debug(
          'Retrying after error (attempt $_retryCount/${widget.maxRetries})');

      await Future.delayed(widget.retryDelay);

      if (mounted) {
        setState(() {
          _error = null;
          _stackTrace = null;
          _isRecovering = false;
        });
      }
    } else {
      _logger.error('Max retries exceeded');
      setState(() {
        _isRecovering = false;
      });
    }
  }

  Future<void> _resetStrategy() async {
    _logger.debug('Resetting after error');

    if (widget.onReset != null) {
      await widget.onReset!();
    }

    if (mounted) {
      setState(() {
        _error = null;
        _stackTrace = null;
        _retryCount = 0;
        _isRecovering = false;
      });
    }
  }

  void _navigateStrategy() {
    if (widget.errorRoute != null) {
      _logger.debug('Navigating to error route: ${widget.errorRoute}');
      Navigator.of(context).pushReplacementNamed(widget.errorRoute!);
    }
    setState(() {
      _isRecovering = false;
    });
  }

  void _dialogStrategy() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
        content: Text(_error.toString()),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              setState(() {
                _error = null;
                _stackTrace = null;
                _isRecovering = false;
              });
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _ignoreStrategy() {
    _logger.debug('Ignoring error and continuing');
    setState(() {
      _error = null;
      _stackTrace = null;
      _isRecovering = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null && !_isRecovering) {
      return widget.errorBuilder?.call(_error!, _stackTrace) ??
          _defaultErrorWidget();
    }

    return ErrorBoundary(
      onError: _handleError,
      errorBuilder: widget.errorBuilder,
      child: widget.child,
    );
  }

  Widget _defaultErrorWidget() {
    return Material(
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline,
              color: Colors.red,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              'Something went wrong',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            if (_retryCount > 0)
              Text(
                'Retry attempt $_retryCount of ${widget.maxRetries}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.strategy == ErrorRecoveryStrategy.retry &&
                    _retryCount < widget.maxRetries)
                  ElevatedButton(
                    onPressed: () => _retryStrategy(),
                    child: const Text('Retry'),
                  ),
                if (widget.onReset != null) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => _resetStrategy(),
                    child: const Text('Reset'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Global error handler registration
class GlobalErrorHandler {
  static final MCPLogger _logger = MCPLogger('GlobalErrorHandler');
  static final List<void Function(Object, StackTrace?)> _handlers = [];

  /// Register a global error handler
  static void registerHandler(void Function(Object, StackTrace?) handler) {
    _handlers.add(handler);
  }

  /// Unregister a global error handler
  static void unregisterHandler(void Function(Object, StackTrace?) handler) {
    _handlers.remove(handler);
  }

  /// Initialize global error handling
  static void initialize() {
    FlutterError.onError = (FlutterErrorDetails details) {
      _logger.error('Flutter error', details.exception, details.stack);

      for (final handler in _handlers) {
        handler(details.exception, details.stack);
      }

      // Present error in debug mode
      if (kDebugMode) {
        FlutterError.presentError(details);
      }
    };

    // Catch async errors
    PlatformDispatcher.instance.onError = (error, stack) {
      _logger.error('Async error', error, stack);

      for (final handler in _handlers) {
        handler(error, stack);
      }

      return true; // Handled
    };
  }
}
