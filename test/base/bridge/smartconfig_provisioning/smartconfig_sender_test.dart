// VENDORED COPY of the recipe's test — do not hand-edit. Canonical:
//   os/core/brain_kernel/recipes/smartconfig_provisioning/test/smartconfig_sender_test.dart
// Re-vendor alongside debug/tool/sync_provisioning_forks.sh runs.
//
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/bridge/smartconfig_provisioning/smartconfig_provisioning.dart';

/// In-memory transport: records every sent datagram and lets the test script
/// inbound ACK datagrams — no real sockets, mirroring how softap tests
/// substitute MockClient for http.Client.
class FakeTransport implements SmartConfigTransport {
  final sent = <List<int>>[];
  final _acks = StreamController<List<int>>.broadcast();
  void Function(int sentCount)? onSend;

  @override
  List<int> get localIpv4 => const [192, 168, 4, 2];

  @override
  void sendBroadcast(List<int> payload) {
    sent.add(payload);
    onSend?.call(sent.length);
  }

  @override
  Stream<List<int>> get ackDatagrams => _acks.stream;

  void receiveAck(List<int> datagram) => _acks.add(datagram);

  @override
  Future<void> close() => _acks.close();
}

SmartConfigSender fastSender(FakeTransport transport) => SmartConfigSender(
      transport: transport,
      sendInterval: const Duration(milliseconds: 1),
      guidePhase: const Duration(milliseconds: 8),
      dataPhase: const Duration(milliseconds: 12),
    );

void main() {
  test('send loop leads with the 515,514,513,512 guide burst', () async {
    final transport = FakeTransport();
    final sender = fastSender(transport);
    await expectLater(
      sender.provision(
        ssid: 'home',
        password: 's3cret',
        timeout: const Duration(milliseconds: 40),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(transport.sent.length, greaterThanOrEqualTo(4));
    expect(transport.sent.take(4).map((p) => p.length), [515, 514, 513, 512]);
    // Only the length matters on the air; payloads are ASCII '1' filler.
    expect(transport.sent.first.toSet(), {0x31});
  });

  test('send loop advances into datum codes after the guide phase', () async {
    final transport = FakeTransport();
    final sender = fastSender(transport);
    await expectLater(
      sender.provision(
        ssid: 'home',
        password: 's3cret',
        timeout: const Duration(milliseconds: 80),
      ),
      throwsA(isA<TimeoutException>()),
    );
    // The first datum code carries sequence index 0, whose middle datagram
    // length is 0x100 + 0 + 40 = 296 — well below the 512..515 guide band.
    expect(transport.sent.map((p) => p.length), contains(296));
  });

  test('provision completes with mac/ip from a valid ACK, ignoring noise',
      () async {
    final transport = FakeTransport();
    transport.onSend = (count) {
      if (count == 2) {
        transport.receiveAck([1, 2, 3]); // wrong size — ignored
        // Right size, wrong length byte (someone else's session) — ignored.
        transport
            .receiveAck([7, 1, 2, 3, 4, 5, 6, 10, 0, 0, 1]);
        // Valid: length byte = ssidLen(4) + pwdLen(6) + 9 = 19, then MAC, IP.
        transport.receiveAck(
            [19, 0x18, 0xfe, 0x34, 0x9a, 0xa3, 0xc4, 192, 168, 0, 42]);
      }
    };
    final sender = fastSender(transport);
    final result = await sender.provision(
      ssid: 'home',
      password: 's3cret',
      timeout: const Duration(seconds: 5),
    );
    expect(result.mac, '18:fe:34:9a:a3:c4');
    expect(result.ip, '192.168.0.42');
    expect(result.toJson(), {'mac': '18:fe:34:9a:a3:c4', 'ip': '192.168.0.42'});
  });

  test('provision times out when no device ever ACKs', () async {
    final transport = FakeTransport();
    final sender = fastSender(transport);
    await expectLater(
      sender.provision(
        ssid: 'home',
        password: 'pw',
        timeout: const Duration(milliseconds: 30),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });
}
