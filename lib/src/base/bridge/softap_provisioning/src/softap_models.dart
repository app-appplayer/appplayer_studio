// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/softap_provisioning/lib/src/softap_models.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
/// One nearby access point the device reported it can see (from its STA-side
/// scan), so the user picks the network to join from the device's vantage.
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

enum ProvisioningState { idle, connecting, connected, failed }

/// The device's provisioning progress/result, read from `GET /status`.
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
