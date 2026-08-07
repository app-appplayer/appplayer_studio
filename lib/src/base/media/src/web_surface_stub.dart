// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/host_media/lib/src/web_surface_stub.dart
// Regenerate with debug/tool/sync_host_media_fork.sh.
// Runtime imports are rewritten to the studio's vendored runtime fork.
//
library;

import '../../../runtime/flutter_mcp_ui_runtime.dart';

/// Not the web: this build has no iframe to offer. Returning null is the
/// statement that the capability is absent here — the host wires the
/// `webview_flutter` surface instead.
SurfaceBuilder? iframeWebViewSurface() => null;
