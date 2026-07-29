// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_transport/lib/src/ble_client_transport.dart
// Regenerate with debug/tool/sync_discovery_forks.sh.
//
import 'dart:async';
import 'dart:math' as math;

import 'package:mcp_client/mcp_client.dart' show ClientTransport;

import 'ble_link.dart';
import 'ble_uuids.dart';
import 'newline_json_framer.dart';

/// MCP [ClientTransport] over the BLE GATT binding.
///
/// Pure Dart: all radio access goes through the injected [BleLink]
/// (see `FlutterBluePlusLink` for the real radio; tests use a fake).
///
/// [start] performs the connection sequence:
/// 1. connect (GATT central to the board's peripheral),
/// 2. try to negotiate ATT MTU >= [desiredMtu] (SHOULD; failure is
///    non-fatal — the transport keeps working at the default MTU 23),
/// 3. subscribe TX-characteristic notifications (CCCD) and feed every
///    received chunk into the newline framer. Nothing is sent before this
///    subscription is in place.
///
/// [send] encodes `jsonEncode(message) + '\n'` and writes it to
/// the RX characteristic in chunks of at most `ATT_MTU - 3` bytes, in
/// order (chunk boundaries carry no semantics on either side).
class BleClientTransport implements ClientTransport {
  BleClientTransport({
    required BleLink link,
    int desiredMtu = bleDesiredAttMtu,
  })  : _link = link,
        _desiredMtu = desiredMtu;

  final BleLink _link;
  final int _desiredMtu;

  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  late final NewlineJsonFramer _framer = NewlineJsonFramer(
    onMessage: _messageController.add,
    onError: _emitError,
  );

  StreamSubscription<List<int>>? _notifySub;
  Future<void> _writeQueue = Future<void>.value();
  int _maxChunkSize = bleDefaultAttMtu - bleAttHeaderOverhead;
  bool _started = false;
  bool _closed = false;

  /// Effective payload size per GATT write after [start]
  /// (`ATT_MTU - 3`).
  int get maxChunkSize => _maxChunkSize;

  /// Connect, negotiate MTU, subscribe notifications. Must complete before
  /// [send] is usable (and before injecting into the kernel seam).
  Future<void> start() async {
    if (_started) return;
    if (_closed) throw StateError('ble client transport already closed');

    await _link.connect();

    // SHOULD try MTU >= 247; MUST still work at the default 23.
    int mtu;
    try {
      mtu = await _link.requestMtu(_desiredMtu);
    } catch (_) {
      mtu = bleDefaultAttMtu;
    }
    if (mtu < bleDefaultAttMtu) mtu = bleDefaultAttMtu;
    _maxChunkSize = mtu - bleAttHeaderOverhead;

    // CCCD subscription first — the server sends nothing before
    // it, and this transport sends nothing before it either (send() is
    // gated on _started, which only flips after this line).
    final notifications = await _link.subscribeTxNotifications();
    _notifySub = notifications.listen(
      _framer.feed,
      onError: _emitError,
      onDone: _handleClosed,
      cancelOnError: false,
    );
    unawaited(_link.onDisconnected.then((_) => _handleClosed()));

    _started = true;
  }

  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) {
    if (!_started) {
      throw StateError(
        'ble client transport not started — call start() before send() '
        '(no bytes may go out before the CCCD subscription is in place)',
      );
    }
    if (_closed) {
      throw StateError('ble client transport is closed');
    }
    final frame = NewlineJsonFramer.encodeFrame(message);
    // Serialize chunk writes: GATT writes are async but ClientTransport
    // send() is sync, so writes are chained on a queue to preserve stream
    // order across messages and across chunks of one message.
    _writeQueue = _writeQueue.then((_) async {
      for (var offset = 0; offset < frame.length; offset += _maxChunkSize) {
        final end = math.min(offset + _maxChunkSize, frame.length);
        await _link.writeRxChunk(frame.sublist(offset, end));
      }
    }).catchError((Object error, StackTrace stack) {
      _emitError(error, stack);
    });
  }

  /// Error sink that stays safe across teardown: a GATT write still in
  /// flight when the transport closes must not addError into the already
  /// closed message controller (that would surface as an unhandled async
  /// StateError instead of a transport error).
  void _emitError(Object error, StackTrace stack) {
    if (!_messageController.isClosed) {
      _messageController.addError(error, stack);
    }
  }

  @override
  void close() {
    if (_closed) return;
    unawaited(_link.disconnect().catchError((_) {}));
    _handleClosed();
  }

  void _handleClosed() {
    if (_closed) return;
    _closed = true;
    _notifySub?.cancel();
    _notifySub = null;
    if (!_closeCompleter.isCompleted) _closeCompleter.complete();
    if (!_messageController.isClosed) _messageController.close();
  }
}
