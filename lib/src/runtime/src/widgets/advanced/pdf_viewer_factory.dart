import 'package:flutter/material.dart';

import '../../assets/asset_ref.dart';
import '../../renderer/render_context.dart';
import '../capability_absent.dart';
import '../widget_factory.dart';
import 'platform/pdf_view.dart';

/// Factory for `pdfViewer` (spec §10.25).
///
/// `src` is an `AssetRef`, so the same document works from a bundle, a URL, a
/// picked file (`fileInput` writes a `data:` URI), or a server resource.
///
/// Where the platform has no PDF renderer, this reports rather than rendering
/// a blank box — the §6.12.4 rule applied to a widget: a host that cannot
/// serve a form says so, and `onError` fires so the document can respond.
class PdfViewerFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // §6.13 — PDF rendering is a platform power. With a host surface wired this draws
    // the real thing; without one it reports the absence rather than drawing
    // something that looks like a rendered document.
    final surface = context.capabilities.pdfBuilder;
    if (surface != null) {
      return applyCommonWrappers(
        Builder(
          builder: (ctx) =>
              surface(ctx, properties, surfaceEventsFor(properties, context),
                  surfaceAssetsFor(context)) ??
              const SizedBox.shrink(),
        ),
        properties,
        context,
      );
    }

    final raw = context.resolve<dynamic>(properties['src']);
    final ref = AssetRef.parse(raw);
    final height = context.resolve<num?>(properties['height'])?.toDouble();
    final onError = actionOf(properties['onError'], context);

    // PDF open parameters — the standard fragment every browser viewer reads,
    // which is how page, zoom and chrome stay addressable from the DSL rather
    // than belonging to the viewer.
    // One-way: the fragment carries page/zoom *into* the embedded viewer and
    // the viewer reports nothing back, so there is no change to write to
    // state. `resolve` covers both declared branches.
    final page = context.resolve<num?>(properties['page'])?.toInt();
    final zoom = context.resolve<num?>(properties['zoom'])?.toDouble();
    final showToolbar = context.resolve<bool?>(properties['showToolbar']) ?? true;
    final showPageNav = context.resolve<bool?>(properties['showPageNav']) ?? true;
    final showZoom = context.resolve<bool?>(properties['showZoom']) ?? true;
    final fit = context.resolve<String?>(properties['fit']) ?? 'width';

    void reportError(String message) {
      if (onError == null) return;
      context.actionHandler.execute(
        onError,
        context.createChildContext(
          variables: {
            'event': {'type': 'error', 'message': message},
          },
        ),
      );
    }

    if (ref == null) {
      return _Unavailable(
        height: height,
        message: 'No document',
        onBuilt: () => reportError('pdfViewer: no src'),
      );
    }

    if (!pdfViewSupported) {
      return _Unavailable(
        height: height,
        message: 'PDF viewing is not available on this platform',
        onBuilt: () => reportError(
            'pdfViewer: this runtime has no PDF renderer on this platform'),
      );
    }

    // The browser fetches the document itself, so it needs a URL it can
    // resolve: a network URL or an inline data: URI. Bundle- and origin-served
    // documents are read by the host and handed over as data:.
    final source = switch (ref.form) {
      AssetForm.network || AssetForm.data => ref.uri,
      _ => null,
    };

    if (source == null) {
      return _Unavailable(
        height: height,
        message: 'This document source cannot be displayed here',
        onBuilt: () => reportError(
            'pdfViewer: ${ref.form.name} sources need the host to supply bytes'),
      );
    }

    return buildPdfView(
      source: _withOpenParameters(
        source,
        page: page,
        zoom: zoom,
        fit: fit,
        showToolbar: showToolbar,
        showPageNav: showPageNav,
        showZoom: showZoom,
      ),
      height: height ?? 480,
    );
  }
}

/// Appends the PDF open-parameter fragment (Adobe's `#page=`, `#zoom=`, …),
/// which every browser viewer honours.
String _withOpenParameters(
  String source, {
  int? page,
  double? zoom,
  required String fit,
  required bool showToolbar,
  required bool showPageNav,
  required bool showZoom,
}) {
  final parts = <String>[
    if (page != null) 'page=$page',
    if (zoom != null)
      'zoom=${(zoom * 100).round()}'
    else if (fit == 'width')
      'view=FitH'
    else if (fit == 'height')
      'view=FitV'
    else
      'view=Fit',
    if (!showToolbar) 'toolbar=0',
    if (!showPageNav) 'navpanes=0',
    // No dedicated open parameter for the zoom control; hiding it means
    // pinning the view so the control has nothing to change.
    if (!showZoom && zoom == null) 'view=Fit',
  ];
  if (parts.isEmpty) return source;
  // A data: URI carries no fragment slot, so parameters are dropped rather
  // than corrupting the payload.
  if (source.startsWith('data:')) return source;
  final base = source.split('#').first;
  return '$base#${parts.join('&')}';
}

class _Unavailable extends StatefulWidget {
  const _Unavailable({
    required this.message,
    required this.onBuilt,
    this.height,
  });

  final String message;
  final VoidCallback onBuilt;
  final double? height;

  @override
  State<_Unavailable> createState() => _UnavailableState();
}

class _UnavailableState extends State<_Unavailable> {
  @override
  void initState() {
    super.initState();
    // Reported once, after the frame, so the document hears about it rather
    // than only the user seeing an empty area.
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onBuilt());
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: widget.height ?? 240,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(widget.message, textAlign: TextAlign.center),
          ),
        ),
      );
}
