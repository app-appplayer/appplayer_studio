// VENDORED COPY of the recipe's test — do not hand-edit. Canonical:
//   os/core/brain_kernel/recipes/ble_provisioning/test/status_payload_test.dart
// Re-vendor alongside debug/tool/sync_provisioning_forks.sh runs.
//
import 'dart:convert';
import 'dart:typed_data';

import 'package:appplayer_studio/src/base/bridge/ble_provisioning/ble_provisioning.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _notify(String s, {int mtu = 23}) {
  // What the peripheral actually puts on the air: an ATT notification carries
  // at most `MTU - 3` bytes and is not continued.
  final full = utf8.encode(s);
  final cap = mtu - 3;
  return Uint8List.fromList(full.length <= cap ? full : full.sublist(0, cap));
}

/// The defect these pin: provisioning SUCCEEDED on the board while the sheet
/// showed `FormatException: Unterminated string … {"state":"connecting`.
///
/// `{"state":"idle"}` is 16 bytes and fits the 20-byte notification payload of
/// Android's default MTU, so the session looked healthy right up to the moment
/// it started working — `{"state":"connecting"}` is 22 and arrives cut. The
/// decode must therefore treat a partial payload as "read the value instead",
/// not as an error, because a notification cannot be continued.
void main() {
  group('decodeStatusPayload', () {
    test('decodes a status that fits the notification payload', () {
      final s = decodeStatusPayload(_notify('{"state":"idle"}'));
      expect(s, isNotNull);
      expect(s!.state, ProvisioningState.idle);
    });

    test('returns null for the status that overflows it', () {
      // The exact payload from the field: 22 bytes truncated to 20.
      final bytes = _notify('{"state":"connecting"}');
      expect(bytes.length, 20);
      expect(utf8.decode(bytes), '{"state":"connecting');
      expect(decodeStatusPayload(bytes), isNull,
          reason: 'a cut payload must ask for a read, not throw');
    });

    test('a larger MTU carries the same status whole', () {
      // What requesting MTU 247 buys: no fallback read on the common path.
      final s = decodeStatusPayload(_notify('{"state":"connecting"}', mtu: 247));
      expect(s, isNotNull);
      expect(s!.state, ProvisioningState.connecting);
    });

    test('a long terminal status also survives a larger MTU', () {
      const json = '{"state":"connected","ssid":"ais21-2.4G",'
          '"ip":"192.168.0.21"}';
      expect(json.length, greaterThan(20));
      final s = decodeStatusPayload(_notify(json, mtu: 247));
      expect(s, isNotNull);
      expect(s!.state, ProvisioningState.connected);
      expect(s.ip, '192.168.0.21');
    });

    test('an empty payload is a read request, not a crash', () {
      expect(decodeStatusPayload(Uint8List(0)), isNull);
    });
  });
}
