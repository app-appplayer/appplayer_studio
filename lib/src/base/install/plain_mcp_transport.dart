/// A client transport that speaks plain MCP JSON-RPC over a relay channel.
///
/// The Arche lane carries ordinary MCP messages on the relay socket (the
/// market hubs carry the hub wire instead), so the MCP client talks to it
/// directly: every message is one frame, in both directions.
library;

import 'dart:async';

import 'package:mcp_client/mcp_client.dart';

import 'hub_connections.dart' show HubChannel;

class PlainMcpTransport implements ClientTransport {
  PlainMcpTransport(this._channel) {
    _sub = _channel.incoming.listen(
      (m) {
        if (!_out.isClosed) _out.add(m);
      },
      onDone: _end,
      onError: (Object _) => _end(),
    );
    unawaited(_channel.done.then((_) => _end(), onError: (Object _) => _end()));
  }

  final HubChannel _channel;
  final StreamController<dynamic> _out = StreamController<dynamic>.broadcast();
  final Completer<void> _closed = Completer<void>();
  late final StreamSubscription<Map<String, dynamic>> _sub;

  @override
  Stream<dynamic> get onMessage => _out.stream;

  @override
  Future<void> get onClose => _closed.future;

  @override
  void send(dynamic message) {
    if (_closed.isCompleted) return;
    unawaited(
      _channel
          .send((message as Map).cast<String, dynamic>())
          .catchError((Object _) {}),
    );
  }

  void _end() {
    if (!_closed.isCompleted) _closed.complete();
    if (!_out.isClosed) unawaited(_out.close());
  }

  @override
  void close() {
    unawaited(_sub.cancel());
    _end();
  }
}
