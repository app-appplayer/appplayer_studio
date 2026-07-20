// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/device_discovery/lib/device_discovery.dart
// Regenerate with debug/tool/sync_discovery_forks.sh.
//
/// Recipe — nearby MCP device discovery
/// (`specs/platform/17-device-discovery.md`).
///
/// Stage 1: [MdnsBoardScanner] browses `_mcp._tcp.local` and yields
/// lightweight candidates (no manifest). Stage 2: [probeCandidate] attaches
/// a standard mcp_client over the candidate's transport
/// ([TcpProbeTransport] for `proto=ndjson`), reads
/// `bundle://manifest.json`, and confirms the [BoardIdentity]. Probe
/// failure drops the candidate.
library;

export 'src/directory_board_scanner.dart';
export 'src/mdns_board_scanner.dart';
export 'src/mdns_types.dart';
export 'src/newline_json_framer.dart';
export 'src/probe.dart';
export 'src/tcp_probe_transport.dart';
