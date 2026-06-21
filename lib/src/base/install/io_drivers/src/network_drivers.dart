/// Builders for the network io drivers (dart:io sockets — mobile + desktop).
///
/// modbus(TCP) · mqtt(TCP) · http · scpi(TCP). Each builds a real transport
/// from the config params (no connection opens until the adapter is used) and
/// a per-instance adapter with a unique `adapterId` (so multiple instances of
/// the same type can coexist in the registry).
library;

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:mcp_io_http/mcp_io_http.dart';
import 'package:mcp_io_modbus/mcp_io_modbus.dart';
import 'package:mcp_io_mqtt/mcp_io_mqtt.dart';
import 'package:mcp_io_scpi/mcp_io_scpi.dart';

import 'io_device_provisioner.dart';

/// Mobile + desktop (web is excluded — no dart:io sockets).
const Set<DevicePlatform> _network = {
  DevicePlatform.mobile,
  DevicePlatform.desktop,
};

/// Per-instance manifest. The registry keys adapters by `adapterId`, so each
/// provisioned instance needs a unique one.
AdapterManifest _manifest(String type, String id) => AdapterManifest(
      adapterId: '$type-$id',
      adapterVersion: '0',
      contractVersionRange: '>=0.1.0 <1.0.0',
      displayName: '$type device',
      description: 'io $type device instance',
      capabilities: const [],
    );

int _port(IoDeviceConfig c) => (c.params['port'] as num).toInt();
String _host(IoDeviceConfig c) => c.params['host'] as String;

/// Register the network driver builders on [registry].
void registerNetworkDrivers(IoDriverRegistry registry) {
  registry.registerDriver(
    'modbus',
    platforms: _network,
    builder: (c) => ModbusTcpAdapter(
      deviceId: c.id,
      unitId: (c.params['unitId'] as num?)?.toInt() ?? 1,
      transport: TcpModbusTransport(host: _host(c), port: _port(c)),
      manifest: _manifest('modbus', c.id),
    ),
  );

  registry.registerDriver(
    'mqtt',
    platforms: _network,
    builder: (c) => MqttAdapter(
      deviceId: c.id,
      clientId: (c.params['clientId'] as String?) ?? c.id,
      transport: TcpMqttTransport(host: _host(c), port: _port(c)),
      manifest: _manifest('mqtt', c.id),
    ),
  );

  registry.registerDriver(
    'http',
    platforms: _network,
    builder: (c) => HttpIoAdapter(
      deviceId: c.id,
      baseUri: Uri.parse(c.params['baseUri'] as String),
      transport: DartHttpIoTransport(),
      manifest: _manifest('http', c.id),
    ),
  );

  registry.registerDriver(
    'scpi',
    platforms: _network,
    builder: (c) => ScpiAdapter(
      deviceId: c.id,
      transport: TcpScpiTransport(host: _host(c), port: _port(c)),
      manifest: _manifest('scpi', c.id),
    ),
  );
}
