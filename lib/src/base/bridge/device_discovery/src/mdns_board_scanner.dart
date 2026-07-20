// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/device_discovery/lib/src/mdns_board_scanner.dart
// Regenerate with debug/tool/sync_discovery_forks.sh.
//
import 'dart:async';

import 'package:multicast_dns/multicast_dns.dart';

import 'mdns_types.dart';

/// Stage 1 mDNS scanner (`specs/platform/17-device-discovery.md` §2–§3):
/// browses `_mcp._tcp.local` on the local network and yields one
/// [MdnsBoardCandidate] per discovered instance.
///
/// Scope is inherently LAN-only — mDNS is link-local multicast
/// (224.0.0.251), which is exactly the "nearby" definition of spec 17 §2.
///
/// The scanner never requests a manifest (spec 17 §5 conformance) — the
/// caller confirms candidates with the Stage 2 probe (`probeCandidate`).
///
/// The [MDnsClient] is created per scan through [clientFactory] so tests
/// can inject a fake and hosts can customize socket options.
class MdnsBoardScanner {
  MdnsBoardScanner({MDnsClient Function()? clientFactory})
      : _clientFactory = clientFactory ?? MDnsClient.new;

  final MDnsClient Function() _clientFactory;

  /// One scan window. Emits each instance at most once per call (repeat
  /// announcements are deduplicated by instance domain name) and closes
  /// after [timeout]. [recordTimeout] bounds the follow-up SRV/TXT/A
  /// lookups per instance.
  Stream<MdnsBoardCandidate> scan({
    Duration timeout = const Duration(seconds: 5),
    Duration recordTimeout = const Duration(seconds: 2),
  }) async* {
    final client = _clientFactory();
    await client.start();
    final seen = <String>{};
    try {
      await for (final ptr in client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer(mcpMdnsServiceType),
        timeout: timeout,
      )) {
        if (!seen.add(ptr.domainName)) continue;
        final candidate = await _resolve(client, ptr.domainName, recordTimeout);
        if (candidate != null) yield candidate;
      }
    } finally {
      client.stop();
    }
  }

  Future<MdnsBoardCandidate?> _resolve(
    MDnsClient client,
    String domainName,
    Duration recordTimeout,
  ) async {
    final srvRecords = await client
        .lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(domainName),
          timeout: recordTimeout,
        )
        .take(1)
        .toList();
    if (srvRecords.isEmpty) return null; // No SRV — not a resolvable service.
    final srv = srvRecords.first;

    final txtRecords = await client
        .lookup<TxtResourceRecord>(
          ResourceRecordQuery.text(domainName),
          timeout: recordTimeout,
        )
        .take(1)
        .toList();
    final txt = txtRecords.isEmpty
        ? const MdnsTxt(proto: MdnsProto.unknown)
        : MdnsTxt.parse(txtRecords.first.text);

    // Persist the mDNS HOSTNAME (e.g. `mcp-esp32.local`), not a point-in-time
    // IP. The discovered endpoint is saved and reused on later opens, and a
    // DHCP device's address changes across reboots — a stored IP would go stale
    // and the saved app would fail to connect. The hostname re-resolves through
    // mDNS on every connect (macOS/iOS/Android resolve `.local` natively), so
    // the link follows the device to its new address automatically. It also
    // makes the dedupe key (host:port) stable, so a changed IP no longer spawns
    // a duplicate discovered tile. (A user who types a raw IP by hand keeps it
    // verbatim — that's a deliberate static address and never comes through
    // here.) The Stage 2 probe still confirms the name is reachable right now,
    // so a ghost SRV record without a live server is dropped.
    final host = _stripTrailingDot(srv.target);

    return MdnsBoardCandidate(
      host: host,
      port: srv.port,
      instanceName: _instanceNameOf(domainName),
      txt: txt,
    );
  }

  /// mDNS FQDNs come back with a trailing dot (`mcp-esp32.local.`); strip it so
  /// the host is a clean `mcp-esp32.local` for socket/URL use.
  static String _stripTrailingDot(String h) =>
      h.endsWith('.') ? h.substring(0, h.length - 1) : h;

  static String _instanceNameOf(String domainName) {
    const suffix = '.$mcpMdnsServiceType';
    return domainName.endsWith(suffix)
        ? domainName.substring(0, domainName.length - suffix.length)
        : domainName;
  }
}
