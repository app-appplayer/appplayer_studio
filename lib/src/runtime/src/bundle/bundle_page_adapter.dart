import 'package:mcp_bundle/mcp_bundle.dart';

/// Internal helper that converts UiSection pages into route mappings
/// and page content for ApplicationDefinition consumption.
///
/// Retained for callers that construct bundles programmatically via
/// mcp_bundle's typed `UiSection` / `WidgetNode` models. The canonical
/// bundle layout is a filesystem snapshot of the server's resource URI
/// space (ui/app.json, ui/pages/<id>.json) — see
/// `BundleApplicationAdapter` — so runtime consumers should prefer
/// that path; this adapter is kept only as a typed-model bridge.
///
/// This helper performs NO shape translation on page content — the
/// bundle is expected to store exactly what the runtime consumes.
class BundlePageAdapter {
  BundlePageAdapter._();

  /// Convert UiSection pages to a routes map.
  ///
  /// Returns a `Map<String, String>` mapping route paths to resource
  /// URIs (`ui://pages/<id>`).
  static Map<String, String> toRoutes(UiSection? uiSection) {
    if (uiSection == null || uiSection.pages.isEmpty) {
      return const {};
    }
    final routes = <String, String>{};
    for (final page in uiSection.pages.values) {
      final routePath = page.route ?? '/${page.id}';
      routes[routePath] = 'ui://pages/${page.id}';
    }
    return routes;
  }

  /// Convert UiSection pages to embedded page content map.
  ///
  /// Emits `{pageId: page.toJson()}` verbatim. The runtime expects the
  /// page JSON to already be in its execution shape; no translation
  /// happens here.
  static Map<String, Map<String, dynamic>> toPageContent(
      UiSection? uiSection) {
    if (uiSection == null || uiSection.pages.isEmpty) {
      return const {};
    }
    final content = <String, Map<String, dynamic>>{};
    for (final page in uiSection.pages.values) {
      content[page.id] = page.toJson();
    }
    return content;
  }
}
