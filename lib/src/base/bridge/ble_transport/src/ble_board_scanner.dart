// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_transport/lib/src/ble_board_scanner.dart
// Regenerate with debug/tool/sync_discovery_forks.sh.
//
import 'dart:async';

import 'package:universal_ble/universal_ble.dart';

import 'ble_uuids.dart';

/// One nearby MCP-serving board seen during a scan
/// (`specs/platform/16-ble-transport.md` §6).
class BleBoardCandidate {
  const BleBoardCandidate({
    required this.deviceId,
    required this.localName,
    required this.rssi,
  });

  /// Platform device identifier — pass to `UniversalBleLink(deviceId:)`.
  final String deviceId;

  /// Advertised local name (may be empty — the name is free-form, spec §6).
  final String localName;

  /// Signal strength at scan time (dBm); 0 when the platform does not
  /// report RSSI.
  final int rssi;

  @override
  String toString() => 'BleBoardCandidate($deviceId, "$localName", $rssi dBm)';
}

/// Scans for nearby MCP-serving boards. Discovery per spec §6 is a single
/// scan filter on the fixed MCP Serving service UUID — boards must include
/// it in their advertising PDU or scan response, so no other heuristics
/// are needed.
///
/// The service-UUID filter is passed to the platform (`ScanFilter
/// .withServices` — native filtering on Android/Apple/Windows/Web, a
/// package-side filter on Linux). As a defensive second gate, results whose
/// advertisement carries service UUIDs that do not include the MCP service
/// are dropped here as well; results advertising no service list at all are
/// passed through, trusting the platform filter.
class BleBoardScanner {
  /// Stream of candidates while scanning. The scan starts on listen and
  /// stops when the subscription is cancelled or [timeout] elapses (the
  /// stream then closes). The same board may be emitted repeatedly with
  /// updated RSSI; deduplicate by [BleBoardCandidate.deviceId] if needed.
  Stream<BleBoardCandidate> scan({
    Duration timeout = const Duration(seconds: 15),
  }) {
    final controller = StreamController<BleBoardCandidate>();
    StreamSubscription<BleDevice>? resultsSub;
    Timer? timeoutTimer;
    final mcpService = BleUuidParser.string(mcpBleServiceUuid);

    Future<void> stop() async {
      timeoutTimer?.cancel();
      await resultsSub?.cancel();
      try {
        await UniversalBle.stopScan();
      } catch (_) {
        // Teardown best-effort — the adapter may already be off/stopped.
      }
    }

    controller.onListen = () async {
      resultsSub = UniversalBle.scanStream.listen(
        (device) {
          if (controller.isClosed) return;
          final advertised = device.services
              .map(BleUuidParser.stringOrNull)
              .whereType<String>()
              .toList();
          if (advertised.isNotEmpty && !advertised.contains(mcpService)) {
            return; // Defensive gate on top of the platform filter.
          }
          controller.add(
            BleBoardCandidate(
              deviceId: device.deviceId,
              localName: device.name ?? device.rawName ?? '',
              rssi: device.rssi ?? 0,
            ),
          );
        },
        onError: controller.addError,
      );
      try {
        await UniversalBle.startScan(
          scanFilter: ScanFilter(withServices: [mcpBleServiceUuid]),
        );
        // universal_ble has no built-in scan timeout — enforce it here.
        timeoutTimer = Timer(timeout, () async {
          await stop();
          if (!controller.isClosed) await controller.close();
        });
      } catch (error, stack) {
        controller.addError(error, stack);
        await stop();
        if (!controller.isClosed) await controller.close();
      }
    };

    controller.onCancel = stop;

    return controller.stream;
  }
}
