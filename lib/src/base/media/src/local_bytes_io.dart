// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/host_media/lib/src/local_bytes_io.dart
// Regenerate with debug/tool/sync_host_media_fork.sh.
// Runtime imports are rewritten to the studio's vendored runtime fork.
//
library;

import 'dart:io';
import 'dart:typed_data';

/// Reads a `file:` URI. Anything else, or an unreadable path, answers null —
/// an unreadable source is not a crash, it is a waveform this host cannot draw.
Future<Uint8List?> localFileBytes(String uri) async {
  if (!uri.startsWith('file:')) return null;
  try {
    final file = File.fromUri(Uri.parse(uri));
    if (!await file.exists()) return null;
    return await file.readAsBytes();
  } catch (_) {
    return null;
  }
}
