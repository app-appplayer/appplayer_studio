// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_transport/lib/src/ble_link.dart
// Regenerate with debug/tool/sync_discovery_forks.sh.
//
/// Thin radio seam — the only surface that touches a BLE stack.
///
/// [BleClientTransport] holds all transport logic (framing, chunking,
/// lifecycle) in pure Dart and drives the radio exclusively through this
/// interface, so the logic is fully testable with a fake link and the
/// BLE plugin dependency stays isolated in one implementation file.
library;

/// One GATT connection to an MCP-serving BLE board
/// (`specs/platform/16-ble-transport.md`).
///
/// Call order used by the transport: [connect] → [requestMtu] →
/// [subscribeTxNotifications] → [writeRxChunk]* → [disconnect].
abstract interface class BleLink {
  /// Open the GATT connection to the peripheral.
  Future<void> connect();

  /// Try to negotiate an ATT MTU of [desired] and return the effective
  /// ATT MTU afterwards. Implementations where explicit negotiation is
  /// unsupported (e.g. iOS/macOS auto-negotiate) should swallow the
  /// rejection and return the platform-reported MTU. May throw if even
  /// that is unavailable — the transport falls back to the default MTU.
  Future<int> requestMtu(int desired);

  /// Enable notifications on the TX characteristic (CCCD write) and return
  /// the stream of notification payloads (server-to-client byte chunks).
  /// Per spec §3 the server sends nothing before this subscription.
  Future<Stream<List<int>>> subscribeTxNotifications();

  /// Write one chunk (already sized to fit ATT_MTU - 3) to the RX
  /// characteristic. Chunks must arrive at the server in call order.
  Future<void> writeRxChunk(List<int> chunk);

  /// Completes when the underlying connection is lost (either side).
  Future<void> get onDisconnected;

  /// Tear the connection down.
  Future<void> disconnect();
}
