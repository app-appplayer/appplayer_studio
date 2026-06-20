import 'dart:async';

/// Debouncer utility for performance optimization
/// according to MCP UI DSL v1.0 specification
class Debouncer {
  final int milliseconds;
  Timer? _timer;

  Debouncer({required this.milliseconds});

  /// Run the action after the specified delay
  /// Cancels any previous pending action
  void run(void Function() action) {
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: milliseconds), action);
  }

  /// Run the action asynchronously after the specified delay
  /// Cancels any previous pending action
  void runAsync(Future<void> Function() action) {
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: milliseconds), () async {
      await action();
    });
  }

  /// Cancel any pending action
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// Check if there's a pending action
  bool get isActive => _timer?.isActive ?? false;

  /// Dispose of the debouncer
  void dispose() {
    cancel();
  }
}

/// Throttler utility for performance optimization
class Throttler {
  final int milliseconds;
  DateTime? _lastRunTime;
  Timer? _timer;
  void Function()? _pendingAction;

  Throttler({required this.milliseconds});

  /// Run the action immediately if enough time has passed
  /// Otherwise, schedule it for later
  void run(void Function() action) {
    final now = DateTime.now();

    if (_lastRunTime == null ||
        now.difference(_lastRunTime!).inMilliseconds >= milliseconds) {
      // Execute immediately
      action();
      _lastRunTime = now;
      _pendingAction = null;
      _timer?.cancel();
    } else {
      // Schedule for later
      _pendingAction = action;
      final delay = milliseconds - now.difference(_lastRunTime!).inMilliseconds;

      _timer?.cancel();
      _timer = Timer(Duration(milliseconds: delay), () {
        if (_pendingAction != null) {
          _pendingAction!();
          _lastRunTime = DateTime.now();
          _pendingAction = null;
        }
      });
    }
  }

  /// Run the action asynchronously with throttling
  void runAsync(Future<void> Function() action) {
    run(() async {
      await action();
    });
  }

  /// Cancel any pending action
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _pendingAction = null;
  }

  /// Reset the throttler
  void reset() {
    cancel();
    _lastRunTime = null;
  }

  /// Check if there's a pending action
  bool get isActive => _timer?.isActive ?? false;

  /// Dispose of the throttler
  void dispose() {
    cancel();
  }
}

/// Rate limiter utility for controlling action frequency
class RateLimiter {
  final int maxCalls;
  final Duration window;
  final List<DateTime> _callTimes = [];
  Timer? _cleanupTimer;

  RateLimiter({
    required this.maxCalls,
    required this.window,
  }) {
    // Schedule periodic cleanup
    _scheduleCleanup();
  }

  /// Check if an action can be executed
  bool canExecute() {
    _cleanup();
    return _callTimes.length < maxCalls;
  }

  /// Execute the action if within rate limit
  bool execute(void Function() action) {
    if (canExecute()) {
      _callTimes.add(DateTime.now());
      action();
      return true;
    }
    return false;
  }

  /// Execute the action asynchronously if within rate limit
  Future<bool> executeAsync(Future<void> Function() action) async {
    if (canExecute()) {
      _callTimes.add(DateTime.now());
      await action();
      return true;
    }
    return false;
  }

  /// Get the number of remaining calls allowed
  int get remainingCalls {
    _cleanup();
    return maxCalls - _callTimes.length;
  }

  /// Get the time until the next call is allowed
  Duration? get timeUntilNextCall {
    _cleanup();

    if (_callTimes.length < maxCalls) {
      return Duration.zero;
    }

    if (_callTimes.isEmpty) {
      return null;
    }

    final oldestCall = _callTimes.first;
    final timeSinceOldest = DateTime.now().difference(oldestCall);

    if (timeSinceOldest >= window) {
      return Duration.zero;
    }

    return window - timeSinceOldest;
  }

  /// Clean up old call times
  void _cleanup() {
    final now = DateTime.now();
    _callTimes.removeWhere((time) => now.difference(time) >= window);
  }

  /// Schedule periodic cleanup
  void _scheduleCleanup() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(window, (_) => _cleanup());
  }

  /// Reset the rate limiter
  void reset() {
    _callTimes.clear();
  }

  /// Dispose of the rate limiter
  void dispose() {
    _cleanupTimer?.cancel();
    _callTimes.clear();
  }
}

/// Mixin to add debouncing capabilities to widgets
mixin DebounceMixin {
  final Map<String, Debouncer> _debouncers = {};

  /// Get or create a debouncer with the specified key
  Debouncer debouncer(String key, {int milliseconds = 300}) {
    return _debouncers.putIfAbsent(
      key,
      () => Debouncer(milliseconds: milliseconds),
    );
  }

  /// Run a debounced action
  void debounce(String key, void Function() action, {int milliseconds = 300}) {
    debouncer(key, milliseconds: milliseconds).run(action);
  }

  /// Dispose all debouncers
  void disposeDebouncers() {
    for (final debouncer in _debouncers.values) {
      debouncer.dispose();
    }
    _debouncers.clear();
  }
}

/// Mixin to add throttling capabilities to widgets
mixin ThrottleMixin {
  final Map<String, Throttler> _throttlers = {};

  /// Get or create a throttler with the specified key
  Throttler throttler(String key, {int milliseconds = 300}) {
    return _throttlers.putIfAbsent(
      key,
      () => Throttler(milliseconds: milliseconds),
    );
  }

  /// Run a throttled action
  void throttle(String key, void Function() action, {int milliseconds = 300}) {
    throttler(key, milliseconds: milliseconds).run(action);
  }

  /// Dispose all throttlers
  void disposeThrottlers() {
    for (final throttler in _throttlers.values) {
      throttler.dispose();
    }
    _throttlers.clear();
  }
}
