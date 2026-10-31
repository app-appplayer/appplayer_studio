/// Reference wiring for joining a central **gateway hub** via `mcp_gateway`:
/// exposing a local MCP server / node so its tools are reachable from outside,
/// and consuming an exposed node as a standard local MCP server.
///
/// This is the "expose to the outside" seam a **local gateway app** (a product)
/// and **Studio** need — a local server (Studio itself, or any local MCP tool
/// surface) registers as a gateway *provider*, and its tools become reachable
/// through the hub; a consumer connects through the gateway and sees it as an
/// ordinary MCP server. AppPlayer uses the same pieces for the account peer
/// link (platform spec 22): a device lends the connections it holds as
/// providers on its own peer node, and another device of the same account
/// opens one as a server, over the relay or a direct pipe.
///
/// Vendored reference (`publish_to: none`): a host copies this file and injects
/// its own **already-started** `GatewayRuntime` (`await runtime.start()`, its
/// connection to the central gateway) plus its local tool dispatch. The runtime
/// lifecycle (start / dispose) is the host's. `mcp_gateway` is unchanged — glue.
library gateway_node;

import 'package:mcp_gateway/mcp_gateway.dart';

/// The hub pump — drive the gateway dispatch protocol across a hub relay
/// (spec 15 §8), entirely over `mcp_gateway`'s public surface (core unchanged).
export 'hub_pump.dart';

/// Surfacing — present a hub consumer as an `mcp_client` ClientTransport so a
/// host opens it through its ordinary MCP server-open path.
export 'hub_surface.dart';

/// ws relay transport — the desktop `(incoming, send)` primitive a host injects
/// (client = consume, node = expose).
export 'hub_relay_ws.dart';

/// Hub caller identity — the market-signed token on a session's `open`, and
/// the market's verification rule for it.
export 'hub_caller.dart';

/// Node server (expose direction) — demux the relay's per-session envelope over
/// one node socket and serve each session against a shared runtime.
export 'hub_node.dart';

/// Account peer link (platform spec 22) — one session moving between the
/// relay and a direct pipe, with in-band `k:"link"` negotiation frames.
export 'peer_link.dart';

/// Relay socket over `web_socket_channel` — native and browser, token in the
/// subprotocol offer.
export 'relay_socket.dart';

/// A held MCP connection offered as one gateway provider — the lending side of
/// the account peer link (spec 22 §5.2).
export 'connection_provider.dart';

/// Expose a local tool surface through the gateway hub.
///
/// Registers [registration] as a provider and routes every incoming dispatch (a
/// remote tool call) to [onToolCall] — the host's own local dispatch: call the
/// tool named `dispatch.method` with `dispatch.params` and return its result.
/// The caller then drives the provider with `adapter.startPollLoop()` and tears
/// it down with `adapter.unregister()`; the loop is left to the caller so the
/// host owns the lifecycle.
Future<GatewayClientAdapter> exposeThroughGateway({
  required GatewayRuntime runtime,
  required ProviderRegistration registration,
  required Future<DispatchResult> Function(DispatchPayload dispatch) onToolCall,
}) async {
  final adapter = GatewayClientAdapter(runtime)..onDispatch = onToolCall;
  await adapter.register(registration);
  return adapter;
}

/// Consume an exposed node through the gateway. The gateway surfaces the remote
/// provider as a standard MCP server locally; the caller uses [GatewayServerAdapter]
/// (e.g. `handleToolsCall`) as an ordinary MCP server.
Future<GatewayServerAdapter> connectThroughGateway({
  required GatewayRuntime runtime,
  required String consumerId,
}) async {
  final adapter = GatewayServerAdapter(runtime);
  await adapter.start(consumerId);
  return adapter;
}
