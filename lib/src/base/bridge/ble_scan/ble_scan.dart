// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_scan/lib/ble_scan.dart
// Regenerate with debug/tool/sync_ble_scan_fork.sh.
//
/// ble_scan — a BLE advertisement OBSERVATION capability (not a transport).
///
/// A single physical BLE radio is multiplexed across many concurrent
/// subscriptions ([BleScanHub]); each subscriber (a bundle app or an agent)
/// registers its OWN [BleScanFilter] and receives its OWN stream of matching
/// [BleAdvertisement]s. This is the sensing seam a DSL bundle binds a chart/list
/// to (subscribe → accumulate into state → render) — distinct from `ble_transport`
/// (a byte pipe to one MCP server) and `device_discovery` (finding MCP boards by
/// the MCP service UUID). Radio access is isolated behind [BleScanRadio] so the
/// multiplex logic is pure Dart and testable without hardware.
///
/// Vendored by Flutter hosts (AppPlayer, Studio); publish_to: none, no
/// kernel/core package is modified.
library;

export 'src/ble_advertisement.dart' show BleAdvertisement, BleScanFilter;
export 'src/ble_scan_radio.dart' show BleScanRadio, UniversalBleScanRadio;
export 'src/ble_scan_hub.dart' show BleScanHub, BleScanSubscription;
export 'src/ble_scan_capability.dart' show BleScanCapability;
export 'src/ble_scan_stream_source.dart' show BleScanStreamSource;
export 'src/ble_scan_ui.dart'
    show buildBleScanMonitorUi, buildBleScanLiveMonitorUi;
