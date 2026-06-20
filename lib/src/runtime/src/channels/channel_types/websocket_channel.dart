/// WebSocket channel for MCP UI DSL v1.1
///
/// Bidirectional WebSocket communication channel.
library websocket_channel;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../channel_manager.dart';

/// Channel that provides WebSocket bidirectional communication
class WebSocketChannel implements Channel {
  /// WebSocket URL
  final String url;

  /// Sub-protocols
  final List<String>? protocols;

  /// Custom headers
  final Map<String, String>? headers;

  /// Whether to automatically reconnect on disconnect
  final bool autoReconnect;

  /// Maximum reconnection attempts
  final int maxReconnectAttempts;

  /// Reconnection delay in milliseconds
  final int reconnectDelay;

  /// Heartbeat interval in milliseconds (null to disable)
  final int? heartbeatInterval;

  /// Heartbeat timeout in milliseconds before considering connection lost
  final int? heartbeatTimeout;

  /// Heartbeat message to send (defaults to 'ping')
  final String? heartbeatMessage;

  WebSocket? _socket;
  StreamController<dynamic>? _controller;
  bool _isActive = false;
  int _reconnectCount = 0;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  Timer? _heartbeatTimeoutTimer;

  WebSocketChannel({
    required this.url,
    this.protocols,
    this.headers,
    this.autoReconnect = true,
    this.maxReconnectAttempts = 5,
    this.reconnectDelay = 1000,
    this.heartbeatInterval,
    this.heartbeatTimeout,
    this.heartbeatMessage,
  });

  @override
  Future<void> start() async {
    if (_isActive) return;

    _controller = StreamController<dynamic>.broadcast();
    _reconnectCount = 0;

    await _connect();
  }

  @override
  Future<void> stop() async {
    _isActive = false;
    _stopHeartbeat();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    await _socket?.close();
    _socket = null;

    await _controller?.close();
    _controller = null;
  }

  @override
  Stream<dynamic> get stream =>
      _controller?.stream ?? const Stream.empty();

  @override
  bool get isActive => _isActive;

  /// Send data through the WebSocket
  void send(dynamic data) {
    if (_socket == null || !_isActive) {
      throw StateError('WebSocket is not connected');
    }

    if (data is Map || data is List) {
      _socket!.add(jsonEncode(data));
    } else {
      _socket!.add(data.toString());
    }
  }

  /// Connect to the WebSocket server
  Future<void> _connect() async {
    try {
      _socket = await WebSocket.connect(
        url,
        protocols: protocols,
        headers: headers,
      );

      _isActive = true;
      _reconnectCount = 0;
      _startHeartbeat();

      _controller?.add({
        'type': 'connected',
        'url': url,
        'timestamp': DateTime.now().toIso8601String(),
      });

      _socket!.listen(
        (data) {
          _resetHeartbeatTimeout();
          dynamic parsed = data;
          if (data is String) {
            try {
              parsed = jsonDecode(data);
            } catch (_) {
              // Keep as string if not valid JSON
            }
          }

          _controller?.add({
            'type': 'message',
            'data': parsed,
            'timestamp': DateTime.now().toIso8601String(),
          });
        },
        onError: (error) {
          _controller?.addError(error);
        },
        onDone: () {
          _isActive = false;
          _controller?.add({
            'type': 'disconnected',
            'url': url,
            'code': _socket?.closeCode,
            'reason': _socket?.closeReason,
            'timestamp': DateTime.now().toIso8601String(),
          });

          if (autoReconnect &&
              _reconnectCount < maxReconnectAttempts) {
            _scheduleReconnect();
          }
        },
      );
    } catch (e) {
      _controller?.addError(e);

      if (autoReconnect &&
          _reconnectCount < maxReconnectAttempts) {
        _scheduleReconnect();
      }
    }
  }

  /// Start periodic heartbeat pings
  void _startHeartbeat() {
    if (heartbeatInterval == null || heartbeatInterval! <= 0) return;

    _heartbeatTimer = Timer.periodic(
      Duration(milliseconds: heartbeatInterval!),
      (_) {
        if (_isActive && _socket != null) {
          final msg = heartbeatMessage ?? 'ping';
          _socket!.add(msg);

          // Set timeout for heartbeat response
          if (heartbeatTimeout != null && heartbeatTimeout! > 0) {
            _heartbeatTimeoutTimer?.cancel();
            _heartbeatTimeoutTimer = Timer(
              Duration(milliseconds: heartbeatTimeout!),
              () {
                _controller?.addError('Heartbeat timeout');
                if (autoReconnect) {
                  _stopHeartbeat();
                  _scheduleReconnect();
                }
              },
            );
          }
        }
      },
    );
  }

  /// Stop heartbeat timers
  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatTimeoutTimer?.cancel();
    _heartbeatTimeoutTimer = null;
  }

  /// Reset the heartbeat timeout (called when any data is received)
  void _resetHeartbeatTimeout() {
    _heartbeatTimeoutTimer?.cancel();
    _heartbeatTimeoutTimer = null;
  }

  /// Schedule a reconnection attempt
  void _scheduleReconnect() {
    _reconnectCount++;
    final delay = reconnectDelay * _reconnectCount;

    _reconnectTimer = Timer(
      Duration(milliseconds: delay),
      () async {
        _controller?.add({
          'type': 'reconnecting',
          'attempt': _reconnectCount,
          'maxAttempts': maxReconnectAttempts,
          'timestamp': DateTime.now().toIso8601String(),
        });

        await _connect();
      },
    );
  }
}
