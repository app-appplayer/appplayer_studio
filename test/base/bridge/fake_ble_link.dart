/// Copied from the canonical recipe's test support
/// (`os/core/brain_kernel/recipes/ble_transport/test/ (via appplayer standard)`) — the radio-free
/// [BleLink] fake used to exercise the BLE transport without hardware.
/// Keep faithful to the recipe.
library;

import 'dart:async';

import 'package:appplayer_studio/src/base/bridge/ble_transport/ble_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory [BleLink]: records the call order and every written chunk;
/// the test injects notification bytes and connection loss.
class FakeBleLink implements BleLink {
  final List<String> log = <String>[];
  final List<List<int>> writes = <List<int>>[];
  final StreamController<List<int>> _notify =
      StreamController<List<int>>.broadcast();
  final Completer<void> _disconnected = Completer<void>();

  /// ATT MTU returned by [requestMtu] (unless [mtuError] is set).
  int negotiatedMtu = 247;

  /// When set, [requestMtu] throws it (negotiation failure path).
  Object? mtuError;

  bool _subscribed = false;

  /// Simulate the board notifying [bytes] on the TX characteristic.
  void notifyBytes(List<int> bytes) => _notify.add(bytes);

  /// Simulate connection loss.
  void dropConnection() {
    if (!_disconnected.isCompleted) _disconnected.complete();
    if (!_notify.isClosed) _notify.close();
  }

  /// All chunks written so far, concatenated back into the byte stream
  /// (spec 4: chunk boundaries carry no semantics).
  List<int> get writtenStream => writes.expand((c) => c).toList();

  @override
  Future<void> connect() async {
    log.add('connect');
  }

  @override
  Future<int> requestMtu(int desired) async {
    log.add('requestMtu($desired)');
    final error = mtuError;
    if (error != null) throw error;
    return negotiatedMtu;
  }

  @override
  Future<Stream<List<int>>> subscribeTxNotifications() async {
    log.add('subscribe');
    _subscribed = true;
    return _notify.stream;
  }

  @override
  Future<void> writeRxChunk(List<int> chunk) async {
    log.add('write(${chunk.length})');
    if (!_subscribed) {
      throw StateError('protocol violation: write before CCCD subscription');
    }
    writes.add(List<int>.from(chunk));
  }

  @override
  Future<void> get onDisconnected => _disconnected.future;

  @override
  Future<void> disconnect() async {
    log.add('disconnect');
    dropConnection();
  }
}

/// Decode the fake link's written byte stream into JSON-RPC messages
/// (what a conformant board would parse out of the RX writes).
List<dynamic> decodeWrittenMessages(FakeBleLink link) {
  final messages = <dynamic>[];
  final framer = NewlineJsonFramer(
    onMessage: messages.add,
    onError: (error, stack) => fail('malformed frame on wire: $error'),
  );
  framer.feed(link.writtenStream);
  return messages;
}
