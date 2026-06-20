import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart' as core;
import 'package:mcp_bundle/mcp_bundle.dart';

import 'bundle_asset_provider.dart';
import 'bundle_page_adapter.dart';

/// Read adapter that implements [UiPort] from mcp_bundle.
///
/// Converts a loaded [McpBundle] into runtime-consumable UI definition
/// JSON. All UI file I/O goes through `mcp_bundle`'s reserved-folder
/// API ([McpBundle.uiResources]) — never `dart:io` directly. The bundle
/// is the single owner of file access; this adapter is just the
/// translator between bundle bytes and the runtime's JSON shape.
///
/// ## Resolution order
///
/// 1. **Snapshot layout** (canonical): when the bundle has a
///    [McpBundle.directory] and `ui/app.json` exists, read the full UI
///    definition off disk via `bundle.uiResources` — `app.json` →
///    application root, `pages/*.json` → page content.
/// 2. **Embedded layout** (fallback): when neither of the above
///    conditions holds, fall back to the typed [UiSection] inside
///    `manifest.json`. This path covers in-memory bundles and bundles
///    constructed programmatically via the typed models.
///
/// Manifest-derived metadata (`icon`, `splash`, `publisher.logo`,
/// `screenshots`) is handled identically in both paths — `bundle://`
/// URIs resolve through [BundleAssetProvider].
///
/// Composes with [BundleAssetProvider] (which itself composes with
/// [BundleStoragePort]) for `bundle://` URI resolution.
///
/// Single-direction adapter: [fromDefinition] throws [UnsupportedError].
class BundleUiReadAdapter implements UiPort {
  /// Requires a [BundleAssetProvider] for resolving bundle:// URIs in
  /// icon, splash image, publisher logo, and screenshots fields.
  BundleUiReadAdapter({required BundleAssetProvider assetProvider})
      : _assetProvider = assetProvider;

  final BundleAssetProvider _assetProvider;

  @override
  Future<UiResult<Map<String, dynamic>>> toDefinition(
      McpBundle bundle) async {
    final manifest = bundle.manifest;

    // Validate required manifest fields
    if (manifest.id.isEmpty ||
        manifest.name.isEmpty ||
        manifest.version.isEmpty) {
      return UiResult.fail(UiError(
        code: 'INVALID_MANIFEST',
        message: 'Bundle manifest requires non-empty id, name, and version',
      ));
    }

    final warnings = <UiError>[];

    // Manifest-derived metadata (path-independent — same for snapshot and
    // embedded layouts).
    final resolvedIcon = manifest.icon != null
        ? await _resolveUri(manifest.icon!, warnings, 'icon')
        : null;

    SplashConfig? resolvedSplash = manifest.splash;
    if (manifest.splash?.image != null &&
        BundleAssetProvider.isBundleUri(manifest.splash!.image)) {
      final resolved = await _resolveUri(
          manifest.splash!.image!, warnings, 'splash.image');
      if (resolved != null) {
        resolvedSplash = SplashConfig(
          image: resolved,
          backgroundColor: manifest.splash!.backgroundColor,
          duration: manifest.splash!.duration,
        );
      }
    }

    PublisherInfo? resolvedPublisher = manifest.publisher;
    if (manifest.publisher?.logo != null &&
        BundleAssetProvider.isBundleUri(manifest.publisher!.logo)) {
      final resolved = await _resolveUri(
          manifest.publisher!.logo!, warnings, 'publisher.logo');
      resolvedPublisher = PublisherInfo(
        name: manifest.publisher!.name,
        logo: resolved,
        url: manifest.publisher!.url,
        email: manifest.publisher!.email,
      );
    }

    List<String>? resolvedScreenshots;
    if (manifest.screenshots.isNotEmpty) {
      resolvedScreenshots =
          await _resolveUriList(manifest.screenshots, warnings);
    } else {
      // Empty list [] is preserved as empty (distinct from null/absent)
      resolvedScreenshots = [];
    }

    core.TimestampInfo? timestamps;
    if (manifest.createdAt != null || manifest.updatedAt != null) {
      timestamps = core.TimestampInfo(
        createdAt: manifest.createdAt,
        updatedAt: manifest.updatedAt,
      );
    }

    final manifestMeta = _ManifestMetadata(
      icon: resolvedIcon,
      splash: resolvedSplash,
      publisher: resolvedPublisher,
      screenshots: resolvedScreenshots,
      timestamps: timestamps,
    );

    // Prefer snapshot layout when the bundle has an on-disk root and
    // ui/app.json exists. This is the canonical AppPlayer bundle shape.
    if (bundle.directory != null &&
        await bundle.uiResources.exists('app.json')) {
      return _fromSnapshot(bundle, manifest, manifestMeta, warnings);
    }

    // Embedded fallback for in-memory / programmatically-constructed
    // bundles (no directory, or no ui/app.json on disk).
    return _fromEmbedded(bundle, manifest, manifestMeta, warnings);
  }

  // ---------------------------------------------------------------------------
  // Snapshot layout — UI delivered as `<bundle>/ui/**.json` files. All I/O
  // goes through `bundle.uiResources` (mcp_bundle owns the disk surface).
  // ---------------------------------------------------------------------------

  Future<UiResult<Map<String, dynamic>>> _fromSnapshot(
    McpBundle bundle,
    BundleManifest manifest,
    _ManifestMetadata meta,
    List<UiError> warnings,
  ) async {
    final ui = bundle.uiResources;

    // Application root.
    final Map<String, dynamic> appJson;
    try {
      final decoded = await ui.readJson('app.json');
      if (decoded is! Map<String, dynamic>) {
        return UiResult.fail(UiError(
          code: 'INVALID_APP_JSON',
          message: 'ui/app.json must be a JSON object',
        ));
      }
      appJson = decoded;
    } on BundleResourceParseException catch (e) {
      return UiResult.fail(UiError(
        code: 'INVALID_APP_JSON',
        message: e.toString(),
        path: 'ui/app.json',
      ));
    }

    // Pages — read every `ui/pages/*.json` and emit a `{<pageId>: <json>}`
    // map alongside the application root. Page id is the file's stem
    // under `pages/`.
    final pagesContent = <String, Map<String, dynamic>>{};
    final pageFiles = await ui.list(extension: '.json');
    for (final rel in pageFiles) {
      if (!rel.startsWith('pages/')) continue;
      final pageId = rel
          .substring('pages/'.length, rel.length - '.json'.length);
      try {
        final decoded = await ui.readJson(rel);
        if (decoded is Map<String, dynamic>) {
          pagesContent[pageId] = decoded;
        } else {
          warnings.add(UiError(
            code: 'INVALID_PAGE_JSON',
            message: 'Page content must be a JSON object',
            path: 'ui/$rel',
          ));
        }
      } on BundleResourceParseException catch (e) {
        warnings.add(UiError(
          code: 'INVALID_PAGE_JSON',
          message: e.toString(),
          path: 'ui/$rel',
        ));
      }
    }

    // Merge: app.json's top-level fields drive the result; manifest-
    // derived metadata fills any field that app.json did not specify.
    final result = <String, dynamic>{...appJson};
    _applyManifestDefaults(result, manifest, meta);
    if (pagesContent.isNotEmpty) {
      result['pages'] = pagesContent;
    }

    return warnings.isEmpty
        ? UiResult.ok(result)
        : UiResult.okWithWarnings(result, warnings);
  }

  // ---------------------------------------------------------------------------
  // Embedded layout — UI delivered inline through `manifest.json`'s typed
  // [UiSection]. Used for in-memory bundles and programmatic construction.
  // ---------------------------------------------------------------------------

  Future<UiResult<Map<String, dynamic>>> _fromEmbedded(
    McpBundle bundle,
    BundleManifest manifest,
    _ManifestMetadata meta,
    List<UiError> warnings,
  ) async {
    final uiSection = bundle.ui;
    final routes = BundlePageAdapter.toRoutes(uiSection);

    Map<String, dynamic>? initialState;
    if (uiSection != null && uiSection.state.isNotEmpty) {
      final stateMap = <String, dynamic>{};
      for (final entry in uiSection.state.entries) {
        if (entry.value.initialValue != null) {
          stateMap[entry.key] = entry.value.initialValue;
        }
      }
      if (stateMap.isNotEmpty) {
        initialState = stateMap;
      }
    }

    final appDef = core.ApplicationDefinition(
      title: manifest.name,
      version: manifest.version,
      initialRoute: routes.keys.isNotEmpty ? routes.keys.first : '/',
      routes: routes,
      theme: uiSection?.theme != null
          ? core.ThemeDefinition.fromJson(uiSection!.theme!.toJson())
          : null,
      navigation: uiSection?.navigation != null
          ? core.NavigationConfig.fromJson(uiSection!.navigation!.toJson())
          : null,
      initialState: initialState,
      id: manifest.id.isNotEmpty ? manifest.id : null,
      description: manifest.description,
      icon: meta.icon,
      splash: meta.splash,
      category: manifest.category?.name,
      publisher: meta.publisher,
      timestamps: meta.timestamps,
      screenshots: meta.screenshots,
    );

    final result = appDef.toJson();
    final pageContent = BundlePageAdapter.toPageContent(uiSection);
    if (pageContent.isNotEmpty) {
      result['pages'] = pageContent;
    }

    return warnings.isEmpty
        ? UiResult.ok(result)
        : UiResult.okWithWarnings(result, warnings);
  }

  /// Fill manifest-derived fields on the snapshot's app.json result so
  /// callers see the same composite ApplicationDefinition shape that
  /// the embedded path emits. App.json's own values always win.
  void _applyManifestDefaults(
    Map<String, dynamic> result,
    BundleManifest manifest,
    _ManifestMetadata meta,
  ) {
    result['type'] ??= 'application';
    result['title'] ??= manifest.name;
    result['version'] ??= manifest.version;
    result['id'] ??= manifest.id;
    if (manifest.description != null) {
      result['description'] ??= manifest.description;
    }
    if (meta.icon != null) result['icon'] ??= meta.icon;
    if (meta.splash != null) result['splash'] ??= meta.splash!.toJson();
    if (manifest.category != null) {
      result['category'] ??= manifest.category!.name;
    }
    if (meta.publisher != null) {
      result['publisher'] ??= meta.publisher!.toJson();
    }
    if (meta.timestamps != null) {
      result['timestamps'] ??= meta.timestamps!.toJson();
    }
    if (meta.screenshots != null && meta.screenshots!.isNotEmpty) {
      result['screenshots'] ??= meta.screenshots;
    }
  }

  @override
  Future<UiResult<Map<String, dynamic>>> toAppInfo(McpBundle bundle) async {
    final manifest = bundle.manifest;

    if (manifest.id.isEmpty ||
        manifest.name.isEmpty ||
        manifest.version.isEmpty) {
      return UiResult.fail(UiError(
        code: 'INVALID_MANIFEST',
        message: 'Bundle manifest requires non-empty id, name, and version',
      ));
    }

    final warnings = <UiError>[];

    final result = <String, dynamic>{
      'id': manifest.id,
      'name': manifest.name,
      'version': manifest.version,
    };

    if (manifest.description != null) {
      result['description'] = manifest.description;
    }
    if (manifest.category != null) {
      result['category'] = manifest.category!.name;
    }

    if (manifest.publisher != null) {
      final pub = manifest.publisher!;
      if (pub.logo != null && BundleAssetProvider.isBundleUri(pub.logo)) {
        final resolvedLogo =
            await _resolveUri(pub.logo!, warnings, 'publisher.logo');
        result['publisher'] = PublisherInfo(
          name: pub.name,
          logo: resolvedLogo,
          url: pub.url,
          email: pub.email,
        ).toJson();
      } else {
        result['publisher'] = pub.toJson();
      }
    }

    if (manifest.icon != null) {
      final resolved = await _resolveUri(manifest.icon!, warnings, 'icon');
      if (resolved != null) result['icon'] = resolved;
    }

    return warnings.isEmpty
        ? UiResult.ok(result)
        : UiResult.okWithWarnings(result, warnings);
  }

  @override
  Future<UiResult<UiWriteOutput>> fromDefinition(
      Map<String, dynamic> definitionJson) {
    throw UnsupportedError(
        'BundleUiReadAdapter does not support write operations');
  }

  /// Resolve a single URI, adding a warning if resolution fails.
  Future<String?> _resolveUri(
      String uri, List<UiError> warnings, String fieldPath) async {
    if (!BundleAssetProvider.isBundleUri(uri)) return uri;
    final resolved = await _assetProvider.resolve(uri);
    if (resolved == null) {
      warnings.add(UiError(
        code: 'UNRESOLVABLE_URI',
        message: 'Could not resolve bundle:// URI: $uri',
        path: fieldPath,
      ));
    }
    return resolved;
  }

  /// Resolve a list of URIs, adding warnings for failures.
  /// Unresolvable URIs are preserved as the original value (not dropped).
  Future<List<String>> _resolveUriList(
      List<String> uris, List<UiError> warnings) async {
    final resolved = <String>[];
    for (var i = 0; i < uris.length; i++) {
      final result =
          await _resolveUri(uris[i], warnings, 'screenshots[$i]');
      resolved.add(result ?? uris[i]);
    }
    return resolved;
  }
}

/// Internal — manifest-derived fields with bundle:// URIs already resolved.
/// Carried between the resolution step and either snapshot/embedded path.
class _ManifestMetadata {
  const _ManifestMetadata({
    required this.icon,
    required this.splash,
    required this.publisher,
    required this.screenshots,
    required this.timestamps,
  });

  final String? icon;
  final SplashConfig? splash;
  final PublisherInfo? publisher;
  final List<String>? screenshots;
  final core.TimestampInfo? timestamps;
}
