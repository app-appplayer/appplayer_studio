import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../utils/mcp_logger.dart';

/// Applies [update] through `setState`, deferring to after the frame when the
/// framework is mid-build.
///
/// A child that throws during build reaches these boundaries through
/// `ErrorWidget.builder`, which the framework calls WHILE building. Calling
/// `setState` there marks the element dirty during its own build — the
/// `!_dirty` assertion in debug, and a frame the framework has already walked
/// past in release. The error surface then depends on something else
/// scheduling a frame, which is why a failed build could leave the previous
/// content on screen with no error shown at all.
void _setStateSafely(State state, VoidCallback update) {
  final phase = SchedulerBinding.instance.schedulerPhase;
  final midFrame = phase == SchedulerPhase.persistentCallbacks ||
      phase == SchedulerPhase.midFrameMicrotasks;
  if (midFrame) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (state.mounted) {
        // ignore: invalid_use_of_protected_member
        state.setState(update);
      }
    });
    return;
  }
  // ignore: invalid_use_of_protected_member
  state.setState(update);
}

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

  /// What `FlutterError.onError` was before this boundary took it over.
  /// Restored on dispose: the handler is global and the closure outlives the
  /// State, so a boundary that came and went used to leave the framework
  /// reporting into a widget that is no longer mounted — every later error
  /// hit the `mounted` guard and vanished, shown nowhere and logged nowhere.
  FlutterExceptionHandler? _previousOnError;

  @override
  void initState() {
    super.initState();

    if (widget.catchAsync) {
      _previousOnError = FlutterError.onError;
      // Catch async errors
      FlutterError.onError = (FlutterErrorDetails details) {
        _handleError(details.exception, details.stack);

        // Pass the error on to whoever had the channel before this boundary
        // took it — NOT to `FlutterError.presentError`. They are the same
        // thing only when nothing else is installed; a host that wired a crash
        // reporter (or a test binding that records exceptions) had its handler
        // replaced, so calling `presentError` here meant every error inside a
        // boundary was dumped to the console and reached the reporter never.
        if (widget.showErrorInDebug) {
          final previous = _previousOnError;
          if (previous != null) {
            previous(details);
          } else {
            FlutterError.presentError(details);
          }
        }
      };
    }
  }

  void _handleError(Object error, StackTrace? stackTrace) {
    // One failed build arrives TWICE: once through `ErrorWidget.builder`
    // (which the framework calls in place of the widget) and once through
    // `FlutterError.onError` (which reports the same exception). Without this
    // guard the host's `onError` fired twice per failure and every downstream
    // count — retries, dialogs, navigations — was doubled.
    if (identical(_error, error)) return;

    _logger.error('Error caught by ErrorBoundary', error, stackTrace);

    // Call error callback
    widget.onError?.call(error, stackTrace);

    // Recorded synchronously, repainted when the framework can take it. The
    // fields have to be set NOW rather than inside the deferred callback: the
    // duplicate delivery arrives within the same frame, and a guard reading a
    // field that a post-frame callback has not written yet is no guard.
    if (mounted) {
      _error = error;
      _stackTrace = stackTrace;
      _setStateSafely(this, () {});
    }
  }

  void _resetError() {
    setState(() {
      _error = null;
      _stackTrace = null;
    });
  }

  @override
  void dispose() {
    if (widget.catchAsync) {
      FlutterError.onError = _previousOnError;
    }
    super.dispose();
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
/// Installs the build-error surface for the subtree.
///
/// `ErrorWidget.builder` is global. This used to be assigned from `build`,
/// which runs on every frame and never undoes itself: the last boundary to
/// build owned the builder for the whole application, and it kept owning it
/// after being disposed. Installing in `initState` and restoring in `dispose`
/// keeps the override to the lifetime it was meant to have — and keeps `build`
/// free of side effects.
class _ErrorWidget extends StatefulWidget {
  final Widget child;
  final void Function(Object error, StackTrace? stackTrace) onError;

  const _ErrorWidget({
    required this.child,
    required this.onError,
  });

  @override
  State<_ErrorWidget> createState() => _ErrorWidgetState();
}

/// The builders currently installed by mounted boundaries, innermost last.
///
/// A single save/restore pair is not enough. Flutter inflates a replacement
/// element BEFORE disposing the one it replaces, so a boundary that is rekeyed
/// (which is exactly what `ErrorRecovery` does on every retry) saved the
/// OUTGOING boundary's override as its "previous", and the outgoing one then
/// restored the original over the top. The global was left holding a closure
/// belonging to a defunct State — errors after that point were reported to a
/// widget that no longer existed, and `flutter_test` failed the whole test
/// file with "the value of ErrorWidget.builder was changed by the test".
final List<ErrorWidgetBuilder> _installedErrorWidgetBuilders = [];
ErrorWidgetBuilder? _rootErrorWidgetBuilder;

class _ErrorWidgetState extends State<_ErrorWidget> {
  late final ErrorWidgetBuilder _mine;

  @override
  void initState() {
    super.initState();
    if (_installedErrorWidgetBuilders.isEmpty) {
      _rootErrorWidgetBuilder = ErrorWidget.builder;
    }
    _mine = (FlutterErrorDetails details) {
      widget.onError(details.exception, details.stack);
      return const SizedBox.shrink();
    };
    _installedErrorWidgetBuilders.add(_mine);
    ErrorWidget.builder = _mine;
  }

  @override
  void dispose() {
    _installedErrorWidgetBuilders.remove(_mine);
    ErrorWidget.builder = _installedErrorWidgetBuilders.isNotEmpty
        ? _installedErrorWidgetBuilders.last
        : (_rootErrorWidgetBuilder ?? ErrorWidget.builder);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
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

  /// Incremented every time this widget decides to try the child again.
  ///
  /// It keys the inner [ErrorBoundary]. Without it the retry could not work at
  /// all: the boundary holds the error it caught, so clearing THIS widget's
  /// error rebuilt the same boundary element, which went straight back to its
  /// own error surface. Every strategy that clears the error — retry, reset,
  /// ignore, the dialog's OK — was therefore a no-op on screen.
  int _generation = 0;

  final MCPLogger _logger = MCPLogger('ErrorRecovery');

  void _handleError(Object error, StackTrace? stackTrace) async {
    // Same duplicate delivery as in `ErrorBoundary` above, and here it is
    // worse than a doubled log line: the strategy would run twice, stacking
    // two dialogs or pushing the error route twice for one failure.
    if (_isRecovering || identical(_error, error)) return;

    _logger.error('Error in ErrorRecovery', error, stackTrace);

    // Call error callback
    widget.onError?.call(error, stackTrace);

    _error = error;
    _stackTrace = stackTrace;
    _isRecovering = true;
    _setStateSafely(this, () {});

    // The strategies run AFTER the frame that raised the error. A build
    // failure reaches this method from inside `build`, and `showDialog` or
    // `Navigator.push` from there is illegal — the dialog and navigate
    // strategies simply asserted instead of doing anything.
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applyStrategy();
      });
      return;
    }
    await _applyStrategy();
  }

  Future<void> _applyStrategy() async {
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
        _setStateSafely(this, () {
          _error = null;
          _stackTrace = null;
          _isRecovering = false;
          _generation++;
        });
      }
    } else {
      _logger.error('Max retries exceeded');
      _setStateSafely(this, () {
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
      _setStateSafely(this, () {
        _error = null;
        _stackTrace = null;
        _retryCount = 0;
        _isRecovering = false;
        _generation++;
      });
    }
  }

  void _navigateStrategy() {
    if (widget.errorRoute != null) {
      _logger.debug('Navigating to error route: ${widget.errorRoute}');
      Navigator.of(context).pushReplacementNamed(widget.errorRoute!);
    }
    if (!mounted) return;
    _setStateSafely(this, () {
      _isRecovering = false;
    });
  }

  void _dialogStrategy() {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
        content: Text(_error.toString()),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _setStateSafely(this, () {
                _error = null;
                _stackTrace = null;
                _isRecovering = false;
                _generation++;
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
    if (!mounted) return;
    _setStateSafely(this, () {
      _error = null;
      _stackTrace = null;
      _isRecovering = false;
      _generation++;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null && !_isRecovering) {
      return widget.errorBuilder?.call(_error!, _stackTrace) ??
          _defaultErrorWidget();
    }

    return ErrorBoundary(
      // A new key per recovery attempt: the boundary is a fresh element, so
      // the child is built again rather than being replaced by the boundary's
      // own error surface for good.
      key: ValueKey<int>(_generation),
      onError: _handleError,
      // The recovery owns the presentation. Handing the boundary a null
      // builder let it draw its OWN error surface while a retry was in
      // flight, so one failure showed two different screens depending on
      // when you looked.
      errorBuilder: widget.errorBuilder ?? (error, stack) => _defaultErrorWidget(),
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
