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

  /// GAP name a node advertises in provisioning mode
  /// (firmware `ble_svc_gap_device_name_set("mcp-prov")`). Part of the
  /// provisioning contract: it is the match that works on hosts whose BLE stack
  /// does not surface a 128-bit service UUID from an advertisement.
  static const String advertisedName = 'mcp-prov';

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


/// Walks a device's paged Wi-Fi list to the end and returns every network.
///
/// A GATT attribute value is capped at 512 bytes by ATT and that cannot be
/// raised, so a device with more networks than fit serves them in pages: read a
/// page, [seek] to the index to continue from, read again. Walking to the end
/// is what makes the number of visible networks a property of the radio rather
/// than of the payload size — a device that answered in one read used to simply
/// omit the rest, and neither end could tell.
///
/// A device that predates paging omits `more`, which reads as false: it serves
/// its whole list in one read and this returns after a single round trip.
///
/// Separated from any transport so the walk itself can be exercised without a
/// radio; the BLE and HTTP onboarding paths differ only in [read] and [seek].
Future<List<WifiAp>> pageWifiList({
  required Future<Map<String, Object?>> Function() read,
  required Future<void> Function(int from) seek,
  int maxPages = 32,
  int maxRestarts = 3,
}) async {
  var collected = <WifiAp>[];
  var from = 0;
  Object? generation;
  var restarts = 0;
  // Bounded so a device that always reports `more` cannot hang onboarding.
  // 32 pages is far past any real scan; reaching it means the device is
  // misbehaving, and returning what was gathered beats never returning.
  for (var page = 0; page < maxPages; page++) {
    // The cursor lives on the DEVICE, so `from` has to be sent whenever it
    // may differ from where the device is parked — including a restart back to
    // zero, which would otherwise resume from wherever the abandoned walk left
    // it. Skipped only for the very first read of a fresh walk, so a device
    // that predates paging (read-only characteristic) is never written to.
    if (from > 0 || restarts > 0) await seek(from);
    final obj = await read();

    // A device rescans on its own schedule, so a walk can straddle two scans.
    // Splicing their pages produces a list that was never true of either — a
    // network can appear twice or vanish from the middle. Start over instead,
    // a bounded number of times so a device scanning constantly still answers.
    final gen = obj['gen'];
    if (gen != null && generation != null && gen != generation) {
      if (restarts++ >= maxRestarts) break;
      collected = <WifiAp>[];
      from = 0;
      generation = null;
      continue;
    }
    generation ??= gen;

    final aps = (obj['aps'] as List?) ?? const <Object?>[];
    for (final a in aps) {
      collected.add(WifiAp.fromJson(Map<String, Object?>.from(a as Map)));
    }
    // A page that promises more but carries nothing would leave the cursor
    // where it is and loop forever, so treat it as the end.
    if (obj['more'] != true || aps.isEmpty) break;
    from += aps.length;
  }
  return collected;
}
