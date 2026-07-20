// VENDORED COPY of the recipe's test — do not hand-edit. Canonical:
//   os/core/brain_kernel/recipes/smartconfig_provisioning/test/smartconfig_codec_test.dart
// Re-vendor alongside debug/tool/sync_provisioning_forks.sh runs.
//
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/bridge/smartconfig_provisioning/smartconfig_provisioning.dart';

/// Independent CRC-8/MAXIM (poly 0x8C reflected, init 0) — table-driven, a
/// deliberately different construction from the library's bitwise version, so
/// the test hand-checks the codec rather than mirroring it.
int refCrc8(List<int> bytes) {
  final table = List<int>.generate(256, (dividend) {
    var remainder = dividend;
    for (var bit = 0; bit < 8; bit++) {
      remainder =
          (remainder & 1) != 0 ? (remainder >> 1) ^ 0x8c : remainder >> 1;
    }
    return remainder;
  });
  var value = 0;
  for (final b in bytes) {
    value = table[(b ^ value) & 0xff] ^ ((value << 8) & 0xff00);
    value &= 0xff;
  }
  return value;
}

/// Independent expansion of one (u8, index) data code into its 3 datagram
/// lengths, per the reference DataCode: crc/data high nibbles + 40, sequence
/// header 0x100|index + 40, crc/data low nibbles + 40.
List<int> refDataCode(int u8, int index) {
  final crc = refCrc8([u8 & 0xff, index]);
  return [
    ((crc & 0xf0) | ((u8 >> 4) & 0x0f)) + 40,
    0x100 + index + 40,
    (((crc & 0x0f) << 4) | (u8 & 0x0f)) + 40,
  ];
}

void main() {
  test('crc8 matches the CRC-8/MAXIM standard check value', () {
    // The documented check value of CRC-8/MAXIM ("123456789" -> 0xA1).
    expect(crc8(utf8.encode('123456789')), 0xa1);
    expect(crc8(const []), 0x00);
    expect(crc8(utf8.encode('ABC')), refCrc8(utf8.encode('ABC')));
  });

  test('guide code is the fixed 515,514,513,512 length pattern', () {
    expect(guideCodeLengths, [515, 514, 513, 512]);
  });

  group('datum lengths for ssid=ABC password=pw bssid=aa:bb:cc:dd:ee:ff', () {
    const ssid = 'ABC';
    const password = 'pw';
    const bssid = 'aa:bb:cc:dd:ee:ff';
    const localIp = [192, 168, 4, 2];
    final lengths = buildDatumLengths(
        ssid: ssid, password: password, bssid: bssid, localIp: localIp);

    // Hand-derived header values per the reference DatumCode:
    // totalLen = 5 (head) + 4 (ip) + 2 (pwd) + 3 (ssid) = 14.
    const totalLen = 14;
    final ssidBytes = utf8.encode(ssid);
    final pwdBytes = utf8.encode(password);
    const bssidBytes = [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff];

    test('header codes match an independent hand-check', () {
      final ssidCrc = refCrc8(ssidBytes);
      final bssidCrc = refCrc8(bssidBytes);
      var totalXor = totalLen ^ pwdBytes.length ^ ssidCrc ^ bssidCrc;
      for (final b in [...localIp, ...pwdBytes, ...ssidBytes]) {
        totalXor ^= b;
      }
      final expectedHeader = [
        ...refDataCode(totalLen, 0),
        ...refDataCode(pwdBytes.length, 1),
        ...refDataCode(ssidCrc, 2),
        ...refDataCode(bssidCrc, 3),
        ...refDataCode(totalXor & 0xff, 4),
      ];
      expect(lengths.sublist(0, 15), expectedHeader);
    });

    test('total count covers data + interleaved bssid codes', () {
      // 5 header + 4 ip + 2 pwd + 3 ssid = 14 data codes, + 6 bssid codes,
      // each expanded to 3 datagram lengths.
      expect(lengths.length, (14 + 6) * 3);
    });

    test('sequence headers reveal the reference bssid interleaving order', () {
      // Every code's middle length is 0x100 + seqIndex + 40; recover the
      // sequence order and compare with the reference LinkedList inserts:
      // bssid codes (seq totalLen..totalLen+5) at positions 5, 9, 13, then
      // appended once the insert index passes the end.
      final seqOrder = [
        for (var i = 1; i < lengths.length; i += 3) lengths[i] - 0x100 - 40,
      ];
      expect(seqOrder, [
        0, 1, 2, 3, 4, // header
        totalLen, // bssid[0] inserted at position 5
        5, 6, 7, // ip[0..2]
        totalLen + 1, // bssid[1] at position 9
        8, 9, 10, // ip[3], pwd[0..1]
        totalLen + 2, // bssid[2] at position 13
        11, 12, 13, // ssid[0..2]
        totalLen + 3, totalLen + 4, totalLen + 5, // appended tail
      ]);
    });

    test('bssid code positions carry the bssid byte values', () {
      // Position 5 in transmit order is bssid[0] = 0xaa with seq index 14.
      expect(lengths.sublist(15, 18), refDataCode(0xaa, totalLen));
    });
  });

  test('expectedAckLength is ssidLen + pwdLen + 9', () {
    expect(expectedAckLength('home', 's3cret'), 4 + 6 + 9);
  });

  test('payloadOfLength fills with ASCII 1', () {
    final p = payloadOfLength(515);
    expect(p.length, 515);
    expect(p.toSet(), {0x31});
  });

  test('parseBssid accepts colon-separated, dashed, bare and empty forms', () {
    expect(parseBssid('aa:bb:cc:dd:ee:ff'),
        [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]);
    expect(parseBssid('18-FE-34-9A-A3-C4'),
        [0x18, 0xfe, 0x34, 0x9a, 0xa3, 0xc4]);
    expect(parseBssid('18fe349aa3c4'), [0x18, 0xfe, 0x34, 0x9a, 0xa3, 0xc4]);
    expect(parseBssid(''), isEmpty);
  });
}
