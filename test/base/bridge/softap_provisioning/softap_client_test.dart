// VENDORED COPY of the recipe's test — do not hand-edit. Canonical:
//   os/core/brain_kernel/recipes/softap_provisioning/test/softap_client_test.dart
// Re-vendor alongside debug/tool/sync_provisioning_forks.sh runs.
//
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:appplayer_studio/src/base/bridge/softap_provisioning/softap_provisioning.dart';

void main() {
  test('scanWifi parses the device AP list', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/wifi-scan');
      return http.Response(
          jsonEncode({
            'aps': [
              {'ssid': 'home', 'rssi': -40, 'secure': true},
              {'ssid': 'guest', 'rssi': -70, 'secure': false},
            ]
          }),
          200);
    });
    final c = SoftApProvisioningClient(httpClient: mock);
    final aps = await c.scanWifi();
    expect(aps.map((a) => a.ssid), ['home', 'guest']);
    expect(aps.first.secure, isTrue);
  });

  test('commission POSTs credentials then polls to connected+ip', () async {
    String? sentBody;
    var polls = 0;
    final mock = MockClient((req) async {
      if (req.method == 'POST' && req.url.path == '/credentials') {
        sentBody = req.body;
        return http.Response('{}', 200);
      }
      // /status: connecting twice, then connected.
      polls++;
      final state = polls < 2 ? 'connecting' : 'connected';
      final ip = polls < 2 ? '' : '192.168.0.42';
      return http.Response(
          jsonEncode({'state': state, 'ip': ip, 'error': ''}), 200);
    });
    final c = SoftApProvisioningClient(httpClient: mock);
    final r = await c.commission('home', 's3cret',
        pollEvery: const Duration(milliseconds: 5));
    expect(jsonDecode(sentBody!),
        {'ssid': 'home', 'password': 's3cret'});
    expect(r['state'], 'connected');
    expect(r['ip'], '192.168.0.42');
  });

  test('commission surfaces a failed join', () async {
    final mock = MockClient((req) async {
      if (req.method == 'POST') return http.Response('{}', 200);
      return http.Response(
          jsonEncode({'state': 'failed', 'error': 'auth'}), 200);
    });
    final c = SoftApProvisioningClient(httpClient: mock);
    final r = await c.commission('home', 'wrong',
        pollEvery: const Duration(milliseconds: 5));
    expect(r['state'], 'failed');
    expect(r['error'], 'auth');
  });

  test('commission times out when the device never reports terminal', () async {
    final mock = MockClient((req) async {
      if (req.method == 'POST') return http.Response('{}', 200);
      return http.Response(jsonEncode({'state': 'connecting'}), 200);
    });
    final c = SoftApProvisioningClient(httpClient: mock);
    final r = await c.commission('home', 'pw',
        timeout: const Duration(milliseconds: 30),
        pollEvery: const Duration(milliseconds: 10));
    expect(r['state'], 'failed');
    expect(r['error'], 'timeout');
  });
}
