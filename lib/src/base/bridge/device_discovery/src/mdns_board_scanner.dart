// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/device_discovery/lib/src/mdns_board_scanner.dart
// Regenerate with debug/tool/sync_discovery_forks.sh.
//
import 'dart:async';

import 'package:multicast_dns/multicast_dns.dart';

import 'mdns_platform.dart';
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
/// A scan queries EVERY multicast-capable interface, not one. Which interface
/// a `0.0.0.0` socket sends multicast on is the routing table's decision, and
/// the routing table answers a different question than "which network is the
/// device on" — see [createPlatformMDnsClients] for the hotspot case where it
/// answered "the cellular one". Rather than pick, the scanner opens one client
/// per interface and merges what comes back.
///
/// [clientFactory] overrides that with a single client, for tests and for a
/// host that knows better than the default.
///
/// [gate] holds whatever the platform needs open for multicast to arrive
/// (Android's `MulticastLock`); it wraps the scan window, not the process.
class MdnsBoardScanner {
  MdnsBoardScanner({
    MDnsClient Function()? clientFactory,
    MulticastGate gate = const OpenMulticastGate(),
    void Function(Object error)? onSocketError,
  })  : _clientFactory = clientFactory,
        _gate = gate,
        _onSocketError = onSocketError;

  /// When null, one client per interface (the default). When set, exactly one.
  final MDnsClient Function()? _clientFactory;
  final MulticastGate _gate;

  /// Errors raised by the mDNS socket AFTER a successful bind — a join that
  /// the interface refuses, a receive the platform denies. `multicast_dns`
  /// drops these on the floor by default, which is how Android could fail
  /// every scan for months while the scanner reported a clean "found none".
  final void Function(Object error)? _onSocketError;

  /// One scan window. Emits each instance at most once per call (repeat
  /// announcements are deduplicated by instance domain name) and closes
  /// after [timeout]. [recordTimeout] bounds the follow-up SRV/TXT/A
  /// lookups per instance.
  Stream<MdnsBoardCandidate> scan({
    Duration timeout = const Duration(seconds: 5),
    Duration recordTimeout = const Duration(seconds: 2),
  }) async* {
    await _gate.acquire();
    final started = <MDnsClient>[];
    try {
      final browsed = StreamController<_Sighting>();
      final windows = <Future<void>>[];
      final override = _clientFactory;

      if (override != null) {
        final client = override();
        await client.start(onError: _onSocketError);
        started.add(client);
        windows.add(_browse(client, browsed, timeout));
      } else {
        for (final interface in await multicastInterfaces()) {
          final client = clientFor(interface);
          try {
            await client.start(
              interfacesFactory: interfacesFactoryFor(interface),
              onError: _onSocketError,
            );
          } catch (error) {
            // One interface refusing the join must not take the scan down —
            // a machine with a VPN or a virtual bridge always has one.
            _onSocketError?.call(error);
            continue;
          }
          started.add(client);
          windows.add(_browse(client, browsed, timeout));
        }
        if (started.isEmpty) {
          final client = createPlatformMDnsClient();
          await client.start(onError: _onSocketError);
          started.add(client);
          windows.add(_browse(client, browsed, timeout));
        }
      }

      unawaited(Future.wait(windows).whenComplete(browsed.close));

      final seen = <String>{};
      await for (final sighting in browsed.stream) {
        if (!seen.add(sighting.domainName)) continue;
        final candidate =
            await _resolve(sighting.client, sighting.domainName, recordTimeout);
        if (candidate != null) yield candidate;
      }
    } finally {
      // `start()` may throw (a platform that refuses the bind), and the
      // consumer may cancel mid-stream. Both paths must still hand the gate
      // back — an Android MulticastLock leaked here keeps the Wi-Fi radio out
      // of its power-saving filter for the rest of the process.
      for (final client in started) {
        client.stop();
      }
      await _gate.release();
    }
  }

  /// Pumps one client's browse window into the shared stream. Each interface
  /// runs its own window concurrently, so the scan takes as long as ONE
  /// window rather than the sum.
  Future<void> _browse(
    MDnsClient client,
    StreamController<_Sighting> out,
    Duration timeout,
  ) async {
    // One query per window is one lost datagram away from an empty scan.
    // Multicast is unreliable by construction and a Wi-Fi hotspot drops it
    // readily — measured as a board that appeared, vanished and reappeared
    // while sitting still. RFC 6762 §5.1 has one-shot queriers retransmit for
    // exactly this reason, so the window is split into repeats. Answers are
    // deduplicated upstream, so a board that replies to all of them still
    // yields one candidate.
    final attempts = _repeatsFor(timeout);
    final slice = Duration(
      microseconds: timeout.inMicroseconds ~/ attempts,
    );
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (out.isClosed) return;
      try {
        await for (final ptr in client.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer(mcpMdnsServiceType),
          timeout: slice,
        )) {
          if (out.isClosed) return;
          out.add(_Sighting(client, ptr.domainName));
        }
      } catch (error) {
        _onSocketError?.call(error);
        return;
      }
    }
  }

  /// Repeats that fit in [timeout] while leaving each one long enough for a
  /// board to answer. Sub-second slices would expire before a sleepy device
  /// on a congested link replies, so short windows simply query once.
  static int _repeatsFor(Duration timeout) {
    const minSlice = Duration(milliseconds: 700);
    final fits = timeout.inMicroseconds ~/ minSlice.inMicroseconds;
    if (fits < 2) return 1;
    return fits > 3 ? 3 : fits;
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

    // Keep the mDNS HOSTNAME as the candidate's IDENTITY: it is stable across
    // a DHCP move, so the dedupe key (host:port) does not spawn a second tile
    // when the address changes.
    //
    // It is NOT what gets dialled. The comment that used to sit here claimed
    // "macOS/iOS/Android resolve `.local` natively" — Android does not. Its
    // system resolver has no mDNS path, so `mcp-esp32.local` came back
    // `unknown host` while the same address pinged in 130ms, and every probe
    // failed in 15ms with the board sitting right there. [dialHost] uses the
    // announced A record for that.
    final host = _stripTrailingDot(srv.target);

    // The announcement's own A record. Kept because [host] is only dialable
    // where the platform resolves `.local`, and Android does not.
    final aRecords = await client
        .lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(srv.target),
          timeout: recordTimeout,
        )
        .take(1)
        .toList();

    return MdnsBoardCandidate(
      host: host,
      port: srv.port,
      instanceName: _instanceNameOf(domainName),
      txt: txt,
      address: aRecords.isEmpty ? null : aRecords.first.address.address,
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

/// A PTR seen by a particular client. The follow-up SRV/TXT lookups must go
/// back out the SAME interface — that is the one the responder answered on.
class _Sighting {
  const _Sighting(this.client, this.domainName);

  final MDnsClient client;
  final String domainName;
}
