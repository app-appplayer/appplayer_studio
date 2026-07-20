// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_provisioning/lib/src/provisioning_models.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
/// A device found advertising the provisioning GATT service (i.e. in
/// provisioning mode, not yet on the network). The first step of provisioning
/// is discovery — this is one scan subscriber's result.
class ProvisioningCandidate {
  const ProvisioningCandidate({
    required this.deviceId,
    required this.name,
    required this.rssi,
  });

  final String deviceId;
  final String name;
  final int rssi;

  Map<String, Object?> toJson() =>
      {'deviceId': deviceId, 'name': name, 'rssi': rssi};
}

/// One nearby access point the device reported it can see, so the user picks
/// the network to join from the DEVICE's vantage point (not the phone's).
class WifiAp {
  const WifiAp({required this.ssid, this.rssi = 0, this.secure = true});

  final String ssid;
  final int rssi;
  final bool secure;

  Map<String, Object?> toJson() =>
      {'ssid': ssid, 'rssi': rssi, 'secure': secure};

  factory WifiAp.fromJson(Map<String, Object?> j) => WifiAp(
        ssid: (j['ssid'] as String?) ?? '',
        rssi: (j['rssi'] as num?)?.toInt() ?? 0,
        secure: (j['secure'] as bool?) ?? true,
      );
}

/// Where the device is in the join sequence, reported back over the status
/// characteristic while commissioning runs.
enum ProvisioningState { idle, connecting, connected, failed }

/// A provisioning progress/result the device reports: the [state], and on
/// success the [ip] it obtained, or on failure an [error] reason.
class ProvisioningStatus {
  const ProvisioningStatus({required this.state, this.ip, this.error});

  final ProvisioningState state;
  final String? ip;
  final String? error;

  bool get isTerminal =>
      state == ProvisioningState.connected || state == ProvisioningState.failed;

  Map<String, Object?> toJson() => {
        'state': state.name,
        if (ip != null) 'ip': ip,
        if (error != null) 'error': error,
      };

  factory ProvisioningStatus.fromJson(Map<String, Object?> j) =>
      ProvisioningStatus(
        state: ProvisioningState.values.firstWhere(
          (s) => s.name == j['state'],
          orElse: () => ProvisioningState.idle,
        ),
        ip: j['ip'] as String?,
        error: j['error'] as String?,
      );
}
