// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/host_media/lib/src/local_bytes_stub.dart
// Regenerate with debug/tool/sync_host_media_fork.sh.
// Runtime imports are rewritten to the studio's vendored runtime fork.
//
library;

import 'dart:typed_data';

/// No file system here. The caller treats null as "no waveform", which is what
/// the widget then reports.
Future<Uint8List?> localFileBytes(String uri) async => null;
