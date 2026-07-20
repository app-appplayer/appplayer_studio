// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/smartconfig_provisioning/lib/src/smartconfig_codec.dart
// Regenerate with debug/tool/sync_provisioning_forks.sh.
//
/// ESP-Touch v1 (SmartConfig) wire encoding — a faithful port of the
/// reference implementation (EspressifApp/EsptouchForAndroid: `GuideCode`,
/// `DataCode`, `DatumCode`, `CRC8`, `ByteUtil.genSpecBytes`).
///
/// ESP-Touch does not put credentials in packet PAYLOADS — the listening
/// device is a promiscuous-mode sniffer that can only see 802.11 frame
/// LENGTHS. Every 9-bit code point is therefore transmitted as the LENGTH of
/// one UDP broadcast datagram (payload content is irrelevant; the reference
/// fills it with ASCII '1'). This module computes those length sequences.
library;

import 'dart:convert';

/// The four guide-code datagram lengths, sent in a tight loop so the device
/// can lock onto the sender and measure the length offset added by 802.11
/// encapsulation. Order matters: 515, 514, 513, 512.
const List<int> guideCodeLengths = [515, 514, 513, 512];

/// Every datum code point adds this to the raw 9-bit value so no datagram
/// length is ever 0 (reference `DatumCode.EXTRA_LEN`).
const int _extraLen = 40;

/// Header code points before the IP bytes: total-len, apPwd-len, ssid CRC,
/// bssid CRC, total XOR (reference `DatumCode.EXTRA_HEAD_LEN`).
const int _extraHeadLen = 5;

/// A datum sequence index must fit the 7-bit sequence header
/// (reference `DataCode.INDEX_MAX`).
const int _indexMax = 127;

/// Dallas/Maxim CRC-8 (reflected polynomial 0x8C, init 0x00), exactly the
/// reference `CRC8` class. Used for the SSID/BSSID header CRCs and for the
/// per-code CRC that shares a byte with the data nibbles.
int crc8(Iterable<int> bytes) {
  var value = 0;
  for (final b in bytes) {
    var remainder = (b ^ value) & 0xff;
    for (var bit = 0; bit < 8; bit++) {
      if ((remainder & 0x01) != 0) {
        remainder = (remainder >> 1) ^ 0x8c;
      } else {
        remainder >>= 1;
      }
    }
    value = (remainder ^ (value << 8)) & 0xff;
  }
  return value;
}

/// One data code: a (u8 value, sequence index) pair encoded as THREE datagram
/// lengths (reference `DataCode` — three 9-bit tuples per code):
///   1. `(crc high nibble << 4 | data high nibble) + 40`
///   2. `0x100 | index, + 40` (the sequence header, high bit 9 set)
///   3. `(crc low nibble << 4 | data low nibble) + 40`
/// where `crc = crc8([u8, index])`.
List<int> dataCodeLengths(int u8, int index) {
  if (index > _indexMax) {
    throw ArgumentError.value(index, 'index', 'exceeds ESP-Touch INDEX_MAX');
  }
  final data = u8 & 0xff;
  final crc = crc8([data, index]);
  return [
    ((crc & 0xf0) | (data >> 4)) + _extraLen,
    (0x100 | index) + _extraLen,
    (((crc & 0x0f) << 4) | (data & 0x0f)) + _extraLen,
  ];
}

/// Parse a BSSID string ("aa:bb:cc:dd:ee:ff", '-' separated, or bare hex)
/// into bytes. An empty string yields an empty list (BSSID unknown — the
/// device then matches on SSID alone).
List<int> parseBssid(String bssid) {
  final hex = bssid.replaceAll(':', '').replaceAll('-', '');
  if (hex.isEmpty) return const [];
  if (hex.length % 2 != 0) {
    throw ArgumentError.value(bssid, 'bssid', 'not a hex MAC address');
  }
  return [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}

/// Build the full datum-code datagram length sequence for one credential set,
/// mirroring the reference `DatumCode` construction exactly:
///
/// Data codes (sequence indices):
///   0: totalLen = 5 + ipLen + pwdLen + ssidLen
///   1: apPwd length
///   2: CRC8(ssid bytes)
///   3: CRC8(bssid bytes)
///   4: XOR of all data u8s (header + ip + password + ssid)
///   5...: local IP bytes, then password bytes, then SSID bytes
///   totalLen + i: BSSID byte i
///
/// The BSSID codes carry indices past the data but are INTERLEAVED into the
/// transmit order at list positions 5, 9, 13, ... (reference
/// `bssidInsertIndex` logic), appending once past the end.
List<int> buildDatumLengths({
  required String ssid,
  required String password,
  String bssid = '',
  required List<int> localIp,
}) {
  final ssidBytes = utf8.encode(ssid);
  final pwdBytes = utf8.encode(password);
  final bssidBytes = parseBssid(bssid);

  final totalLen =
      _extraHeadLen + localIp.length + pwdBytes.length + ssidBytes.length;
  if (totalLen > _indexMax || totalLen + bssidBytes.length - 1 > _indexMax) {
    throw ArgumentError('ssid + password too long for ESP-Touch v1');
  }

  final ssidCrc = crc8(ssidBytes);
  final bssidCrc = crc8(bssidBytes);

  // (u8 value, sequence index) pairs in transmit order.
  final codes = <(int, int)>[
    (totalLen, 0),
    (pwdBytes.length, 1),
    (ssidCrc, 2),
    (bssidCrc, 3),
  ];
  var totalXor = totalLen ^ pwdBytes.length ^ ssidCrc ^ bssidCrc;

  final body = [...localIp, ...pwdBytes, ...ssidBytes];
  for (var i = 0; i < body.length; i++) {
    final c = body[i] & 0xff;
    totalXor ^= c;
    codes.add((c, i + _extraHeadLen));
  }

  // The total XOR sits at transmit position 4, sequence index 4.
  codes.insert(4, (totalXor & 0xff, 4));

  // Interleave the BSSID codes every 4 positions starting at position 5.
  var bssidInsertIndex = _extraHeadLen;
  for (var i = 0; i < bssidBytes.length; i++) {
    final code = (bssidBytes[i] & 0xff, totalLen + i);
    if (bssidInsertIndex >= codes.length) {
      codes.add(code);
    } else {
      codes.insert(bssidInsertIndex, code);
    }
    bssidInsertIndex += 4;
  }

  return [for (final (u8, index) in codes) ...dataCodeLengths(u8, index)];
}

/// The datagram payload for one code length: [length] bytes of ASCII '1'
/// (reference `ByteUtil.genSpecBytes` — only the length carries information).
List<int> payloadOfLength(int length) => List<int>.filled(length, 0x31);

/// The first byte the device's ACK must carry so we know it decoded OUR
/// credentials: `ssidLen + pwdLen + 9` truncated to a byte (reference
/// `__EsptouchTask.expectOneByte`).
int expectedAckLength(String ssid, String password) =>
    (utf8.encode(ssid).length + utf8.encode(password).length + 9) & 0xff;
