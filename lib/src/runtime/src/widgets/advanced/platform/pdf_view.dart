/// Platform-split PDF surface.
///
/// The web has a PDF renderer built into every browser; native platforms do
/// not, and pulling one in would put a heavy dependency on every host that
/// embeds this runtime. So the web branch renders for real and the native
/// branch asks the host — declared, not assumed, exactly as is required
/// of an unresolvable asset.
library pdf_view;

export 'pdf_view_stub.dart'
    if (dart.library.js_interop) 'pdf_view_web.dart';
