import 'package:brain_kernel/brain_kernel.dart' show McpBundle;
import 'canonical_patch.dart';

/// Read-only six-layer projection over the raw canonical JSON map. Every
/// getter is derived from the map's `manifest` / `ui` / `flow` / ... sections
/// — no separate storage.
///
/// The projection is anchored at `ui/app.json` (= the mcp_ui DSL
/// `ApplicationDefinition`). Top-level fields of the in-memory `ui` map are
/// the ApplicationDefinition fields directly (`theme`, `routes`,
/// `lifecycle`, `services`, ...); there is no spurious `ui.app.*` wrapper —
/// see appplayer's `bundle_application_adapter.dart` for the same contract.
abstract interface class LayerProjection {
  /// Build a projection from a typed [McpBundle]. Loses ApplicationDefinition
  /// fields outside mcp_bundle's typed schema (lifecycle, services, ...);
  /// prefer [LayerProjection.fromJson] for canonical reads.
  factory LayerProjection.from(McpBundle bundle) =>
      _LayerProjectionFactory.fromMap(
        Map<String, dynamic>.from(bundle.toJson()),
      );

  /// Build a projection from the raw canonical JSON map. Lossless.
  factory LayerProjection.fromJson(Map<String, dynamic> rawJson) =
      _LayerProjectionFactory.fromMap;

  AppStructure get appStructure;
  ThemeView get theme;
  ComponentSet get components;

  /// The single application-scoped dashboard (`ui.dashboard`, spec §11.9).
  /// Independent of the route/page tree — at most one per app, edited as
  /// its own design view rather than treated as a route.
  DashboardSlice? get dashboard;

  /// Application-level navigation chrome (`ui.navigation`, spec
  /// `NavigationConfig`): drawer / bottomBar / rail / tabs + items[].
  /// Edited as its own surface — chrome wraps every page at runtime
  /// but is authored once at the app level. Null when no navigation
  /// is configured yet.
  NavigationSlice? get navigation;

  /// Asset registry (`manifest.assets`): id-keyed Asset entries
  /// (icon / image / font / file / etc.). Each asset references
  /// either an in-bundle path (`.mbd/assets/...`) or an external
  /// reference (Material name / URL / data URI / inline).
  AssetSlice get assets;

  Map<String, PageSlice> get pages;

  /// Whole raw JSON snapshot. Bodies that need to read fields outside the
  /// typed slices (e.g. `manifest.publisher.email`, `ui.lifecycle.onInit`)
  /// can resolve them through [lookup].
  Map<String, dynamic> get rawJson;

  /// Walk a `/`-separated JSON Pointer (`/manifest/publisher/email`) against
  /// [rawJson] and return the value, or null when any segment is missing.
  dynamic lookup(String pointer);

  /// Path within `.mbd/` that backs the given layer. Throws for [LayerId.whole]
  /// because the whole layer is a synthetic union of all others.
  String pathFor(LayerId layerId);

  /// Reverse mapping. Returns null if the path is not owned by any layer.
  LayerId? layerForPath(String path);
}

class _LayerProjectionFactory implements LayerProjection {
  _LayerProjectionFactory.fromMap(this._json);
  final Map<String, dynamic> _json;

  Map<String, dynamic> _uiMap() {
    final ui = _json['ui'];
    return ui is Map ? Map<String, dynamic>.from(ui) : <String, dynamic>{};
  }

  @override
  AppStructure get appStructure {
    final ui = _uiMap();
    if (ui.isEmpty) return const AppStructure();
    final routes = <RouteDef>[];
    final routesRaw = ui['routes'];
    if (routesRaw is Map) {
      // Spec form: `routes: { "/path": PageDefinition | "ui://..." }`.
      routesRaw.forEach((path, value) {
        final pageId =
            value is String
                ? _pageIdFromUri(value)
                : (value is Map && value['id'] is String
                    ? value['id'] as String
                    : '');
        routes.add(RouteDef(id: '$path', path: '$path', pageId: pageId));
      });
    } else if (routesRaw is List) {
      // Legacy form: `routes: [ {id, path, pageId} ]`.
      for (final r in routesRaw) {
        if (r is Map) {
          routes.add(
            RouteDef(
              id: '${r['id'] ?? ''}',
              path: '${r['path'] ?? ''}',
              pageId: '${r['pageId'] ?? ''}',
            ),
          );
        }
      }
    }
    final permsRaw = ui['permissions'];
    final permissions = <PermissionDef>[];
    if (permsRaw is List) {
      for (final p in permsRaw) {
        if (p is String) {
          permissions.add(PermissionDef(id: p, granted: true));
        } else if (p is Map) {
          permissions.add(
            PermissionDef(
              id: '${p['id'] ?? ''}',
              granted: p['granted'] == true,
            ),
          );
        }
      }
    }
    return AppStructure(
      routes: routes,
      permissions: permissions,
      background:
          ui['background'] is Map
              ? BackgroundPolicy(kind: '${(ui['background'] as Map)['kind']}')
              : null,
      entryPageId: _entryPageId(ui),
    );
  }

  String _pageIdFromUri(String uri) {
    const pagesPrefix = 'ui://pages/';
    const uiPrefix = 'ui://';
    if (uri.startsWith(pagesPrefix)) return uri.substring(pagesPrefix.length);
    if (uri.startsWith(uiPrefix)) return uri.substring(uiPrefix.length);
    return uri;
  }

  String? _entryPageId(Map<String, dynamic> ui) {
    final initial = ui['initialRoute'];
    if (initial is! String) return null;
    final routes = ui['routes'];
    if (routes is Map && routes[initial] != null) {
      final v = routes[initial];
      if (v is String) return _pageIdFromUri(v);
      if (v is Map && v['id'] is String) return v['id'] as String;
    }
    return initial;
  }

  @override
  ThemeView get theme {
    final t = _uiMap()['theme'];
    return ThemeView(
      t is Map ? Map<String, dynamic>.from(t) : <String, dynamic>{},
    );
  }

  @override
  ComponentSet get components {
    // Reusable widget definitions under `ui.templates` (mcp_ui DSL 1.3
    // canonical). vibe does not honour the mcp_bundle UiSection alias
    // (`ui.widgets`) — the bundle storage layer isn't used here.
    final ui = _uiMap();
    final src = ui['templates'];
    if (src is Map) {
      return ComponentSet(<String, Map<String, dynamic>>{
        for (final entry in src.entries)
          if (entry.value is Map)
            '${entry.key}': Map<String, dynamic>.from(entry.value as Map),
      });
    }
    return const ComponentSet(<String, Map<String, dynamic>>{});
  }

  @override
  DashboardSlice? get dashboard {
    final raw = _uiMap()['dashboard'];
    if (raw is! Map) return null;
    return DashboardSlice(raw: Map<String, dynamic>.from(raw));
  }

  @override
  NavigationSlice? get navigation {
    final raw = _uiMap()['navigation'];
    if (raw is! Map) return null;
    return NavigationSlice(raw: Map<String, dynamic>.from(raw));
  }

  @override
  AssetSlice get assets {
    // mcp_bundle's AssetSection lives at `/manifest/assets`. The
    // top-level shape is `{ schemaVersion, assets[], directories[],
    // bundles[] }`. We surface the entries list and the raw section
    // so the UI editor can read both.
    final manifest = _json['manifest'];
    final raw = manifest is Map ? manifest['assets'] : null;
    if (raw is! Map) {
      return const AssetSlice(
        raw: <String, dynamic>{},
        entries: <Map<String, dynamic>>[],
      );
    }
    final entries = raw['assets'];
    return AssetSlice(
      raw: Map<String, dynamic>.from(raw),
      entries:
          entries is List
              ? List<Map<String, dynamic>>.unmodifiable(
                entries.whereType<Map>().map(Map<String, dynamic>.from),
              )
              : const <Map<String, dynamic>>[],
    );
  }

  @override
  Map<String, PageSlice> get pages {
    final ui = _uiMap();
    // Spec form: routes is a map of path → PageDefinition or `ui://` URI.
    // We surface inline pages directly. URI-only routes show up as empty
    // slices keyed by their route path until resolved by a loader.
    final pages = <String, PageSlice>{};
    final pagesMap = ui['pages'];
    if (pagesMap is Map) {
      pagesMap.forEach((id, value) {
        if (value is Map) {
          pages['$id'] = PageSlice(
            id: '$id',
            raw: Map<String, dynamic>.from(value),
          );
        }
      });
    }
    final routes = ui['routes'];
    if (routes is Map) {
      routes.forEach((path, value) {
        if (value is Map && !pages.containsKey(path)) {
          pages['$path'] = PageSlice(
            id: '$path',
            raw: Map<String, dynamic>.from(value),
          );
        }
      });
    }
    return pages;
  }

  @override
  String pathFor(LayerId layerId) {
    switch (layerId) {
      case LayerId.appStructure:
      case LayerId.theme:
      case LayerId.components:
      case LayerId.navigation:
        return 'ui/app.json';
      case LayerId.pages:
      case LayerId.dashboard:
        return 'ui/pages/';
      case LayerId.assets:
      case LayerId.knowledge:
      case LayerId.manifest:
      case LayerId.tools:
      case LayerId.agents:
        // Bundle-mode layers author against `manifest.json` — Tools edits
        // `manifest.tools.tools[]`, Agents `manifest.agents.agents[]`,
        // Knowledge the knowledge sections, Manifest the identity block.
        return 'manifest.json';
      case LayerId.whole:
        throw UnsupportedError(
          'whole is a synthetic union of all layers and has no single path',
        );
    }
  }

  @override
  LayerId? layerForPath(String path) {
    if (path == 'ui/app.json') return LayerId.appStructure;
    if (path.startsWith('ui/pages/')) return LayerId.pages;
    return null;
  }

  @override
  Map<String, dynamic> get rawJson => _json;

  @override
  dynamic lookup(String pointer) {
    final segments = pointer.split('/').where((s) => s.isNotEmpty).toList();
    dynamic cur = _json;
    for (final seg in segments) {
      if (cur is Map) {
        cur = cur[seg];
      } else if (cur is List) {
        final idx = int.tryParse(seg);
        if (idx == null || idx < 0 || idx >= cur.length) return null;
        cur = cur[idx];
      } else {
        return null;
      }
      if (cur == null) return null;
    }
    return cur;
  }
}

/// App-level routing / permissions / background slice.
class AppStructure {
  const AppStructure({
    this.routes = const <RouteDef>[],
    this.permissions = const <PermissionDef>[],
    this.background,
    this.entryPageId,
  });
  final List<RouteDef> routes;
  final List<PermissionDef> permissions;
  final BackgroundPolicy? background;
  final String? entryPageId;
}

class RouteDef {
  const RouteDef({required this.id, required this.path, required this.pageId});
  final String id;
  final String path;
  final String pageId;
}

class PermissionDef {
  const PermissionDef({required this.id, required this.granted});
  final String id;
  final bool granted;
}

class BackgroundPolicy {
  const BackgroundPolicy({required this.kind});
  final String kind;
}

/// Theme slice. Concrete shape mirrors the mcp_ui DSL theme block; details
/// resolved by the implementation against mcp_ui types.
class ThemeView {
  const ThemeView(this.raw);
  final Map<String, dynamic> raw;
}

/// Component-template slice.
class ComponentSet {
  const ComponentSet(this.templates);
  final Map<String, Map<String, dynamic>> templates;
}

/// Page slice.
class PageSlice {
  const PageSlice({required this.id, required this.raw});
  final String id;
  final Map<String, dynamic> raw;
}

/// Dashboard slice — the single `ui.dashboard` block (`content`,
/// `refreshInterval`, `onTap` per spec §11.9.3). Unlike pages there is
/// at most one per application.
class DashboardSlice {
  const DashboardSlice({required this.raw});
  final Map<String, dynamic> raw;
}

/// Navigation slice — `ui.navigation` block per the app schema's
/// `NavigationConfig` (`type` ∈ drawer/bottomBar/rail/tabs, `items[]`,
/// optional `header` / `footer`). One per app; chrome wraps every
/// page at runtime.
class NavigationSlice {
  const NavigationSlice({required this.raw});
  final Map<String, dynamic> raw;
}

/// Asset registry slice — `manifest.assets` (mcp_bundle
/// `AssetSection`). [raw] is the whole section; [entries] surfaces
/// the `assets[]` list directly because the editor walks them
/// individually.
class AssetSlice {
  const AssetSlice({required this.raw, required this.entries});

  /// Full `manifest.assets` map (`schemaVersion`, `assets[]`,
  /// `directories[]`, `bundles[]`).
  final Map<String, dynamic> raw;

  /// Individual asset entries — each carries `id`, `path` /
  /// `contentRef`, `type`, `mimeType`, `hash`, `size`, ... per
  /// mcp_bundle's `Asset` model. Empty when no assets registered.
  final List<Map<String, dynamic>> entries;
}
