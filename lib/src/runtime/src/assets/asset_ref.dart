/// `AssetRef` parsing — MCP UI DSL 1.4 `configs/_primitive/AssetRef.yaml`.
///
/// One parser, used by every slot typed `AssetRef`. Spec §6.12 requires
/// that two widgets given the same reference resolve it identically, which
/// only holds if they agree on what the reference *is* before they try to
/// load it.
library asset_ref;

import 'package:flutter/foundation.dart';

/// The shape an [AssetRef] takes, which selects the loader.
///
/// The set is deliberately open (§6.12.1): [unknown] is a scheme this
/// runtime does not implement, not a malformed reference. It travels the
/// unresolvable path (§6.12.4) rather than being rejected.
enum AssetForm {
  /// `data:<mime>;base64,<payload>` or `data:<mime>,<urlencoded>`.
  data,

  /// `assets/<path>` — consumer app asset declared in pubspec.
  flutterAsset,

  /// `http://` / `https://`.
  network,

  /// `bundle://<path>` — asset inside the ambient origin's bundle.
  bundle,

  /// `client://<type>/<path>` — resource held by the client/host process.
  client,

  /// Object form `{uri, origin?}` — read via MCP `resources/read`.
  origin,

  /// A scheme this runtime does not resolve.
  unknown,
}

/// A parsed asset reference.
@immutable
class AssetRef {
  const AssetRef._(this.form, this.uri, {this.origin});

  /// Which loader this reference selects.
  final AssetForm form;

  /// The reference itself: the raw string, or the object form's `uri`.
  final String uri;

  /// Object form's `origin`, when one was declared.
  ///
  /// `null` means the **ambient origin** — the origin of the definition
  /// that declared the asset, never the embedder's (§6.12.3).
  final Map<String, dynamic>? origin;

  /// Parses a value already stripped of bindings.
  ///
  /// Callers MUST resolve bindings before calling this (§6.12.2): a slot
  /// that parses the literal `"{{item.picture}}"` finds no scheme and
  /// fails on a document that is correct.
  ///
  /// Returns `null` when [value] is absent, empty, or not an asset shape.
  static AssetRef? parse(dynamic value) {
    if (value is Map) {
      final uri = value['uri'];
      if (uri is! String || uri.isEmpty) return null;
      final origin = value['origin'];
      return AssetRef._(
        AssetForm.origin,
        uri,
        origin: origin is Map
            ? Map<String, dynamic>.from(origin)
            : null,
      );
    }
    if (value is! String || value.isEmpty) return null;
    return AssetRef._(_formOf(value), value);
  }

  static AssetForm _formOf(String src) {
    if (src.startsWith('data:')) return AssetForm.data;
    if (src.startsWith('http://') || src.startsWith('https://')) {
      return AssetForm.network;
    }
    if (src.startsWith('bundle://')) return AssetForm.bundle;
    if (src.startsWith('client://')) return AssetForm.client;
    if (src.startsWith('assets/')) return AssetForm.flutterAsset;
    return AssetForm.unknown;
  }

  /// Path after the `bundle://` prefix. Empty for other forms.
  String get bundlePath =>
      form == AssetForm.bundle ? uri.substring('bundle://'.length) : '';

  /// Whether this reference names a Material icon rather than an asset.
  ///
  /// `icon.icon` accepts a name, a codepoint object, or an `AssetRef`
  /// (§2.5.4). A bare string carrying no known scheme and no `assets/`
  /// prefix is a **name**, which keeps the named form the zero-ceremony
  /// default rather than an error.
  bool get looksLikeIconName => form == AssetForm.unknown && !uri.contains(':');

  @override
  bool operator ==(Object other) =>
      other is AssetRef &&
      other.form == form &&
      other.uri == uri &&
      mapEquals(other.origin, origin);

  @override
  int get hashCode => Object.hash(form, uri, origin?.length ?? 0);

  @override
  String toString() => 'AssetRef(${form.name}, $uri)';
}
