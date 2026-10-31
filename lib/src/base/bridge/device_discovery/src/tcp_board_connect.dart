// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/device_discovery/lib/src/tcp_board_connect.dart
// Regenerate with debug/tool/sync_discovery_forks.sh.
//
/// Dialling a board that speaks MCP over raw TCP (newline JSON-RPC, platform
/// spec 17 §3) as a ready MCP client.
///
/// A host keeps such a board as a `tcp://host:port` address — what an mDNS
/// `proto=ndjson` sighting resolves to, or what a person types. Every host
/// that opens one does the same three things, so they live here once: parse
/// the address, start the socket, and run the MCP handshake inside one bound,
/// releasing the socket if any of it fails (a board that takes one peer at a
/// time stays unreachable while a half-open link holds it).
library;

import 'dart:async';

import 'package:mcp_client/mcp_client.dart';

import 'mdns_types.dart';
import 'tcp_probe_transport.dart';

/// The scheme a raw-TCP board address carries.
const String tcpBoardScheme = 'tcp://';

/// `tcp://<dial host>:<port>` for an [MdnsProto.ndjson] sighting.
String tcpBoardAddress(MdnsBoardCandidate candidate) =>
    '$tcpBoardScheme${candidate.dialHost}:${candidate.port}';

/// Whether [baseUrl] names a raw-TCP board.
bool isTcpBoardAddress(String baseUrl) => baseUrl.startsWith(tcpBoardScheme);

/// Connects an MCP [Client] to the board at [baseUrl] (`tcp://host:port`).
///
/// [dialTimeout] bounds the socket connect and the initialize round-trip
/// together. Throws [ArgumentError] for an address that is not one, and
/// whatever the dial raised when it fails — after closing the socket.
Future<Client> connectTcpBoard(
  String baseUrl, {
  Duration dialTimeout = const Duration(seconds: 25),
  String clientName = 'AppPlayer Client',
  String clientVersion = '1.0.0',
}) async {
  if (!isTcpBoardAddress(baseUrl)) {
    throw ArgumentError.value(baseUrl, 'baseUrl', 'not a tcp:// board address');
  }
  final rest = baseUrl.substring(tcpBoardScheme.length);
  final sep = rest.lastIndexOf(':');
  final host = sep > 0 ? rest.substring(0, sep) : '';
  final port = sep > 0 ? int.tryParse(rest.substring(sep + 1)) : null;
  if (host.isEmpty || port == null) {
    throw ArgumentError.value(
      baseUrl,
      'baseUrl',
      'tcp endpoint needs host:port',
    );
  }
  final transport = TcpProbeTransport(host: host, port: port);
  try {
    return await Future.sync(() async {
      await transport.start();
      final client = Client(name: clientName, version: clientVersion);
      await client.connect(transport);
      return client;
    }).timeout(dialTimeout);
  } catch (_) {
    try {
      transport.close();
    } catch (_) {
      // Best effort: the dial's own error is what the caller needs.
    }
    rethrow;
  }
}
