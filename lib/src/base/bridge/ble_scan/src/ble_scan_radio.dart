// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_scan/lib/src/ble_scan_radio.dart
// Regenerate with debug/tool/sync_ble_scan_fork.sh.
//
import 'dart:async';

import 'package:universal_ble/universal_ble.dart';

import 'ble_advertisement.dart';

/// The single physical BLE radio, isolated behind a thin seam (mirrors
/// `ble_transport`'s `BleLink`) so the multiplex logic is pure Dart and testable
/// without hardware. ONE radio: [start] begins the platform scan, [advertisements]
/// is the raw result stream, [stop] ends it. The [BleScanHub] owns the single
/// instance and ref-counts start/stop across many subscribers.
abstract class BleScanRadio {
  /// Raw advertisements while scanning (broadcast — many subscribers listen).
  Stream<BleAdvertisement> get advertisements;

  /// Begin the platform scan (no service filter — this is raw observation, not
  /// discovery; per-subscription filtering happens in the hub).
  Future<void> start();

  /// End the platform scan.
  Future<void> stop();
}

/// [BleScanRadio] over `universal_ble` (BSD-3-Clause). Web/desktop/mobile; the
/// host degrades where BLE is unavailable.
class UniversalBleScanRadio implements BleScanRadio {
  UniversalBleScanRadio({int Function()? now}) : _now = now ?? _wallClockMs;

  final int Function() _now;

  @override
  Stream<BleAdvertisement> get advertisements =>
      UniversalBle.scanStream.map((d) => BleAdvertisement(
            deviceId: d.deviceId,
            name: d.name ?? d.rawName ?? '',
            rssi: d.rssi ?? 0,
            serviceUuids:
                d.services.map((s) => s.toLowerCase()).toList(growable: false),
            manufacturerData: firstManufacturerBytes(
                d.manufacturerDataList.map((m) => m.toUint8List()).toList()),
            receivedAtMs: _now(),
          ));

  @override
  Future<void> start() => UniversalBle.startScan();

  @override
  Future<void> stop() => UniversalBle.stopScan();

  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;
}
