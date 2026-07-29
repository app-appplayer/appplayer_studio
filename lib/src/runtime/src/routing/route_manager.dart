import 'package:flutter/material.dart';
import 'route_value.dart';
import '../models/ui_definition.dart';
import '../runtime/runtime_engine.dart';
import 'page_state_scope.dart';

/// Manages application routing based on MCP UI DSL spec
class RouteManager {
  final ApplicationDefinition appDefinition;
  final Map<String, PageDefinition> _loadedPages = {};
  final Function(String uri) pageLoader;
  final RuntimeEngine runtimeEngine;

  /// Page stack for tracking push/pop navigation and page pause/resume
  final List<String> _pageStack = [];

  RouteManager({
    required this.appDefinition,
    required this.pageLoader,
    required this.runtimeEngine,
    this.launchRoute,
  });

  /// Route requested by whatever opened this runtime — a scan entry, a deep
  /// link, an app-to-app open (MCP UI DSL 8.9, platform spec 19 4.3).
  ///
  /// It overrides the document's own `initialRoute`, and only when the
  /// document actually declares it: an entry that names a route the app no
  /// longer has MUST NOT be honoured silently, because a stale binding would
  /// then look exactly like a working one. [launchRouteMissing] reports that
  /// case so the host can disclose it.
  final String? launchRoute;

  /// Generate Flutter routes from application definition
  Map<String, WidgetBuilder> generateRoutes(BuildContext context) {
    final routes = <String, WidgetBuilder>{};

    for (final entry in appDefinition.routes.entries) {
      final routePath = entry.key;
      final pageUri = entry.value;

      routes[routePath] = (context) => FutureBuilder<PageDefinition>(
            future: _loadPage(pageUri, routePath: routePath),
            builder: (context, snapshot) {
              if (snapshot.hasData) {
                return _buildPageWidget(snapshot.data!, routePath);
              } else if (snapshot.hasError) {
                return _buildErrorPage(snapshot.error);
              } else {
                return _buildLoadingPage();
              }
            },
          );
    }

    return routes;
  }

  /// Get initial route — the launch route when one was requested and the
  /// document declares it, the document's own initial route otherwise.
  String get initialRoute {
    final requested = launchRoute;
    if (requested != null && appDefinition.routes.containsKey(requested)) {
      return requested;
    }
    return appDefinition.initialRoute;
  }

  /// True when a launch route was requested but this document has no such
  /// route. The host discloses it rather than pretending the request landed.
  bool get launchRouteMissing {
    final requested = launchRoute;
    return requested != null && !appDefinition.routes.containsKey(requested);
  }

  /// Navigate to a route with parameters
  ///
  /// Push navigation: old page receives pagePause, new page receives enter.
  /// Replace navigation: old page receives leave, new page receives enter.
  Future<T?> navigateTo<T>(
    BuildContext context,
    String route, {
    Map<String, dynamic>? params,
    bool replace = false,
  }) async {
    final routeWithParams = _buildRouteWithParams(route, params);

    // Execute pagePause on the current page (push) or leave (replace)
    if (_pageStack.isNotEmpty) {
      final currentRoute = _pageStack.last;
      final currentKey = routeValueCacheKey(
          currentRoute, appDefinition.routes[currentRoute]);
      if (_loadedPages.containsKey(currentKey)) {
        final currentPage = _loadedPages[currentKey]!;
        final lifecycle = currentPage.lifecycleDefinition;
        if (replace) {
          // Unmount teardown belongs to the page widget's dispose — see
          // RuntimeEngine.navigateToRoute. Running it here too fired the hook
          // twice.
        } else {
          if (lifecycle?.onPause != null) {
            runtimeEngine.lifecycle.executeOnPagePause(lifecycle!.onPause!);
          }
        }
      }
    }

    if (replace) {
      if (_pageStack.isNotEmpty) _pageStack.removeLast();
      _pageStack.add(routeWithParams);
      return Navigator.pushReplacementNamed<T, T>(
        context,
        routeWithParams,
        arguments: params,
      );
    } else {
      _pageStack.add(routeWithParams);
      return Navigator.pushNamed<T>(
        context,
        routeWithParams,
        arguments: params,
      );
    }
  }

  /// Navigate back
  ///
  /// Pop navigation: current page receives leave, previous page receives pageResume.
  void navigateBack<T>(BuildContext context, [T? result]) {
    // The outgoing page tears itself down from its widget's dispose; this only
    // pops the stack.
    if (_pageStack.isNotEmpty) {
      _pageStack.removeLast();
    }

    // Execute pageResume on the previous (now visible) page
    if (_pageStack.isNotEmpty) {
      final previousRoute = _pageStack.last;
      final previousKey = routeValueCacheKey(
          previousRoute, appDefinition.routes[previousRoute]);
      if (_loadedPages.containsKey(previousKey)) {
        final previousPage = _loadedPages[previousKey]!;
        final lifecycle = previousPage.lifecycleDefinition;
        if (lifecycle?.onResume != null) {
          runtimeEngine.lifecycle.executeOnPageResume(lifecycle!.onResume!);
        }
      }
    }

    Navigator.pop(context, result);
  }

  /// Pop to root
  void popToRoot(BuildContext context) {
    // Clear page stack except first
    if (_pageStack.length > 1) {
      _pageStack.removeRange(1, _pageStack.length);
    }
    Navigator.popUntil(context, (route) => route.isFirst);
  }

  /// Load a page definition for any `RouteValue` (spec v1.4 §1.2.1).
  ///
  /// A plain resource URI goes through the host's [pageLoader] as before.
  /// Every other form — inline page, transition wrapper, qualified `$ref` to
  /// another origin, or a binding — is normalised locally by
  /// [routeValueToPageJson]; the origin-carrying forms become a page whose
  /// content is a single `view`, so route-level and widget-level composition
  /// share one implementation.
  Future<PageDefinition> _loadPage(dynamic routeValue,
      {String routePath = ''}) async {
    final cacheKey = routeValueCacheKey(routePath, routeValue);
    if (_loadedPages.containsKey(cacheKey)) {
      return _loadedPages[cacheKey]!;
    }

    final local = routeValueToPageJson(routeValue);
    final pageJson = local ?? await pageLoader(routeValue as String);
    final uiDef = UIDefinition.fromJson(pageJson as Map<String, dynamic>);
    final pageDef = PageDefinition.fromUIDefinition(uiDef);

    _loadedPages[cacheKey] = pageDef;
    return pageDef;
  }

  /// Build route with parameters
  String _buildRouteWithParams(String route, Map<String, dynamic>? params) {
    if (params == null || params.isEmpty) {
      return route;
    }

    // Replace route parameters like /user/:id with actual values
    var finalRoute = route;
    params.forEach((key, value) {
      finalRoute = finalRoute.replaceAll(':$key', value.toString());
    });

    return finalRoute;
  }

  /// Build loading page
  Widget _buildLoadingPage() {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }

  /// Build error page
  Widget _buildErrorPage(dynamic error) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline,
              size: 64,
              color: Colors.red,
            ),
            const SizedBox(height: 16),
            const Text(
              'Failed to load page',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              error.toString(),
              style: const TextStyle(fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// Build widget for a page
  Widget _buildPageWidget(PageDefinition pageDef, String routePath) {
    // Create a page-specific state scope
    return PageStateScope(
      pageDefinition: pageDef,
      routePath: routePath,
      runtimeEngine: runtimeEngine,
      child: Builder(
        builder: (context) {
          return MCPPageWidget(
            pageDefinition: pageDef,
            runtimeEngine: runtimeEngine,
          );
        },
      ),
    );
  }

  /// Parse route and extract parameters
  RouteInfo parseRoute(String route) {
    // Extract path and query parameters
    final uri = Uri.parse(route);
    final path = uri.path;
    final queryParams = uri.queryParameters;

    // Match against application routes
    for (final appRoute in appDefinition.routes.keys) {
      final regex = _createRouteRegex(appRoute);
      final match = regex.firstMatch(path);

      if (match != null) {
        final pathParams = <String, String>{};

        // Extract path parameters
        final paramNames = _extractParamNames(appRoute);
        for (var i = 0; i < paramNames.length; i++) {
          if (i + 1 <= match.groupCount) {
            pathParams[paramNames[i]] = match.group(i + 1)!;
          }
        }

        return RouteInfo(
          route: appRoute,
          pathParams: pathParams,
          queryParams: queryParams,
          pageUri: appDefinition.routes[appRoute],
        );
      }
    }

    throw ArgumentError('No matching route found for: $route');
  }

  /// Create regex for route matching
  RegExp _createRouteRegex(String route) {
    var pattern = route;

    // Replace :param with regex capture group
    pattern = pattern.replaceAllMapped(
      RegExp(r':(\w+)'),
      (match) => r'(\w+)',
    );

    return RegExp('^$pattern\$');
  }

  /// Extract parameter names from route
  List<String> _extractParamNames(String route) {
    final matches = RegExp(r':(\w+)').allMatches(route);
    return matches.map((m) => m.group(1)!).toList();
  }
}

/// Route information
class RouteInfo {
  final String route;
  final Map<String, String> pathParams;
  final Map<String, String> queryParams;

  /// The route's raw `RouteValue` (spec v1.4 §1.2.1). Typed `dynamic` because a
  /// route may be a resource URI string, an inline page, a transition wrapper,
  /// a qualified `{ $ref, from }` reference to another origin, or a binding.
  /// Casting this to `String` would throw on every composed route.
  final dynamic pageUri;

  RouteInfo({
    required this.route,
    required this.pathParams,
    required this.queryParams,
    required this.pageUri,
  });

  Map<String, dynamic> get allParams => {
        ...pathParams,
        ...queryParams,
      };
}
