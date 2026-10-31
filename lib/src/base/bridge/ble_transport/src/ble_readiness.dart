// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_transport/lib/src/ble_readiness.dart
// Regenerate with debug/tool/sync_discovery_forks.sh.
//
/// Whether this phone can use Bluetooth now, asking for permission on the way.
///
/// One answer for every host that searches on a person's request (a nearby
/// list): the permission prompt comes when the person asks, never at launch,
/// and a refusal or a switched-off radio is said as such instead of looking
/// like an empty room.
library;

import 'package:universal_ble/universal_ble.dart';

enum BleReadiness { ready, permissionDenied, off, unsupported }

Future<BleReadiness> bleReadiness() async {
  try {
    if (!await UniversalBle.hasPermissions()) {
      try {
        await UniversalBle.requestPermissions();
      } catch (_) {
        // A refusal comes back as an error. What counts is what is granted
        // afterwards — read below — not how the request ended; taken as "no
        // Bluetooth here", a refusal looked like an endless search.
      }
      if (!await UniversalBle.hasPermissions()) {
        return BleReadiness.permissionDenied;
      }
    }
    final state = await UniversalBle.getBluetoothAvailabilityState();
    return switch (state) {
      AvailabilityState.poweredOff => BleReadiness.off,
      AvailabilityState.unauthorized => BleReadiness.permissionDenied,
      AvailabilityState.unsupported => BleReadiness.unsupported,
      _ => BleReadiness.ready,
    };
  } catch (_) {
    return BleReadiness.unsupported;
  }
}
