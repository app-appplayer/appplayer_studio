// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/device_discovery/lib/src/tcp_probe_transport.dart
// Regenerate with debug/tool/sync_discovery_forks.sh.
//
import 'dart:async';
import 'dart:io';

import 'package:mcp_client/mcp_client.dart' show ClientTransport;

import 'newline_json_framer.dart';

/// Minimal MCP [ClientTransport] over raw TCP with newline-delimited
/// JSON-RPC framing — the `proto=ndjson` binding of
/// `specs/platform/17-device-discovery.md` §3 (embedded board contract,
/// `specs/embedded/` §3).
///
/// Self-contained on purpose: the probe path must stay pure Dart with no
/// bridge/FFI baggage, so this transport is implemented here instead of
/// importing `mcp_bridge`.
class TcpProbeTransport implements ClientTransport {
  TcpProbeTransport({
    required this.host,
    required this.port,
    this.connectTimeout = const Duration(seconds: 5),
  });

  final String host;
  final int port;
  final Duration connectTimeout;

  Socket? _socket;
  StreamSubscription<List<int>>? _byteSub;
  bool _closed = false;

  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  late final NewlineJsonFramer _framer = NewlineJsonFramer(
    onMessage: _messageController.add,
    onError: _messageController.addError,
  );

  /// Connect the socket. Must complete before the transport is handed to
  /// an mcp_client `Client`.
  ///
  /// Uses `startConnect` + explicit timeout instead of
  /// `Socket.connect(timeout:)` — the latter's internal abort can leave the
  /// attempt's late failure (e.g. a peer RST racing the timer) with no
  /// listener, which surfaces as an unhandled async error in the caller's
  /// zone.
  Future<void> start() async {
    if (_socket != null) return;
    if (_closed) throw StateError('tcp probe transport already closed');
    final task = await Socket.startConnect(host, port);
    final Socket socket;
    try {
      socket = await task.socket.timeout(connectTimeout);
    } on TimeoutException {
      task.cancel();
      // The cancelled attempt may still settle later; consume it so nothing
      // escapes to the zone.
      unawaited(task.socket.then<void>((s) => s.destroy(), onError: (_) {}));
      rethrow;
    }
    _socket = socket;
    _byteSub = socket.listen(
      _framer.feed,
      onError: _messageController.addError,
      onDone: _handleClosed,
      cancelOnError: false,
    );
  }

  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) {
    final socket = _socket;
    if (socket == null) {
      throw StateError(
        'tcp probe transport not started — call start() before send()',
      );
    }
    if (_closed) throw StateError('tcp probe transport is closed');
    socket.add(NewlineJsonFramer.encodeFrame(message));
  }

  @override
  void close() {
    if (_closed) return;
    _byteSub?.cancel();
    _byteSub = null;
    _socket?.destroy();
    _socket = null;
    _handleClosed();
  }

  void _handleClosed() {
    _closed = true;
    if (!_closeCompleter.isCompleted) _closeCompleter.complete();
    if (!_messageController.isClosed) _messageController.close();
  }
}
