// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/extension_transport/lib/extension_transport.dart
// Regenerate with debug/tool/sync_extension_transport_fork.sh.
//
/// Reference host surface for the **extension-transport** standard
/// (`specs/platform/08-extension.md` §4).
///
/// The kernel exposes a pure injection seam — [ExtensionTransportConnect]
/// (`connectWith`) on the reference [McpClientKernelHost], reached via the
/// [connectExtension] helper. This recipe is the canonical host-facing
/// surface on top of that seam: the `mcp.connect_extension` tool, companion
/// to the kernel's `mcp.connect` (which only drives the FFI-free stdio /
/// Streamable HTTP / SSE transports the kernel builds itself).
///
/// `mcp.connect_extension` builds the chosen **mcp_bridge** transport
/// (serial / usb / ble / tcp / ws — the FFI lives in mcp_bridge, never the
/// kernel), opens it, and injects it through the seam. The connection lands
/// in the same client-host registry the kernel `mcp.*` tools resolve by
/// `id`, so `mcp.list_tools` / `mcp.call_tool` / `mcp.read_resource`
/// (e.g. `ui://app`) / `mcp.disconnect` drive the board with no further
/// wiring.
///
/// Vendored reference (`publish_to: none`): a host that exposes board /
/// device connect copies this file and registers the tool against its own
/// [HostToolRegistry] and booted client host. Hosts that never connect to
/// extension transports simply do not adopt it (and pull no mcp_bridge FFI).
library;

import 'package:brain_kernel/brain_kernel.dart'
    show HostToolRegistry, KernelClientHost, wrapInProcess;
import 'package:brain_kernel/mcp_host.dart' show connectExtension;
import 'package:mcp_bridge/mcp_bridge.dart'
    show
        BleClientTransport,
        SerialClientTransport,
        TcpClientTransport,
        UsbClientTransport,
        WebSocketClientTransport;
import 'package:mcp_client/mcp_client.dart' show ClientTransport;

/// Register `mcp.connect_extension` onto [registry], injecting through
/// [clientHost] (the host's booted `KernelApp.clientHost` — the abstract
/// [KernelClientHost] is enough; the [connectExtension] helper probes the
/// seam). Returns the exposed tool name (`mcp.connect_extension`).
String registerExtensionConnectTool(
  HostToolRegistry registry,
  KernelClientHost? clientHost,
) {
  Future<Map<String, dynamic>> handler(Map<String, dynamic> args) async {
    final id = args['id'] as String?;
    final kind = args['transport'] as String?;
    final options =
        (args['options'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    if (id == null || id.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': "required field 'id'"};
    }
    if (kind == null || kind.isEmpty) {
      return <String, dynamic>{
        'ok': false,
        'error': "required field 'transport'",
      };
    }

    // Build the concrete mcp_bridge transport (FFI lives here, not the
    // kernel) and open it before injection. `options` flows straight to the
    // transport config — keys are transport-specific (serial: port/baudRate ·
    // tcp: host/port · websocket: url · usb/ble: device).
    final ClientTransport transport;
    switch (kind) {
      case 'serial':
        final t = SerialClientTransport(options);
        await t.start();
        transport = t;
      case 'tcp':
        final t = TcpClientTransport(options);
        await t.start();
        transport = t;
      case 'websocket':
      case 'ws':
        final t = WebSocketClientTransport(options);
        await t.start();
        transport = t;
      case 'usb':
        final t = UsbClientTransport(options);
        await t.start();
        transport = t;
      case 'ble':
        final t = BleClientTransport(options);
        await t.start();
        transport = t;
      default:
        return <String, dynamic>{
          'ok': false,
          'error': 'transport must be serial | tcp | websocket | usb | ble',
        };
    }

    // Inject through the kernel seam — probes ExtensionTransportConnect off
    // the (possibly abstract) client host; throws if it cannot inject.
    final conn = await connectExtension(
      clientHost,
      id: id,
      transport: transport,
    );
    return <String, dynamic>{
      'ok': true,
      'id': conn.id,
      'connected': conn.isConnected,
    };
  }

  return registry.registerExposed(
    bundleId: 'mcp',
    rawName: 'connect_extension',
    description:
        'Connect (through the host) to an external MCP server over a '
        'host-built extension transport — serial / usb / ble / tcp / ws. '
        'Returns the connection id; drive it afterward with mcp.list_tools / '
        'mcp.call_tool / mcp.read_resource / mcp.disconnect.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'id': <String, dynamic>{'type': 'string'},
        'transport': <String, dynamic>{
          'type': 'string',
          'enum': <String>['serial', 'tcp', 'websocket', 'usb', 'ble'],
        },
        'options': <String, dynamic>{
          'type': 'object',
          'description':
              'Transport config — serial: {port, baudRate} · tcp: '
              '{host, port} · websocket: {url} · usb/ble: device options.',
        },
      },
      'required': <String>['id', 'transport'],
    },
    handler: wrapInProcess(handler),
  );
}
