/// Minimal QR Code encoder (ISO/IEC 18004), byte mode, versions 1–10.
///
/// Written rather than depended upon. `qrCode` is Advanced-profile chrome, and
/// this runtime is embedded in several hosts — a rendering dependency here is
/// one every one of them carries, on every platform, forever. The algorithm is
/// small and fixed, so the cheaper trade is to own it: pure Dart, no
/// conditional imports, identical output on web and native.
///
/// Scope is deliberate. Byte mode with versions up to 10 covers the payloads a
/// UI puts in a code — URLs, `ui://` routes, entry tokens — at every error
/// correction level. A payload that does not fit reports rather than silently
/// truncating, because an unreadable code is worse than a missing one.
library qr_encoder;

import 'dart:typed_data';

/// Error correction level, lowest to highest redundancy.
enum QrErrorCorrection { l, m, q, h }

/// A rendered QR symbol: a square grid of dark/light modules.
class QrSymbol {
  QrSymbol(this.size) : modules = List.generate(size, (_) => List.filled(size, false));

  /// Edge length in modules (21 for version 1, +4 per version).
  final int size;

  /// `modules[y][x]` — true is dark.
  final List<List<bool>> modules;

  bool isDark(int x, int y) => modules[y][x];
}

/// Thrown when a payload cannot be encoded within the supported versions.
class QrTooLongException implements Exception {
  QrTooLongException(this.byteLength);
  final int byteLength;
  @override
  String toString() =>
      'QrTooLongException: $byteLength bytes exceed the supported capacity';
}

/// Encodes [data] into a [QrSymbol].
QrSymbol encodeQr(List<int> data, QrErrorCorrection ec) {
  final version = _pickVersion(data.length, ec);
  if (version == null) throw QrTooLongException(data.length);

  final totalCodewords = _totalCodewords[version - 1];
  final ecPerBlock = _ecCodewordsPerBlock[ec.index][version - 1];
  final blockCount = _blockCount[ec.index][version - 1];
  final dataCodewords = totalCodewords - ecPerBlock * blockCount;

  // --- bit stream: mode (byte = 0100), length, payload, terminator ---
  final bits = _BitBuffer();
  bits.put(4, 4);
  bits.put(data.length, version < 10 ? 8 : 16);
  for (final b in data) {
    bits.put(b, 8);
  }
  final capacityBits = dataCodewords * 8;
  for (var i = 0; i < 4 && bits.length < capacityBits; i++) {
    bits.putBit(false);
  }
  while (bits.length % 8 != 0) {
    bits.putBit(false);
  }
  // Pad alternately with the two specified bytes until the block is full.
  var padToggle = true;
  while (bits.length < capacityBits) {
    bits.put(padToggle ? 0xEC : 0x11, 8);
    padToggle = !padToggle;
  }

  // --- split into blocks, append Reed-Solomon parity ---
  final shortBlocks = blockCount - (dataCodewords % blockCount);
  final shortLen = dataCodewords ~/ blockCount;
  final dataBlocks = <List<int>>[];
  final ecBlocks = <List<int>>[];
  var offset = 0;
  for (var i = 0; i < blockCount; i++) {
    final len = shortLen + (i < shortBlocks ? 0 : 1);
    final block = bits.bytes.sublist(offset, offset + len);
    offset += len;
    dataBlocks.add(block);
    ecBlocks.add(_reedSolomon(block, ecPerBlock));
  }

  // Interleave: data column-wise, then parity column-wise.
  final interleaved = <int>[];
  final maxDataLen = shortLen + 1;
  for (var i = 0; i < maxDataLen; i++) {
    for (final block in dataBlocks) {
      if (i < block.length) interleaved.add(block[i]);
    }
  }
  for (var i = 0; i < ecPerBlock; i++) {
    for (final block in ecBlocks) {
      interleaved.add(block[i]);
    }
  }

  return _place(version, ec, Uint8List.fromList(interleaved));
}

// ---------------------------------------------------------------------------
// Module placement
// ---------------------------------------------------------------------------

QrSymbol _place(int version, QrErrorCorrection ec, Uint8List codewords) {
  final size = version * 4 + 17;
  final symbol = QrSymbol(size);
  final reserved = List.generate(size, (_) => List.filled(size, false));

  void setFn(int x, int y, bool dark) {
    if (x < 0 || y < 0 || x >= size || y >= size) return;
    symbol.modules[y][x] = dark;
    reserved[y][x] = true;
  }

  // Finder patterns + separators.
  for (final origin in [
    [0, 0],
    [size - 7, 0],
    [0, size - 7],
  ]) {
    final ox = origin[0], oy = origin[1];
    for (var dy = -1; dy <= 7; dy++) {
      for (var dx = -1; dx <= 7; dx++) {
        final x = ox + dx, y = oy + dy;
        if (x < 0 || y < 0 || x >= size || y >= size) continue;
        final inRing = dx >= 0 && dx <= 6 && dy >= 0 && dy <= 6;
        final dark = inRing &&
            ((dx == 0 || dx == 6 || dy == 0 || dy == 6) ||
                (dx >= 2 && dx <= 4 && dy >= 2 && dy <= 4));
        setFn(x, y, dark);
      }
    }
  }

  // Timing patterns.
  for (var i = 8; i < size - 8; i++) {
    setFn(i, 6, i % 2 == 0);
    setFn(6, i, i % 2 == 0);
  }

  // Alignment patterns (absent on version 1).
  final centres = _alignmentCentres(version);
  for (final cy in centres) {
    for (final cx in centres) {
      final nearFinder = (cx <= 8 && cy <= 8) ||
          (cx >= size - 9 && cy <= 8) ||
          (cx <= 8 && cy >= size - 9);
      if (nearFinder) continue;
      for (var dy = -2; dy <= 2; dy++) {
        for (var dx = -2; dx <= 2; dx++) {
          final ring = dx.abs() == 2 || dy.abs() == 2 || (dx == 0 && dy == 0);
          setFn(cx + dx, cy + dy, ring);
        }
      }
    }
  }

  // Dark module and format-info reservation.
  setFn(8, size - 8, true);
  for (var i = 0; i < 9; i++) {
    if (!reserved[i][8]) reserved[i][8] = true;
    if (!reserved[8][i]) reserved[8][i] = true;
  }
  for (var i = 0; i < 8; i++) {
    reserved[size - 1 - i][8] = true;
    reserved[8][size - 1 - i] = true;
  }
  // Version info (7+).
  if (version >= 7) {
    for (var i = 0; i < 18; i++) {
      final a = size - 11 + i % 3;
      final b = i ~/ 3;
      reserved[b][a] = true;
      reserved[a][b] = true;
    }
  }

  // Zig-zag data placement, mask 0 applied as it is written.
  var bitIndex = 0;
  var upward = true;
  for (var right = size - 1; right >= 1; right -= 2) {
    if (right == 6) right = 5; // skip the vertical timing column
    for (var v = 0; v < size; v++) {
      final y = upward ? size - 1 - v : v;
      for (var c = 0; c < 2; c++) {
        final x = right - c;
        if (reserved[y][x]) continue;
        var dark = false;
        if (bitIndex < codewords.length * 8) {
          final byte = codewords[bitIndex >> 3];
          dark = ((byte >> (7 - (bitIndex & 7))) & 1) == 1;
          bitIndex++;
        }
        if ((y + x) % 2 == 0) dark = !dark; // mask pattern 0
        symbol.modules[y][x] = dark;
      }
    }
    upward = !upward;
  }

  _writeFormatInfo(symbol, reserved, ec, size);
  if (version >= 7) _writeVersionInfo(symbol, version, size);
  return symbol;
}

void _writeFormatInfo(
  QrSymbol symbol,
  List<List<bool>> reserved,
  QrErrorCorrection ec,
  int size,
) {
  const ecBits = {
    QrErrorCorrection.l: 1,
    QrErrorCorrection.m: 0,
    QrErrorCorrection.q: 3,
    QrErrorCorrection.h: 2,
  };
  var data = (ecBits[ec]! << 3) | 0; // mask 0
  var rem = data;
  for (var i = 0; i < 10; i++) {
    rem = (rem << 1) ^ ((rem >> 9) * 0x537);
  }
  final bits = ((data << 10) | rem) ^ 0x5412;

  for (var i = 0; i < 15; i++) {
    final dark = ((bits >> i) & 1) == 1;
    // Copy 1 — around the top-left finder.
    if (i < 6) {
      symbol.modules[i][8] = dark;
    } else if (i < 8) {
      symbol.modules[i + 1][8] = dark;
    } else if (i == 8) {
      symbol.modules[8][7] = dark;
    } else {
      symbol.modules[8][14 - i] = dark;
    }
    // Copy 2 — split across the other two finders.
    if (i < 8) {
      symbol.modules[8][size - 1 - i] = dark;
    } else {
      symbol.modules[size - 15 + i][8] = dark;
    }
  }
  symbol.modules[size - 8][8] = true; // dark module
}

void _writeVersionInfo(QrSymbol symbol, int version, int size) {
  var rem = version;
  for (var i = 0; i < 12; i++) {
    rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
  }
  final bits = (version << 12) | rem;
  for (var i = 0; i < 18; i++) {
    final dark = ((bits >> i) & 1) == 1;
    final a = size - 11 + i % 3;
    final b = i ~/ 3;
    symbol.modules[b][a] = dark;
    symbol.modules[a][b] = dark;
  }
}

List<int> _alignmentCentres(int version) {
  if (version == 1) return const [];
  const table = <List<int>>[
    [], // v1
    [6, 18], [6, 22], [6, 26], [6, 30], [6, 34],
    [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50],
  ];
  return table[version - 1];
}

// ---------------------------------------------------------------------------
// Reed-Solomon over GF(256)
// ---------------------------------------------------------------------------

final Uint8List _expTable = Uint8List(512);
final Uint8List _logTable = Uint8List(256);
bool _tablesReady = false;

void _initTables() {
  if (_tablesReady) return;
  var x = 1;
  for (var i = 0; i < 255; i++) {
    _expTable[i] = x;
    _logTable[x] = i;
    x <<= 1;
    if (x & 0x100 != 0) x ^= 0x11D;
  }
  for (var i = 255; i < 512; i++) {
    _expTable[i] = _expTable[i - 255];
  }
  _tablesReady = true;
}

int _mul(int a, int b) {
  if (a == 0 || b == 0) return 0;
  return _expTable[_logTable[a] + _logTable[b]];
}

List<int> _reedSolomon(List<int> data, int ecLength) {
  _initTables();
  // Generator polynomial for `ecLength` parity symbols.
  var generator = <int>[1];
  for (var i = 0; i < ecLength; i++) {
    final next = List<int>.filled(generator.length + 1, 0);
    for (var j = 0; j < generator.length; j++) {
      next[j] ^= generator[j];
      next[j + 1] ^= _mul(generator[j], _expTable[i]);
    }
    generator = next;
  }

  final remainder = List<int>.filled(ecLength, 0, growable: true);
  for (final byte in data) {
    final factor = byte ^ remainder[0];
    remainder.removeAt(0);
    remainder.add(0);
    for (var i = 0; i < ecLength; i++) {
      remainder[i] ^= _mul(generator[i + 1], factor);
    }
  }
  return remainder;
}

// ---------------------------------------------------------------------------
// Capacity tables (versions 1–10)
// ---------------------------------------------------------------------------

const _totalCodewords = [26, 44, 70, 100, 134, 172, 196, 242, 292, 346];

/// EC codewords per block, indexed [ec][version-1].
const _ecCodewordsPerBlock = [
  [7, 10, 15, 20, 26, 18, 20, 24, 30, 18], // L
  [10, 16, 26, 18, 24, 16, 18, 22, 22, 26], // M
  [13, 22, 18, 26, 18, 24, 18, 22, 20, 24], // Q
  [17, 28, 22, 16, 22, 28, 26, 26, 24, 28], // H
];

/// Block count, indexed [ec][version-1].
const _blockCount = [
  [1, 1, 1, 1, 1, 2, 2, 2, 2, 4], // L
  [1, 1, 1, 2, 2, 4, 4, 4, 5, 5], // M
  [1, 1, 2, 2, 4, 4, 6, 6, 8, 8], // Q
  [1, 1, 2, 4, 4, 4, 5, 6, 8, 8], // H
];

int? _pickVersion(int byteLength, QrErrorCorrection ec) {
  for (var v = 1; v <= 10; v++) {
    final total = _totalCodewords[v - 1];
    final ecPer = _ecCodewordsPerBlock[ec.index][v - 1];
    final blocks = _blockCount[ec.index][v - 1];
    final dataCodewords = total - ecPer * blocks;
    final headerBits = 4 + (v < 10 ? 8 : 16);
    if (dataCodewords * 8 >= headerBits + byteLength * 8) return v;
  }
  return null;
}

class _BitBuffer {
  final List<int> _bytes = [];
  int _length = 0;

  int get length => _length;
  List<int> get bytes => _bytes;

  void putBit(bool bit) {
    final index = _length >> 3;
    if (_bytes.length <= index) _bytes.add(0);
    if (bit) _bytes[index] |= 0x80 >> (_length & 7);
    _length++;
  }

  void put(int value, int bitCount) {
    for (var i = bitCount - 1; i >= 0; i--) {
      putBit(((value >> i) & 1) == 1);
    }
  }
}
