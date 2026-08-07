// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/host_media/lib/src/web_surface_web.dart
// Regenerate with debug/tool/sync_host_media_fork.sh.
// Runtime imports are rewritten to the studio's vendored runtime fork.
//
library;

import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import '../../../runtime/flutter_mcp_ui_runtime.dart';
import 'package:web/web.dart' as web;

/// A web view on the web is an iframe — the browser already is the engine.
///
/// `webview_flutter` has no web implementation, which is why the plugin-based
/// surface reports absent here. That does not mean a browser build cannot show
/// a page: it can, natively, and refusing to would be a limitation the runtime
/// invented rather than one the platform has.
///
/// What the platform genuinely limits is which pages agree to be framed. A site
/// sending `X-Frame-Options: DENY` or a `frame-ancestors` CSP is refused by the
/// browser, and the refusal is not always observable from script — so `onError`
/// fires where it is, and the rest is the platform's honesty, not ours.
SurfaceBuilder? iframeWebViewSurface() {
  var counter = 0;
  return (context, properties, events, assets) {
    final url = properties['url'];
    final html = properties['html'];
    if (url is! String && html is! String) return null;

    final viewType = 'mcp-webview-${counter++}';
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
      final iframe = web.HTMLIFrameElement()
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%';

      // A document that asked for JavaScript off gets a sandbox without it.
      // Omitting the attribute entirely is the "on" case, since a bare iframe
      // runs scripts.
      if (properties['enableJavaScript'] == false) {
        iframe.setAttribute('sandbox', '');
      }

      iframe.onLoad.listen((_) => events.emit('onPageFinished', {
            if (url is String) 'url': url,
          }));
      iframe.onError.listen((_) => events.emit('onError', {
            'message': 'the browser refused to load this page in a frame',
          }));

      if (url is String) {
        events.emit('onPageStarted', {'url': url});
        iframe.src = url;
      } else {
        iframe.srcdoc = (html as String).toJS;
      }
      return iframe;
    });

    return HtmlElementView(viewType: viewType);
  };
}
