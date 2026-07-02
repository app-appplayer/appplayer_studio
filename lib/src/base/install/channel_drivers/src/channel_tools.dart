/// Host-agnostic channel provisioning tools — `channel.connect` /
/// `channel.disconnect`. Mirrors io_drivers' `io.connect_device` /
/// `io.disconnect_device`.
///
/// A host calls [channelDriverTools] once with a configured
/// [ChannelDriverRegistry] and its **live connectors map** (the same
/// `Map<String, ExtendedChannelPort>` its `registerChannelCapability` owns, so
/// `channel.list` / `send` / `receive` see connected externals immediately).
/// The connect tool provisions a connector from a [ChannelConnectorConfig],
/// starts it, and registers it under its id; disconnect stops and removes it.
///
/// The fixed `channel.*` surface (`list` · `status` · `send` ·
/// `session.history` · `receive`) is owned by the host capability, unchanged.
library;

import 'package:mcp_channel/mcp_channel.dart';

import 'channel_provisioner.dart';

/// A channel tool handler: JSON args in, JSON-able result out.
typedef ChannelToolHandler = Future<Object?> Function(Map<String, dynamic> args);

/// Build the connect/disconnect tool map. [connectors] is the host's live map;
/// [platform] gates which connectors may be provisioned here.
Map<String, ChannelToolHandler> channelDriverTools({
  required ChannelDriverRegistry registry,
  required Map<String, ExtendedChannelPort> connectors,
  required ChannelPlatform platform,
}) {
  Map<String, dynamic> ok(Map<String, dynamic> body) => {'ok': true, ...body};
  Map<String, dynamic> err(String code, String message) =>
      {'ok': false, 'code': code, 'error': message};

  return <String, ChannelToolHandler>{
    // Provision + register an external connector at runtime.
    'channel.connect': (args) async {
      final platformKey = args['platform'] as String?;
      final id = args['id'] as String?;
      if (platformKey == null || id == null) {
        return err('channel.bad_args',
            'channel.connect requires "platform" and "id"');
      }
      if (connectors.containsKey(id)) {
        return err('channel.exists', 'channel already connected: $id');
      }
      final config = ChannelConnectorConfig(
        platform: platformKey,
        id: id,
        params: (args['params'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      );
      final ExtendedChannelPort connector;
      try {
        connector = registry.build(config, platform: platform);
      } on ChannelProvisionException catch (e) {
        return err(e.code, e.message);
      }
      await connector.start();
      connectors[id] = connector;
      return ok({'connected': true, 'id': id, 'platform': platformKey});
    },

    // Stop + deregister a connected external connector.
    'channel.disconnect': (args) async {
      final id = args['id'] as String?;
      if (id == null) {
        return err('channel.bad_args', 'channel.disconnect requires "id"');
      }
      final connector = connectors.remove(id);
      if (connector == null) {
        return err('channel.not_found', 'channel not connected: $id');
      }
      await connector.stop();
      return ok({'disconnected': true, 'id': id});
    },
  };
}
