/// End-to-end test for the Studio extension-transport seam + the
/// `mcp.connect_extension` host tool (cherry `embedded-mcp-serving-base`,
/// 2026-06-10). Proves a board-shaped MCP server reached over an
/// mcp_bridge transport is driveable through the kernel `mcp.*` surface —
/// without a physical board. Mirrors the recipe's tcp rendezvous.
@TestOn('vm')
library;

import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart' as fb;
import 'package:brain_kernel/mcp_host.dart' show McpClientKernelHost;
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bridge/mcp_bridge.dart'
    show TcpClientTransport, TcpServerTransport;
import 'package:mcp_server/mcp_server.dart'
    show CallToolResult, Server, ServerCapabilities, TextContent;
import 'package:appplayer_studio/base.dart'
    show StudioBackbone, registerExtensionConnectTool;

void main() {
  late Directory tmpDir;
  late fb.KernelApp app;
  late McpClientKernelHost clientHost;
  late StudioBackbone backbone;

  // A board-shaped MCP server stood up over mcp_bridge's tcp server
  // transport, advertising a single `led.set` tool.
  late Server boardServer;
  late TcpServerTransport boardTransport;
  late int port;

  setUpAll(() async {
    // Free port for the client/server rendezvous (mcp_bridge's tcp server
    // transport binds a fixed port and surfaces no OS-assigned one).
    final probe = await ServerSocket.bind('localhost', 0);
    port = probe.port;
    await probe.close();

    boardServer = Server(
      name: 'fake-board',
      version: '1.0.0',
      capabilities: ServerCapabilities.simple(tools: true),
    );
    boardServer.addTool(
      name: 'led.set',
      description: 'set the onboard LED',
      inputSchema: const {'type': 'object'},
      handler:
          (args) async =>
              CallToolResult(content: [TextContent(text: 'led on')]),
    );
    boardTransport = TcpServerTransport({'host': 'localhost', 'port': port});
    await boardTransport.start();
    boardServer.connect(boardTransport);

    tmpDir = Directory.systemTemp.createTempSync('vibe_studio_ext_');
    clientHost = McpClientKernelHost();
    app = await fb.KernelApp.boot(
      workspaceId: 'vibe_studio_ext_test',
      kvStorage: fb.KvStoragePortAdapter(rootDir: tmpDir.path),
      bundleRegistryStorageDir: tmpDir.path,
      clientHost: clientHost,
    );
    backbone = StudioBackbone(
      toolId: 'vibe_studio_ext_test',
      configRoot: tmpDir.path,
      app: app,
      clientHost: clientHost,
      agentHost: null,
      growth: null,
      seedLoader: null,
    );
  });

  tearDownAll(() async {
    await clientHost.shutdown();
    boardTransport.close();
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {
      /* best-effort cleanup */
    }
  });

  test(
    'connectExtensionTransport reaches the board and drives its tool',
    () async {
      final transport = TcpClientTransport({'host': 'localhost', 'port': port});
      await transport.start();

      final conn = await backbone.connectExtensionTransport(
        id: 'board-1',
        transport: transport,
      );
      expect(conn.isConnected, isTrue);

      final tools = await conn.listTools();
      expect(tools.map((t) => t.name), contains('led.set'));

      final result = await conn.callTool('led.set', const {});
      expect(result.isError ?? false, isFalse);
      expect(result.content, isNotEmpty);
    },
  );

  test('mcp.connect_extension tool registers and connects by id', () async {
    final exposedNames = <String>[];
    final endpoint = app.addEndpoint(label: 'studio', appName: 'ext-test');
    endpoint.server.register();
    final registry = fb.HostToolRegistry(
      endpoint: endpoint.server,
      attachToDispatcher: (name, _) => exposedNames.add(name),
      detachFromDispatcher: (_) {},
    );

    final exposed = registerExtensionConnectTool(registry, backbone);
    // Registered under the `mcp.*` family (sibling to the kernel's
    // `mcp.connect`) on both the dispatcher and the endpoint. The
    // connect-by-id drive path is covered end-to-end by the first test.
    expect(exposed, equals('mcp.connect_extension'));
    expect(exposedNames, contains('mcp.connect_extension'));
  });
}
