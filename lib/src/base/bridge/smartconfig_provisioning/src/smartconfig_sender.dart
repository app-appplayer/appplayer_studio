// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/smartconfig_provisioning/lib/src/smartconfig_sender.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
import 'dart:async';

import 'smartconfig_codec.dart';
import 'smartconfig_models.dart';

/// Seam over the two UDP sockets SmartConfig needs — a broadcast sender
/// (target 255.255.255.255:7001) and an ACK listener (port 18266) — so
/// [SmartConfigSender] is pure Dart and unit-testable without a network,
/// mirroring how softap_provisioning injects `http.Client`. The concrete
/// dart:io implementation is [UdpSmartConfigTransport].
abstract class SmartConfigTransport {
  /// Send one UDP datagram to the broadcast target. Only [payload]'s LENGTH
  /// carries information on the air.
  void sendBroadcast(List<int> payload);

  /// Datagrams arriving on the ACK listen port (18266).
  Stream<List<int>> get ackDatagrams;

  /// The host's IPv4 on the target network (4 bytes), encoded into the datum
  /// so the device knows where to unicast its ACK.
  List<int> get localIpv4;

  Future<void> close();
}

/// Pure-Dart ESP-Touch v1 credential sender: repeats guide-code bursts and
/// datum-code rounds (credentials encoded as datagram LENGTHS) until the
/// device ACKs on port 18266 or [provision] times out. Timing defaults match
/// the reference `EsptouchTaskParameter` (8 ms between datagrams, 2 s guide
/// phase, 4 s data phase per round).
class SmartConfigSender {
  SmartConfigSender({
    required this.transport,
    this.sendInterval = const Duration(milliseconds: 8),
    this.guidePhase = const Duration(milliseconds: 2000),
    this.dataPhase = const Duration(milliseconds: 4000),
  });

  final SmartConfigTransport transport;

  /// Delay between consecutive datagrams (guide and datum alike).
  final Duration sendInterval;

  /// How long each round repeats the 515/514/513/512 guide burst.
  final Duration guidePhase;

  /// How long each round cycles datum codes before re-sending the guide.
  final Duration dataPhase;

  /// Broadcast the credentials until the device ACKs with its MAC + IP, or
  /// throw [TimeoutException] after [timeout]. [bssid] narrows which AP the
  /// device matches ('' = match on SSID alone).
  Future<SmartConfigResult> provision({
    required String ssid,
    required String password,
    String bssid = '',
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final datum = buildDatumLengths(
      ssid: ssid,
      password: password,
      bssid: bssid,
      localIp: transport.localIpv4,
    );
    final expected = expectedAckLength(ssid, password);

    final completer = Completer<SmartConfigResult>();
    final sub = transport.ackDatagrams.listen((datagram) {
      final result =
          SmartConfigResult.tryParseAck(datagram, expectedLength: expected);
      if (result != null && !completer.isCompleted) {
        completer.complete(result);
      }
    });

    var stopped = false;
    final sendLoop = _sendLoop(datum, () => stopped);
    try {
      return await completer.future.timeout(timeout);
    } finally {
      stopped = true;
      await sub.cancel();
      await sendLoop;
    }
  }

  /// Reference `__EsptouchTask.__execute`: each round sends the guide burst
  /// for [guidePhase], then cycles the datum lengths in groups of 3 (one data
  /// code = 3 datagrams) for [dataPhase], and repeats until stopped.
  Future<void> _sendLoop(List<int> datum, bool Function() stopped) async {
    var index = 0;
    while (!stopped()) {
      final guideClock = Stopwatch()..start();
      while (!stopped() && guideClock.elapsed < guidePhase) {
        for (final length in guideCodeLengths) {
          if (stopped()) return;
          transport.sendBroadcast(payloadOfLength(length));
          await Future<void>.delayed(sendInterval);
        }
      }
      final dataClock = Stopwatch()..start();
      while (!stopped() && dataClock.elapsed < dataPhase) {
        for (var i = 0; i < 3; i++) {
          if (stopped()) return;
          transport.sendBroadcast(
              payloadOfLength(datum[(index + i) % datum.length]));
          await Future<void>.delayed(sendInterval);
        }
        index = (index + 3) % datum.length;
      }
    }
  }
}
