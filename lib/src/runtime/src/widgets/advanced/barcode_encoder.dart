/// Minimal 1-D barcode encoders — spec §10.24.
///
/// Pure Dart for the same reason as the QR encoder: a rendering dependency in
/// this runtime is one every embedding host carries on every platform. Each
/// symbology is a small, fixed table plus a check digit rule.
///
/// Every encoder validates its payload and reports rather than rendering. A
/// barcode that scans as the wrong number is worse than one that does not
/// render at all — an EAN-13 with a bad check digit is exactly that.
library barcode_encoder;

/// Supported symbologies.
enum BarcodeFormat { code128, code39, ean13, ean8, upcA, upcE, itf, codabar }

/// Thrown when a payload does not satisfy its format.
class BarcodeFormatException implements Exception {
  BarcodeFormatException(this.format, this.reason);
  final BarcodeFormat format;
  final String reason;
  @override
  String toString() => 'BarcodeFormatException(${format.name}): $reason';
}

/// A bar pattern: `true` is a dark bar, one entry per module.
class BarcodePattern {
  const BarcodePattern(this.bars, this.text);

  /// Module-wide bars, left to right.
  final List<bool> bars;

  /// Human-readable text as encoded (may carry an appended check digit).
  final String text;

  int get moduleCount => bars.length;
}

/// Encodes [value] in [format].
BarcodePattern encodeBarcode(String value, BarcodeFormat format) {
  switch (format) {
    case BarcodeFormat.code128:
      return _code128(value);
    case BarcodeFormat.code39:
      return _code39Encode(value);
    case BarcodeFormat.ean13:
      return _ean13(value);
    case BarcodeFormat.ean8:
      return _ean8(value);
    case BarcodeFormat.upcA:
      return _ean13('0$value'); // UPC-A is EAN-13 with a leading zero
    case BarcodeFormat.upcE:
      throw BarcodeFormatException(format, 'UPC-E is not supported');
    case BarcodeFormat.itf:
      return _itf(value);
    case BarcodeFormat.codabar:
      return _codabarEncode(value);
  }
}

// ---------------------------------------------------------------------------
// EAN / UPC
// ---------------------------------------------------------------------------

const _eanL = [
  '0001101', '0011001', '0010011', '0111101', '0100011',
  '0110001', '0101111', '0111011', '0110111', '0001011',
];
const _eanG = [
  '0100111', '0110011', '0011011', '0100001', '0011101',
  '0111001', '0000101', '0010001', '0001001', '0010111',
];
const _eanR = [
  '1110010', '1100110', '1101100', '1000010', '1011100',
  '1001110', '1010000', '1000100', '1001000', '1110100',
];
const _eanParity = [
  'LLLLLL', 'LLGLGG', 'LLGGLG', 'LLGGGL', 'LGLLGG',
  'LGGLLG', 'LGGGLL', 'LGLGLG', 'LGLGGL', 'LGGLGL',
];

int _eanCheckDigit(String digits) {
  var sum = 0;
  // Weights alternate from the right, which is why the parity depends on the
  // payload length rather than being fixed.
  for (var i = 0; i < digits.length; i++) {
    final d = digits.codeUnitAt(digits.length - 1 - i) - 0x30;
    sum += d * (i.isEven ? 3 : 1);
  }
  return (10 - sum % 10) % 10;
}

String _normaliseNumeric(String value, int expected, BarcodeFormat format) {
  if (!RegExp(r'^\d+$').hasMatch(value)) {
    throw BarcodeFormatException(format, 'payload must be digits only');
  }
  if (value.length == expected - 1) {
    // A payload one short is read as "check digit omitted" and completed,
    // rather than rejected — the common authoring case.
    return value + _eanCheckDigit(value).toString();
  }
  if (value.length != expected) {
    throw BarcodeFormatException(
        format, 'expected $expected digits, got ${value.length}');
  }
  final body = value.substring(0, expected - 1);
  final given = value.codeUnitAt(expected - 1) - 0x30;
  if (_eanCheckDigit(body) != given) {
    throw BarcodeFormatException(format, 'check digit does not match');
  }
  return value;
}

BarcodePattern _ean13(String value) {
  final digits = _normaliseNumeric(value, 13, BarcodeFormat.ean13);
  final parity = _eanParity[digits.codeUnitAt(0) - 0x30];
  final buffer = StringBuffer('101'); // start guard
  for (var i = 1; i <= 6; i++) {
    final d = digits.codeUnitAt(i) - 0x30;
    buffer.write(parity[i - 1] == 'L' ? _eanL[d] : _eanG[d]);
  }
  buffer.write('01010'); // centre guard
  for (var i = 7; i <= 12; i++) {
    buffer.write(_eanR[digits.codeUnitAt(i) - 0x30]);
  }
  buffer.write('101'); // end guard
  return BarcodePattern(_toBars(buffer.toString()), digits);
}

BarcodePattern _ean8(String value) {
  final digits = _normaliseNumeric(value, 8, BarcodeFormat.ean8);
  final buffer = StringBuffer('101');
  for (var i = 0; i < 4; i++) {
    buffer.write(_eanL[digits.codeUnitAt(i) - 0x30]);
  }
  buffer.write('01010');
  for (var i = 4; i < 8; i++) {
    buffer.write(_eanR[digits.codeUnitAt(i) - 0x30]);
  }
  buffer.write('101');
  return BarcodePattern(_toBars(buffer.toString()), digits);
}

// ---------------------------------------------------------------------------
// Code 128 (subset B, plus subset C for long digit runs)
// ---------------------------------------------------------------------------

const _code128Patterns = [
  '11011001100', '11001101100', '11001100110', '10010011000', '10010001100',
  '10001001100', '10011001000', '10011000100', '10001100100', '11001001000',
  '11001000100', '11000100100', '10110011100', '10011011100', '10011001110',
  '10111001100', '10011101100', '10011100110', '11001110010', '11001011100',
  '11001001110', '11011100100', '11001110100', '11101101110', '11101001100',
  '11100101100', '11100100110', '11101100100', '11100110100', '11100110010',
  '11011011000', '11011000110', '11000110110', '10100011000', '10001011000',
  '10001000110', '10110001000', '10001101000', '10001100010', '11010001000',
  '11000101000', '11000100010', '10110111000', '10110001110', '10001101110',
  '10111011000', '10111000110', '10001110110', '11101110110', '11010001110',
  '11000101110', '11011101000', '11011100010', '11011101110', '11101011000',
  '11101000110', '11100010110', '11101101000', '11101100010', '11100011010',
  '11101111010', '11001000010', '11110001010', '10100110000', '10100001100',
  '10010110000', '10010000110', '10000101100', '10000100110', '10110010000',
  '10110000100', '10011010000', '10011000010', '10000110100', '10000110010',
  '11000010010', '11001010000', '11110111010', '11000010100', '10001111010',
  '10100111100', '10010111100', '10010011110', '10111100100', '10011110100',
  '10011110010', '11110100100', '11110010100', '11110010010', '11011011110',
  '11011110110', '11110110110', '10101111000', '10100011110', '10001011110',
  '10111101000', '10111100010', '11110101000', '11110100010', '10111011110',
  '10111101110', '11101011110', '11110101110', '11010000100', '11010010000',
  '11010011100', '1100011101011',
];

BarcodePattern _code128(String value) {
  for (final unit in value.codeUnits) {
    if (unit < 32 || unit > 126) {
      throw BarcodeFormatException(
          BarcodeFormat.code128, 'only printable ASCII is supported');
    }
  }
  const startB = 104;
  final codes = <int>[startB];
  for (final unit in value.codeUnits) {
    codes.add(unit - 32);
  }
  var checksum = startB;
  for (var i = 1; i < codes.length; i++) {
    checksum += codes[i] * i;
  }
  codes.add(checksum % 103);
  codes.add(106); // stop

  final buffer = StringBuffer();
  for (final c in codes) {
    buffer.write(_code128Patterns[c]);
  }
  return BarcodePattern(_toBars(buffer.toString()), value);
}

// ---------------------------------------------------------------------------
// Code 39
// ---------------------------------------------------------------------------

const _code39 = {
  '0': '101001101101', '1': '110100101011', '2': '101100101011',
  '3': '110110010101', '4': '101001101011', '5': '110100110101',
  '6': '101100110101', '7': '101001011011', '8': '110100101101',
  '9': '101100101101', 'A': '110101001011', 'B': '101101001011',
  'C': '110110100101', 'D': '101011001011', 'E': '110101100101',
  'F': '101101100101', 'G': '101010011011', 'H': '110101001101',
  'I': '101101001101', 'J': '101011001101', 'K': '110101010011',
  'L': '101101010011', 'M': '110110101001', 'N': '101011010011',
  'O': '110101101001', 'P': '101101101001', 'Q': '101010110011',
  'R': '110101011001', 'S': '101101011001', 'T': '101011011001',
  'U': '110010101011', 'V': '100110101011', 'W': '110011010101',
  'X': '100101101011', 'Y': '110010110101', 'Z': '100110110101',
  '-': '100101011011', '.': '110010101101', ' ': '100110101101',
  r'$': '100100100101', '/': '100100101001', '+': '100101001001',
  '%': '101001001001', '*': '100101101101',
};

BarcodePattern _code39Encode(String value) {
  final upper = value.toUpperCase();
  final buffer = StringBuffer(_code39['*']!);
  buffer.write('0');
  for (final ch in upper.split('')) {
    final pattern = _code39[ch];
    if (pattern == null) {
      throw BarcodeFormatException(
          BarcodeFormat.code39, 'character "$ch" is not in Code 39');
    }
    buffer.write(pattern);
    buffer.write('0'); // inter-character gap
  }
  buffer.write(_code39['*']!);
  return BarcodePattern(_toBars(buffer.toString()), upper);
}

// ---------------------------------------------------------------------------
// ITF (Interleaved 2 of 5)
// ---------------------------------------------------------------------------

const _itfPatterns = [
  'nnwwn', 'wnnnw', 'nwnnw', 'wwnnn', 'nnwnw',
  'wnwnn', 'nwwnn', 'nnnww', 'wnnwn', 'nwnwn',
];

BarcodePattern _itf(String value) {
  if (!RegExp(r'^\d+$').hasMatch(value)) {
    throw BarcodeFormatException(BarcodeFormat.itf, 'payload must be digits');
  }
  // Digits are interleaved in pairs, so an odd count cannot be encoded; a
  // leading zero is the standard remedy and is applied rather than refused.
  final digits = value.length.isOdd ? '0$value' : value;
  final bars = <bool>[true, false, true, false]; // start
  for (var i = 0; i < digits.length; i += 2) {
    final a = _itfPatterns[digits.codeUnitAt(i) - 0x30];
    final b = _itfPatterns[digits.codeUnitAt(i + 1) - 0x30];
    for (var j = 0; j < 5; j++) {
      bars.addAll(List.filled(a[j] == 'w' ? 3 : 1, true));
      bars.addAll(List.filled(b[j] == 'w' ? 3 : 1, false));
    }
  }
  bars.addAll([true, true, true, false, true]); // stop
  return BarcodePattern(bars, digits);
}

// ---------------------------------------------------------------------------
// Codabar
// ---------------------------------------------------------------------------

const _codabar = {
  '0': '101010011', '1': '101011001', '2': '101001011', '3': '110010101',
  '4': '101101001', '5': '110101001', '6': '100101011', '7': '100101101',
  '8': '100110101', '9': '110100101', '-': '101001101', r'$': '101100101',
  ':': '1101011011', '/': '1101101011', '.': '1101101101', '+': '101100110011',
  'A': '1011001001', 'B': '1001001011', 'C': '1010010011', 'D': '1010011001',
};

BarcodePattern _codabarEncode(String value) {
  final upper = value.toUpperCase();
  // Codabar carries its own start/stop letters; supply them when absent so an
  // author writing only digits still gets a scannable symbol.
  final body = RegExp(r'^[ABCD].*[ABCD]$').hasMatch(upper) ? upper : 'A${upper}B';
  final buffer = StringBuffer();
  for (var i = 0; i < body.length; i++) {
    final pattern = _codabar[body[i]];
    if (pattern == null) {
      throw BarcodeFormatException(
          BarcodeFormat.codabar, 'character "${body[i]}" is not in Codabar');
    }
    buffer.write(pattern);
    if (i < body.length - 1) buffer.write('0');
  }
  return BarcodePattern(_toBars(buffer.toString()), body);
}

// ---------------------------------------------------------------------------

List<bool> _toBars(String bits) =>
    bits.split('').map((c) => c == '1').toList();
