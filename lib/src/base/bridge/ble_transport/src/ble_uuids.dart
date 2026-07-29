// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_transport/lib/src/ble_uuids.dart
// Regenerate with debug/tool/sync_discovery_forks.sh.
//
/// Fixed GATT constants of the MCP Serving BLE binding.
///
/// The UUIDs are constants of the standard, hardcodable by firmware and
/// clients alike — they are not configuration. Base `4D435042-4C45` is
/// ASCII "MCPB-LE"; node `6D6370626C65` is ASCII "mcpble".
library;

/// MCP Serving primary service. Discovery = a single scan filter
/// on this UUID.
const String mcpBleServiceUuid = '4D435042-4C45-0001-8000-6D6370626C65';

/// RX characteristic — central (MCP client) to peripheral (MCP server)
/// bytes. The server accepts both Write and Write Without Response.
const String mcpBleRxCharUuid = '4D435042-4C45-0002-8000-6D6370626C65';

/// TX characteristic — peripheral (MCP server) to central (MCP client)
/// bytes via Notify. CCCD subscription is required before the server sends
/// anything.
const String mcpBleTxCharUuid = '4D435042-4C45-0003-8000-6D6370626C65';

/// Default ATT MTU every BLE stack starts at. The binding must work at
/// this floor — chunking absorbs it.
const int bleDefaultAttMtu = 23;

/// ATT MTU the central should try to negotiate right after connecting
/// (SHOULD be >= 247). Negotiation failure is non-fatal.
const int bleDesiredAttMtu = 247;

/// ATT payload overhead per write/notify — max chunk size = ATT_MTU - 3.
const int bleAttHeaderOverhead = 3;
