// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/serial_provisioning/lib/src/serial_models.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
/// One nearby access point the device reported it can see (from its STA-side
/// scan), so the user picks the network to join from the device's vantage.
/// Same shape as the ble/softap sibling model; the serial wire payload carries
/// an `auth` mode number (0 = open) which maps onto [secure].
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
        secure: j['auth'] is num
            ? (j['auth'] as num) != 0
            : (j['secure'] as bool?) ?? true,
      );
}

enum ProvisioningState { idle, connecting, connected, failed }

/// The device's join progress/result, decoded from the terminal `#PROV`
/// status line (`{"status":"connected","ip":..}` / `{"status":"failed",
/// "reason":..}`). Same shape as the ble/softap sibling model.
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

  /// Decode a `{"status":..,"ip"?..,"reason"?..}` join-progress payload.
  factory ProvisioningStatus.fromProvJson(Map<String, Object?> j) {
    final status = j['status'] as String?;
    return ProvisioningStatus(
      state: ProvisioningState.values.firstWhere(
        (s) => s.name == status,
        orElse: () => ProvisioningState.idle,
      ),
      ip: j['ip'] as String?,
      error: j['reason'] as String?,
    );
  }
}

/// The device's persisted provisioning state, from `prov.status`
/// (`{"provisioned":bool,"ssid":..,"ip":..}`).
class ProvisioningInfo {
  const ProvisioningInfo({required this.provisioned, this.ssid, this.ip});

  final bool provisioned;
  final String? ssid;
  final String? ip;

  Map<String, Object?> toJson() => {
        'provisioned': provisioned,
        if (ssid != null) 'ssid': ssid,
        if (ip != null) 'ip': ip,
      };

  factory ProvisioningInfo.fromJson(Map<String, Object?> j) => ProvisioningInfo(
        provisioned: (j['provisioned'] as bool?) ?? false,
        ssid: j['ssid'] as String?,
        ip: j['ip'] as String?,
      );
}
