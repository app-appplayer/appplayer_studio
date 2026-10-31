import '../services/navigation_service.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import '../actions/action_handler.dart';
import '../models/ui_definition.dart';
import '../runtime/runtime_engine.dart';
import '../runtime/lifecycle_manager.dart';
import '../runtime/lifecycle_runner.dart';
import '../renderer/render_context.dart';
import 'page_activity_scope.dart';

/// Provides a page-specific state scope for multi-page applications
class PageStateScope extends InheritedNotifier<PageStateNotifier> {
  final PageDefinition pageDefinition;
  final String routePath;
  final RuntimeEngine runtimeEngine;

  PageStateScope({
    super.key,
    required this.pageDefinition,
    required this.routePath,
    required this.runtimeEngine,
    required super.child,
  }) : super(
          notifier: PageStateNotifier(pageDefinition.initialState ?? {}),
        );

  /// Get the page state map
  Map<String, dynamic> get pageState => notifier!.state;

  static PageStateScope? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<PageStateScope>();
  }
}

/// Notifier for page state changes
class PageStateNotifier extends ChangeNotifier {
  final Map<String, dynamic> _state;

  PageStateNotifier(Map<String, dynamic> initialState)
      : _state = Map<String, dynamic>.from(initialState);

  Map<String, dynamic> get state => _state;

  void updateState(String key, dynamic value) {
    _state[key] = value;
    notifyListeners();
  }

  void updateAll(Map<String, dynamic> updates) {
    _state.addAll(updates);
    notifyListeners();
  }
}

/// Widget that renders a single page
class MCPPageWidget extends StatefulWidget {
  final PageDefinition pageDefinition;
  final RuntimeEngine runtimeEngine;

  const MCPPageWidget({
    super.key,
    required this.pageDefinition,
    required this.runtimeEngine,
    this.isActive = true,
  });

  /// Whether this page is the one currently shown.
  ///
  /// A shell that keeps its pages alive (a tab bar, a rail, a bottom bar)
  /// leaves every visited page mounted and shows one of them, so no route
  /// changes and `RouteAware` hears nothing. Flipping this is that shell's
  /// report of the same event `didPushNext` / `didPopNext` reports for a
  /// pushed route — and it is why leaving a tab is `onPause` rather than the
  /// `onUnmount` → `onDestroy` it used to be.
  final bool isActive;

  @override
  State<MCPPageWidget> createState() => _MCPPageWidgetState();

  /// The page that [context] sits in, as an identity token; null outside a
  /// page. Running actions are owned by it and end when it is removed.
  static Object? pageOf(BuildContext context) =>
      context.findAncestorStateOfType<_MCPPageWidgetState>();
}

class _MCPPageWidgetState extends State<MCPPageWidget>
    with RouteAware, AutomaticKeepAliveClientMixin {
  // TabBarView disposes children that scroll out of view. That is right for a
  // list and wrong for a page: a swipe to the next tab and back would rebuild
  // the one behind, re-running `onInit` and everything it fetches. Kept alive,
  // the swipe back is the same instance — which is what makes `onPause` /
  // `onResume` mean anything here.
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // A locale change redraws the page (§12.6): every `{{i18n.*}}` binding
    // in it is resolved again on the rebuild.
    widget.runtimeEngine.i18nManager.addListener(_onLocaleChanged);
    // Defer initialization to avoid setState during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializePage();
    });
  }

  void _onLocaleChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(MCPPageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive == widget.isActive) return;
    _active.value = widget.isActive;
    unawaited(widget.isActive
        ? (_runner?.resume() ?? Future<void>.value())
        : (_runner?.pause() ?? Future<void>.value()));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // `onPause` / `onResume` describe a page that loses focus
    // *without* being destroyed, and a page covered by a pushed route is
    // exactly that: its element stays in the tree, so `dispose` never runs
    // and nothing else reports the change. `RouteAware` is the framework's
    // own answer to that question, so the hooks ride on it rather than on a
    // second mechanism.
    final route = ModalRoute.of(context);
    if (route is ModalRoute<void>) {
      // The runtime's own observer watches the navigator it drew; a host that
      // builds its own navigator around the routes watches with the shared
      // one. An observer only reports routes in the navigator it watches, so
      // subscribing to both never doubles a report.
      widget.runtimeEngine.routeObserver.subscribe(this, route);
      NavigationService.instance.routeObserver.subscribe(this, route);
    }
  }

  /// Another route was pushed over this page — it stays mounted.
  @override
  void didPushNext() {
    _active.value = false;
    unawaited(_runner?.pause() ?? Future<void>.value());
  }

  /// The route above this page was popped — this instance is visible again,
  /// and it is the *same* instance, which is what separates this from the
  /// `onInit` a replaced page gets on its next visit.
  @override
  void didPopNext() {
    _active.value = true;
    unawaited(_runner?.resume() ?? Future<void>.value());
  }

  /// Seeds page state and channels, then runs the page's own lifecycle.
  ///
  /// The routed page used to run `onEnter` and `onMount` and nothing else — so
  /// a page written the documented way (subscribe in `onReady`, release
  /// in `onDestroy`) initialized its state and then sat there, while the very
  /// same document streamed correctly when embedded. Hook order now comes from
  /// [LifecycleRunner], the same one every other mount site uses.
  void _initializePage() {
    // Initialize page state in StateManager only for new values
    if (widget.pageDefinition.initialState != null) {
      // Only set values that don't already exist in global state
      widget.pageDefinition.initialState!.forEach((key, value) {
        if (widget.runtimeEngine.stateManager.get(key) == null) {
          widget.runtimeEngine.stateManager.set(key, value);
        }
      });
    }

    // Register channels declared at page scope.
    // autoDispose channels are torn down in [dispose].
    final channels = widget.pageDefinition.channels;
    if (channels != null && channels.isNotEmpty) {
      widget.runtimeEngine.channelManager.initializeChannels(channels);
    }

    _runner = LifecycleRunner(
      lifecycle: widget.pageDefinition.lifecycleDefinition,
      label: 'page',
      execute: (action, hook) =>
          widget.runtimeEngine.lifecycle.executeLifecycleHooks(
        _eventFor(hook),
        <dynamic>[action],
      ),
    );
    unawaited(_runner!.mount());
  }

  /// The hook's own event, so a listener registered for it actually hears it.
  static LifecycleEvent _eventFor(String hook) {
    switch (hook) {
      case 'onInit':
        return LifecycleEvent.initialize;
      case 'onMount':
        return LifecycleEvent.mount;
      case 'onReady':
        return LifecycleEvent.ready;
      case 'onPause':
        return LifecycleEvent.pause;
      case 'onResume':
        return LifecycleEvent.resume;
      case 'onUnmount':
        return LifecycleEvent.unmount;
      case 'onDestroy':
        return LifecycleEvent.destroy;
    }
    return LifecycleEvent.mount;
  }

  LifecycleRunner? _runner;

  /// Published to the subtree so instance-level `lifecycle` blocks and
  /// embedded views can follow the page they are in.
  final ValueNotifier<bool> _active = ValueNotifier<bool>(true);

  @override
  void dispose() {
    widget.runtimeEngine.i18nManager.removeListener(_onLocaleChanged);
    widget.runtimeEngine.routeObserver.unsubscribe(this);
    NavigationService.instance.routeObserver.unsubscribe(this);
    _active.dispose();
    // The runner fires onUnmount → onDestroy. `onPause` is not part
    // of it: this page is being destroyed, and that hook is defined as
    // losing focus *without* being destroyed. It is not
    // awaited: dispose cannot be async, and a hook that releases a
    // subscription must still be given the chance to run.
    unawaited(_runner?.unmount() ?? Future<void>.value());

    // Dispose auto-dispose channels for this page (P7)
    widget.runtimeEngine.channelManager.disposeAutoChannels();

    // Waits started from this page end with it (§4.15).
    widget.runtimeEngine.actionHandler.cancelInFlightOf(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    // Create render context with BuildContext for state resolution
    final renderContext = RenderContext(
      renderer: widget.runtimeEngine.renderer,
      stateManager: widget.runtimeEngine.stateManager,
      bindingEngine: widget.runtimeEngine.bindingEngine,
      actionHandler: widget.runtimeEngine.actionHandler,
      themeManager: widget.runtimeEngine.themeManager,
      i18nManager: widget.runtimeEngine.i18nManager,
      buildContext: context,
      engine: widget.runtimeEngine,
    );

    final body = widget.runtimeEngine.renderer.renderWidget(
      widget.pageDefinition.content,
      renderContext,
    );

    // Every page gets its own Scaffold so the Flutter pipeline always
    // has a DefaultTextStyle / Material ancestor for the widget tree.
    // Without this, Text widgets draw with `DefaultTextStyle.fallback`
    // (red glyphs with a yellow underline) because a plain MaterialApp
    // does not provide one to its route bodies.
    //
    // The AppBar, however, is suppressed when an outer shell already
    // provides chrome: ApplicationShell wraps each page in its own
    // Scaffold for drawer / tabs / bottomNav apps, and hosts (AppPlayer
    // renderer) add a close-button AppBar outside the runtime. In
    // either case we want the content scaffolding without a duplicate
    // title bar.
    final outerScaffold = Scaffold.maybeOf(context);
    final title = widget.pageDefinition.title;
    final hasTitle = title != null && title.isNotEmpty;
    // A route the app pushed is an inner route: its AppBar `leading` is the
    // automatic back button, and the host close button belongs to the root
    // route only (spec §6.6.1, §4.3.2).
    final isInnerRoute = ModalRoute.of(context)?.canPop ?? false;
    final showExit = !isInnerRoute && NavigationActionExecutor.hasOnExit;
    // Only a titled page gets a bar; the back and close buttons sit in it.
    final showAppBar = outerScaffold == null && hasTitle;
    return PageActivityScope(
      isActive: _active,
      child: Scaffold(
        appBar: !showAppBar
            ? null
            : AppBar(
                title: hasTitle
                    // A title is a string like any other (spec §3.1).
                    ? AnimatedBuilder(
                        animation: widget.runtimeEngine.stateManager,
                        builder: (context, _) =>
                            Text(_resolveTitle(renderContext, title)),
                      )
                    : null,
                actions: showExit
                    ? <Widget>[
                        const IconButton(
                          key: Key('mcp.page.close'),
                          icon: Icon(Icons.close),
                          tooltip: 'Close',
                          onPressed: NavigationActionExecutor.invokeOnExit,
                        ),
                      ]
                    : const <Widget>[],
              ),
        body: body,
      ),
    );
  }
}

/// [title] with its bindings resolved.
String _resolveTitle(RenderContext context, String title) {
  if (!title.contains('{{')) return title;
  return context.resolve<dynamic>(title)?.toString() ?? '';
}

/// Widget that provides page state scope wrapper
class MCPPageScopeWrapper extends StatelessWidget {
  final PageDefinition pageDefinition;
  final String routePath;
  final RuntimeEngine runtimeEngine;
  final Widget child;

  const MCPPageScopeWrapper({
    super.key,
    required this.pageDefinition,
    required this.routePath,
    required this.runtimeEngine,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return PageStateScope(
      pageDefinition: pageDefinition,
      routePath: routePath,
      runtimeEngine: runtimeEngine,
      child: child,
    );
  }
}
