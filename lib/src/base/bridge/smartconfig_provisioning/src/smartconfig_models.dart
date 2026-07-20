// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/smartconfig_provisioning/lib/src/smartconfig_models.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
/// The ACK a provisioned device sends back over UDP port 18266 once it has
/// decoded the credentials and joined the network: an 11-byte datagram of
/// `length byte (ssidLen + pwdLen + 9) + device MAC (6) + device IP (4)`.
class SmartConfigResult {
  const SmartConfigResult({required this.mac, required this.ip});

  /// Device MAC as lowercase colon-separated hex, e.g. `18:fe:34:9a:a3:c4`.
  final String mac;

  /// Device IPv4 in dotted-quad form, e.g. `192.168.0.42`.
  final String ip;

  Map<String, Object?> toJson() => {'mac': mac, 'ip': ip};

  /// Parse one received datagram; returns null unless it is exactly 11 bytes
  /// and its first byte matches [expectedLength] (the `ssidLen + pwdLen + 9`
  /// checksum of the credentials WE sent — anything else is another sender's
  /// session or broadcast noise and is ignored).
  static SmartConfigResult? tryParseAck(
    List<int> datagram, {
    required int expectedLength,
  }) {
    if (datagram.length != 11) return null;
    if ((datagram[0] & 0xff) != (expectedLength & 0xff)) return null;
    final mac = datagram
        .sublist(1, 7)
        .map((b) => (b & 0xff).toRadixString(16).padLeft(2, '0'))
        .join(':');
    final ip = datagram.sublist(7, 11).map((b) => b & 0xff).join('.');
    return SmartConfigResult(mac: mac, ip: ip);
  }
}
