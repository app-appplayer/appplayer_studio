/// [ImageProvider] for the asynchronous `AssetRef` forms.
///
/// Spec §6.12.5: `bundle://`, `client://`, and origin-served references are
/// read asynchronously, and a runtime whose asset path is synchronous can only
/// support the forms needing no I/O — while appearing to implement the whole
/// contract. Flutter's [ImageProvider] is already an asynchronous loader, so
/// the wait belongs here rather than in every widget that takes an asset.
library asset_ref_image;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'asset_ref.dart';
import 'asset_resolver.dart';

/// Loads an [AssetRef] through an [AssetResolver].
@immutable
class AssetRefImage extends ImageProvider<AssetRefImage> {
  const AssetRefImage(this.ref, this.resolver, {this.scale = 1.0});

  final AssetRef ref;
  final AssetResolver resolver;
  final double scale;

  @override
  Future<AssetRefImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<AssetRefImage>(this);

  @override
  ImageStreamCompleter loadImage(
    AssetRefImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: key.scale,
      debugLabel: key.ref.uri,
      informationCollector: () sync* {
        yield ErrorDescription('AssetRef: ${key.ref}');
      },
    );
  }

  Future<ui.Codec> _load(AssetRefImage key, ImageDecoderCallback decode) async {
    final bytes = await key.resolver.bytesFor(key.ref);
    if (bytes == null || bytes.isEmpty) {
      // Evict so a later attempt re-reads rather than serving a cached
      // failure — a bundle asset can arrive after first paint.
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      throw StateError('Asset could not be resolved: ${key.ref.uri}');
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is AssetRefImage && other.ref == ref && other.scale == scale;

  @override
  int get hashCode => Object.hash(ref, scale);

  @override
  String toString() => 'AssetRefImage(${ref.uri})';
}
