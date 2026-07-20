// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/softap_provisioning/lib/src/softap_client.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'softap_models.dart';

/// HTTP client for a device in SoftAP provisioning mode. The host must already
/// be joined to the device's AP so [baseUrl] (e.g. http://192.168.4.1) is
/// reachable; how the host joins that AP is out of scope here (the platform
/// switches Wi-Fi, or the user joins it manually). The JSON payloads match the
/// ble_provisioning GATT protocol byte-for-byte, so decoders are shared:
///   GET  /wifi-scan   → {"aps":[{ssid,rssi,secure},...]}
///   POST /credentials   {"ssid":..,"password":..}
///   GET  /status      → {state, ip?, error?}
class SoftApProvisioningClient {
  SoftApProvisioningClient({
    this.baseUrl = 'http://192.168.4.1',
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  /// The APs the device can see from its Wi-Fi side.
  Future<List<WifiAp>> scanWifi() async {
    final res = await _http.get(Uri.parse('$baseUrl/wifi-scan'));
    final obj = jsonDecode(res.body) as Map<String, Object?>;
    final aps = (obj['aps'] as List?) ?? const [];
    return [
      for (final a in aps) WifiAp.fromJson(Map<String, Object?>.from(a as Map)),
    ];
  }

  /// Push the chosen credentials; the device begins the STA join.
  Future<void> sendCredentials(String ssid, String password) async {
    await _http.post(
      Uri.parse('$baseUrl/credentials'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'ssid': ssid, 'password': password}),
    );
  }

  /// One status read.
  Future<ProvisioningStatus> status() async {
    final res = await _http.get(Uri.parse('$baseUrl/status'));
    return ProvisioningStatus.fromJson(
        jsonDecode(res.body) as Map<String, Object?>);
  }

  /// Send credentials and poll `/status` until the join reaches a terminal
  /// state (connected → ip, or failed → error). Returns the result; on timeout
  /// or a poll error (the device may drop the AP as it switches to STA), yields
  /// the last non-terminal state as `failed`/`timeout`.
  Future<Map<String, Object?>> commission(
    String ssid,
    String password, {
    Duration timeout = const Duration(seconds: 45),
    Duration pollEvery = const Duration(seconds: 1),
  }) async {
    await sendCredentials(ssid, password);
    final deadline = timeout;
    var elapsed = Duration.zero;
    while (elapsed < deadline) {
      await Future<void>.delayed(pollEvery);
      elapsed += pollEvery;
      try {
        final s = await status();
        if (s.isTerminal) return s.toJson();
      } catch (_) {
        // The AP can disappear when the device switches to STA on success;
        // keep polling until the timeout in case it recovers.
      }
    }
    return const {'state': 'failed', 'error': 'timeout'};
  }

  void close() => _http.close();
}
