// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/serial_provisioning/lib/src/serial_client.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
import 'dart:async';
import 'dart:convert';

import 'serial_models.dart';

/// Line-protocol client for provisioning a node over its UART console.
///
/// Transport-agnostic: the constructor takes the byte stream FROM the device
/// and a byte writer TO the device — no dart:io serial dependency; the host
/// wires a real serial port (or anything else that moves bytes).
///
/// Wire contract (the firmware implements exactly this):
///   host → device (LF-terminated lines, args quoted, `"`/`\` escaped):
///     `prov.scan` | `prov.set "<ssid>" "<password>"` | `prov.forget` | `prov.status`
///   device → host: single JSON lines prefixed with `#PROV `, interleaved
///   with arbitrary log noise (ignored):
///     {"aps":[{"ssid":..,"rssi":-49,"auth":2},..]}      — scan result
///     {"ok":true}                                       — set/forget accepted
///     {"status":"connected","ip":..} /
///     {"status":"failed","reason":..}                   — terminal join state
///     {"provisioned":bool,"ssid":..,"ip":..}            — status query
class SerialProvisioningClient {
  SerialProvisioningClient({
    required Stream<List<int>> fromDevice,
    required void Function(List<int>) toDevice,
  }) : _toDevice = toDevice {
    _sub = fromDevice.listen(_onBytes);
  }

  static const String _sentinel = '#PROV ';

  final void Function(List<int>) _toDevice;
  late final StreamSubscription<List<int>> _sub;
  final List<int> _lineBuffer = <int>[];
  final StreamController<Map<String, Object?>> _payloads =
      StreamController<Map<String, Object?>>.broadcast();

  /// Reassemble LF-terminated lines from arbitrary chunk boundaries and
  /// surface only well-formed `#PROV {json}` payloads; everything else on the
  /// console is log noise and is dropped.
  void _onBytes(List<int> chunk) {
    for (final b in chunk) {
      if (b == 0x0a) {
        _handleLine(utf8.decode(_lineBuffer, allowMalformed: true));
        _lineBuffer.clear();
      } else {
        _lineBuffer.add(b);
      }
    }
  }

  void _handleLine(String raw) {
    var line = raw;
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    if (!line.startsWith(_sentinel)) return;
    try {
      final decoded = jsonDecode(line.substring(_sentinel.length));
      if (decoded is Map) {
        _payloads.add(Map<String, Object?>.from(decoded));
      }
    } on FormatException {
      // A truncated or corrupted sentinel line — treat as noise.
    }
  }

  /// Quote one command argument: wrap in `"`, escape embedded `\` and `"`.
  static String quoteArg(String s) =>
      '"${s.replaceAll('\\', r'\\').replaceAll('"', r'\"')}"';

  void _sendLine(String line) => _toDevice(utf8.encode('$line\n'));

  /// Await the next `#PROV` payload matching [match]. Subscribes BEFORE the
  /// caller sends the command so no response can slip through.
  Future<Map<String, Object?>> _next(
    bool Function(Map<String, Object?>) match,
    Duration timeout,
  ) =>
      _payloads.stream.firstWhere(match).timeout(timeout);

  /// Ask the device to scan; returns the APs it can see from its Wi-Fi side.
  Future<List<WifiAp>> scan({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final response = _next((p) => p.containsKey('aps'), timeout);
    _sendLine('prov.scan');
    final payload = await response;
    final aps = (payload['aps'] as List?) ?? const [];
    return [
      for (final a in aps) WifiAp.fromJson(Map<String, Object?>.from(a as Map)),
    ];
  }

  /// Send the credentials, await the `{"ok":true}` accept, then await the
  /// terminal join status. Returns the softap-style plain map:
  /// `{state: connected, ip}` / `{state: failed, error}`; on timeout,
  /// `{state: failed, error: timeout}`.
  Future<Map<String, Object?>> commission(
    String ssid,
    String password, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final clock = Stopwatch()..start();
    try {
      final accept = _next((p) => p.containsKey('ok'), timeout);
      _sendLine('prov.set ${quoteArg(ssid)} ${quoteArg(password)}');
      final ok = await accept;
      if (ok['ok'] != true) {
        return const {'state': 'failed', 'error': 'rejected'};
      }
      final remaining = timeout - clock.elapsed;
      if (remaining <= Duration.zero) {
        return const {'state': 'failed', 'error': 'timeout'};
      }
      final terminal = await _next((p) => p.containsKey('status'), remaining);
      return ProvisioningStatus.fromProvJson(terminal).toJson();
    } on TimeoutException {
      return const {'state': 'failed', 'error': 'timeout'};
    }
  }

  /// Clear the stored credentials; resolves on the device's `{"ok":true}`.
  Future<void> forget({Duration timeout = const Duration(seconds: 5)}) async {
    final accept = _next((p) => p.containsKey('ok'), timeout);
    _sendLine('prov.forget');
    await accept;
  }

  /// One provisioning-state query.
  Future<ProvisioningInfo> status({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final response = _next((p) => p.containsKey('provisioned'), timeout);
    _sendLine('prov.status');
    return ProvisioningInfo.fromJson(await response);
  }

  Future<void> dispose() async {
    await _sub.cancel();
    await _payloads.close();
  }
}
