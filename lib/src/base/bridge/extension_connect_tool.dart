/// `mcp.connect_extension` — the host-side companion to the kernel's
/// `mcp.connect`. The kernel surface only drives transports it can build
/// itself (`stdio` / `streamableHttp` / `sse`, all FFI-free). Embedded
/// boards (STM32, …) expose their MCP server over an **extension
/// transport** (serial / usb / ble / tcp / ws) whose platform libraries
/// live in `mcp_bridge` (the opt-in FFI home), not the kernel.
///
/// This tool builds the chosen `mcp_bridge` transport, opens it, and
/// injects it through the kernel seam (`StudioBackbone.connectExtension
/// Transport` → `McpClientKernelHost.connectWith`). The connection lands
/// in the same client host registry the kernel `mcp.*` tools resolve by
/// `id`, so once connected the existing `mcp.list_tools` / `mcp.call_tool`
/// / `mcp.read_resource` (e.g. `ui://app`) / `mcp.disconnect` drive the
/// board with no further host wiring. See `specs/platform/08-extension.md`
/// §4 + cherry `embedded-mcp-serving-base` (2026-06-10).
library;

import 'package:brain_kernel/brain_kernel.dart'
    show HostToolRegistry, wrapInProcess;
import 'package:mcp_bridge/mcp_bridge.dart'
    show
        BleClientTransport,
        SerialClientTransport,
        TcpClientTransport,
        UsbClientTransport,
        WebSocketClientTransport;
import 'package:mcp_client/mcp_client.dart' show ClientTransport;

import '../boot/studio_backbone.dart';

/// Register `mcp.connect_extension` onto [registry], building transports
/// through [backbone]'s client host seam. Returns the exposed name.
String registerExtensionConnectTool(
  HostToolRegistry registry,
  StudioBackbone backbone,
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

    // Build the concrete mcp_bridge transport (FFI lives here, not in the
    // kernel) and open it before injection. `options` flows straight to the
    // transport's config map — keys are transport-specific (serial:
    // port/baudRate · tcp: host/port · websocket: url · usb/ble: device).
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

    final conn = await backbone.connectExtensionTransport(
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
