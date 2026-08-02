import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// The browser renders PDFs itself, so the widget is an embedded frame.
bool get pdfViewSupported => true;

final Set<String> _registered = <String>{};

Widget buildPdfView({
  required String source,
  required double? height,
  Key? key,
}) {
  // One view type per source: the registry is global and keyed by name, so
  // re-registering the same name with a different URL would silently serve the
  // first document for every later one.
  final viewType = 'mcp-pdf-${source.hashCode}';
  if (_registered.add(viewType)) {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
      final iframe = web.HTMLIFrameElement()
        ..src = source
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%';
      return iframe;
    });
  }
  return SizedBox(
    key: key,
    height: height,
    child: HtmlElementView(viewType: viewType),
  );
}
