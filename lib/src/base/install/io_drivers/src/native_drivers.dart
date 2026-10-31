/// Builders for the io drivers that need native libraries (FFI) — desktop only.
///
/// Registered by a host that wants them, next to [registerNetworkDrivers]; a
/// host that never calls this registers exactly what it did before. The
/// registry skips these on mobile and web (platform spec 11 §5).
///
/// Failures that belong to the device or the machine — a missing port name, a
/// value the driver cannot take, the native library not being installed — are
/// raised as [ProvisionException] so `io.connect_device` answers them as an
/// ordinary tool error rather than letting them escape the handler.
library;

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:mcp_io_serial/mcp_io_serial.dart';
import 'package:mcp_io_serial/native.dart';

import 'io_device_provisioner.dart';

const Set<DevicePlatform> _desktop = {DevicePlatform.desktop};

AdapterManifest _manifest(String type, String id) => AdapterManifest(
  adapterId: '$type-$id',
  adapterVersion: '0',
  contractVersionRange: '>=0.1.0 <1.0.0',
  displayName: '$type device',
  description: 'io $type device instance',
  capabilities: const [],
);

/// Serial transport for one device. Replaceable so a host (or a test) can
/// supply its own; the default loads the system `libserialport`.
typedef SerialTransportFor = SerialTransport Function(IoDeviceConfig config);

/// Register the native driver builders on [registry]: `serial` (UART /
/// RS-232 / RS-485 / USB-CDC through libserialport).
///
/// `params`: `port` (required — `/dev/ttyUSB0`, `COM3`, …) · `baudRate`
/// (9600) · `dataBits` (8) · `stopBits` (1) · `parity` (`none` · `even` ·
/// `odd` · `mark` · `space`) · `flowControl` (`none` · `rtsCts` · `xonXoff`) ·
/// `lineTerminator` (`\n`).
///
/// [libserialportPath] names the shared library when it is not on the system
/// search path. [serialTransport] replaces the libserialport transport.
void registerNativeDrivers(
  IoDriverRegistry registry, {
  String? libserialportPath,
  SerialTransportFor? serialTransport,
}) {
  registry.registerDriver(
    'serial',
    platforms: _desktop,
    builder: (c) {
      final port = c.params['port'];
      if (port is! String || port.isEmpty) {
        throw ProvisionException(
          'invalid_params',
          'serial device "${c.id}" needs params.port (e.g. /dev/ttyUSB0)',
        );
      }
      final SerialConfig config;
      try {
        config = _serialConfig(c.params);
      } on ArgumentError catch (e) {
        throw ProvisionException('invalid_params', '${e.message}');
      }
      final SerialTransport transport;
      try {
        transport =
            serialTransport != null
                ? serialTransport(c)
                : LibserialportSerialTransport(libraryPath: libserialportPath);
      } catch (e) {
        throw ProvisionException(
          'driver_unavailable',
          'serial driver could not start (is libserialport installed?): $e',
        );
      }
      return SerialIoAdapter(
        deviceId: c.id,
        portName: port,
        config: config,
        transport: transport,
        defaultLineTerminator: (c.params['lineTerminator'] as String?) ?? '\n',
        manifest: _manifest('serial', c.id),
      );
    },
  );
}

SerialConfig _serialConfig(Map<String, dynamic> p) {
  int intOf(String key, int fallback) {
    final v = p[key];
    if (v == null) return fallback;
    if (v is num) return v.toInt();
    throw ArgumentError('params.$key must be a number');
  }

  T enumOf<T extends Enum>(String key, List<T> values, T fallback) {
    final v = p[key];
    if (v == null) return fallback;
    for (final e in values) {
      if (e.name == v) return e;
    }
    throw ArgumentError(
      'params.$key must be one of ${values.map((e) => e.name).join(', ')}',
    );
  }

  return SerialConfig(
    baudRate: intOf('baudRate', 9600),
    dataBits: intOf('dataBits', 8),
    stopBits: intOf('stopBits', 1),
    parity: enumOf('parity', SerialParity.values, SerialParity.none),
    flowControl: enumOf(
      'flowControl',
      SerialFlowControl.values,
      SerialFlowControl.none,
    ),
  );
}
