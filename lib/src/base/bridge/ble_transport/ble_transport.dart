// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_transport/lib/ble_transport.dart
// Regenerate with debug/tool/sync_discovery_forks.sh.
//
/// Recipe — Flutter BLE extension `ClientTransport` for MCP-serving boards.
///
/// Layer 2 (transport impl) of the extension-transport standard
/// (`specs/platform/08-extension.md` §4), realizing the BLE GATT binding of
/// `specs/platform/16-ble-transport.md`: fixed MCP Serving service, write
/// RX characteristic + notify TX characteristic as a pure byte pipe, and
/// newline-delimited JSON-RPC on the reassembled stream — the MCP layer
/// never knows it is on BLE.
///
/// Radio access is isolated behind the thin [BleLink] seam
/// ([UniversalBleLink] is the real radio — universal_ble, BSD-3-Clause);
/// [BleClientTransport] itself is pure Dart and fully covered by fakes in
/// `test/`. [BleBoardScanner] discovers nearby boards by the fixed service
/// UUID.
///
/// Vendored reference (`publish_to: none`): Flutter hosts (AppPlayer,
/// Studio) copy this package and inject the transport through the layer-1
/// kernel seam (`connectExtension` / the host's `connectExtensionTransport`
/// wrapper). Layer 1 and layer 3 stay unchanged.
library;

export 'src/ble_board_scanner.dart' show BleBoardCandidate, BleBoardScanner;
export 'src/ble_client_transport.dart' show BleClientTransport;
export 'src/ble_link.dart' show BleLink;
export 'src/ble_uuids.dart';
export 'src/newline_json_framer.dart' show NewlineJsonFramer;
export 'src/universal_ble_link.dart' show UniversalBleLink;
