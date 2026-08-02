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
        final bytes = decodeDataUri(ref.uri);
        return bytes == null ? null : MemoryImage(bytes);
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
