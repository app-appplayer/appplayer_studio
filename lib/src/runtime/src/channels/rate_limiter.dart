/// Rate limiting for MCP UI DSL v1.1 channel flow control
///
/// Implements configurable rate limiting with maxRate/window and
/// drop/queue overflow policies per spec §2277-2302.
library rate_limiter;

import 'dart:async';
import 'dart:collection';

/// Configuration for a single direction (inbound or outbound) rate limit
class RateLimitConfig {
  /// Maximum messages allowed per window
  final int maxRate;

  /// Window duration in milliseconds
  final int windowMs;

  /// Policy when rate is exceeded: 'drop' or 'queue'
  final String onExceeded;

  const RateLimitConfig({
    required this.maxRate,
    required this.windowMs,
    this.onExceeded = 'drop',
  });

  factory RateLimitConfig.fromJson(Map<String, dynamic> json) {
    return RateLimitConfig(
      maxRate: json['maxRate'] as int? ?? 100,
      windowMs: json['window'] as int? ?? 1000,
      onExceeded: json['onExceeded'] as String? ?? 'drop',
    );
  }
}

/// Flow control configuration combining inbound and outbound rate limits
class FlowControlConfig {
  /// Rate limit for inbound (received) messages
  final RateLimitConfig? inbound;

  /// Rate limit for outbound (sent) messages
  final RateLimitConfig? outbound;

  const FlowControlConfig({this.inbound, this.outbound});

  factory FlowControlConfig.fromJson(Map<String, dynamic> json) {
    return FlowControlConfig(
      inbound: json['inbound'] != null
          ? RateLimitConfig.fromJson(json['inbound'] as Map<String, dynamic>)
          : null,
      outbound: json['outbound'] != null
          ? RateLimitConfig.fromJson(json['outbound'] as Map<String, dynamic>)
          : null,
    );
  }
}

/// Sliding window rate limiter
///
/// Tracks message timestamps within a configurable window and enforces
/// a maximum rate. Messages that exceed the rate are either dropped or
/// queued depending on the [RateLimitConfig.onExceeded] policy.
class ChannelRateLimiter {
  final RateLimitConfig config;
  final Queue<DateTime> _timestamps = Queue<DateTime>();
  final Queue<dynamic> _queue = Queue<dynamic>();
  Timer? _drainTimer;

  ChannelRateLimiter(this.config);

  /// Apply rate limiting to an inbound stream
  Stream<dynamic> applyToStream(Stream<dynamic> source) {
    late StreamController<dynamic> controller;

    controller = StreamController<dynamic>.broadcast(
      onListen: () {
        source.listen(
          (data) {
            _pruneWindow();

            if (_timestamps.length < config.maxRate) {
              _timestamps.add(DateTime.now());
              controller.add(data);
            } else if (config.onExceeded == 'queue') {
              _queue.add(data);
              _scheduleDrain(controller);
            }
            // 'drop' policy: silently discard
          },
          onError: controller.addError,
          onDone: () {
            _drainTimer?.cancel();
            // Flush remaining queued messages on close
            while (_queue.isNotEmpty) {
              controller.add(_queue.removeFirst());
            }
            controller.close();
          },
        );
      },
      onCancel: () {
        _drainTimer?.cancel();
        _queue.clear();
      },
    );

    return controller.stream;
  }

  /// Check if an outbound message is allowed under the rate limit.
  ///
  /// Returns true if the message can be sent immediately.
  /// If the rate is exceeded and policy is 'queue', the message is queued.
  /// If the rate is exceeded and policy is 'drop', the message is discarded.
  bool tryEmit(dynamic message) {
    _pruneWindow();

    if (_timestamps.length < config.maxRate) {
      _timestamps.add(DateTime.now());
      return true;
    }

    if (config.onExceeded == 'queue') {
      _queue.add(message);
    }
    return false;
  }

  /// Get queued messages as a stream (for deferred sending)
  Stream<dynamic> get queuedMessages async* {
    while (_queue.isNotEmpty) {
      _pruneWindow();
      if (_timestamps.length < config.maxRate) {
        _timestamps.add(DateTime.now());
        yield _queue.removeFirst();
      } else {
        await Future.delayed(Duration(milliseconds: config.windowMs ~/ 10));
      }
    }
  }

  /// Remove timestamps outside the current window
  void _pruneWindow() {
    final cutoff = DateTime.now().subtract(
      Duration(milliseconds: config.windowMs),
    );
    while (_timestamps.isNotEmpty && _timestamps.first.isBefore(cutoff)) {
      _timestamps.removeFirst();
    }
  }

  /// Schedule periodic drain of queued messages
  void _scheduleDrain(StreamController<dynamic> controller) {
    if (_drainTimer?.isActive == true) return;

    _drainTimer = Timer.periodic(
      Duration(milliseconds: config.windowMs ~/ 10),
      (_) {
        _pruneWindow();
        while (_queue.isNotEmpty && _timestamps.length < config.maxRate) {
          _timestamps.add(DateTime.now());
          controller.add(_queue.removeFirst());
        }
        if (_queue.isEmpty) {
          _drainTimer?.cancel();
        }
      },
    );
  }

  /// Clean up resources
  void dispose() {
    _drainTimer?.cancel();
    _queue.clear();
    _timestamps.clear();
  }
}
