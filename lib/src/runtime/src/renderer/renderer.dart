import 'package:flutter/material.dart';
import '../widgets/lifecycle_host.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart' as core
    show WidgetDefinition, PageDefinition, WidgetSpecRegistry;

import '../runtime/widget_registry.dart';
import '../binding/binding_engine.dart';
import '../actions/action_handler.dart';
import '../state/state_manager.dart';
import '../theme/theme_manager.dart';
import '../utils/color_parser.dart';
import '../utils/icon_resolver.dart';
import '../optimization/widget_cache.dart';
import '../plugins/plugin_hooks.dart';
import '../utils/mcp_logger.dart';
import 'render_context.dart';

/// Wrap callback supplied by host tooling (e.g. the AppPlayer Builder /
/// vibe editor) so each rendered widget can be paired with its source
/// JSON node for hit-testing. The runtime invokes the wrapper exactly
/// once per `renderWidget` call. When no wrapper is supplied the runtime
/// follows the fast path with zero per-node overhead.
typedef RenderInspector = Widget Function(
  Widget child,
  Map<String, dynamic> node,
);

/// Core rendering engine for MCP UI DSL
class Renderer {
  final WidgetRegistry widgetRegistry;
  final BindingEngine bindingEngine;
  final ActionHandler actionHandler;
  final StateManager stateManager;
  /// This renderer's own widget cache — see `WidgetCache.isolated`. A shared
  /// one leaks the closures of whichever document built the entry first.
  final WidgetCache _widgetCache = WidgetCache.isolated();
  final MCPLogger _logger = MCPLogger('Renderer');
  dynamic engine;
  bool Function(String action, String route, Map<String, dynamic> params)?
      navigationHandler;
  Future<dynamic> Function(
          String resource, String method, String target, dynamic data)?
      resourceHandler;

  /// Optional inspector wrapper. `null` on the production fast path.
  final RenderInspector? _widgetWrapper;

  Renderer({
    required this.widgetRegistry,
    required this.bindingEngine,
    required this.actionHandler,
    required this.stateManager,
    this.engine,
    RenderInspector? widgetWrapper,
  }) : _widgetWrapper = widgetWrapper;

  /// Render a page definition
  Widget renderPage(Map<String, dynamic> pageDefinition) {
    final type = pageDefinition['type'] as String? ?? 'single';
    final properties =
        pageDefinition['properties'] as Map<String, dynamic>? ?? {};
    // Support both List and Map for children, plus content for v1.0 compatibility (P6)
    final rawChildren = pageDefinition['children'] ?? pageDefinition['content'];
    final Map<String, dynamic>? content;
    if (rawChildren is List) {
      // Multiple children: wrap in a Column widget
      content = <String, dynamic>{
        'type': 'column',
        'children': rawChildren,
      };
    } else if (rawChildren is Map<String, dynamic>) {
      content = rawChildren;
    } else {
      content = null;
    }

    // Handle both formats: appBar in properties or at root level
    final appBar = pageDefinition['appBar'] ?? properties['appBar'];
    final body = pageDefinition['body'] ?? content;
    final bottomBar = pageDefinition['bottomBar'] ?? properties['bottomBar'];
    final floatingAction =
        pageDefinition['floatingAction'] ?? properties['floatingAction'];

    switch (type) {
      case 'page': // Add explicit handling for 'page' type
      case 'single':
        return _renderSinglePage({
          ...properties,
          'appBar': appBar,
          'bottomBar': bottomBar,
          'floatingAction': floatingAction,
        }, body);
      case 'tabs':
        return _renderTabsPage(properties, pageDefinition);
      case 'drawer':
        return _renderDrawerPage(properties, content);
      default:
        return _renderSinglePage({
          ...properties,
          'appBar': appBar,
          'bottomBar': bottomBar,
          'floatingAction': floatingAction,
        }, body);
    }
  }

  Widget _renderSinglePage(
    Map<String, dynamic> properties,
    Map<String, dynamic>? content,
  ) {
    // Wrap in a [Builder] so the [RenderContext] carries a live
    // [BuildContext] — this is what lets `theme.x.y` bindings, the
    // responsive-value resolver, and any `AppSpacing.of(context)`-style
    // helpers see the active form factor. Without it the context falls
    // back to compact regardless of window width.
    return Builder(builder: (ctx) {
      final renderCtx = createRootContext(ctx);
      return Scaffold(
        appBar: _buildAppBar(properties['appBar'], renderCtx),
        body: content != null
            ? renderWidget(content, renderCtx)
            : Container(),
        floatingActionButton: _buildFloatingActionButton(
          properties['floatingAction'],
          renderCtx,
        ),
        bottomNavigationBar:
            _buildBottomBar(properties['bottomBar'], renderCtx),
        backgroundColor: _resolveColor(properties['backgroundColor']),
      );
    });
  }

  Widget _renderTabsPage(
    Map<String, dynamic> properties,
    Map<String, dynamic> pageDefinition,
  ) {
    final tabs = pageDefinition['tabs'] as List<dynamic>? ?? [];

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(properties['title'] ?? ''),
          bottom: TabBar(
            tabs: tabs.map((tab) {
              final tabData = tab as Map<String, dynamic>;
              return Tab(
                text: tabData['label'] as String?,
                icon: tabData['icon'] != null
                    ? Icon(_resolveIconData(tabData['icon']))
                    : null,
              );
            }).toList(),
          ),
        ),
        body: TabBarView(
          children: tabs.map((tab) {
            final tabData = tab as Map<String, dynamic>;
            final content = tabData['content'] as Map<String, dynamic>?;
            return content != null
                ? renderWidget(content, createRootContext(null))
                : Container();
          }).toList(),
        ),
      ),
    );
  }

  Widget _renderDrawerPage(
    Map<String, dynamic> properties,
    Map<String, dynamic>? content,
  ) {
    final context = createRootContext(null);
    final drawer = properties['drawer'] as Map<String, dynamic>?;

    return Scaffold(
      appBar: _buildAppBar(properties['appBar'], context),
      drawer: drawer != null ? renderWidget(drawer, context) : null,
      body: content != null ? renderWidget(content, context) : Container(),
    );
  }

  /// Render a widget definition.
  ///
  /// When a [WidgetInspector] was supplied at construction, the built widget
  /// is paired with the source [definition] via the inspector before being
  /// returned. The null-check is the only added cost on the production path
  /// and folds into a single predicted branch.
  /// Depth of the render pass inside an `errorRecovery` subtree.
  ///
  /// The renderer normally converts a failed build into an inline error card,
  /// which is right for a screen with nothing else to fall back on — but it
  /// also meant `errorRecovery` never saw a failure. Its `handlers`, its
  /// `fallback` and its `onError` were unreachable: the card had already been
  /// returned by the time control came back to the widget.
  ///
  /// A counter rather than a parameter, because the failure is usually not in
  /// the immediate child but somewhere below it, and nested `renderWidget`
  /// calls run on this same instance. Builds are synchronous, so there is no
  /// interleaving to guard against.
  int _rethrowDepth = 0;

  /// Renders [definition] letting a build failure escape to the caller.
  ///
  /// Only `errorRecovery` should use this: it exists to handle the failure
  /// itself, and an escaping exception with nobody above to catch it reaches
  /// the framework instead.
  Widget renderWidgetRethrowingErrors(
      Map<String, dynamic> definition, RenderContext context) {
    _rethrowDepth++;
    try {
      return renderWidget(definition, context);
    } finally {
      _rethrowDepth--;
    }
  }

  Widget renderWidget(Map<String, dynamic> definition, RenderContext context) {
    // Instance-level lifecycle: a widget's own `lifecycle: {}` block.
    // Nothing read it before, so a widget could declare hooks and have them
    // silently dropped. Wrapping happens only when hooks are actually
    // declared, so the tree is unchanged for every other widget.
    final built = LifecycleHost.maybeWrap(
      definition: definition,
      context: context,
      label: (definition['type'] as String?) ?? 'widget',
      child: _renderWidgetCore(definition, context),
    );
    final wrap = _widgetWrapper;
    if (wrap == null) return built;
    // ParentDataWidgets (Expanded / Flexible / Positioned) must remain a
    // direct child of their parent (Row, Column, Stack) so the parent's
    // RenderObject can read their ParentData. Wrapping the
    // ParentDataWidget itself with anything (e.g. a host-supplied
    // MetaData) would hide it from the parent and collapse the layout.
    // Push the wrap *inside* the ParentDataWidget instead.
    if (built is Expanded) {
      return Expanded(
        flex: built.flex,
        child: wrap(built.child, definition),
      );
    }
    if (built is Flexible) {
      return Flexible(
        flex: built.flex,
        fit: built.fit,
        child: wrap(built.child, definition),
      );
    }
    if (built is Positioned) {
      return Positioned(
        left: built.left,
        top: built.top,
        right: built.right,
        bottom: built.bottom,
        width: built.width,
        height: built.height,
        child: wrap(built.child, definition),
      );
    }
    return wrap(built, definition);
  }

  /// Slots the runtime itself reads on any widget, so a child sitting in one
  /// of them is not lost.
  static const _universalSlots = <String>{
    'child', 'children', 'content', 'body', 'properties', 'lifecycle',
  };

  /// Already-reported (type, key) pairs — a page that repeats the mistake says
  /// it once. Per renderer, not per process: a host that opens a second
  /// document (a studio tab, a launcher opening another app) must hear about
  /// that document's own dropped children.
  final Set<String> _reportedUnreadSlots = <String>{};

  /// A child declared into a slot its widget never reads draws nothing and
  /// says nothing.
  ///
  /// `{"type": "box", "content": {...}}` is the shape that cost a colleague a
  /// day: `box` reads `child`, so the node was never mounted — no widget, no
  /// error, no pixels, and every downstream reading ("the surface is never
  /// called", "the capability must be missing") was consistent with it. The
  /// widget cannot render what it does not know about, but it can say that
  /// something was declared and dropped, which is the perform-or-report rule applied to a
  /// slot rather than to a capability.
  ///
  /// Reported, never rendered: drawing an error box here would change screens
  /// that carry harmless extra keys. Once per (type, key).
  void _warnAboutUnreadChildSlots(
      String type, Map<String, dynamic> definition) {
    final spec = core.WidgetSpecRegistry.getSpec(type);
    if (spec == null) return; // unknown to the registry: nothing to compare
    for (final entry in definition.entries) {
      final key = entry.key;
      if (key == 'type') continue;
      if (spec.parameters.containsKey(key)) continue;
      if (_universalSlots.contains(key) && spec.parameters.containsKey(key)) {
        continue;
      }
      if (!_looksLikeWidget(entry.value)) continue;
      // `child`/`children` on a widget whose spec declares neither is the same
      // mistake in the other direction, and is reported the same way.
      if (!_reportedUnreadSlots.add('$type|$key')) continue;
      _logger.warning(
        '`$type` declares no `$key`, and the widget placed there was dropped: '
        'nothing was mounted, and nothing else will report it. '
        '${spec.parameters.containsKey('child') ? 'This widget takes `child`.' : spec.parameters.containsKey('children') ? 'This widget takes `children`.' : ''}',
      );
    }
  }

  /// Whether [value] is a widget declaration, or a list containing one.
  static bool _looksLikeWidget(Object? value) {
    if (value is Map && value['type'] is String) return true;
    if (value is List) {
      return value.any((e) => e is Map && e['type'] is String);
    }
    return false;
  }

  Widget _renderWidgetCore(
      Map<String, dynamic> definition, RenderContext context) {
    final type = definition['type'] as String?;
    if (kDebugMode) {
      _logger.debug('renderWidget called with type: $type');
      _logger.debug('renderWidget definition: $definition');
    }

    if (type == null) {
      return _errorWidget('Widget type is required', definition);
    }

    _warnAboutUnreadChildSlots(type, definition);

    // Check visible property - return empty widget if explicitly hidden
    // Skip for 'visibility' type which handles visible property itself
    if (type != 'visibility') {
      final properties =
          definition['properties'] as Map<String, dynamic>? ?? definition;
      final visible = properties['visible'];
      if (visible != null) {
        final resolvedVisible = bindingEngine.resolve<bool>(visible, context);
        if (resolvedVisible == false) {
          return const SizedBox.shrink();
        }
      }
    }

    // Check cache first if caching is enabled and widget is cacheable
    if (_widgetCache.enabled && _isCacheable(definition, type)) {
      final contextData = _extractCacheableContext(context);
      final cachedWidget = _widgetCache.get(definition, contextData);
      if (cachedWidget != null) {
        return cachedWidget;
      }
    }

    // Use exact case for case-sensitive matching (MCP UI DSL v1.0)
    final factory = widgetRegistry.get(type);
    if (factory == null) {
      return _errorWidget('Unknown widget type: $type', definition);
    }

    try {
      // Fire plugin onRender hook before rendering
      PluginHookManager.instance.fireHookSync(
        PluginHookType.onRender,
        data: {'type': type, 'phase': 'before'},
      );

      final widget = factory.build(definition, context);

      // Fire plugin onRender hook after rendering
      PluginHookManager.instance.fireHookSync(
        PluginHookType.onRender,
        data: {'type': type, 'phase': 'after'},
      );

      // Cache the widget if caching is enabled and it's cacheable
      if (_widgetCache.enabled && _isCacheable(definition, type)) {
        final contextData = _extractCacheableContext(context);
        _widgetCache.put(definition, contextData, widget);
      }

      return widget;
    } catch (e, stackTrace) {
      final message = 'Error rendering $type: $e';

      // Inside an `errorRecovery` subtree the document asked to handle this
      // itself; the inline card would hide the failure from the widget whose
      // whole job is to answer it. The failure is still reported.
      if (_rethrowDepth > 0) {
        _reportFailure(message, type, error: e, stackTrace: stackTrace);
        rethrow;
      }

      // `_errorWidget` reports; reporting here as well would deliver one
      // failure twice.
      return _errorWidget(message, definition,
          error: e, stackTrace: stackTrace);
    }
  }

  /// Render multiple child widget definitions
  List<Widget> renderChildren(
      List<Map<String, dynamic>> children, RenderContext context) {
    return children.map((child) => renderWidget(child, context)).toList();
  }

  /// Render a single optional child widget definition
  Widget? renderChild(Map<String, dynamic>? child, RenderContext context) {
    if (child == null) return null;
    return renderWidget(child, context);
  }

  /// Render a strongly-typed WidgetDefinition
  /// Converts to JSON internally for backward compatibility with factories.
  Widget renderDefinition(core.WidgetDefinition definition, RenderContext context) {
    return renderWidget(definition.toJson(), context);
  }

  /// Render a strongly-typed PageDefinition
  Widget renderPageDefinition(core.PageDefinition definition) {
    return renderPage(definition.toJson());
  }

  /// Render dashboard summary widget (v1.3)
  ///
  /// Renders the compact dashboard widget tree without routing or navigation.
  /// Returns an empty SizedBox if no dashboard config is provided.
  Widget renderDashboard(Map<String, dynamic>? dashboardConfig) {
    if (dashboardConfig == null) return const SizedBox.shrink();

    final content = dashboardConfig['content'] as Map<String, dynamic>?;
    if (content == null) return const SizedBox.shrink();

    final context = createRootContext(null);
    return renderWidget(content, context);
  }

  /// Create root render context
  RenderContext createRootContext(BuildContext? context) {
    _logger.debug(
        'Creating root context with navigationHandler: ${navigationHandler != null}');
    return RenderContext(
      renderer: this,
      stateManager: stateManager,
      bindingEngine: bindingEngine,
      actionHandler: actionHandler,
      themeManager: ThemeManager.instance,
      buildContext: context,
      engine: engine,
      navigationHandler: navigationHandler,
      resourceHandler: resourceHandler,
    )..definitionResolver = definitionResolver;
  }

  /// Resolver the `view` widget uses to fetch a definition from an origin
  /// (Composition Profile). Held here rather than on a single
  /// context because root contexts are created on demand — stamping it in
  /// [createRootContext] is what makes it reach every tree, and
  /// `RenderContext.createChildContext` carries it the rest of the way.
  ///
  /// `null` = this runtime does not implement the Composition Profile; `view`
  /// then fails closed rather than resolving a foreign `\$ref` against the
  /// host's own origin.
  Future<Map<String, dynamic>> Function(String ref, Map<String, dynamic> origin)?
      definitionResolver;

  /// Host hook for running a `tool` action against a named origin.
  ///
  /// A `view` that names an origin makes that origin ambient for its subtree,
  /// and a tool call from inside it belongs to that device — not to the app's
  /// own server. Without this the subtree renders but
  /// nothing in it works: the call takes the app's normal path and lands on a
  /// session with no client for it.
  Future<dynamic> Function(
          Map<String, dynamic> origin, String tool, Map<String, dynamic> params)?
      originToolCaller;

  /// Host hook for watching a resource on a named origin.
  ///
  /// The live half. A device's changing value — an uptime, a temperature —
  /// reaches a composed screen only through this; without it the subtree
  /// renders the reading's label and never a number, which looks like a layout
  /// bug rather than a missing capability.
  ///
  /// [onUpdate] fires with the resource's new contents each time the origin
  /// reports it changed. Returns a disposer the runtime calls on unsubscribe.
  Future<void Function()> Function(
    Map<String, dynamic> origin,
    String uri,
    void Function(dynamic contents) onUpdate,
  )? originResourceWatcher;

  /// Host hook for a ONE-SHOT read on a named origin.
  ///
  /// Separate from the watcher because a read that leaves a subscription
  /// behind keeps a device pushing to a view that asked once — and a view that
  /// only ever reads should not make the device stream.
  Future<Object?> Function(Map<String, dynamic> origin, String uri)?
      originResourceReader;

  AppBar? _buildAppBar(
    Map<String, dynamic>? appBarDef,
    RenderContext context,
  ) {
    if (appBarDef == null) return null;

    // If it already has a type, use the factory
    if (appBarDef['type'] != null) {
      final widget = renderWidget(appBarDef, context);
      if (widget is AppBar) {
        return widget;
      } else if (widget is PreferredSizeWidget) {
        // Wrap in AppBar if it's a PreferredSizeWidget
        return AppBar(
          flexibleSpace: widget,
        );
      }
    }

    // Otherwise create a simple AppBar (backward compatibility)
    final properties =
        appBarDef['properties'] as Map<String, dynamic>? ?? appBarDef;
    final actions = properties['actions'] as List<dynamic>?;
    final leading = properties['leading'] as Map<String, dynamic>?;
    final title = properties['title'];

    return AppBar(
      title: title is String
          ? Text(context.resolve(title))
          : (title is Map<String, dynamic>
              ? renderWidget(title, context)
              : null),
      elevation: properties['elevation']?.toDouble(),
      backgroundColor: _resolveColor(properties['backgroundColor']),
      leading: leading != null ? renderWidget(leading, context) : null,
      actions: actions
          ?.map(
              (action) => renderWidget(action as Map<String, dynamic>, context))
          .toList(),
    );
  }

  Widget? _buildFloatingActionButton(
    Map<String, dynamic>? fabDef,
    RenderContext context,
  ) {
    if (fabDef == null) return null;
    return renderWidget(fabDef, context);
  }

  Widget? _buildBottomBar(
    Map<String, dynamic>? bottomBarDef,
    RenderContext context,
  ) {
    if (bottomBarDef == null) return null;
    return renderWidget(bottomBarDef, context);
  }

  /// Colors through the one parser. This used to be a private copy that
  /// took `pink` and `transparent`, knew no scheme slot, and read `#fff` as
  /// near-black — so a page background could not use the spelling the spec
  /// prefers, and the shorthand it allows drew the wrong color.
  Color? _resolveColor(dynamic color) => DslColor.parse(
        color,
        slotResolver: ThemeManager.instance.getColorValue,
        where: 'page color',
      );

  /// Icons through the one resolver.
  ///
  /// This was a 580-line switch of its own. Two of its names drew a different
  /// glyph than the shared map (`camera`, `copy`) and 186 more existed only
  /// here, so `icon: "car"` worked on an app bar and drew the missing-icon cue
  /// in any widget — the same drift 0.6.1 closed in two other slots. The short
  /// forms moved into `icon_resolver.dart` as aliases; nothing an author wrote
  /// stops working, and it now works everywhere the spec says an `IconRef`
  /// is taken.
  IconData _resolveIconData(dynamic icon) => resolveIconRef(icon);

  /// Extract cacheable context data for widget caching
  Map<String, dynamic>? _extractCacheableContext(RenderContext context) {
    // Extract only relevant state data for caching key generation
    // We exclude non-deterministic data like BuildContext

    // Filter out non-serializable local variables
    final cleanVariables = <String, dynamic>{};
    context.localVariables.forEach((key, value) {
      // Skip internal keys and non-serializable objects
      if (!key.startsWith('_') && _isSerializable(value)) {
        cleanVariables[key] = value;
      }
    });

    return {
      'stateData': context.stateManager.getState(),
      // ThemeManager state full fingerprint — identity of the active
      // `_themeData` map ref + declared mode + host brightness override
      // + resolved effective mode. Captures every token (color slots /
      // typography / shape / spacing / ...) so a cached widget whose
      // baked Color or TextStyle came from a since-superseded theme
      // misses the cache and rebuilds with the current state. Replaces
      // the prior `{mode, primaryColor}` snapshot which only invalidated
      // on two of the 14 token domains and let stale Colors survive a
      // brightness swap (see `text_factory.dart` + theme_manager.dart
      // `getColorValue` — Color is resolved at build time and baked into
      // the Widget's immutable TextStyle, so cache hits return the old
      // colour until invalidated).
      'themeData': {
        'fingerprint': context.themeManager.fingerprint,
      },
      // Include only serializable context variables
      'variables': cleanVariables,
    };
  }

  /// Check if a value is JSON serializable
  bool _isSerializable(dynamic value) {
    if (value == null || value is num || value is String || value is bool) {
      return true;
    }
    if (value is List) {
      return value.every(_isSerializable);
    }
    if (value is Map) {
      return value.values.every(_isSerializable);
    }
    // Exclude Flutter framework objects and other non-serializable types
    return false;
  }

  /// Check if a widget type is cacheable
  bool _isCacheable(Map<String, dynamic> definition, String type) {
    // Don't cache widgets with event handlers or dynamic content
    final properties = definition;

    // Skip caching for widgets with event handlers
    if (_hasEventHandlers(properties)) {
      return false;
    }

    // Skip caching for certain widget types that are typically dynamic
    const nonCacheableTypes = {
      'textField', 'TextField',
      'textFormField', 'TextFormField',
      'form', 'Form',
      'timer', 'Timer',
      'animatedContainer', 'AnimatedContainer',
      'hero', 'Hero',
      'gestureDetector', 'GestureDetector',
      'inkWell', 'InkWell',
      'listener', 'Listener',
      // Additional non-cacheable widgets
      'textInput', 'TextInput',
      'numberField', 'NumberField',
      'dateField', 'DateField',
      'timeField', 'TimeField',
      'colorPicker', 'ColorPicker',
      // Template invocation: each `use` site is an INSTANCE — its expansion
      // must not share a cached widget across calls or sessions, since the
      // expanded subtree's event closures capture the live RenderContext
      // (state manager, action handler) of the active engine.
      'use',
    };

    if (nonCacheableTypes.contains(type)) {
      return false;
    }

    return true;
  }

  /// Check if properties contain event handlers — recurses through `child`
  /// and `children` so that ancestor containers holding event-bound
  /// descendants (e.g., a Row whose children include onTap buttons) are
  /// also flagged non-cacheable. Without recursion, the row would be
  /// cached as a Widget instance whose button children retain stale
  /// onTap closures across runtime sessions.
  bool _hasEventHandlers(Map<String, dynamic> properties) {
    const eventHandlers = {
      // Canonical v1.0 names (on + PascalCase)
      'onTap',
      'onDoubleTap',
      'onLongPress',
      'onChange',
      'onSubmit',
      'onFocus',
      'onBlur',
      'onHover',
      // Legacy aliases (backward compatibility)
      'onPressed',
      'onClick',
      'onDoubleClick',
      'onChanged',
      'onSubmitted',
      'onEditingComplete',
      'onEnter',
      'onExit',
      'click',
      'change',
      'submit',
      'focus',
      'blur',
    };

    if (properties.keys.any((key) => eventHandlers.contains(key))) {
      return true;
    }

    final child = properties['child'];
    if (child is Map<String, dynamic> && _hasEventHandlers(child)) {
      return true;
    }

    final children = properties['children'];
    if (children is List) {
      for (final c in children) {
        if (c is Map<String, dynamic> && _hasEventHandlers(c)) {
          return true;
        }
      }
    }

    return false;
  }

  /// Get widget cache statistics
  Map<String, dynamic> getCacheStatistics() {
    return _widgetCache.getStatistics();
  }

  /// Clear widget cache
  void clearCache() {
    _widgetCache.clear();
  }

  /// Enable or disable widget caching
  void setCacheEnabled(bool enabled) {
    if (enabled) {
      _widgetCache.enable();
    } else {
      _widgetCache.disable();
    }
  }

  /// Reports a widget that could not be built, and paints the reason only in
  /// a debug build. A release build collapses the slot: developer
  /// text does not belong on an end user's screen. Reporting is
  /// unconditional — a logged error and the plugin `onError` hook.
  Widget _errorWidget(
    String message,
    Map<String, dynamic> definition, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    final type = definition['type'];
    _reportFailure(message, type, error: error, stackTrace: stackTrace);
    if (!kDebugMode) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        border: Border.all(color: Colors.red.shade200),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: TextStyle(
                color: Colors.red.shade800, fontWeight: FontWeight.bold),
          ),
          if (definition['type'] != null)
            Text(
              'Type: ${definition['type']}',
              style: TextStyle(color: Colors.red.shade600, fontSize: 12),
            ),
        ],
      ),
    );
  }

  /// The one place the renderer reports a failure: one log record and one
  /// `onError` hook per failure, in every build mode and on every path, so
  /// every renderer report carries the same keys (see [PluginHookType.onError])
  /// and a host that installed only a log sink sees what the hook sees.
  void _reportFailure(
    String message,
    Object? widgetType, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    _logger.error(
      '$message${widgetType == null ? '' : ' (type: $widgetType)'}',
      error,
      stackTrace,
    );
    PluginHookManager.instance.fireHookSync(
      PluginHookType.onError,
      data: {
        'source': 'renderer',
        'message': message,
        'widgetType': widgetType,
      },
    );
  }
}
