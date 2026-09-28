import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';

/// Whether this build can reach the local filesystem.
const bool fileAssetsAvailable = true;

/// An [ImageProvider] over the file a `file:` URI names.
ImageProvider fileImageFor(String uri) => FileImage(File(_pathOf(uri)));

/// The bytes of the file a `file:` URI names, or null when it cannot be read.
Future<Uint8List?> readFileAsset(String uri) async {
  try {
    return await File(_pathOf(uri)).readAsBytes();
  } catch (_) {
    return null;
  }
}

String _pathOf(String uri) => Uri.parse(uri).toFilePath();
