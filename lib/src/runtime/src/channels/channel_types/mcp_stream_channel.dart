/// MCP server-pushed stream channel for MCP UI DSL (`client.mcpStream`).
///
/// Unlike `client.poll` (the client re-invokes an action on an interval) or
/// `client.websocket` (a raw socket that lives outside MCP), this channel
/// subscribes to a host-provided MCP stream source identified by [uri] and
/// forwards every server push as a channel message. The source is opened by a
/// resolver the host registers with the runtime (`registerStreamSource`),
/// keyed off the uri scheme — the runtime itself stays transport-agnostic and
/// never learns what a `ble://` or `sensor://` stream actually is.
///
/// This closes the gap left by the other five channel types: none of them can
/// carry an MCP-server-initiated live stream (advertisements, sensor frames,
/// notifications) with channel ergonomics (lifecycle, backpressure, callbacks).
library mcp_stream_channel;

import 'dart:async';

import '../channel_manager.dart';

/// Resolves a stream-source [uri] (with subscribe [params]) to a live stream,
/// or `null` when no source is registered for the uri's scheme.
typedef StreamSourceResolver = Stream<dynamic>? Function(
  String uri,
  Map<String, dynamic> params,
);

/// A channel whose data is pushed by a host-registered MCP stream source.
class McpStreamChannel implements Channel {
  /// Stream-source URI to subscribe (e.g. `ble://scan`). The scheme selects
  /// the registered source; the rest is source-specific.
  final String uri;

  /// Subscribe parameters passed to the source (e.g. a scan filter).
  final Map<String, dynamic> params;

  /// Opens the underlying source stream for [uri]/[params].
  final StreamSourceResolver open;

  StreamController<dynamic>? _controller;
  StreamSubscription<dynamic>? _sourceSub;
  bool _isActive = false;

  McpStreamChannel({
    required this.uri,
    required this.open,
    this.params = const {},
  });

  @override
  Future<void> start() async {
    if (_isActive) return;

    final source = open(uri, params);
    if (source == null) {
      throw StateError('No stream source registered for uri: $uri');
    }

    _controller = StreamController<dynamic>.broadcast();
    _sourceSub = source.listen(
      (data) => _controller?.add(data),
      onError: (Object e) => _controller?.addError(e),
    );

    _isActive = true;
  }

  @override
  Future<void> stop() async {
    _isActive = false;
    await _sourceSub?.cancel();
    _sourceSub = null;
    await _controller?.close();
    _controller = null;
  }

  @override
  Stream<dynamic> get stream => _controller?.stream ?? const Stream.empty();

  @override
  bool get isActive => _isActive;
}
