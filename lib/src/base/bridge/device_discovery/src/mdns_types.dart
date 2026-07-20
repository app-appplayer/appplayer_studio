// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/device_discovery/lib/src/mdns_types.dart
// Regenerate with debug/tool/sync_discovery_forks.sh.
//
/// Stage 1 candidate types for the mDNS/DNS-SD contract of
/// `specs/platform/17-device-discovery.md` §3.
library;

/// DNS-SD service type every MCP-serving LAN device announces (spec 17 §3).
const String mcpMdnsServiceType = '_mcp._tcp.local';

/// Recommended default TCP listener port (spec 17 §3 — keypad M-C-P;
/// a manual-entry convention only, the SRV record stays authoritative).
const int mcpDefaultTcpPort = 6270;

/// `proto` TXT key values (spec 17 §3). `ndjson` = raw TCP +
/// newline-delimited JSON-RPC (the embedded board contract); `http` =
/// MCP streamable HTTP. Anything else / missing parses as [unknown].
enum MdnsProto { ndjson, http, unknown }

/// Parsed TXT record of one `_mcp._tcp` announcement.
class MdnsTxt {
  const MdnsTxt({
    required this.proto,
    this.id,
    this.version,
    this.path,
    this.raw = const <String, String>{},
  });

  /// Wire protocol Stage 2 must use to attach (spec 17 §3, MUST key).
  final MdnsProto proto;

  /// Manifest id hint (`<vendor>.<model>`, SHOULD key). Stage 1 metadata
  /// only — the authoritative id comes from the Stage 2 probe.
  final String? id;

  /// Version hint (`v` key, MAY).
  final String? version;

  /// Endpoint path (MUST when proto=http).
  final String? path;

  /// All key=value pairs as received, for keys beyond the contract.
  final Map<String, String> raw;

  /// Parse the raw TXT text (one `key=value` entry per line — the shape
  /// `package:multicast_dns` delivers). Keys without `=` map to ''.
  factory MdnsTxt.parse(String text) {
    final raw = <String, String>{};
    for (final line in text.split('\n')) {
      final entry = line.trim();
      if (entry.isEmpty) continue;
      final eq = entry.indexOf('=');
      if (eq < 0) {
        raw[entry] = '';
      } else {
        raw[entry.substring(0, eq)] = entry.substring(eq + 1);
      }
    }
    final proto = switch (raw['proto']) {
      'ndjson' => MdnsProto.ndjson,
      'http' => MdnsProto.http,
      _ => MdnsProto.unknown,
    };
    return MdnsTxt(
      proto: proto,
      id: raw['id'],
      version: raw['v'],
      path: raw['path'],
      raw: raw,
    );
  }
}

/// One Stage 1 candidate found on the LAN. Carries no manifest — per
/// spec 17 §1 the manifest is only obtained by the Stage 2 probe.
class MdnsBoardCandidate {
  const MdnsBoardCandidate({
    required this.host,
    required this.port,
    required this.instanceName,
    required this.txt,
  });

  /// The SRV target hostname (e.g. `mcp-esp32.local`), NOT a resolved IP.
  /// The endpoint is persisted and reused on later opens, so storing the
  /// hostname — which re-resolves through mDNS on every connect — survives
  /// the device's DHCP address changing, whereas a point-in-time IP would go
  /// stale. (A hand-typed static IP is a separate, manual path.)
  final String host;

  /// SRV port — authoritative (spec 17 §3).
  final int port;

  /// DNS-SD instance name (= display name, spec 17 §3).
  final String instanceName;

  /// Parsed TXT record.
  final MdnsTxt txt;

  /// Whether the Stage 2 probe can attach over raw TCP + newline JSON-RPC
  /// ([TcpProbeTransport]). `http` candidates use [probeableOverHttp]
  /// instead; `unknown` candidates are non-conformant and out of the probe
  /// path entirely.
  bool get probeableOverTcp => txt.proto == MdnsProto.ndjson;

  /// Whether the Stage 2 probe must attach over MCP streamable HTTP — the
  /// STANDARD MCP-over-network transport ([MdnsProto.http]). Confirmed via
  /// `probeHttpCandidate([httpEndpoint])` and registered as a plain
  /// `http(s)://` server (no custom transport).
  bool get probeableOverHttp => txt.proto == MdnsProto.http;

  /// Streamable-HTTP endpoint URL for an [MdnsProto.http] candidate —
  /// `http://<host>[:<port>]<path>`. The SRV port is omitted when it is the
  /// HTTP default (80) so the canonical URL matches what a user would type by
  /// hand (`http://board.local/mcp`). Falls back to `/mcp` when the announce
  /// omitted the (MUST-when-http) `path` TXT key, matching the board default.
  String get httpEndpoint {
    final rawPath = txt.path;
    final path = (rawPath == null || rawPath.isEmpty)
        ? '/mcp'
        : (rawPath.startsWith('/') ? rawPath : '/$rawPath');
    final authority = port == 80 ? host : '$host:$port';
    return 'http://$authority$path';
  }

  @override
  String toString() =>
      'MdnsBoardCandidate("$instanceName", $host:$port, '
      'proto=${txt.proto.name}${txt.id != null ? ', id=${txt.id}' : ''})';
}
