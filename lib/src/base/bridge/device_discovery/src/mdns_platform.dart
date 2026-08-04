// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/device_discovery/lib/src/mdns_platform.dart
// Regenerate with debug/tool/sync_discovery_forks.sh.
//
import 'dart:io';
import 'dart:typed_data';

import 'package:multicast_dns/multicast_dns.dart';

/// Binds the mDNS sockets the way THIS platform allows.
///
/// `multicast_dns` binds 5353 with `reusePort: true` unconditionally. That is
/// right on macOS/iOS/Linux/Windows, where a system responder (mDNSResponder,
/// Avahi) already holds the port and the bind only succeeds by sharing it.
///
/// Android's kernel has no `SO_REUSEPORT` exposed through Dart's socket layer,
/// so the same bind throws:
///
/// ```
/// Dart Socket ERROR: socket_linux.cc:157: `reusePort` not supported
/// ```
///
/// The scan then fails before a single query goes out — silently, because the
/// error surfaces on the socket, not as a thrown Dart exception the scanner
/// could report. Measured on a Galaxy Z Fold 2: the app rebound every 4s for
/// minutes and discovered nothing, while the same board resolved from a Mac on
/// the same subnet. Android also does not run a second responder on 5353, so
/// dropping the flag there costs nothing.
///
/// The source port moves too, and for a second reason.
///
/// Android always runs its own responder (`mdnsd`, the daemon behind
/// `NsdManager`) bound to 5353. Two sockets on one UDP port means the kernel
/// decides which one a UNICAST datagram goes to, and a responder answering a
/// query sent from 5353 may answer unicast. The reply then lands in the system
/// daemon and our scan sees nothing — no error, no packet, just an empty
/// window. Binding an ephemeral port instead makes the query a "legacy unicast
/// query" (RFC 6762 §6.7): the responder addresses its answer to that port,
/// which no one else holds, so the reply cannot be taken by another socket.
///
/// The destination port is untouched — queries still go to 224.0.0.251:5353.
/// What is given up is passive reception of unsolicited announcements, which an
/// active browse does not rely on.
///
/// Both of these are platform facts, not host preferences, so this is the
/// DEFAULT rather than something each host has to remember to inject.
Future<RawDatagramSocket> bindMdnsSocket(
  dynamic host,
  int port, {
  bool reuseAddress = true,
  bool reusePort = true,
  int ttl = 1,
  InternetAddress? sendVia,
}) async {
  final socket = await RawDatagramSocket.bind(
    host,
    Platform.isAndroid ? 0 : port,
    reuseAddress: reuseAddress,
    reusePort: reusePort && !Platform.isAndroid,
    ttl: ttl,
  );
  if (sendVia != null) sendMulticastVia(socket, sendVia);
  return socket;
}

/// Pins this socket's multicast SENDS to [localAddress]'s interface.
///
/// Not a platform workaround: the caller owns one interface and says so, on
/// every platform. Without it the kernel picks, and the routing table answers
/// a different question than "which network is the device on" — see
/// [createPlatformMDnsClients] for the measured case.
void sendMulticastVia(RawDatagramSocket socket, InternetAddress localAddress) {
  if (socket.address.type != InternetAddressType.IPv4) return;
  if (localAddress.type != InternetAddressType.IPv4) return;
  try {
    socket.setRawOption(RawSocketOption(
      RawSocketOption.levelIPv4,
      RawSocketOption.IPv4MulticastInterface,
      Uint8List.fromList(localAddress.rawAddress),
    ));
  } on OSError {
    // An interface that refuses the option keeps the kernel's choice, which is
    // the behaviour that already works wherever the default route is right.
  } on SocketException {
    // Same.
  }
}

/// One [MDnsClient] per multicast-capable IPv4 interface, each pinned to its
/// own interface for sending.
///
/// A single client bound to `0.0.0.0` sends where the routing table says, and
/// the routing table answers a different question than "which network is the
/// device on". Measured on a phone acting as a hotspot:
///
/// ```
/// multicast 224.0.0.251 dev rmnet_data1 table 1023 src 192.0.0.2 uid 10663
/// swlan0 192.168.73.37/24        <- where the board actually is
/// ```
///
/// Every query left over mobile data and nothing on the hotspot heard it,
/// while the identical board had resolved fine minutes earlier on station
/// Wi-Fi — there the same route happened to name `wlan0`. The problem is not
/// Android's: a Mac sharing its connection, a laptop on Wi-Fi and Ethernet at
/// once, a machine with a VPN or a Docker bridge each put the same choice in
/// front of the same code, and any single answer is wrong on some of them.
///
/// So no choice is made. Every interface is queried and whoever answers is
/// found. mDNS is link-local by construction (TTL 1, 224.0.0.251), so querying
/// an interface with no responder costs one datagram and reaches nothing
/// beyond that link.
Future<List<MDnsClient>> createPlatformMDnsClients() async {
  final interfaces = await multicastInterfaces();
  if (interfaces.isEmpty) return <MDnsClient>[createPlatformMDnsClient()];
  return <MDnsClient>[
    for (final interface in interfaces) clientFor(interface),
  ];
}

/// A client that sends through [interface].
MDnsClient clientFor(NetworkInterface interface) {
  final local = firstIPv4(interface);
  return MDnsClient(
    rawDatagramSocketFactory: (host, port,
            {bool reuseAddress = true,
            bool reusePort = true,
            int ttl = 1}) =>
        bindMdnsSocket(
      host,
      port,
      reuseAddress: reuseAddress,
      reusePort: reusePort,
      ttl: ttl,
      sendVia: local,
    ),
  );
}

/// The `interfacesFactory` for [MDnsClient.start] so a client joins only the
/// interface it sends on.
NetworkInterfacesFactory interfacesFactoryFor(NetworkInterface interface) =>
    (InternetAddressType type) async => <NetworkInterface>[interface];

/// Non-loopback IPv4 interfaces, in enumeration order.
Future<List<NetworkInterface>> multicastInterfaces() async {
  try {
    final all = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: false,
      type: InternetAddressType.IPv4,
    );
    return <NetworkInterface>[
      for (final i in all)
        if (firstIPv4(i) != null) i,
    ];
  } on OSError {
    // Enumeration is not guaranteed (a sandbox may refuse it). An empty list
    // falls back to one unpinned client, which is the behaviour that already
    // works wherever the default route is right — better than finding nothing.
    return const <NetworkInterface>[];
  } on SocketException {
    return const <NetworkInterface>[];
  }
}

/// First IPv4 address of [interface], or null if it has none.
InternetAddress? firstIPv4(NetworkInterface interface) {
  for (final a in interface.addresses) {
    if (a.type == InternetAddressType.IPv4) return a;
  }
  return null;
}

/// An [MDnsClient] with the platform-correct bind but no interface pinning —
/// the fallback for when interfaces cannot be enumerated.
MDnsClient createPlatformMDnsClient() =>
    MDnsClient(rawDatagramSocketFactory: bindMdnsSocket);

/// Holds whatever the platform requires OPEN for multicast reception to reach
/// this process, for the duration of a scan.
///
/// On Android, Wi-Fi hardware filters multicast frames that are not addressed
/// to the device unless the app holds a `WifiManager.MulticastLock`. Binding
/// 5353 successfully is not enough — the query goes out and the responses are
/// dropped below the socket. The lock is battery-expensive by design, so it is
/// held per scan window rather than for the process lifetime.
///
/// Platform code lives in the host, so this is a port. Hosts on platforms with
/// nothing to acquire (desktop, iOS) leave the default.
abstract interface class MulticastGate {
  /// Opens reception. Must be paired with [release]; nested [acquire] calls
  /// are reference-counted by the implementation.
  Future<void> acquire();

  /// Closes reception opened by a matching [acquire].
  Future<void> release();
}

/// Default gate for platforms where multicast reception needs no permission.
class OpenMulticastGate implements MulticastGate {
  const OpenMulticastGate();

  @override
  Future<void> acquire() async {}

  @override
  Future<void> release() async {}
}
