/// Host-agnostic io tool map — `io.*` passthrough + connect/disconnect.
///
/// A host calls [ioDeviceTools] once with its `IoRuntime`, a configured
/// [IoDriverRegistry], and its current [DevicePlatform], then registers the
/// returned handlers into its own dispatcher (AppPlayer) or server registry
/// (Studio). Both hosts consume the identical map → bundle parity.
library;

import 'package:mcp_io/mcp_io.dart';

import 'io_device_provisioner.dart';

/// In-process tool handler shape (raw JSON-ish in / out). Compatible with
/// AppPlayer's `registerCapabilityTools` and Studio's exposed-tool adapter.
typedef IoToolHandler = Future<Object?> Function(Map<String, dynamic> args);

/// Build the io tool handler map.
///
/// Includes the fixed `io.*` surface (via [IoTools]) plus
/// `io.connect_device` / `io.disconnect_device`, which provision connection
/// drivers at runtime through [registry] (platform-gated by [platform]).
Map<String, IoToolHandler> ioDeviceTools({
  required IoRuntime runtime,
  required IoDriverRegistry registry,
  required DevicePlatform platform,
}) {
  final ioTools = IoTools(runtime: runtime);
  // Live connection instances: deviceId -> adapterId (the registry keys
  // adapters by adapterId, so disconnect needs the mapping).
  final connected = <String, String>{};

  Map<String, dynamic> ok(Object? content) => {'content': content};
  Map<String, dynamic> err(String message) =>
      {'isError': true, 'errorMessage': message};

  final handlers = <String, IoToolHandler>{};

  // Fixed io.* surface — pass through to IoTools.
  for (final tool in ioTools.tools) {
    final name = tool.name;
    handlers[name] = (args) async {
      final result = await ioTools.call(name, args);
      return {
        'content': result.content,
        if (result.isError) 'isError': true,
        if (result.errorMessage != null) 'errorMessage': result.errorMessage,
      };
    };
  }

  // Runtime provisioning of a connection driver.
  handlers['io.connect_device'] = (args) async {
    final type = args['type'] as String?;
    final id = args['id'] as String?;
    if (type == null || id == null) {
      return err('io.connect_device requires "type" and "id"');
    }
    final config = IoDeviceConfig(
      type: type,
      id: id,
      params: (args['params'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
    );
    final AdapterBase adapter;
    try {
      adapter = registry.build(config, platform: platform);
    } on ProvisionException catch (e) {
      return err(e.message);
    }
    await runtime.registry.registerAdapter(adapter.manifest, adapter);
    await runtime.registry.discover();
    connected[id] = adapter.manifest.adapterId;
    return ok({'connected': true, 'id': id});
  };

  handlers['io.disconnect_device'] = (args) async {
    final id = args['id'] as String?;
    if (id == null) return err('io.disconnect_device requires "id"');
    final adapterId = connected.remove(id);
    if (adapterId == null) return err('device not connected: $id');
    await runtime.registry.unregisterAdapter(adapterId);
    return ok({'disconnected': true, 'id': id});
  };

  return handlers;
}
