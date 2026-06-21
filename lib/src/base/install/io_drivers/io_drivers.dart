/// Shared io device-driver wiring — reference recipe.
///
/// Implements the model defined in `specs/platform/11-io-devices.md`:
///   - [IoDriverRegistry] / [IoDeviceConfig] — type-keyed builders with
///     per-driver platform gating (the provisioner).
///   - [registerNetworkDrivers] — builders for the dart:io socket drivers
///     (modbus / mqtt / http / scpi) that run on mobile + desktop.
///   - [ioDeviceTools] — the host-agnostic tool map (`io.*` + connect /
///     disconnect) a host registers into its dispatcher / server registry.
///
/// Consumed identically by AppPlayer and Studio so the same bundle sees the
/// same `io.*` surface. `mcp_io` core is not modified; FFI/native drivers
/// (serial, can) and the session-based opcua / websocket plug in under the
/// same builder pattern (see README).
library;

export 'src/io_device_provisioner.dart';
export 'src/network_drivers.dart';
export 'src/local_drivers.dart';
export 'src/io_device_tools.dart';
