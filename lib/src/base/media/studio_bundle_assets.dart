/// Reads `bundle://` assets off the project folder (UI DSL §6.12).
///
/// The runtime resolves `data:`, `assets/` and `http(s)` on its own — those
/// need no host. `bundle://` does: only the host knows where this document's
/// bundle lives. With no reader wired the runtime declares the form absent,
/// and every surface that needs BYTES rather than a path draws an empty box:
/// `lottieAnimation`, `pdfViewer`, a media waveform. Measured — a Lottie known
/// to render elsewhere came back blank here while an `image` from the same
/// `bundle://` uri drew, because images go through a provider that the runtime
/// can build without a reader.
///
/// A player never noticed the gap because it opens a path itself. Anything
/// asking for the bytes did.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// A reader for the bundle at [bundleDir].
///
/// The path arriving here is already the part after `bundle://` (the runtime
/// splits it), so it is relative to the bundle root.
///
/// Refuses to leave the bundle. A document is not a trusted author: a
/// reference like `../../.ssh/id_rsa` would otherwise read whatever the studio
/// process can, and this reader exists to serve a bundle's own files.
Future<Uint8List?> Function(String path) studioBundleAssetReader(
  String bundleDir,
) {
  final root = p.normalize(p.absolute(bundleDir));
  return (String path) async {
    // `isWithin` normalises both sides, so `../` and an absolute path are both
    // answered here — an explicit `normalize` first changed no outcome.
    final resolved = p.join(root, path);
    if (resolved != root && !p.isWithin(root, resolved)) return null;
    try {
      final bytes = await File(resolved).readAsBytes();
      // Zero bytes is not an asset. Handing them on gives the surface an empty
      // frame to draw, which is indistinguishable from the capability being
      // absent — the exact confusion this whole path was stuck in.
      return bytes.isEmpty ? null : bytes;
    } on FileSystemException {
      // Missing, a directory, or unreadable — all the same answer. The surface
      // reports through `onError` and draws nothing (§6.13.1). An explicit
      // existence check ahead of this was unreachable: no test could tell it
      // from the catch, because the catch already answers for every case.
      return null;
    }
  };
}
