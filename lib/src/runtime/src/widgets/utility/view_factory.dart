import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../../models/ui_definition.dart' show LifecycleDefinition;
import '../../runtime/lifecycle_runner.dart';
import '../../state/state_manager.dart';
import '../../utils/mcp_logger.dart';
import '../widget_factory.dart';

/// Resolves a qualified `DefinitionSource` to a UI definition.
///
/// Registered by the host via `MCPUIRuntime.registerDefinitionResolver`. The
/// runtime never learns how a connection is opened or what a `from` origin
/// physically is — establishing outbound connections is a host capability
/// (spec §6.11.1), and this seam is the only thing the runtime needs.
///
/// Returns the parsed definition, or throws to signal that the source could not
/// be resolved (unknown origin, dead connection, missing resource, malformed
/// document). Throwing — never returning null-as-success — is what keeps
/// §7.10.1 rule 6 enforceable: a runtime must fail rather than silently fall
/// back to its own origin.
typedef DefinitionResolver = Future<Map<String, dynamic>> Function(
  String ref,
  Map<String, dynamic> origin,
);

/// `view` — embeds a definition sourced from anywhere, including another MCP
/// origin (spec §2.13.1, Composition Profile).
///
/// The consumer side of composition: §11.9 `dashboard` says how an app presents
/// itself *when embedded*; `view` is how an app *embeds*.
///
/// Four `source` forms are accepted (§1.9.1):
///   * inline definition — a map that is the definition itself
///   * `"ui://…"` — resource on the current origin
///   * `{ "$ref": …, "from": { "connection": … } }` — another origin
///   * `"{{binding}}"` — a definition already held in state
///
/// Resolution failure is LOCAL: the view renders `fallback` and fires
/// `onError`, while siblings and the embedding page keep rendering (§6.11.4).
class ViewFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final rawSource = definition['source'];
    if (rawSource == null) {
      return const SizedBox.shrink();
    }

    // Bindings resolve first: `source` may be `"{{sensors.tempUi}}"`, and a
    // qualified ref's `from.connection` is normally a binding too, since an app
    // stores connection ids in state after opening them in `lifecycle.onInit`.
    final source = context.resolve<dynamic>(rawSource);

    return _ViewWidget(
      // Keyed by what it renders, so a rebuild that produces an equal source
      // keeps the same State — and its already-resolved definition. Without
      // this an embedded application whose route is a uri built a fresh nested
      // view each frame, each one resolving from scratch: the tile flickered
      // between content and spinner and then stayed on the spinner.
      key: ValueKey<String>(_sourceKey(source)),
      source: source,
      props: _asMap(definition['props']),
      fallback: definition['fallback'],
      loading: definition['loading'],
      onError: definition['onError'] as Map<String, dynamic>?,
      themeMode: definition['theme'] as String? ?? 'inherit',
      context: context,
    );
  }

  /// Stable identity for a source: equal sources give equal keys.
  static String _sourceKey(dynamic source) {
    if (source is String) return source;
    try {
      return jsonEncode(source);
    } catch (_) {
      return '$source';
    }
  }

  static Map<String, dynamic>? _asMap(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : null;
}

class _ViewWidget extends StatefulWidget {
  const _ViewWidget({
    super.key,
    required this.source,
    required this.props,
    required this.fallback,
    required this.loading,
    required this.onError,
    required this.themeMode,
    required this.context,
  });

  final dynamic source;
  final Map<String, dynamic>? props;
  final dynamic fallback;
  final dynamic loading;
  final Map<String, dynamic>? onError;
  final String themeMode;
  final RenderContext context;

  @override
  State<_ViewWidget> createState() => _ViewWidgetState();
}

class _ViewWidgetState extends State<_ViewWidget> {
  Map<String, dynamic>? _definition;
  Map<String, dynamic>? _origin;

  static final _log = MCPLogger('ViewFactory');

  /// The embedded definition's scope, held for the life of this mount.
  /// Cleared whenever the source changes, so a different origin never inherits
  /// the previous one's state.
  RenderContext? _scope;
  Object? _error;
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  /// Structural equality for a `DefinitionSource`.
  ///
  /// A source is plain JSON, so encoding it is both correct and cheap at the
  /// size these are; the alternative is a deep-equals helper that has to know
  /// every shape a source can take.
  static bool _sameSource(dynamic a, dynamic b) {
    if (identical(a, b)) return true;
    if (a is String || b is String) return a == b;
    try {
      return jsonEncode(a) == jsonEncode(b);
    } catch (_) {
      return false;
    }
  }

  @override
  void didUpdateWidget(covariant _ViewWidget old) {
    super.didUpdateWidget(old);
    // A changed source means a different origin or resource — remount rather
    // than reuse, since the previous scope belongs to the previous origin
    // (§6.11.4).
    // Compared BY VALUE. A source rebuilt each frame — an embedded application
    // whose route is a uri produces a fresh `{$ref, from}` map every build — is
    // a different object with identical meaning, and identity comparison read
    // that as a changed origin: resolve, render, rebuild, resolve again. On the
    // bench the tile flickered between its content and its spinner and then
    // stuck on the spinner.
    if (!_sameSource(old.source, widget.source)) {
      _definition = null;
      _error = null;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final source = widget.source;

    // Inline definition — nothing to fetch.
    if (source is Map) {
      final map = Map<String, dynamic>.from(source);
      if (!map.containsKey(r'$ref')) {
        setState(() => _definition = map);
        return;
      }
      await _resolveQualified(map);
      return;
    }

    if (source is String) {
      // A local `ui://` uri still needs the host to read it; the same resolver
      // handles it with an absent origin, which the host reads as "mine".
      await _resolveQualified(<String, dynamic>{r'$ref': source});
      return;
    }

    _fail(StateError('view.source must be a definition, a uri, or a binding'));
  }

  Future<void> _resolveQualified(Map<String, dynamic> ref) async {
    final resolver = widget.context.definitionResolver;
    if (resolver == null) {
      // No resolver wired = this runtime does not implement the Composition
      // Profile. §18.7.3 / §1.7.2: reject rather than resolve the ref against
      // our own origin, which would render a different server's UI in place of
      // the requested one.
      _fail(StateError(
          'view: no definition resolver registered — this runtime does not '
          'implement the Composition Profile'));
      return;
    }

    final target = ref[r'$ref'];
    if (target is! String) {
      _fail(StateError(r'view.source.$ref must be a string uri'));
      return;
    }

    final origin = ref['from'];
    if (origin != null && origin is! Map) {
      _fail(StateError('view.source.from must be an Origin object'));
      return;
    }

    setState(() => _resolving = true);
    try {
      final resolved = await resolver(
        target,
        origin == null
            ? const <String, dynamic>{}
            : Map<String, dynamic>.from(origin as Map),
      );
      if (!mounted) return;
      setState(() {
        // A different definition means a different scope: reusing it would let
        // one origin's state show up under another's identity.
        // The outgoing definition releases what it started before the new
        // one mounts — otherwise switching source leaves the old
        // subscription running against a scope nobody reads.
        _disposeDefinitionLifecycle();
        _scope = null;
        _definition = resolved;
        // Held for the embedded scope: rendering the definition is half the
        // job — everything inside it (tool calls, reads, subscriptions) belongs
        // to the origin it came from, not to the app's own server.
        _origin = origin == null
            ? null
            : Map<String, dynamic>.from(origin as Map);
        _resolving = false;
      });
    } catch (e) {
      if (!mounted) return;
      _fail(e);
    }
  }

  void _fail(Object error) {
    setState(() {
      _error = error;
      _resolving = false;
    });
    final onError = widget.onError;
    if (onError == null) return;
    // Fire once, off the build phase.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final eventContext = widget.context.createChildContext(
        variables: <String, dynamic>{
          'event': <String, dynamic>{'error': error.toString()},
        },
      );
      widget.context.actionHandler.execute(onError, eventContext);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      if (widget.fallback != null) {
        try {
          return widget.context.renderer
              .renderWidget(widget.fallback, widget.context);
        } catch (_) {
          // A fallback that itself fails must not escalate into a page-level
          // failure — that is the whole point of per-view containment.
        }
      }
      return const _UnavailableIndicator();
    }

    if (_definition == null || _resolving) {
      if (widget.loading != null) {
        return widget.context.renderer
            .renderWidget(widget.loading, widget.context);
      }
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    // The embedded definition renders in its OWN scope: its own state tree,
    // seeded only by `props` (§7.10.1 rules 1–2). `props` is the single,
    // explicit, one-way channel in — the embedded definition never reads the
    // embedder's state.
    // Created ONCE per mounted view, not per build. The scope owns a fresh
    // StateManager, so rebuilding it discarded everything the embedded
    // definition had put there — a subscription would write the device's value,
    // that write would trigger a rebuild, and the rebuild would throw the value
    // away. The reading rendered its label and never a number, forever.
    final embedded = _scope ??= widget.context.createEmbeddedScope(
      props: widget.props,
      inheritTheme: widget.themeMode != 'own',
    )
      ..origin = _origin;

    final def = _definition!;
    // An embedded application definition renders its initial route; an embedded
    // page or widget renders directly.
    final content = def['type'] == 'application'
        ? _initialRouteContent(def)
        : (def['type'] == 'page' || def['type'] == 'screen')
            ? def['content']
            : def;

    if (content == null) return const _UnavailableIndicator();

    // The embedded definition's own lifecycle runs, once per mount.
    //
    // A definition is the lifecycle-aware entity (§6.8), and mounting one
    // without firing its hooks changes what the document does: a device whose
    // `onReady` subscribes to its own live reading rendered a value that never
    // arrived, and the only way to get it was a control the author had put
    // there as a manual override. `state.initial` is seeded for the same
    // reason — it is what the definition shows before the first push.
    _runDefinitionLifecycle(def, embedded);

    // Rebuilt when the embedded scope's own state changes.
    //
    // A page gets this from its route scope; an embedded subtree had nothing,
    // so its bindings were evaluated once at mount and never again. A device's
    // value would arrive, land in the scope, and never reach the screen — the
    // reading rendered its label and no number while every layer underneath
    // reported success.
    return _EmbeddedStateScope(
      state: embedded.stateManager,
      build: () => widget.context.renderer.renderWidget(content, embedded),
    );
  }

  /// Seeds `state.initial` and runs the embedded definition's lifecycle
  /// (§6.11.2b), through the same [LifecycleRunner] a routed page uses.
  ///
  /// Guarded per mount — the scope is created once, so this is too, and a
  /// rebuild must not re-subscribe.
  void _runDefinitionLifecycle(
      Map<String, dynamic> def, RenderContext scope) {
    if (_runner != null) return;

    final initial = (def['state'] as Map?)?['initial'];
    if (initial is Map) {
      initial.forEach((k, v) => scope.setValue('$k', v));
    }

    // Both placements §1.5.3 allows are read by the parser, so the embedded
    // definition is treated exactly like the same document opened on its own.
    final hooks = LifecycleDefinition.fromDefinition(def);
    for (final w in hooks.aliasWarnings) {
      _log.warning('embedded definition: $w');
    }

    _runner = LifecycleRunner(
      lifecycle: hooks,
      label: 'embedded definition',
      execute: (action) => scope.actionHandler.execute(action, scope),
    );

    // Scheduled as a microtask, not a post-frame callback.
    //
    // A hook must not run during build (it writes state), but waiting for the
    // frame to be painted is later than it needs to be: a subscription that
    // starts a frame late is a value that arrives a frame late, and in a test
    // that settles on the first frame it never arrives at all.
    scheduleMicrotask(() async {
      if (!mounted) return;
      await _runner!.mount();
    });
  }

  /// Releases what the mount started. Without this a tile that scrolled away
  /// or a screen that closed left its subscription running, so the node kept
  /// streaming to a view that no longer exists.
  void _disposeDefinitionLifecycle() {
    final runner = _runner;
    if (runner == null) return;
    _runner = null;
    unawaited(runner.unmount());
  }

  LifecycleRunner? _runner;

  @override
  void dispose() {
    // The view had no dispose at all, which is why an embedded definition
    // could start a subscription and never release it: the tile went away and
    // the node kept streaming to a scope nobody was reading.
    _disposeDefinitionLifecycle();
    super.dispose();
  }

  /// Pulls the page an embedded ApplicationDefinition opens on. An inline route
  /// value renders directly; a uri route value needs another resolver round,
  /// which is deferred to the resolver by handing it back as a nested `view`.
  dynamic _initialRouteContent(Map<String, dynamic> app) {
    final routes = app['routes'];
    if (routes is! Map || routes.isEmpty) return null;
    final initial = app['initialRoute'] as String?;
    final value = (initial != null && routes.containsKey(initial))
        ? routes[initial]
        : routes.values.first;
    if (value is Map && value['type'] != null) {
      return value['content'] ?? value;
    }
    // Route value is a uri (or a qualified ref): re-enter through `view` so the
    // same resolution + containment rules apply one level down.
    //
    // A bare uri carries no origin, so it MUST inherit this view's — the route
    // belongs to the application that declared it, and reading it against the
    // embedder instead means an embedded device app whose routes are uris
    // (rather than inline pages) renders nothing at all. Observed exactly that:
    // one board inlined its page and appeared, the other used a uri route and
    // showed only "Unavailable".
    final source = (value is String && _origin != null)
        ? <String, dynamic>{r'$ref': value, 'from': _origin}
        : value;
    return <String, dynamic>{'type': 'view', 'source': source};
  }
}

class _UnavailableIndicator extends StatelessWidget {
  const _UnavailableIndicator();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      alignment: Alignment.center,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.link_off, size: 16, color: cs.outline),
          const SizedBox(width: 8),
          Text('Unavailable', style: TextStyle(color: cs.outline)),
        ],
      ),
    );
  }
}


/// Rebuilds [build] whenever the embedded scope's state changes.
///
/// Scoped deliberately to the embedded StateManager: the embedder's changes are
/// not this subtree's business (§7.10.1), and listening to both would rebuild
/// every tile whenever any of them moved.
class _EmbeddedStateScope extends StatefulWidget {
  const _EmbeddedStateScope({required this.state, required this.build});

  final StateManager state;
  final Widget Function() build;

  @override
  State<_EmbeddedStateScope> createState() => _EmbeddedStateScopeState();
}

class _EmbeddedStateScopeState extends State<_EmbeddedStateScope> {
  StreamSubscription<dynamic>? _sub;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(_EmbeddedStateScope old) {
    super.didUpdateWidget(old);
    if (!identical(old.state, widget.state)) _listen();
  }

  void _listen() {
    _sub?.cancel();
    _sub = widget.state.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.build();
}
