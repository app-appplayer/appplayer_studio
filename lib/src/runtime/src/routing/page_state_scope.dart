import 'dart:async';

import 'package:flutter/material.dart';
import '../actions/action_handler.dart';
import '../models/ui_definition.dart';
import '../runtime/runtime_engine.dart';
import '../runtime/lifecycle_manager.dart';
import '../runtime/lifecycle_runner.dart';
import '../renderer/render_context.dart';
import '../services/navigation_service.dart';
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
    // Defer initialization to avoid setState during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializePage();
    });
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
    // `onPause` / `onResume` (§1.5.1) describe a page that loses focus
    // *without* being destroyed, and a page covered by a pushed route is
    // exactly that: its element stays in the tree, so `dispose` never runs
    // and nothing else reports the change. `RouteAware` is the framework's
    // own answer to that question, so the hooks ride on it rather than on a
    // second mechanism.
    final route = ModalRoute.of(context);
    if (route is ModalRoute<void>) {
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
  /// `onInit` a replaced page gets on its next visit (§6.8.3).
  @override
  void didPopNext() {
    _active.value = true;
    unawaited(_runner?.resume() ?? Future<void>.value());
  }

  /// Seeds page state and channels, then runs the page's own lifecycle.
  ///
  /// The routed page used to run `onEnter` and `onMount` and nothing else — so
  /// a page written the way §6.8.1 shows it (subscribe in `onReady`, release
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

    // Register channels declared at page scope (spec §4.13 +
    // §Channel Lifecycle). autoDispose channels are torn down in [dispose].
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
    NavigationService.instance.routeObserver.unsubscribe(this);
    _active.dispose();
    // The runner fires onUnmount → onDestroy (§6.8.3). `onPause` is not part
    // of it: this page is being destroyed, and §1.5.1 defines that hook as
    // losing focus *without* being destroyed. It is not
    // awaited: dispose cannot be async, and a hook that releases a
    // subscription must still be given the chance to run.
    unawaited(_runner?.unmount() ?? Future<void>.value());

    // Dispose auto-dispose channels for this page (P7)
    widget.runtimeEngine.channelManager.disposeAutoChannels();
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
    final suppressAppBar = outerScaffold != null ||
        title == null ||
        title.isEmpty;
    return PageActivityScope(
      isActive: _active,
      child: Scaffold(
      appBar: suppressAppBar
          ? null
          : AppBar(
              automaticallyImplyLeading: false,
              title: Text(title),
              actions: NavigationActionExecutor.hasOnExit
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
