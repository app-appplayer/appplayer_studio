/// Channel manager for MCP UI DSL v1.1
///
/// Manages bidirectional communication channels.
library channel_manager;

import 'dart:async';

import '../models/ui_definition.dart';
import '../utils/mcp_logger.dart';
import 'channel_message.dart';
import 'channel_types/file_watch_channel.dart';
import 'channel_types/directory_watch_channel.dart';
import 'channel_types/poll_channel.dart';
import 'channel_types/system_monitor_channel.dart';
import 'channel_types/websocket_channel.dart';
import 'rate_limiter.dart';

/// Channel lifecycle state enum (CH-05)
enum ChannelState {
  /// Channel is connecting/starting
  connecting,

  /// Channel is connected and active
  connected,

  /// Channel is disconnected
  disconnected,

  /// Channel is attempting to reconnect
  reconnecting,

  /// Channel has failed after max retries
  failed,

  /// Channel has been explicitly stopped
  stopped,
}

/// Manages channel lifecycle and data flow
class ChannelManager {
  final Map<String, Channel> _channels = {};
  final Map<String, StreamSubscription> _subscriptions = {};
  final Map<String, StreamController<dynamic>> _controllers = {};
  final Map<String, ChannelState> _channelStates = {};
  final Map<String, int> _restartCounts = {};
  final Map<String, ChannelConfig> _channelConfigs = {};
  final Map<String, dynamic> _channelData = {};

  /// Returns the registered config for a channelId (null if unknown).
  /// Used by RuntimeEngine to route `onData`/`onError` actions regardless
  /// of whether the channel was declared at application or page scope.
  ChannelConfig? getConfig(String channelId) => _channelConfigs[channelId];
  final MCPLogger _logger = MCPLogger('ChannelManager');

  /// Track channel IDs that have autoDispose enabled
  final Set<String> _autoDisposeChannels = {};

  /// Flow control configs per channel (spec §2277-2302)
  final Map<String, FlowControlConfig> _flowControlConfigs = {};

  /// Inbound rate limiters per channel
  final Map<String, ChannelRateLimiter> _inboundChannelRateLimiters = {};

  /// Outbound rate limiters per channel
  final Map<String, ChannelRateLimiter> _outboundChannelRateLimiters = {};

  /// Sequence counters per channel for message protocol
  final Map<String, int> _sequenceCounters = {};

  /// Callback for channel data
  void Function(String channelId, dynamic data)? onData;

  /// Callback for channel errors
  void Function(String channelId, dynamic error)? onError;

  /// Callback fired when a channel transitions to `connected`
  /// (spec § 8.6.4 onConnect).
  void Function(String channelId)? onConnect;

  /// Callback fired when a channel transitions to `disconnected`
  /// (spec § 8.6.4 onDisconnect — graceful or error-driven stop).
  void Function(String channelId)? onDisconnect;

  /// Initialize channels from configuration
  Future<void> initializeChannels(Map<String, ChannelConfig>? configs) async {
    if (configs == null) return;

    for (final entry in configs.entries) {
      await initChannel(entry.key, entry.value);
    }
  }

  /// Subscribe to channel data updates with a callback (per 12-channels.md §8.1).
  ///
  /// Returns a [StreamSubscription] that can be used with [unsubscribe].
  StreamSubscription? subscribe(String channelName, void Function(dynamic data) onData) {
    final controller = _controllers[channelName];
    if (controller == null) return null;
    return controller.stream.listen(onData);
  }

  /// Unsubscribe a previously registered subscription (per 12-channels.md §8.1).
  void unsubscribeListener(StreamSubscription subscription) {
    subscription.cancel();
  }

  /// Initialize and register a channel from config.
  ///
  /// Idempotent: if a channel with the same id is already registered, the
  /// call is a no-op. Channels are connection-scoped by default
  /// (autoDispose: false), so a page re-mount that redeclares the same
  /// channel must preserve a live Timer/subscription rather than tear it
  /// down and recreate it without autoStart.
  Future<void> initChannel(String channelId, ChannelConfig config) async {
    if (_channels.containsKey(channelId)) {
      return;
    }

    // Store config for restart support
    _channelConfigs[channelId] = config;
    _channelStates[channelId] = ChannelState.disconnected;
    _restartCounts[channelId] = 0;

    // Create channel based on type
    final channel = _createChannel(config);
    if (channel == null) {
      throw ArgumentError('Unknown channel type: ${config.type}');
    }

    _channels[channelId] = channel;

    // Track autoDispose flag (default true per spec §Channel Lifecycle)
    if (config.autoDispose) {
      _autoDisposeChannels.add(channelId);
    } else {
      _autoDisposeChannels.remove(channelId);
    }

    // Parse flow control config if present (spec §2277-2302)
    final flowControlJson = config.params?['flowControl'] as Map<String, dynamic>?;
    if (flowControlJson != null) {
      final flowControl = FlowControlConfig.fromJson(flowControlJson);
      _flowControlConfigs[channelId] = flowControl;

      if (flowControl.inbound != null) {
        _inboundChannelRateLimiters[channelId] = ChannelRateLimiter(flowControl.inbound!);
      }
      if (flowControl.outbound != null) {
        _outboundChannelRateLimiters[channelId] = ChannelRateLimiter(flowControl.outbound!);
      }
    }

    // Initialize sequence counter for message protocol
    _sequenceCounters[channelId] = 0;

    // Create stream controller for this channel
    final controller = StreamController<dynamic>.broadcast();
    _controllers[channelId] = controller;

    // Start listening to channel
    if (config.autoStart) {
      await _startChannel(channelId, channel, controller);
    }
  }

  /// Dispose and fully remove a channel by ID.
  Future<void> disposeChannel(String channelId) async {
    // Cancel subscription
    final subscription = _subscriptions.remove(channelId);
    await subscription?.cancel();

    // Stop and dispose channel
    final channel = _channels.remove(channelId);
    await channel?.stop();

    // Close controller
    final controller = _controllers.remove(channelId);
    await controller?.close();

    _channelStates[channelId] = ChannelState.stopped;
    onDisconnect?.call(channelId);
    _channelConfigs.remove(channelId);
    _restartCounts.remove(channelId);
    _autoDisposeChannels.remove(channelId);
    _flowControlConfigs.remove(channelId);
    _inboundChannelRateLimiters.remove(channelId)?.dispose();
    _outboundChannelRateLimiters.remove(channelId)?.dispose();
    _sequenceCounters.remove(channelId);
  }

  /// Dispose all channels that have autoDispose enabled.
  ///
  /// Called during page lifecycle onDestroy to clean up channels that were
  /// declared with autoDispose: true (the default per spec §Channel Lifecycle).
  Future<void> disposeAutoChannels() async {
    final toDispose = _autoDisposeChannels.toList();
    for (final channelId in toDispose) {
      _logger.debug('Auto-disposing channel: $channelId');
      await disposeChannel(channelId);
    }
  }

  /// Start a channel
  Future<void> startChannel(String channelId) async {
    final channel = _channels[channelId];
    final controller = _controllers[channelId];

    if (channel == null || controller == null) {
      throw StateError('Channel not found: $channelId');
    }

    await _startChannel(channelId, channel, controller);
  }

  /// Stop a channel
  Future<void> stopChannel(String channelId) async {
    final subscription = _subscriptions.remove(channelId);
    await subscription?.cancel();

    final channel = _channels[channelId];
    await channel?.stop();
  }

  /// Get stream for a channel
  Stream<dynamic>? getStream(String channelId) {
    return _controllers[channelId]?.stream;
  }

  /// Check if a channel exists
  bool hasChannel(String channelId) {
    return _channels.containsKey(channelId);
  }

  /// Get all channel IDs
  List<String> get channelIds => _channels.keys.toList();

  /// Restart a channel (stop then start)
  Future<void> restartChannel(String channelId) async {
    final channel = _channels[channelId];
    final controller = _controllers[channelId];

    if (channel == null || controller == null) {
      throw StateError('Channel not found: $channelId');
    }

    _logger.debug('Restarting channel: $channelId');

    // Stop current subscription
    final subscription = _subscriptions.remove(channelId);
    await subscription?.cancel();
    await channel.stop();

    _channelStates[channelId] = ChannelState.reconnecting;

    // Start again
    await _startChannel(channelId, channel, controller);
  }

  /// Send data to a channel (for bidirectional channels like WebSocket)
  Future<void> sendToChannel(String channelId, dynamic data) async {
    final channel = _channels[channelId];
    if (channel == null) {
      throw StateError('Channel not found: $channelId');
    }

    // Apply outbound rate limiting if configured (spec §2277-2302)
    final outboundLimiter = _outboundChannelRateLimiters[channelId];
    if (outboundLimiter != null && !outboundLimiter.tryEmit(data)) {
      _logger.debug('Channel $channelId outbound rate limit exceeded');
      return;
    }

    // Wrap in ChannelMessage protocol (spec §2160-2187)
    final seq = _sequenceCounters[channelId] ?? 0;
    _sequenceCounters[channelId] = seq + 1;
    final message = ChannelMessage.outbound(channelId, data, sequence: seq);

    if (channel is WebSocketChannel) {
      channel.send(message.payload);
    } else {
      _logger.debug('Channel $channelId does not support sending data');
    }
  }

  /// Get the current state of a channel
  ChannelState getChannelState(String channelId) {
    return _channelStates[channelId] ?? ChannelState.disconnected;
  }

  /// Toggle a channel on or off
  Future<void> toggleChannel(String channelId) async {
    final channel = _channels[channelId];
    if (channel == null) {
      throw StateError('Channel not found: $channelId');
    }

    if (channel.isActive) {
      await stopChannel(channelId);
    } else {
      await startChannel(channelId);
    }
  }

  /// Check if a channel is currently active
  bool isActive(String channelId) {
    final channel = _channels[channelId];
    return channel?.isActive ?? false;
  }

  /// Get data associated with a channel
  ///
  /// If [key] is provided, returns the value for that key from the channel data.
  /// Otherwise returns the full channel data map including latest data values.
  Map<String, dynamic>? getChannelData(String channelId, [String? key]) {
    if (!_channels.containsKey(channelId)) return null;

    final result = <String, dynamic>{
      'id': channelId,
      'active': isActive(channelId),
      'state': getChannelState(channelId).name,
      'hasSubscription': _subscriptions.containsKey(channelId),
    };

    // Include stored channel data values for binding resolution
    final data = _channelData[channelId];
    if (data is Map<String, dynamic>) {
      result.addAll(data);
    } else if (data != null) {
      result['value'] = data;
    }

    if (key != null) {
      final value = result[key];
      if (value == null) return null;
      return {key: value};
    }

    return result;
  }

  /// Dispose all channels
  Future<void> dispose() async {
    for (final channelId in _channels.keys.toList()) {
      await disposeChannel(channelId);
    }
  }

  /// Create a channel based on type
  Channel? _createChannel(ChannelConfig config) {
    switch (config.type) {
      case 'client.watchFile':
        return FileWatchChannel(
          path: config.params?['path'] as String? ?? '',
        );

      case 'client.watchDirectory':
        return DirectoryWatchChannel(
          path: config.params?['path'] as String? ?? '',
          recursive: config.params?['recursive'] as bool? ?? false,
        );

      case 'client.poll':
        return PollChannel(
          interval: config.params?['interval'] as int? ?? 5000,
          action: config.params?['action'] as Map<String, dynamic>?,
        );

      case 'client.systemMonitor':
        return SystemMonitorChannel(
          metrics: (config.params?['metrics'] as List<dynamic>?)
              ?.cast<String>(),
          interval: config.params?['interval'] as int? ?? 5000,
        );

      case 'client.websocket':
        return WebSocketChannel(
          url: config.params?['url'] as String? ?? '',
          protocols: (config.params?['protocols'] as List<dynamic>?)
              ?.cast<String>(),
          headers: (config.params?['headers'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v.toString())),
          autoReconnect: config.params?['autoReconnect'] as bool? ?? true,
          maxReconnectAttempts:
              config.params?['maxReconnectAttempts'] as int? ?? 5,
          reconnectDelay: config.params?['reconnectDelay'] as int? ?? 1000,
          heartbeatInterval:
              config.params?['heartbeatInterval'] as int?,
          heartbeatTimeout:
              config.params?['heartbeatTimeout'] as int?,
          heartbeatMessage:
              config.params?['heartbeatMessage'] as String?,
        );

      default:
        return null;
    }
  }

  /// Build a [BackpressureController] from a backpressure config map.
  ///
  /// Reads `overflowStrategy`, `bufferSize`, and `windowMs` (or `highWaterMark`
  /// as an alias for bufferSize) from the config map.
  BackpressureController? _buildBackpressureController(
      Map<String, dynamic>? bpConfig) {
    if (bpConfig == null) return null;

    final strategyStr =
        bpConfig['overflowStrategy'] as String? ?? bpConfig['strategy'] as String?;
    if (strategyStr == null) return null;

    final BackpressureStrategy strategy;
    switch (strategyStr) {
      case 'drop':
        strategy = BackpressureStrategy.drop;
        break;
      case 'latest':
        strategy = BackpressureStrategy.latest;
        break;
      case 'throttle':
        strategy = BackpressureStrategy.throttle;
        break;
      case 'debounce':
        strategy = BackpressureStrategy.debounce;
        break;
      case 'buffer':
      default:
        strategy = BackpressureStrategy.buffer;
    }

    // highWaterMark is treated as bufferSize (spec §Backpressure Control)
    final bufferSize = bpConfig['bufferSize'] as int? ??
        bpConfig['highWaterMark'] as int? ??
        100;
    final windowMs = bpConfig['windowMs'] as int? ?? 100;

    return BackpressureController(
      strategy: strategy,
      bufferSize: bufferSize,
      windowMs: windowMs,
    );
  }

  /// Start a channel and begin listening
  Future<void> _startChannel(
    String channelId,
    Channel channel,
    StreamController<dynamic> controller,
  ) async {
    try {
      _channelStates[channelId] = ChannelState.connecting;

      await channel.start();

      _channelStates[channelId] = ChannelState.connected;
      _restartCounts[channelId] = 0;
      _logger.debug('Channel started: $channelId');
      onConnect?.call(channelId);

      final config = _channelConfigs[channelId];
      final restartOnError = config?.params?['restartOnError'] as bool? ?? false;
      final maxRestarts = config?.params?['maxRestarts'] as int? ?? 3;

      // Apply backpressure if configured (spec §Backpressure Control)
      final bpController =
          _buildBackpressureController(config?.backpressure);
      Stream<dynamic> dataStream = bpController != null
          ? bpController.apply(channel.stream)
          : channel.stream;

      // Apply inbound rate limiting if configured (spec §2277-2302)
      final inboundLimiter = _inboundChannelRateLimiters[channelId];
      if (inboundLimiter != null) {
        dataStream = inboundLimiter.applyToStream(dataStream);
      }

      final subscription = dataStream.listen(
        (data) {
          // Wrap raw data in ChannelMessage protocol (spec §2160-2187)
          final seq = _sequenceCounters[channelId] ?? 0;
          _sequenceCounters[channelId] = seq + 1;
          final message = ChannelMessage.inbound(
            channelId,
            data,
            sequence: seq,
          );

          // Store payload for binding resolution (backward compatible)
          _channelData[channelId] = message.payload;
          controller.add(message.payload);
          onData?.call(channelId, message.payload);
        },
        onError: (error) {
          controller.addError(error);
          onError?.call(channelId, error);
          _channelStates[channelId] = ChannelState.disconnected;

          // Auto-restart on error if configured (CH-03, CH-06)
          if (restartOnError) {
            final currentRestarts = _restartCounts[channelId] ?? 0;
            if (currentRestarts < maxRestarts) {
              _restartCounts[channelId] = currentRestarts + 1;
              _channelStates[channelId] = ChannelState.reconnecting;
              _logger.debug(
                  'Channel $channelId error, restarting (${currentRestarts + 1}/$maxRestarts)');

              final restartDelay =
                  config?.params?['restartDelay'] as int? ?? 1000;
              final backoff =
                  config?.params?['restartBackoff'] as String? ?? 'fixed';
              final int delay;
              if (backoff == 'exponential') {
                delay = restartDelay * (1 << currentRestarts);
              } else if (backoff == 'linear') {
                delay = restartDelay * (currentRestarts + 1);
              } else {
                // 'fixed' (default per spec): constant delay
                delay = restartDelay;
              }

              Future.delayed(Duration(milliseconds: delay), () {
                if (_channels.containsKey(channelId)) {
                  _startChannel(channelId, channel, controller);
                }
              });
            } else {
              _channelStates[channelId] = ChannelState.failed;
              _logger.debug(
                  'Channel $channelId max restarts exceeded ($maxRestarts)');
            }
          }
        },
      );

      _subscriptions[channelId] = subscription;
    } catch (e) {
      _channelStates[channelId] = ChannelState.failed;
      onError?.call(channelId, e);
      rethrow;
    }
  }
}

/// Base class for channels
abstract class Channel {
  /// Start the channel
  Future<void> start();

  /// Stop the channel
  Future<void> stop();

  /// Get the data stream
  Stream<dynamic> get stream;

  /// Whether the channel is active
  bool get isActive;
}

/// Backpressure strategy for channel data flow control (CH-07)
enum BackpressureStrategy {
  /// Buffer events up to a limit, then drop oldest
  buffer,

  /// Drop new events when buffer is full
  drop,

  /// Only keep the latest event
  latest,

  /// Throttle events by time interval
  throttle,

  /// Debounce events by time interval
  debounce,
}

/// Controls backpressure for channel streams (CH-07)
///
/// Wraps a source stream and applies a backpressure strategy to prevent
/// overwhelming consumers when data arrives faster than it can be processed.
class BackpressureController {
  /// The backpressure strategy to apply
  final BackpressureStrategy strategy;

  /// Buffer size limit (for buffer/drop strategies)
  final int bufferSize;

  /// Time window in milliseconds (for throttle/debounce strategies)
  final int windowMs;

  BackpressureController({
    this.strategy = BackpressureStrategy.buffer,
    this.bufferSize = 100,
    this.windowMs = 100,
  });

  /// Apply backpressure to a source stream
  Stream<dynamic> apply(Stream<dynamic> source) {
    switch (strategy) {
      case BackpressureStrategy.buffer:
        return _applyBuffer(source);
      case BackpressureStrategy.drop:
        return _applyDrop(source);
      case BackpressureStrategy.latest:
        return _applyLatest(source);
      case BackpressureStrategy.throttle:
        return _applyThrottle(source);
      case BackpressureStrategy.debounce:
        return _applyDebounce(source);
    }
  }

  Stream<dynamic> _applyBuffer(Stream<dynamic> source) {
    final buffer = <dynamic>[];
    late StreamController<dynamic> controller;

    controller = StreamController<dynamic>.broadcast(
      onListen: () {
        source.listen(
          (data) {
            if (buffer.length >= bufferSize) {
              buffer.removeAt(0); // Drop oldest
            }
            buffer.add(data);
            controller.add(data);
          },
          onError: controller.addError,
          onDone: controller.close,
        );
      },
    );

    return controller.stream;
  }

  Stream<dynamic> _applyDrop(Stream<dynamic> source) {
    int count = 0;
    late StreamController<dynamic> controller;

    controller = StreamController<dynamic>.broadcast(
      onListen: () {
        source.listen(
          (data) {
            if (count < bufferSize) {
              count++;
              controller.add(data);
            }
            // Drop if buffer is full; count resets are handled externally
          },
          onError: controller.addError,
          onDone: controller.close,
        );
      },
    );

    return controller.stream;
  }

  Stream<dynamic> _applyLatest(Stream<dynamic> source) {
    late StreamController<dynamic> controller;
    bool scheduled = false;
    dynamic latest;

    controller = StreamController<dynamic>.broadcast(
      onListen: () {
        source.listen(
          (data) {
            latest = data;
            if (!scheduled) {
              scheduled = true;
              Future.microtask(() {
                scheduled = false;
                controller.add(latest);
              });
            }
          },
          onError: controller.addError,
          onDone: controller.close,
        );
      },
    );

    return controller.stream;
  }

  Stream<dynamic> _applyThrottle(Stream<dynamic> source) {
    late StreamController<dynamic> controller;
    DateTime? lastEmit;

    controller = StreamController<dynamic>.broadcast(
      onListen: () {
        source.listen(
          (data) {
            final now = DateTime.now();
            if (lastEmit == null ||
                now.difference(lastEmit!).inMilliseconds >= windowMs) {
              lastEmit = now;
              controller.add(data);
            }
          },
          onError: controller.addError,
          onDone: controller.close,
        );
      },
    );

    return controller.stream;
  }

  Stream<dynamic> _applyDebounce(Stream<dynamic> source) {
    late StreamController<dynamic> controller;
    Timer? debounceTimer;

    controller = StreamController<dynamic>.broadcast(
      onListen: () {
        source.listen(
          (data) {
            debounceTimer?.cancel();
            debounceTimer = Timer(
              Duration(milliseconds: windowMs),
              () => controller.add(data),
            );
          },
          onError: controller.addError,
          onDone: () {
            debounceTimer?.cancel();
            controller.close();
          },
        );
      },
    );

    return controller.stream;
  }
}

/// Ensures message ordering for channel streams (CH-08)
///
/// Reorders out-of-order messages based on a sequence number field
/// in the message data. Buffers messages that arrive out of order
/// and emits them once the expected sequence is available.
class MessageOrderer {
  /// The key in the message map that contains the sequence number
  final String sequenceKey;

  /// Maximum number of out-of-order messages to buffer
  final int maxBuffer;

  /// Timeout in milliseconds before flushing buffered messages regardless of order
  final int flushTimeoutMs;

  MessageOrderer({
    this.sequenceKey = 'seq',
    this.maxBuffer = 50,
    this.flushTimeoutMs = 5000,
  });

  /// Apply message ordering to a source stream
  ///
  /// Messages with a sequence number field are reordered.
  /// Messages without a sequence number are passed through immediately.
  Stream<dynamic> apply(Stream<dynamic> source) {
    int expectedSeq = 0;
    final buffer = <int, dynamic>{};
    Timer? flushTimer;
    late StreamController<dynamic> controller;

    void emitInOrder() {
      while (buffer.containsKey(expectedSeq)) {
        controller.add(buffer.remove(expectedSeq));
        expectedSeq++;
      }
    }

    void flushAll() {
      if (buffer.isEmpty) return;
      final keys = buffer.keys.toList()..sort();
      for (final key in keys) {
        controller.add(buffer.remove(key));
      }
      if (keys.isNotEmpty) {
        expectedSeq = keys.last + 1;
      }
    }

    void resetFlushTimer() {
      flushTimer?.cancel();
      if (buffer.isNotEmpty) {
        flushTimer = Timer(
          Duration(milliseconds: flushTimeoutMs),
          flushAll,
        );
      }
    }

    controller = StreamController<dynamic>.broadcast(
      onListen: () {
        source.listen(
          (data) {
            // If message has no sequence number, pass through
            if (data is! Map<String, dynamic> ||
                !data.containsKey(sequenceKey)) {
              controller.add(data);
              return;
            }

            final seq = data[sequenceKey] as int?;
            if (seq == null) {
              controller.add(data);
              return;
            }

            if (seq == expectedSeq) {
              controller.add(data);
              expectedSeq++;
              emitInOrder();
            } else if (seq > expectedSeq) {
              buffer[seq] = data;
              // Flush oldest if buffer exceeds limit
              if (buffer.length > maxBuffer) {
                flushAll();
              }
              resetFlushTimer();
            }
            // seq < expectedSeq means duplicate, drop it
          },
          onError: controller.addError,
          onDone: () {
            flushTimer?.cancel();
            flushAll();
            controller.close();
          },
        );
      },
      onCancel: () {
        flushTimer?.cancel();
      },
    );

    return controller.stream;
  }
}
