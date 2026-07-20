// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_provisioning/lib/src/provisioning_capability.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
import 'dart:async';

import 'provisioning_link.dart';
import 'provisioning_models.dart';

/// The single directly-usable provisioning capability. A bundle app or an agent
/// drives the whole "find → pick network → send credentials → join" flow
/// through this one JSON surface; internally it orchestrates the candidate scan
/// (discovery), the GATT session (transport), and the status wait.
///
///  - [candidatesJson]   → devices currently in provisioning mode.
///  - [wifiScanJson]     → the networks the chosen device can see.
///  - [commissionJson]   → send credentials and await the join result.
///
/// The commission call is the mutation (writes credentials, changes the
/// device's network membership) — distinct from discovery's read-only find.
class BleProvisioningCapability {
  BleProvisioningCapability(this._transport) {
    _sub = _transport.candidates().listen((c) => _candidates = c);
  }

  final ProvisioningTransport _transport;
  StreamSubscription<List<ProvisioningCandidate>>? _sub;
  List<ProvisioningCandidate> _candidates = const [];

  /// Devices currently advertising the provisioning service.
  Map<String, Object?> candidatesJson() => {
        'candidates': [for (final c in _candidates) c.toJson()],
      };

  /// Connect to [deviceId], read its nearby-AP list, disconnect.
  Future<Map<String, Object?>> wifiScanJson(String deviceId) async {
    final link = await _transport.open(deviceId);
    try {
      final aps = await link.scanWifi();
      return {'deviceId': deviceId, 'aps': [for (final a in aps) a.toJson()]};
    } finally {
      await link.close();
    }
  }

  /// Send [ssid]/[password] to [deviceId] and await the terminal join result
  /// (connected → returns the obtained ip; failed → returns the error). An
  /// optional [timeout] guards against a device that never reports terminal.
  Future<Map<String, Object?>> commissionJson(
    String deviceId,
    String ssid,
    String password, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final link = await _transport.open(deviceId);
    try {
      final terminal = link.status
          .firstWhere((s) => s.isTerminal)
          .timeout(timeout,
              onTimeout: () => const ProvisioningStatus(
                  state: ProvisioningState.failed, error: 'timeout'));
      await link.sendCredentials(ssid, password);
      final result = await terminal;
      return {'deviceId': deviceId, ...result.toJson()};
    } finally {
      await link.close();
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }
}
