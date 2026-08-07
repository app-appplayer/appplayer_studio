import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../models/ui_definition.dart' show LifecycleDefinition;
import '../renderer/render_context.dart';
import '../routing/page_activity_scope.dart';
import '../runtime/lifecycle_runner.dart';

/// Runs the **instance-level** lifecycle of a widget (§6.8.2) — the hooks a
/// widget declares inside its own `lifecycle: {}` object.
///
/// ```json
/// { "type": "box", "lifecycle": { "onMount": {...}, "onUnmount": {...} },
///   "child": {...} }
/// ```
///
/// Nothing read that block before: a widget could declare hooks and the
/// runtime would render the widget and drop them, with no error and no log.
/// Template instances use the same wrapper (§9.9.1 — a template's own
/// `onMount`/`onUnmount` fire once per instance), so both share this host.
///
/// Wrapping is skipped entirely when a definition declares no hooks, so the
/// widget tree is unchanged for the overwhelming majority of widgets.
class LifecycleHost extends StatefulWidget {
  const LifecycleHost({
    super.key,
    required this.hooks,
    required this.context,
    required this.child,
    this.label = 'widget',
  });

  final LifecycleDefinition hooks;
  final RenderContext context;
  final Widget child;
  final String label;

  /// Wraps [child] only when [definition] actually declares hooks.
  static Widget maybeWrap({
    required Map<String, dynamic> definition,
    required RenderContext context,
    required Widget child,
    String label = 'widget',
  }) {
    final raw = definition['lifecycle'];
    if (raw is! Map || raw.isEmpty) return child;
    final hooks = LifecycleDefinition.fromDefinition(
        <String, dynamic>{'lifecycle': Map<String, dynamic>.from(raw)});
    if (hooks.isEmpty) return child;
    return LifecycleHost(
      hooks: hooks,
      context: context,
      label: label,
      child: child,
    );
  }

  @override
  State<LifecycleHost> createState() => _LifecycleHostState();
}

class _LifecycleHostState extends State<LifecycleHost> {
  late final LifecycleRunner _runner = LifecycleRunner(
    lifecycle: widget.hooks,
    label: widget.label,
    execute: (action, hook) => widget.context.actionHandler.execute(
      action,
      widget.context,
    ),
  );

  @override
  void initState() {
    super.initState();
    // After the first frame: a hook that writes state must not do so during
    // build.
    scheduleMicrotask(() {
      if (mounted) unawaited(_runner.mount());
    });
  }

  ValueListenable<bool>? _pageActive;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Follow the page. A paused page stays mounted, so a widget that started
    // a timer or a subscription in `onMount` would otherwise keep running
    // while nobody is looking at it — and would never hear the `onResume`
    // that its own `lifecycle` block declares.
    final active = PageActivityScope.of(context);
    if (identical(active, _pageActive)) return;
    _pageActive?.removeListener(_onPageActivityChanged);
    _pageActive = active?..addListener(_onPageActivityChanged);
  }

  void _onPageActivityChanged() {
    final active = _pageActive?.value ?? true;
    unawaited(active ? _runner.resume() : _runner.pause());
  }

  @override
  void dispose() {
    _pageActive?.removeListener(_onPageActivityChanged);
    // §18 makes running `onUnmount` a MUST for template instances, and a
    // widget that acquired something on mount has no other place to release it.
    unawaited(_runner.unmount());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
