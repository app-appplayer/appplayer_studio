import 'package:flutter/material.dart';

/// Whether this platform can render a PDF without host help.
bool get pdfViewSupported => false;

/// Native builder — never called when [pdfViewSupported] is false.
Widget buildPdfView({
  required String source,
  required double? height,
  Key? key,
}) =>
    const SizedBox.shrink();
