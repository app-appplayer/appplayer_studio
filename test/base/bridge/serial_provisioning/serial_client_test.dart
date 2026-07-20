// VENDORED COPY of the recipe's test — do not hand-edit. Canonical:
//   os/core/brain_kernel/recipes/serial_provisioning/test/serial_client_test.dart
// Re-vendor alongside debug/tool/sync_provisioning_forks.sh runs.
//
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/bridge/serial_provisioning/serial_provisioning.dart';

/// A scripted fake device: captures the LF-terminated command lines the client
/// writes and lets the test feed back arbitrary byte chunks (log noise, split
/// `#PROV` payloads) — no real serial port anywhere.
class FakeDevice {
  FakeDevice() {
    client = SerialProvisioningClient(
      fromDevice: _out.stream,
      toDevice: _onBytesFromHost,
    );
  }

  final _out = StreamController<List<int>>();
  final List<int> _cmdBuffer = <int>[];

  /// Every complete command line the host sent (without the trailing LF).
  final commands = <String>[];

  /// Invoked once per complete command line, so tests can script responses.
  void Function(String line)? onCommand;

  late final SerialProvisioningClient client;

  void _onBytesFromHost(List<int> bytes) {
    for (final b in bytes) {
      if (b == 0x0a) {
        final line = utf8.decode(_cmdBuffer);
        _cmdBuffer.clear();
        commands.add(line);
        onCommand?.call(line);
      } else {
        _cmdBuffer.add(b);
      }
    }
  }

  /// Emit one raw chunk from the device (may contain partial or many lines).
  void emit(String chunk) => _out.add(utf8.encode(chunk));

  Future<void> dispose() async {
    await client.dispose();
    await _out.close();
  }
}

void main() {
  test('scan parses aps through log noise and chunk-split #PROV payloads',
      () async {
    final device = FakeDevice();
    device.onCommand = (line) {
      expect(line, 'prov.scan');
      device.emit('I (1234) wifi: scan start\r\n');
      // Sentinel payload deliberately split across chunk boundaries.
      device.emit('#PROV {"aps":[{"ssid":"ho');
      device.emit('me","rssi":-49,"auth":2},'
          '{"ssid":"guest","rssi":-70,"auth":0}]}\n');
      device.emit('I (1300) wifi: scan done\n');
    };
    final aps = await device.client.scan();
    expect(aps.map((a) => a.ssid), ['home', 'guest']);
    expect(aps.first.rssi, -49);
    expect(aps.first.secure, isTrue); // auth 2 -> secured
    expect(aps.last.secure, isFalse); // auth 0 -> open
    await device.dispose();
  });

  test('noise that merely mentions #PROV mid-line or is bad JSON is ignored',
      () async {
    final device = FakeDevice();
    device.onCommand = (line) {
      device.emit('log: saw #PROV {"aps":[]} in a doc\n'); // not line-start
      device.emit('#PROV {"aps": broken\n'); // bad JSON after sentinel
      device.emit('#PROV {"aps":[{"ssid":"only","rssi":-50,"auth":3}]}\n');
    };
    final aps = await device.client.scan();
    expect(aps.map((a) => a.ssid), ['only']);
    await device.dispose();
  });

  test('commission quotes/escapes args, awaits ok then terminal connected',
      () async {
    final device = FakeDevice();
    device.onCommand = (line) {
      if (line.startsWith('prov.set')) {
        device.emit('#PROV {"ok":true}\n');
        device.emit('I (2000) wifi: connecting...\n');
        device.emit('#PROV {"status":"connected","ip":"10.0.0.7"}\n');
      }
    };
    final r = await device.client.commission('my home', 'p"w\\d');
    // Embedded quote and backslash must be escaped inside the quoted args.
    expect(device.commands, ['prov.set "my home" "p\\"w\\\\d"']);
    expect(r, {'state': 'connected', 'ip': '10.0.0.7'});
    await device.dispose();
  });

  test('commission surfaces a failed join with its reason', () async {
    final device = FakeDevice();
    device.onCommand = (line) {
      device.emit('#PROV {"ok":true}\n');
      device.emit('#PROV {"status":"failed","reason":"auth"}\n');
    };
    final r = await device.client.commission('home', 'wrong');
    expect(r, {'state': 'failed', 'error': 'auth'});
    await device.dispose();
  });

  test('commission times out when no terminal status ever arrives', () async {
    final device = FakeDevice();
    device.onCommand = (line) => device.emit('#PROV {"ok":true}\n');
    final r = await device.client.commission('home', 'pw',
        timeout: const Duration(milliseconds: 50));
    expect(r, {'state': 'failed', 'error': 'timeout'});
    await device.dispose();
  });

  test('commission reports a rejected set', () async {
    final device = FakeDevice();
    device.onCommand = (line) => device.emit('#PROV {"ok":false}\n');
    final r = await device.client.commission('home', 'pw');
    expect(r, {'state': 'failed', 'error': 'rejected'});
    await device.dispose();
  });

  test('forget sends prov.forget and resolves on ok', () async {
    final device = FakeDevice();
    device.onCommand = (line) {
      expect(line, 'prov.forget');
      device.emit('#PROV {"ok":true}\n');
    };
    await device.client.forget();
    expect(device.commands, ['prov.forget']);
    await device.dispose();
  });

  test('status parses the provisioned info payload', () async {
    final device = FakeDevice();
    device.onCommand = (line) {
      expect(line, 'prov.status');
      device.emit(
          '#PROV {"provisioned":true,"ssid":"home","ip":"10.0.0.7"}\n');
    };
    final info = await device.client.status();
    expect(info.provisioned, isTrue);
    expect(info.ssid, 'home');
    expect(info.ip, '10.0.0.7');
    expect(info.toJson(),
        {'provisioned': true, 'ssid': 'home', 'ip': '10.0.0.7'});
    await device.dispose();
  });

  test('quoteArg wraps and escapes quotes and backslashes', () {
    expect(SerialProvisioningClient.quoteArg('plain'), '"plain"');
    expect(SerialProvisioningClient.quoteArg('has space'), '"has space"');
    expect(SerialProvisioningClient.quoteArg('a"b'), '"a\\"b"');
    expect(SerialProvisioningClient.quoteArg('a\\b'), '"a\\\\b"');
  });
}
