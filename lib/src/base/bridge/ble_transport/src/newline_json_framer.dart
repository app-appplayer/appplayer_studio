// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/ble_transport/lib/src/newline_json_framer.dart
// Regenerate with debug/tool/sync_discovery_forks.sh.
//
import 'dart:convert';

/// Newline-delimited JSON-RPC framing over a reassembled byte stream —
/// the client-side realization of the wire contract (UTF-8, `\n` terminated,
/// blank lines skipped, surrounding whitespace trimmed).
///
/// Chunk boundaries carry no semantics: [feed] accepts arbitrary
/// slices of the stream — one JSON-RPC line may span many chunks and one
/// chunk may contain many lines. Buffering is byte-level so a multi-byte
/// UTF-8 sequence split across chunks is reassembled correctly before
/// decoding.
class NewlineJsonFramer {
  NewlineJsonFramer({
    required void Function(dynamic message) onMessage,
    required void Function(Object error, StackTrace stack) onError,
  })  : _onMessage = onMessage,
        _onError = onError;

  static const int _newline = 0x0A;

  final void Function(dynamic message) _onMessage;
  final void Function(Object error, StackTrace stack) _onError;
  final List<int> _buffer = <int>[];

  /// Feed the next received chunk; emits every complete line it closes.
  void feed(List<int> chunk) {
    _buffer.addAll(chunk);
    int newlineIndex;
    while ((newlineIndex = _buffer.indexOf(_newline)) != -1) {
      final lineBytes = _buffer.sublist(0, newlineIndex);
      _buffer.removeRange(0, newlineIndex + 1);
      final line = utf8.decode(lineBytes, allowMalformed: true).trim();
      if (line.isEmpty) continue;
      try {
        _onMessage(jsonDecode(line));
      } catch (error, stack) {
        _onError(error, stack);
      }
    }
  }

  /// Encode one JSON-RPC message into its wire bytes
  /// (`jsonEncode + '\n'`, UTF-8).
  static List<int> encodeFrame(dynamic message) =>
      utf8.encode('${jsonEncode(message)}\n');
}
