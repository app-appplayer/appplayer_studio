import 'package:flutter/material.dart';
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
  });

  /// Generate Flutter routes from application definition
  Map<String, WidgetBuilder> generateRoutes(BuildContext context) {
    final routes = <String, WidgetBuilder>{};

    for (final entry in appDefinition.routes.entries) {
      final routePath = entry.key;
      final pageUri = entry.value;

      routes[routePath] = (context) => FutureBuilder<PageDefinition>(
            future: _loadPage(pageUri),
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

  /// Get initial route
  String get initialRoute => appDefinition.initialRoute;

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
      final currentPageUri = appDefinition.routes[currentRoute];
      if (currentPageUri != null && _loadedPages.containsKey(currentPageUri)) {
        final currentPage = _loadedPages[currentPageUri]!;
        final lifecycle = currentPage.lifecycleDefinition;
        if (replace) {
          if (lifecycle?.onLeave != null) {
            runtimeEngine.lifecycle.executeOnLeave(lifecycle!.onLeave!);
          }
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
    // Execute leave on the current page
    if (_pageStack.isNotEmpty) {
      final currentRoute = _pageStack.last;
      final currentPageUri = appDefinition.routes[currentRoute];
      if (currentPageUri != null && _loadedPages.containsKey(currentPageUri)) {
        final currentPage = _loadedPages[currentPageUri]!;
        final lifecycle = currentPage.lifecycleDefinition;
        if (lifecycle?.onLeave != null) {
          runtimeEngine.lifecycle.executeOnLeave(lifecycle!.onLeave!);
        }
      }
      _pageStack.removeLast();
    }

    // Execute pageResume on the previous (now visible) page
    if (_pageStack.isNotEmpty) {
      final previousRoute = _pageStack.last;
      final previousPageUri = appDefinition.routes[previousRoute];
      if (previousPageUri != null && _loadedPages.containsKey(previousPageUri)) {
        final previousPage = _loadedPages[previousPageUri]!;
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

  /// Load a page definition
  Future<PageDefinition> _loadPage(String pageUri) async {
    // Check cache first
    if (_loadedPages.containsKey(pageUri)) {
      return _loadedPages[pageUri]!;
    }

    // Load from server
    final pageJson = await pageLoader(pageUri);
    final uiDef = UIDefinition.fromJson(pageJson as Map<String, dynamic>);
    final pageDef = PageDefinition.fromUIDefinition(uiDef);

    // Cache the loaded page
    _loadedPages[pageUri] = pageDef;

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
          pageUri: appDefinition.routes[appRoute]!,
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
  final String pageUri;

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
