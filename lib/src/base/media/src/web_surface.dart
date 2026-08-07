// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/host_media/lib/src/web_surface.dart
// Regenerate with debug/tool/sync_host_media_fork.sh.
// Runtime imports are rewritten to the studio's vendored runtime fork.
//
/// The web view surface a browser build can actually provide.
///
/// Conditional so a native build links no web code and a web build links no
/// plugin that has no web implementation. Both answers are honest; only one is
/// available per target.
library;

export 'web_surface_stub.dart'
    if (dart.library.js_interop) 'web_surface_web.dart';
