/// System monitor channel for MCP UI DSL v1.1
///
/// Streams system metrics (CPU, memory, etc.) at regular intervals.
library system_monitor_channel;

import 'dart:async';
import 'dart:io';

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

    // Emit initial reading immediately
    _collectMetrics();
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
          'os': Platform.operatingSystem,
          'version': Platform.operatingSystemVersion,
          'numberOfProcessors': Platform.numberOfProcessors,
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
    return {
      'rss': ProcessInfo.currentRss,
      'maxRss': ProcessInfo.maxRss,
    };
  }

  Map<String, dynamic> _getCpuMetrics() {
    return {
      'processors': Platform.numberOfProcessors,
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
