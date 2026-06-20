import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart' as core show WidgetDefinition, PageDefinition;

import '../runtime/widget_registry.dart';
import '../binding/binding_engine.dart';
import '../actions/action_handler.dart';
import '../state/state_manager.dart';
import '../theme/theme_manager.dart';
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
  final WidgetCache _widgetCache = WidgetCache.instance;
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
  Widget renderWidget(Map<String, dynamic> definition, RenderContext context) {
    final built = _renderWidgetCore(definition, context);
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
      if (kDebugMode) {
        _logger.warning('Widget factory not found for type: $type');
      }
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
      if (kDebugMode) {
        _logger.error('Error rendering widget $type', e, stackTrace);
      }

      // Fire plugin onError hook
      PluginHookManager.instance.fireHookSync(
        PluginHookType.onError,
        data: {'source': 'renderer', 'widgetType': type, 'error': e.toString()},
      );

      return _errorWidget('Error rendering $type: $e', definition);
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
    );
  }

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

  Color? _resolveColor(dynamic color) {
    if (color == null) return null;
    if (color is String) {
      if (color.startsWith('#')) {
        return Color(int.parse(color.substring(1), radix: 16) + 0xFF000000);
      }
      // Handle named colors
      switch (color.toLowerCase()) {
        case 'red':
          return Colors.red;
        case 'blue':
          return Colors.blue;
        case 'green':
          return Colors.green;
        case 'yellow':
          return Colors.yellow;
        case 'orange':
          return Colors.orange;
        case 'purple':
          return Colors.purple;
        case 'pink':
          return Colors.pink;
        case 'grey':
        case 'gray':
          return Colors.grey;
        case 'black':
          return Colors.black;
        case 'white':
          return Colors.white;
        case 'transparent':
          return Colors.transparent;
      }
    } else if (color is int) {
      return Color(color);
    }
    return null;
  }

  IconData _resolveIconData(dynamic icon) {
    if (icon is String) {
      // Map common icon names to Flutter icons
      switch (icon.toLowerCase()) {
        case 'home':
          return Icons.home;
        case 'settings':
          return Icons.settings;
        case 'person':
        case 'profile':
          return Icons.person;
        case 'search':
          return Icons.search;
        case 'menu':
          return Icons.menu;
        case 'close':
          return Icons.close;
        case 'add':
          return Icons.add;
        case 'remove':
          return Icons.remove;
        case 'edit':
          return Icons.edit;
        case 'delete':
          return Icons.delete;
        case 'save':
          return Icons.save;
        case 'share':
          return Icons.share;
        case 'favorite':
          return Icons.favorite;
        case 'star':
          return Icons.star;
        case 'check':
          return Icons.check;
        case 'error':
          return Icons.error;
        case 'warning':
          return Icons.warning;
        case 'info':
          return Icons.info;
        case 'help':
          return Icons.help;
        case 'dashboard':
          return Icons.dashboard;
        case 'notifications':
          return Icons.notifications;
        case 'email':
          return Icons.email;
        case 'phone':
          return Icons.phone;
        case 'calendar':
          return Icons.calendar_today;
        case 'location':
          return Icons.location_on;
        case 'camera':
          return Icons.camera_alt;
        case 'image':
          return Icons.image;
        case 'video':
          return Icons.videocam;
        case 'audio':
          return Icons.audiotrack;
        case 'file':
          return Icons.insert_drive_file;
        case 'folder':
          return Icons.folder;
        case 'download':
          return Icons.download;
        case 'upload':
          return Icons.upload;
        case 'cloud':
          return Icons.cloud;
        case 'link':
          return Icons.link;
        case 'lock':
          return Icons.lock;
        case 'unlock':
          return Icons.lock_open;
        case 'visibility':
          return Icons.visibility;
        case 'visibility_off':
          return Icons.visibility_off;
        case 'refresh':
          return Icons.refresh;
        case 'sync':
          return Icons.sync;
        case 'timer':
          return Icons.timer;
        case 'history':
          return Icons.history;
        case 'language':
          return Icons.language;
        case 'brightness':
          return Icons.brightness_6;
        case 'wifi':
          return Icons.wifi;
        case 'bluetooth':
          return Icons.bluetooth;
        case 'battery':
          return Icons.battery_full;
        case 'signal':
          return Icons.signal_cellular_4_bar;
        case 'gps':
          return Icons.gps_fixed;
        case 'compass':
          return Icons.explore;
        case 'map':
          return Icons.map;
        case 'navigation':
          return Icons.navigation;
        case 'directions':
          return Icons.directions;
        case 'train':
          return Icons.train;
        case 'car':
          return Icons.directions_car;
        case 'bike':
          return Icons.directions_bike;
        case 'walk':
          return Icons.directions_walk;
        case 'flight':
          return Icons.flight;
        case 'hotel':
          return Icons.hotel;
        case 'restaurant':
          return Icons.restaurant;
        case 'cafe':
          return Icons.local_cafe;
        case 'shopping':
          return Icons.shopping_cart;
        case 'gift':
          return Icons.card_giftcard;
        case 'payment':
          return Icons.payment;
        case 'wallet':
          return Icons.account_balance_wallet;
        case 'chart':
          return Icons.insert_chart;
        case 'trending':
          return Icons.trending_up;
        case 'attach':
          return Icons.attach_file;
        case 'send':
          return Icons.send;
        case 'inbox':
          return Icons.inbox;
        case 'archive':
          return Icons.archive;
        case 'reply':
          return Icons.reply;
        case 'forward':
          return Icons.forward;
        case 'undo':
          return Icons.undo;
        case 'redo':
          return Icons.redo;
        case 'copy':
          return Icons.content_copy;
        case 'cut':
          return Icons.content_cut;
        case 'paste':
          return Icons.content_paste;
        case 'select_all':
          return Icons.select_all;
        case 'zoom_in':
          return Icons.zoom_in;
        case 'zoom_out':
          return Icons.zoom_out;
        case 'fullscreen':
          return Icons.fullscreen;
        case 'print':
          return Icons.print;
        case 'book':
          return Icons.book;
        case 'bookmark':
          return Icons.bookmark;
        case 'flag':
          return Icons.flag;
        case 'tag':
          return Icons.label;
        case 'chat':
          return Icons.chat;
        case 'forum':
          return Icons.forum;
        case 'group':
          return Icons.group;
        case 'contacts':
          return Icons.contacts;
        case 'call':
          return Icons.call;
        case 'videocall':
          return Icons.video_call;
        case 'mic':
          return Icons.mic;
        case 'mic_off':
          return Icons.mic_off;
        case 'volume':
          return Icons.volume_up;
        case 'volume_off':
          return Icons.volume_off;
        case 'play':
          return Icons.play_arrow;
        case 'pause':
          return Icons.pause;
        case 'stop':
          return Icons.stop;
        case 'skip_next':
          return Icons.skip_next;
        case 'skip_previous':
          return Icons.skip_previous;
        case 'fast_forward':
          return Icons.fast_forward;
        case 'fast_rewind':
          return Icons.fast_rewind;
        case 'queue_music':
          return Icons.queue_music;
        case 'playlist':
          return Icons.playlist_play;
        case 'shuffle':
          return Icons.shuffle;
        case 'repeat':
          return Icons.repeat;
        case 'games':
          return Icons.games;
        case 'computer':
          return Icons.computer;
        case 'keyboard':
          return Icons.keyboard;
        case 'mouse':
          return Icons.mouse;
        case 'watch':
          return Icons.watch;
        case 'tv':
          return Icons.tv;
        case 'radio':
          return Icons.radio;
        case 'headset':
          return Icons.headset;
        case 'speaker':
          return Icons.speaker;
        case 'router':
          return Icons.router;
        case 'scanner':
          return Icons.scanner;
        case 'printer':
          return Icons.print;
        case 'desktop':
          return Icons.desktop_windows;
        case 'laptop':
          return Icons.laptop;
        case 'tablet':
          return Icons.tablet;
        case 'smartphone':
          return Icons.smartphone;
        case 'sim_card':
          return Icons.sim_card;
        case 'storage':
          return Icons.storage;
        case 'cloud_download':
          return Icons.cloud_download;
        case 'cloud_upload':
          return Icons.cloud_upload;
        case 'cloud_sync':
          return Icons.cloud_sync;
        case 'backup':
          return Icons.backup;
        case 'update':
          return Icons.update;
        case 'extension':
          return Icons.extension;
        case 'puzzle':
          return Icons.extension;
        case 'toys':
          return Icons.toys;
        case 'beach':
          return Icons.beach_access;
        case 'pool':
          return Icons.pool;
        case 'spa':
          return Icons.spa;
        case 'fitness':
          return Icons.fitness_center;
        case 'sports':
          return Icons.sports;
        case 'golf':
          return Icons.golf_course;
        case 'casino':
          return Icons.casino;
        case 'child':
          return Icons.child_care;
        case 'pets':
          return Icons.pets;
        case 'nature':
          return Icons.nature;
        case 'park':
          return Icons.park;
        case 'flower':
          return Icons.local_florist;
        case 'weather':
          return Icons.wb_sunny;
        case 'cloud_weather':
          return Icons.cloud;
        case 'rain':
          return Icons.grain;
        case 'snow':
          return Icons.ac_unit;
        case 'night':
          return Icons.nights_stay;
        case 'weekend':
          return Icons.weekend;
        case 'today':
          return Icons.today;
        case 'event':
          return Icons.event;
        case 'schedule':
          return Icons.schedule;
        case 'alarm':
          return Icons.alarm;
        case 'snooze':
          return Icons.snooze;
        case 'work':
          return Icons.work;
        case 'business':
          return Icons.business;
        case 'store':
          return Icons.store;
        case 'shopping_bag':
          return Icons.shopping_bag;
        case 'school':
          return Icons.school;
        case 'science':
          return Icons.science;
        case 'psychology':
          return Icons.psychology;
        case 'biotech':
          return Icons.biotech;
        case 'medical':
          return Icons.medical_services;
        case 'hospital':
          return Icons.local_hospital;
        case 'pharmacy':
          return Icons.local_pharmacy;
        case 'healing':
          return Icons.healing;
        case 'accessible':
          return Icons.accessible;
        case 'elderly':
          return Icons.elderly;
        case 'pregnant':
          return Icons.pregnant_woman;
        case 'baby':
          return Icons.child_friendly;
        case 'stroller':
          return Icons.stroller;
        case 'wheelchair':
          return Icons.wheelchair_pickup;
        case 'elevator':
          return Icons.elevator;
        case 'escalator':
          return Icons.escalator;
        case 'stairs':
          return Icons.stairs;
        case 'emergency':
          return Icons.emergency;
        case 'fire':
          return Icons.local_fire_department;
        case 'police':
          return Icons.local_police;
        case 'security':
          return Icons.security;
        case 'shield':
          return Icons.shield;
        case 'verified':
          return Icons.verified;
        case 'fingerprint':
          return Icons.fingerprint;
        case 'face':
          return Icons.face;
        case 'mood':
          return Icons.mood;
        case 'sentiment':
          return Icons.sentiment_satisfied;
        case 'emoji':
          return Icons.emoji_emotions;
        case 'celebration':
          return Icons.celebration;
        case 'cake':
          return Icons.cake;
        case 'gift_card':
          return Icons.card_giftcard;
        case 'loyalty':
          return Icons.loyalty;
        case 'discount':
          return Icons.discount;
        case 'qr_code':
          return Icons.qr_code;
        case 'barcode':
          return Icons.barcode_reader;
        case 'receipt':
          return Icons.receipt;
        case 'invoice':
          return Icons.receipt_long;
        case 'account':
          return Icons.account_circle;
        case 'badge':
          return Icons.badge;
        case 'workspace':
          return Icons.workspaces;
        case 'dashboard_customize':
          return Icons.dashboard_customize;
        case 'widgets':
          return Icons.widgets;
        case 'layers':
          return Icons.layers;
        case 'pivot_table':
          return Icons.pivot_table_chart;
        case 'analytics':
          return Icons.analytics;
        case 'insights':
          return Icons.insights;
        case 'data':
          return Icons.data_usage;
        case 'database':
          return Icons.storage;
        case 'dns':
          return Icons.dns;
        case 'vpn':
          return Icons.vpn_key;
        case 'firewall':
          return Icons.security;
        case 'bug':
          return Icons.bug_report;
        case 'code':
          return Icons.code;
        case 'terminal':
          return Icons.terminal;
        case 'developer':
          return Icons.developer_mode;
        case 'api':
          return Icons.api;
        case 'integration':
          return Icons.integration_instructions;
        case 'webhook':
          return Icons.webhook;
        case 'functions':
          return Icons.functions;
        case 'variables':
          return Icons.code;
        case 'class':
          return Icons.class_;
        case 'library':
          return Icons.library_books;
        case 'source':
          return Icons.source;
        case 'git':
          return Icons.account_tree;
        case 'branch':
          return Icons.merge_type;
        case 'merge':
          return Icons.merge;
        case 'pull_request':
          return Icons.compare_arrows;
        case 'commit':
          return Icons.commit;
        case 'diff':
          return Icons.difference;
        case 'fork':
          return Icons.call_split;
        case 'clone':
          return Icons.file_copy;
        case 'deploy':
          return Icons.cloud_upload;
        case 'rollback':
          return Icons.history;
        case 'pipeline':
          return Icons.double_arrow;
        case 'build':
          return Icons.build;
        case 'test':
          return Icons.bug_report;
        case 'release':
          return Icons.new_releases;
        case 'version':
          return Icons.label;
        case 'package':
          return Icons.inventory_2;
        case 'dependencies':
          return Icons.account_tree;
        case 'settings_system':
          return Icons.settings_system_daydream;
        case 'settings_input':
          return Icons.settings_input_composite;
        case 'settings_voice':
          return Icons.settings_voice;
        case 'settings_power':
          return Icons.settings_power;
        case 'settings_bluetooth':
          return Icons.settings_bluetooth;
        case 'settings_brightness':
          return Icons.settings_brightness;
        case 'tune':
          return Icons.tune;
        case 'build_circle':
          return Icons.build_circle;
        case 'eco':
          return Icons.eco;
        case 'energy':
          return Icons.bolt;
        case 'water':
          return Icons.water_drop;
        case 'air':
          return Icons.air;
        case 'terrain':
          return Icons.terrain;
        case 'satellite':
          return Icons.satellite;
        case 'my_location':
          return Icons.my_location;
        case 'near_me':
          return Icons.near_me;
        case 'layers_clear':
          return Icons.layers_clear;
        case 'traffic':
          return Icons.traffic;
        case 'directions_boat':
          return Icons.directions_boat;
        case 'directions_bus':
          return Icons.directions_bus;
        case 'directions_railway':
          return Icons.directions_railway;
        case 'directions_subway':
          return Icons.directions_subway;
        case 'directions_transit':
          return Icons.directions_transit;
        case 'local_taxi':
          return Icons.local_taxi;
        case 'local_shipping':
          return Icons.local_shipping;
        case 'local_airport':
          return Icons.local_airport;
        case 'local_bar':
          return Icons.local_bar;
        case 'local_cafe':
          return Icons.local_cafe;
        case 'local_dining':
          return Icons.local_dining;
        case 'local_drink':
          return Icons.local_drink;
        case 'local_hotel':
          return Icons.local_hotel;
        case 'local_laundry':
          return Icons.local_laundry_service;
        case 'local_library':
          return Icons.local_library;
        case 'local_mall':
          return Icons.local_mall;
        case 'local_movies':
          return Icons.local_movies;
        case 'local_offer':
          return Icons.local_offer;
        case 'local_parking':
          return Icons.local_parking;
        case 'local_pharmacy':
          return Icons.local_pharmacy;
        case 'local_pizza':
          return Icons.local_pizza;
        case 'local_play':
          return Icons.local_play;
        case 'local_post':
          return Icons.local_post_office;
        case 'local_print':
          return Icons.local_printshop;
        case 'local_see':
          return Icons.local_see;
        case 'local_gas':
          return Icons.local_gas_station;
        case 'local_grocery':
          return Icons.local_grocery_store;
        case 'local_activity':
          return Icons.local_activity;
        case 'local_atm':
          return Icons.local_atm;
        case 'local_convenience':
          return Icons.local_convenience_store;
        default:
          return Icons.help_outline; // Fallback icon
      }
    }
    return Icons.help_outline; // Default fallback
  }

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

  Widget _errorWidget(String message, Map<String, dynamic> definition) {
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
}
