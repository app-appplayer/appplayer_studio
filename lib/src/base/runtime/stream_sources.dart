/// Host stream-source wiring for `client.mcpStream` channels (runtime 0.5.2).
///
/// A bundle's `client.mcpStream` channel names a `uri` (e.g. `ble://scan`);
/// the runtime resolves its scheme against the sources the host registers with
/// [MCPUIRuntime.registerStreamSource] AFTER init. [registerStudioStreamSources]
/// is the studio's `_applyStreamSources` analog — called on every freshly
/// initialized render runtime alongside the widget-registration hooks, so any
/// bundle can observe the host's live feeds without per-bundle wiring.
///
/// Registered schemes:
/// - `ble` → [BleScanStreamSource] over a PROCESS-SHARED [BleScanHub] (BLE
///   advertisement observation). One physical radio ([UniversalBleScanRadio])
///   multiplexed across every subscription — each `ble://scan` channel gets its
///   own filtered stream, ref-counted, so N bundles observing at once share the
///   single scan. Lazy: the radio idles until a channel actually subscribes.
library;

import 'package:appplayer_studio/runtime.dart';

import '../bridge/ble_scan/ble_scan.dart';
import '../bridge/ble_stack.dart';

/// Process-shared BLE scan hub — one radio for the whole studio, created on
/// first use.
///
/// Owned by [studioBleStack], not by this file: provisioning and the connect
/// path draw on the same radio, and assembling that wiring in one place is what
/// keeps them from silencing each other.
BleScanHub get studioBleScanHub => studioBleStack.hub;

/// Register every host stream source on an already-initialized [runtime].
/// No-op-safe to call repeatedly across runtimes; each registration is scoped
/// to its runtime but the underlying feed (the BLE radio) is shared.
///
/// [bleScanHub] overrides the process-shared hub — tests inject one over a
/// fake radio so the whole render → channel → hub path runs without hardware.
void registerStudioStreamSources(
  MCPUIRuntime runtime, {
  BleScanHub? bleScanHub,
}) {
  runtime.registerStreamSource(
    'ble',
    BleScanStreamSource(bleScanHub ?? studioBleScanHub).open,
  );
}
