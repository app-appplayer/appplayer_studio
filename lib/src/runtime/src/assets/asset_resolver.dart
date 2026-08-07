/// One asset resolution path for every slot typed `AssetRef`.
///
/// Spec §6.12: two widgets given the same reference MUST resolve it
/// identically, and a runtime MUST publish which forms it resolves. Before
/// this, each factory hand-rolled its own `startsWith` chain and between all
/// of them only `http(s)`, `assets/`, and `data:` were handled — exactly the
/// three a *synchronous* loader can build. `bundle://` and `client://` were
/// declared by the spec and implemented nowhere.
///
/// The asynchronous forms live behind [AssetRefImage], so a widget can still
/// build an `ImageProvider` synchronously (§6.12.5).
library asset_resolver;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'asset_ref.dart';
import 'asset_ref_image.dart';

/// Reads a path inside the ambient origin's bundle.
typedef BundleAssetReader = Future<Uint8List?> Function(String path);

/// Reads a `client://` resource held by the host process.
///
/// Injected rather than implemented here: the obvious implementation reaches
/// `dart:io`, which would take the whole runtime off the web. A host supplies
/// the reader its platform can honour — and on the web that is a real reader,
/// not an absence (`client://cache`, `client://temp`, and `client://asset`
/// all have browser-side homes).
typedef ClientAssetReader = Future<Uint8List?> Function(String uri);

/// Reads a resource uri from a named origin via MCP `resources/read`.
///
/// `origin` is `null` for the ambient origin (§6.12.3) — the origin of the
/// definition that declared the asset, never the embedder's.
typedef OriginAssetReader = Future<Uint8List?> Function(
  String uri,
  Map<String, dynamic>? origin,
);

/// Resolves an [AssetRef] to bytes or to an [ImageProvider].
@immutable
class AssetResolver {
  const AssetResolver({
    this.bundleReader,
    this.clientReader,
    this.originReader,
  });

  /// The forms every host can serve with no capability at all.
  ///
  /// `data:` and `assets/` need no I/O; `http(s)` needs only a network stack
  /// Flutter already has. A host that injects nothing still resolves these,
  /// so adding this resolver never removes a form that used to work.
  static const AssetResolver builtin = AssetResolver();

  final BundleAssetReader? bundleReader;
  final ClientAssetReader? clientReader;
  final OriginAssetReader? originReader;

  /// The set this runtime resolves, for §6.12.4 / §18.2.12 declaration.
  ///
  /// Honest by construction: a form appears only when the reader that serves
  /// it was actually injected, so the published set cannot drift from what
  /// the host wired.
  Set<AssetForm> get supportedForms => {
        AssetForm.data,
        AssetForm.flutterAsset,
        AssetForm.network,
        if (bundleReader != null) AssetForm.bundle,
        if (clientReader != null) AssetForm.client,
        if (originReader != null) AssetForm.origin,
      };

  /// Decoded `data:` payloads, keyed by the URI that produced them.
  ///
  /// `MemoryImage`'s cache key is the byte list's *identity*, so decoding the
  /// same URI again yields a provider Flutter's image cache has never seen:
  /// every rebuild re-runs the base64 decode and the image decode, for a
  /// picture that has not changed. A menu photo runs to 130 kB of base64, and
  /// a page with two of them re-does that work on every frame that rebuilds.
  ///
  /// Bounded rather than unbounded: a document can name any number of data
  /// URIs, and holding all of them would trade a stutter for a leak. The bound
  /// is on entries, not bytes, because the entries are what the cache key
  /// space grows with, and eviction is oldest-first — a rebuild re-reads the
  /// same handful of images, so recency is the right thing to keep.
  /// Static, and deliberately so: the resolver is a `const` value that hosts
  /// construct freely, and a per-instance cache would miss every time a new
  /// one is made. The same `data:` URI is the same picture whoever asks.
  static const _dataImageCacheLimit = 64;
  static final Map<String, MemoryImage> _dataImages = <String, MemoryImage>{};

  /// Whether [ref] names a vector image.
  ///
  /// Vectors do not go through `ImageProvider` — they are drawn by a picture
  /// widget — so every caller needs the same answer before it picks a path.
  /// Kept here rather than in the widgets so the two cannot disagree (§6.12:
  /// one resolution path for every `AssetRef` slot).
  static bool isVector(AssetRef ref) {
    final uri = ref.uri;
    if (uri.startsWith('data:image/svg')) return true;
    final path = uri.split('?').first.split('#').first.toLowerCase();
    return path.endsWith('.svg') || path.endsWith('.svgz');
  }

  /// Whether a `data:` URI carries a vector image.
  static bool isVectorDataUri(String uri) =>
      uri.startsWith('data:image/svg');

  static MemoryImage? _dataImage(String uri) {
    if (isVectorDataUri(uri)) {
      // A vector is not raster bytes. Callers ask `isVector` first and take
      // the picture path; reaching here means one did not, and the raster
      // decoder would fail with nothing an author could act on.
      return null;
    }
    final hit = _dataImages[uri];
    if (hit != null) {
      // Move to the end so the eviction below drops what has not been asked
      // for, rather than what happened to arrive first.
      _dataImages.remove(uri);
      _dataImages[uri] = hit;
      return hit;
    }
    final bytes = decodeDataUri(uri);
    if (bytes == null) return null;
    final image = MemoryImage(bytes);
    if (_dataImages.length >= _dataImageCacheLimit) {
      _dataImages.remove(_dataImages.keys.first);
    }
    _dataImages[uri] = image;
    return image;
  }

  /// Whether [ref] can be resolved at all.
  bool supports(AssetRef ref) => supportedForms.contains(ref.form);

  /// An [ImageProvider] for [ref], or `null` when the form is unsupported.
  ///
  /// Returning `null` is how an unresolvable asset reaches the slot's declared
  /// fallback (§6.12.4) instead of rendering a placeholder that states the
  /// runtime's limitation on the user's screen.
  ImageProvider? imageProviderFor(AssetRef ref) {
    switch (ref.form) {
      case AssetForm.network:
        return NetworkImage(ref.uri);
      case AssetForm.flutterAsset:
        return AssetImage(ref.uri);
      case AssetForm.data:
        return _dataImage(ref.uri);
      case AssetForm.bundle:
      case AssetForm.client:
      case AssetForm.origin:
        // Asynchronous reads. The wait lives inside the provider so callers
        // stay synchronous (§6.12.5).
        return supports(ref) ? AssetRefImage(ref, this) : null;
      case AssetForm.unknown:
        return null;
    }
  }

  /// A widget that draws [ref] as a vector, or `null` when this runtime
  /// cannot reach the bytes.
  ///
  /// Vectors take a picture widget rather than an `ImageProvider`, so this is
  /// the vector half of `imageProviderFor` — same scheme dispatch, same
  /// `null`-means-fallback contract (§6.12.4). Asynchronous schemes read
  /// through [bytesFor], and a slot awaiting bytes shows its loading state
  /// rather than its fallback (§6.12.5).
  Widget? vectorWidgetFor(
    AssetRef ref, {
    double? width,
    double? height,
    BoxFit fit = BoxFit.contain,
    AlignmentGeometry alignment = Alignment.center,
    Color? color,
    Widget Function()? loadingBuilder,
  }) {
    final colorFilter =
        color == null ? null : ColorFilter.mode(color, BlendMode.srcIn);
    switch (ref.form) {
      case AssetForm.network:
        return SvgPicture.network(ref.uri,
            width: width,
            height: height,
            fit: fit,
            alignment: alignment,
            colorFilter: colorFilter);
      case AssetForm.flutterAsset:
        return SvgPicture.asset(ref.uri,
            width: width,
            height: height,
            fit: fit,
            alignment: alignment,
            colorFilter: colorFilter);
      case AssetForm.data:
        final bytes = decodeDataUri(ref.uri);
        if (bytes == null) return null;
        return SvgPicture.memory(bytes,
            width: width,
            height: height,
            fit: fit,
            alignment: alignment,
            colorFilter: colorFilter);
      case AssetForm.bundle:
      case AssetForm.client:
      case AssetForm.origin:
        if (!supports(ref)) return null;
        return FutureBuilder<Uint8List?>(
          future: bytesFor(ref),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return loadingBuilder?.call() ??
                  SizedBox(width: width, height: height);
            }
            final bytes = snapshot.data;
            if (bytes == null) return const SizedBox.shrink();
            return SvgPicture.memory(bytes,
                width: width,
                height: height,
                fit: fit,
                alignment: alignment,
                colorFilter: colorFilter);
          },
        );
      case AssetForm.unknown:
        return null;
    }
  }

  /// Raw bytes for [ref], or `null` when unsupported or unreadable.
  Future<Uint8List?> bytesFor(AssetRef ref) async {
    switch (ref.form) {
      case AssetForm.data:
        return decodeDataUri(ref.uri);
      case AssetForm.flutterAsset:
        try {
          final data = await rootBundleLoader(ref.uri);
          return data;
        } catch (_) {
          return null;
        }
      case AssetForm.bundle:
        return bundleReader == null ? null : bundleReader!(ref.bundlePath);
      case AssetForm.client:
        return clientReader == null ? null : clientReader!(ref.uri);
      case AssetForm.origin:
        return originReader == null
            ? null
            : originReader!(ref.uri, ref.origin);
      case AssetForm.network:
      case AssetForm.unknown:
        // Network bytes are the ImageProvider's job; nothing here needs them
        // as a buffer, and fetching one would duplicate Flutter's cache.
        return null;
    }
  }

  /// Overridable asset loader, so tests need no asset bundle.
  @visibleForTesting
  static Future<Uint8List?> Function(String key) rootBundleLoader =
      _defaultRootBundleLoader;

  static Future<Uint8List?> _defaultRootBundleLoader(String key) async {
    final data = await rootBundle.load(key);
    return data.buffer.asUint8List();
  }
}

/// Decodes a `data:` URI payload, base64 or percent-encoded.
///
/// Returns `null` on a malformed URI rather than throwing: a bad reference is
/// an unresolvable asset (§6.12.4), not a crash.
Uint8List? decodeDataUri(String uri) {
  final comma = uri.indexOf(',');
  if (comma == -1) return null;
  final isBase64 = uri.substring(0, comma).contains(';base64');
  final payload = uri.substring(comma + 1);
  try {
    return isBase64
        ? base64Decode(payload)
        : Uint8List.fromList(utf8.encode(Uri.decodeComponent(payload)));
  } catch (_) {
    return null;
  }
}
