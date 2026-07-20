// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_provisioning/lib/src/provisioning_link.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
import 'provisioning_models.dart';

/// Fixed GATT constants of the MCP provisioning binding — the device firmware
/// exposes this service while in provisioning mode and advertises [serviceUuid]
/// so the host can find it. Lowercased 128-bit form.
class ProvisioningUuids {
  ProvisioningUuids._();

  /// Provisioning service (advertised in provisioning mode).
  static const String serviceUuid = '4d435050-524f-5600-8000-6d6370726f76';

  /// Read/notify — the device's nearby-AP list (JSON: {"aps":[{ssid,rssi,secure}]}).
  static const String wifiListChar = '4d435050-524f-5601-8000-6d6370726f76';

  /// Write — the chosen credentials (JSON: {"ssid":..,"password":..}).
  static const String credentialsChar = '4d435050-524f-5602-8000-6d6370726f76';

  /// Read/notify — provisioning status (JSON: {state, ip?, error?}).
  static const String statusChar = '4d435050-524f-5603-8000-6d6370726f76';
}

/// A live GATT session with one device being provisioned. The concrete
/// implementation ([UniversalBleProvisioningLink]) talks real GATT; a fake
/// drives the orchestration tests without hardware.
abstract class ProvisioningLink {
  /// Read the device's nearby-AP list (its [ProvisioningUuids.wifiListChar]).
  Future<List<WifiAp>> scanWifi();

  /// Write the chosen network credentials to the device.
  Future<void> sendCredentials(String ssid, String password);

  /// Provisioning status updates the device pushes over its status
  /// characteristic (idle → connecting → connected/failed).
  Stream<ProvisioningStatus> get status;

  /// Read the current provisioning status once (the status characteristic is
  /// READ as well as NOTIFY). The recovery path when the BLE link drops before
  /// a terminal NOTIFY arrives — Wi-Fi/BT coexistence commonly kills the link
  /// while the device is joining: reconnect and read where the join ended up.
  Future<ProvisioningStatus> readStatus();

  /// Close the GATT session.
  Future<void> close();
}

/// Finds provisionable devices and opens a [ProvisioningLink] to one. The
/// candidate scan is a subscriber of the shared radio (same model as ble_scan /
/// device_discovery) — provisioning COMPOSES discovery, it does not live inside
/// it.
abstract class ProvisioningTransport {
  /// Devices currently advertising the provisioning service (provisioning
  /// mode). Emits the current set on subscribe and as it changes.
  Stream<List<ProvisioningCandidate>> candidates();

  /// Connect to [deviceId] and open a provisioning GATT session.
  Future<ProvisioningLink> open(String deviceId);
}
