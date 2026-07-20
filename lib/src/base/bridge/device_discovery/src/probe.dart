// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/device_discovery/lib/src/probe.dart
// Regenerate with debug/tool/sync_discovery_forks.sh.
//
import 'dart:async';
import 'dart:convert';

import 'package:mcp_client/mcp_client.dart'
    show Client, ClientTransport, McpClient, TransportConfig;

/// Confirmed identity of a probed device — the `manifest` object of
/// `bundle://manifest.json` (`embedded/docs/01_SRS/SRS.md` FR-SERVE).
class BoardIdentity {
  const BoardIdentity({
    required this.id,
    required this.name,
    required this.version,
    this.entryPoint,
    this.manifest,
  });

  /// Manifest id (`<vendor>.<model>`).
  final String id;

  /// User-facing display name.
  final String name;

  /// Semver version.
  final String version;

  /// Entry UI document uri (usually `ui://app`); null when the board did
  /// not declare one.
  final String? entryPoint;

  /// The raw manifest object exactly as the board served it. Carries
  /// optional fields the typed accessors don't model — notably the `trust`
  /// signature block (`specs/platform/17-device-discovery.md` §6) that
  /// hosts verify against their root CAs. Null only for identities built
  /// by callers that never held the raw document.
  final Map<String, Object?>? manifest;

  @override
  String toString() =>
      'BoardIdentity($id, "$name", $version'
      '${entryPoint != null ? ', entry=$entryPoint' : ''})';
}

/// Stage 2 probe-confirm (`specs/platform/17-device-discovery.md` §1) —
/// transport agnostic: build the candidate's [ClientTransport], run a
/// standard mcp_client `initialize`, read `bundle://manifest.json`, and
/// return the confirmed [BoardIdentity].
///
/// Returns null when the probe does not complete within [timeout] or any
/// step fails — probe failure means the candidate is dropped (it was
/// caught by a scan but is not a conforming MCP node). The probe doubles
/// as conformance verification.
///
/// [buildTransport] must hand back a transport that is ready to carry
/// messages (e.g. `TcpProbeTransport..start()` awaited, or a started
/// `BleClientTransport`). The transport is always closed before this
/// function returns.
Future<BoardIdentity?> probeCandidate({
  required FutureOr<ClientTransport> Function() buildTransport,
  Duration timeout = const Duration(seconds: 10),
  String clientName = 'device_discovery.probe',
  String clientVersion = '0.0.1',
}) async {
  ClientTransport? transport;
  Client? client;
  try {
    final attempt = Future.sync(() async {
      transport = await buildTransport();
      client = Client(name: clientName, version: clientVersion);
      // `connect` performs the MCP `initialize` handshake internally and
      // throws when it does not complete.
      await client!.connect(transport!);
      return probeConnectedClient(client!);
    });
    // `.timeout` abandons [attempt] when it fires; without a listener a
    // late in-flight failure (e.g. a peer resetting the probe socket)
    // would surface as an unhandled async exception in the caller's zone.
    unawaited(attempt.then<void>((_) {}, onError: (_) {}));
    return await attempt.timeout(timeout);
  } catch (_) {
    // Probe failure = candidate dropped (spec 17 §1). The reason is not
    // surfaced — a failed probe simply never reaches the discovery surface.
    return null;
  } finally {
    try {
      client?.dispose();
    } catch (_) {
      // Transport may already be torn down.
    }
    try {
      transport?.close();
    } catch (_) {
      // Already closed.
    }
  }
}

/// Stage 2 probe-confirm over MCP streamable HTTP — the STANDARD
/// MCP-over-network transport (`specs/platform/17-device-discovery.md` §3,
/// `proto=http`). Unlike [probeCandidate], no custom [ClientTransport] is
/// built: mcp_client's own streamable-HTTP transport dials [baseUrl]
/// (`http(s)://host[:port]/path`), runs `initialize`, and the shared
/// [probeConnectedClient] reads `bundle://manifest.json`.
///
/// Returns null on any failure or on [timeout] — a dropped candidate, exactly
/// like the TCP path. The client is always disposed before returning.
Future<BoardIdentity?> probeHttpCandidate({
  required String baseUrl,
  Duration timeout = const Duration(seconds: 10),
  String clientName = 'device_discovery.probe',
  String clientVersion = '0.0.1',
}) async {
  Client? client;
  try {
    final attempt = Future.sync(() async {
      final result = await McpClient.createAndConnect(
        config: McpClient.simpleConfig(
          name: clientName,
          version: clientVersion,
        ),
        transportConfig: TransportConfig.streamableHttp(
          baseUrl: baseUrl,
          // The probe is a throwaway connection; don't DELETE the (stateless)
          // session on close.
          terminateOnClose: false,
        ),
      );
      if (result.isFailure) return null;
      client = result.get();
      return probeConnectedClient(client!);
    });
    // Keep a listener so a late in-flight failure after the timeout fires
    // never escapes as an unhandled async error (mirrors [probeCandidate]).
    unawaited(attempt.then<void>((_) {}, onError: (_) {}));
    return await attempt.timeout(timeout);
  } catch (_) {
    return null;
  } finally {
    try {
      client?.dispose();
    } catch (_) {
      // Transport may already be torn down.
    }
  }
}

/// The transport-agnostic half of [probeCandidate]: read
/// `bundle://manifest.json` over an ALREADY CONNECTED standard client and
/// confirm the identity. Use directly when the client came from another
/// connect path (e.g. a streamableHttp endpoint from a directory entry) —
/// the caller owns the client's lifecycle.
Future<BoardIdentity?> probeConnectedClient(Client client) async {
  final result = await client.readResource('bundle://manifest.json');
  if (result.contents.isEmpty) return null;
  final text = result.contents.first.text;
  if (text == null) return null;
  final decoded = jsonDecode(text);
  if (decoded is! Map) return null;
  // Contract shape: {"manifest": {...}, "ui": {...}} — tolerate a flat
  // manifest object as well.
  final manifest =
      decoded['manifest'] is Map ? decoded['manifest'] as Map : decoded;
  final id = manifest['id'];
  final name = manifest['name'];
  final version = manifest['version'];
  if (id is! String || name is! String || version is! String) return null;
  return BoardIdentity(
    id: id,
    name: name,
    version: version,
    entryPoint: manifest['entryPoint'] as String?,
    manifest: manifest.cast<String, Object?>(),
  );
}
