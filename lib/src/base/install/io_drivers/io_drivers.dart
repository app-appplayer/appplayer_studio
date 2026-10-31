/// Shared io device-driver wiring — reference recipe.
///
/// Implements the io device-driver model:
///   - [IoDriverRegistry] / [IoDeviceConfig] — type-keyed builders with
///     per-driver platform gating (the provisioner).
///   - [registerNetworkDrivers] — builders for the dart:io socket drivers
///     (modbus / mqtt / http / scpi) that run on mobile + desktop.
///   - [registerNativeDrivers] — desktop-only native drivers (serial).
///   - [ioDeviceTools] — the host-agnostic tool map (`io.*` + connect /
///     disconnect) a host registers into its dispatcher / server registry.
///
/// Consumed identically by AppPlayer and Studio so the same bundle sees the
/// same `io.*` surface. `mcp_io` core is not modified. [registerNativeDrivers]
/// adds the desktop-only FFI driver `serial` for a host that asks for it;
/// `can` and the session-based opcua / websocket plug in under the same
/// builder pattern (see README).
library;

export 'src/io_device_provisioner.dart';
export 'src/native_drivers.dart';
export 'src/network_drivers.dart';
export 'src/local_drivers.dart';
export 'src/io_device_tools.dart';
