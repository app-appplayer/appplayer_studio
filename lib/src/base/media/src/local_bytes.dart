// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/host_media/lib/src/local_bytes.dart
// Regenerate with debug/tool/sync_host_media_fork.sh.
// Runtime imports are rewritten to the studio's vendored runtime fork.
//
/// Bytes for a `file:` reference, where a file system exists.
///
/// AppPlayer rewrites `bundle://` to an installed file path before the runtime
/// sees it, so a bundled sound arrives here as `file:///…`. The runtime's asset
/// resolver cannot read it — it runs on the web too and owns no file system —
/// and `readBytes` answers null. That is fine for playback (the player opens
/// the path itself) and not fine for a waveform, which needs the bytes.
///
/// Conditional so a web build links no `dart:io`.
library;

export 'local_bytes_stub.dart' if (dart.library.io) 'local_bytes_io.dart';
