/// Poll channel for MCP UI DSL v1.1
///
/// Periodically triggers an action or emits events.
library poll_channel;

import 'dart:async';

import '../channel_manager.dart';

/// Channel that emits events at regular intervals
class PollChannel implements Channel {
  /// Interval between polls in milliseconds
  final int interval;

  /// Action to execute on each poll (optional)
  final Map<String, dynamic>? action;

  /// Minimum allowed interval (1 second)
  static const int minInterval = 1000;

  StreamController<PollEvent>? _controller;
  Timer? _timer;
  bool _isActive = false;
  int _pollCount = 0;

  PollChannel({
    required this.interval,
    this.action,
  });

  @override
  Future<void> start() async {
    if (_isActive) return;

    // Enforce minimum interval
    final effectiveInterval = interval < minInterval ? minInterval : interval;

    _controller = StreamController<PollEvent>.broadcast();
    _pollCount = 0;

    _timer = Timer.periodic(
      Duration(milliseconds: effectiveInterval),
      (_) => _onPoll(),
    );

    _isActive = true;

    // Emit initial event immediately
    _onPoll();
  }

  @override
  Future<void> stop() async {
    _isActive = false;
    _timer?.cancel();
    _timer = null;
    await _controller?.close();
    _controller = null;
  }

  @override
  Stream<dynamic> get stream =>
      _controller?.stream ?? const Stream.empty();

  @override
  bool get isActive => _isActive;

  /// Handle a poll tick
  void _onPoll() {
    _pollCount++;

    _controller?.add(PollEvent(
      count: _pollCount,
      timestamp: DateTime.now(),
      action: action,
    ));
  }

  /// Get the current poll count
  int get pollCount => _pollCount;

  /// Reset the poll count
  void resetCount() {
    _pollCount = 0;
  }
}

/// Event emitted on each poll
class PollEvent {
  /// Number of polls since start
  final int count;

  /// Timestamp of this poll
  final DateTime timestamp;

  /// Action to execute (if any)
  final Map<String, dynamic>? action;

  PollEvent({
    required this.count,
    required this.timestamp,
    this.action,
  });

  Map<String, dynamic> toJson() => {
        'count': count,
        'timestamp': timestamp.toIso8601String(),
        if (action != null) 'action': action,
      };

  @override
  String toString() => 'PollEvent(count: $count)';
}
