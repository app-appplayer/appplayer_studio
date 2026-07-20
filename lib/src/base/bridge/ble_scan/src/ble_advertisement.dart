// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_scan/lib/src/ble_advertisement.dart
// Regenerate with debug/tool/sync_ble_scan_fork.sh.
//
import 'dart:typed_data';

/// One raw BLE advertisement observed during a scan — the sensing payload the
/// `ble_scan` capability streams, distinct from a connection/transport. A single
/// device re-advertises continuously, so the same [deviceId] arrives repeatedly
/// with a fresh [rssi]; consumers window/dedup as they see fit.
class BleAdvertisement {
  const BleAdvertisement({
    required this.deviceId,
    required this.name,
    required this.rssi,
    this.serviceUuids = const [],
    this.manufacturerData = const [],
    this.receivedAtMs = 0,
  });

  /// Platform device identifier (stable per session; not the MAC on Apple).
  final String deviceId;

  /// Advertised local name — may be empty (the name is optional in the PDU).
  final String name;

  /// Signal strength (dBm); 0 when the platform does not report it.
  final int rssi;

  /// Service UUIDs advertised (lowercased 128-bit form).
  final List<String> serviceUuids;

  /// Raw manufacturer-specific data bytes (empty when none).
  final List<int> manufacturerData;

  /// Ingest timestamp (epoch ms) — stamped by the radio at receipt so a chart
  /// can plot RSSI over time. 0 = unstamped.
  final int receivedAtMs;

  Map<String, Object?> toJson() => {
        'deviceId': deviceId,
        'name': name,
        'rssi': rssi,
        'serviceUuids': serviceUuids,
        'manufacturerData': manufacturerData,
        'receivedAtMs': receivedAtMs,
      };

  @override
  String toString() =>
      'BleAdvertisement($deviceId, "$name", $rssi dBm, uuids=$serviceUuids)';
}

/// Per-subscription filter — the "different thing each bundle app registers".
/// Every constraint is ANDed; an unset (empty / null) constraint matches all,
/// so a `const BleScanFilter()` observes every advertisement.
class BleScanFilter {
  const BleScanFilter({
    this.serviceUuids = const [],
    this.deviceIds = const [],
    this.minRssi,
  });

  /// Match when the ad advertises ANY of these service UUIDs (empty = any).
  final List<String> serviceUuids;

  /// Match only these device ids (empty = any).
  final List<String> deviceIds;

  /// Match when `rssi >= minRssi` (null = any).
  final int? minRssi;

  bool matches(BleAdvertisement ad) {
    if (deviceIds.isNotEmpty && !deviceIds.contains(ad.deviceId)) return false;
    if (minRssi != null && ad.rssi < minRssi!) return false;
    if (serviceUuids.isNotEmpty &&
        !serviceUuids.any((u) => ad.serviceUuids.contains(u.toLowerCase()))) {
      return false;
    }
    return true;
  }

  factory BleScanFilter.fromJson(Map<String, Object?> j) => BleScanFilter(
        serviceUuids:
            (j['serviceUuids'] as List?)?.cast<String>() ?? const [],
        deviceIds: (j['deviceIds'] as List?)?.cast<String>() ?? const [],
        minRssi: (j['minRssi'] as num?)?.toInt(),
      );
}

/// Helper for concrete radios: first manufacturer-data blob as bytes.
List<int> firstManufacturerBytes(List<Uint8List> list) =>
    list.isEmpty ? const [] : list.first.toList(growable: false);
