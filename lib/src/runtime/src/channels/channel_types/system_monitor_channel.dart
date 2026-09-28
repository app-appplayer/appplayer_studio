/// System monitor channel for MCP UI DSL v1.1
///
/// Streams system metrics (CPU, memory, etc.) at regular intervals.
library system_monitor_channel;

import 'dart:async';

import '../../platform/host_platform.dart';
import '../channel_manager.dart';

/// Channel that streams system metrics at regular intervals
class SystemMonitorChannel implements Channel {
  /// Metrics to monitor
  final List<String> metrics;

  /// Interval between readings in milliseconds
  final int interval;

  /// Minimum allowed interval (1 second)
  static const int minInterval = 1000;

  StreamController<SystemMetrics>? _controller;
  Timer? _timer;
  bool _isActive = false;

  SystemMonitorChannel({
    List<String>? metrics,
    this.interval = 5000,
  }) : metrics = metrics ?? const ['memory'];

  @override
  Future<void> start() async {
    if (_isActive) return;

    final effectiveInterval = interval < minInterval ? minInterval : interval;

    _controller = StreamController<SystemMetrics>.broadcast();
    _isActive = true;

    _timer = Timer.periodic(
      Duration(milliseconds: effectiveInterval),
      (_) => _collectMetrics(),
    );

    // Emit the initial reading on the next turn, not synchronously.
    //
    // The controller is a broadcast one and it is created HERE, so a caller
    // cannot listen before `start` — `stream` answers `Stream.empty()` until
    // then. A reading emitted inside `start` therefore reached nobody: every
    // consumer does `await start(); stream.listen(...)`, and a broadcast
    // controller drops what it emits with no listeners. The dashboard sat
    // empty for a whole interval and then filled in, which reads as a slow
    // backend rather than as a reading that was thrown away.
    _initialReading = Timer(Duration.zero, _collectMetrics);
  }

  Timer? _initialReading;

  @override
  Future<void> stop() async {
    _isActive = false;
    _initialReading?.cancel();
    _initialReading = null;
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

  /// Collect system metrics
  void _collectMetrics() {
    try {
      final data = <String, dynamic>{
        'timestamp': DateTime.now().toIso8601String(),
      };

      if (metrics.contains('memory')) {
        data['memory'] = _getMemoryMetrics();
      }

      if (metrics.contains('cpu')) {
        data['cpu'] = _getCpuMetrics();
      }

      if (metrics.contains('platform')) {
        data['platform'] = {
          'os': HostPlatform.name,
          'version': HostPlatform.osVersion,
          'numberOfProcessors': HostPlatform.processorCount,
        };
      }

      _controller?.add(SystemMetrics(data: data));
    } catch (e) {
      _controller?.addError(e);
    }
  }

  Map<String, dynamic> _getMemoryMetrics() {
    // Dart doesn't expose detailed memory metrics directly,
    // but ProcessInfo provides RSS
    final memory = HostPlatform.memory;
    return {
      'rss': memory.rss,
      'maxRss': memory.maxRss,
    };
  }

  Map<String, dynamic> _getCpuMetrics() {
    return {
      'processors': HostPlatform.processorCount,
    };
  }
}

/// System metrics event
class SystemMetrics {
  final Map<String, dynamic> data;

  SystemMetrics({required this.data});

  Map<String, dynamic> toJson() => data;

  @override
  String toString() => 'SystemMetrics($data)';
}
