import 'dart:typed_data';

import 'package:flutter/painting.dart';

/// A browser has no local filesystem to read a `file:` URI from.
const bool fileAssetsAvailable = false;

ImageProvider fileImageFor(String uri) =>
    throw UnsupportedError('file: assets are not reachable on the web');

Future<Uint8List?> readFileAsset(String uri) async => null;
