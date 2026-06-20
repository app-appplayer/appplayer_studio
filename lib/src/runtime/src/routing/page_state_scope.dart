import 'package:flutter/material.dart';
import '../actions/action_handler.dart';
import '../models/ui_definition.dart';
import '../runtime/runtime_engine.dart';
import '../runtime/lifecycle_manager.dart';
import '../renderer/render_context.dart';

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
  });

  @override
  State<MCPPageWidget> createState() => _MCPPageWidgetState();
}

class _MCPPageWidgetState extends State<MCPPageWidget> {
  @override
  void initState() {
    super.initState();
    // Defer initialization to avoid setState during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializePage();
    });
  }

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

    final lifecycle = widget.pageDefinition.lifecycleDefinition;

    // Execute page onEnter lifecycle (before onMount per spec)
    if (lifecycle?.onEnter != null) {
      widget.runtimeEngine.lifecycle.executeOnEnter(lifecycle!.onEnter!);
    }

    // Execute page onMount lifecycle
    if (lifecycle?.onMount != null) {
      widget.runtimeEngine.lifecycle.executeLifecycleHooks(
        LifecycleEvent.mount,
        lifecycle!.onMount!,
      );
    }
  }

  @override
  void dispose() {
    final lifecycle = widget.pageDefinition.lifecycleDefinition;

    // Execute page onLeave lifecycle (before onUnmount per spec)
    if (lifecycle?.onLeave != null) {
      widget.runtimeEngine.lifecycle.executeOnLeave(lifecycle!.onLeave!);
    }

    // Dispose auto-dispose channels for this page (P7)
    widget.runtimeEngine.channelManager.disposeAutoChannels();

    // Execute page onUnmount lifecycle
    if (lifecycle?.onUnmount != null) {
      widget.runtimeEngine.lifecycle.executeLifecycleHooks(
        LifecycleEvent.unmount,
        lifecycle!.onUnmount!,
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
    return Scaffold(
      appBar: suppressAppBar
          ? null
          : AppBar(
              automaticallyImplyLeading: false,
              title: Text(title),
              actions: NavigationActionExecutor.hasOnExit
                  ? <Widget>[
                      IconButton(
                        key: const Key('mcp.page.close'),
                        icon: const Icon(Icons.close),
                        tooltip: 'Close',
                        onPressed: NavigationActionExecutor.invokeOnExit,
                      ),
                    ]
                  : const <Widget>[],
            ),
      body: body,
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
