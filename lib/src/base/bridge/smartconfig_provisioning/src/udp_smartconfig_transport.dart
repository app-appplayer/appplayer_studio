// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/smartconfig_provisioning/lib/src/udp_smartconfig_transport.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
import 'dart:async';
import 'dart:io';

import 'smartconfig_sender.dart';

/// Concrete dart:io [SmartConfigTransport]: a broadcast-enabled UDP socket
/// sending to 255.255.255.255:7001 and an any-address listener on 18266 for
/// the device ACK (ports from the reference `EsptouchTaskParameter`). Not
/// used by unit tests — those inject a fake transport.
class UdpSmartConfigTransport implements SmartConfigTransport {
  UdpSmartConfigTransport._(this._socket, this.localIpv4, this.targetPort);

  /// Bind the sockets and discover the host's IPv4 (first non-loopback
  /// interface address; [0,0,0,0] if none — the device then broadcasts its
  /// ACK instead of unicasting).
  static Future<UdpSmartConfigTransport> bind({
    int ackPort = 18266,
    int targetPort = 7001,
  }) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, ackPort);
    socket.broadcastEnabled = true;
    var localIpv4 = const <int>[0, 0, 0, 0];
    for (final iface in await NetworkInterface.list(
        includeLoopback: false, type: InternetAddressType.IPv4)) {
      if (iface.addresses.isNotEmpty) {
        localIpv4 = iface.addresses.first.rawAddress;
        break;
      }
    }
    return UdpSmartConfigTransport._(socket, localIpv4, targetPort);
  }

  final RawDatagramSocket _socket;
  final int targetPort;

  @override
  final List<int> localIpv4;

  static final InternetAddress _broadcast =
      InternetAddress('255.255.255.255');

  @override
  void sendBroadcast(List<int> payload) {
    _socket.send(payload, _broadcast, targetPort);
  }

  @override
  Stream<List<int>> get ackDatagrams => _socket
      .where((event) => event == RawSocketEvent.read)
      .map((_) => _socket.receive())
      .where((datagram) => datagram != null)
      .map((datagram) => datagram!.data);

  @override
  Future<void> close() async {
    _socket.close();
  }
}
