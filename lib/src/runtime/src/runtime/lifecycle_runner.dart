import '../models/ui_definition.dart' show LifecycleDefinition;
import '../utils/mcp_logger.dart';

/// Runs a definition's lifecycle hooks in the order the spec fixes (§1.5.2,
/// §6.8.3), for every place a definition can be mounted.
///
/// One runner, because the alternative is what this replaces: an application,
/// a routed page and an embedded `view` each executed a different subset of
/// the seven hooks, so the same document behaved differently depending on
/// where it was shown, and a page that subscribed in `onReady` streamed when
/// embedded and sat dead when opened on its own. A mount site now says only
/// *when* it mounted; which hooks run, and in what order, is decided here.
///
/// ```
/// mount:    onInit → onMount → onReady
/// unmount:  onPause → onUnmount → onDestroy
/// ```
///
/// Hooks are awaited in order — §6.8.3 requires `onInit` to complete before
/// `onReady` begins, and `onDestroy` to complete before the runtime releases
/// page-scoped resources. A failing hook is logged and the rest still run
/// (§6.8.3); one bad hook must not strand a subscription or leave a view
/// half-built.
class LifecycleRunner {
  LifecycleRunner({
    required this.lifecycle,
    required this.execute,
    this.label = 'definition',
    MCPLogger? logger,
  }) : _logger = logger ?? MCPLogger('LifecycleRunner');

  final LifecycleDefinition? lifecycle;

  /// Runs one action. The caller supplies it so the runner stays free of any
  /// particular scope, render context or action handler.
  final Future<void> Function(Map<String, dynamic> action) execute;

  /// Used in log lines to say which definition a failing hook belongs to.
  final String label;

  final MCPLogger _logger;

  bool _mounted = false;
  bool _unmounted = false;

  /// `onInit` → `onMount` → `onReady`. Idempotent: a rebuild must not
  /// re-subscribe, so a second call is a no-op.
  Future<void> mount() async {
    if (_mounted) return;
    _mounted = true;
    await _run('onInit', lifecycle?.onInit);
    await _run('onMount', lifecycle?.onMount);
    await _run('onReady', lifecycle?.onReady);
  }

  /// `onPause` → `onUnmount` → `onDestroy` (§6.8.3). Idempotent, and a no-op
  /// when the definition never mounted — releasing what was never started
  /// would unsubscribe a resource this definition does not hold.
  Future<void> unmount() async {
    if (!_mounted || _unmounted) return;
    _unmounted = true;
    await _run('onPause', lifecycle?.onPause);
    await _run('onUnmount', lifecycle?.onUnmount);
    await _run('onDestroy', lifecycle?.onDestroy);
  }

  /// Focus lost without teardown — the definition stays mounted.
  Future<void> pause() => _run('onPause', lifecycle?.onPause);

  /// Focus regained after [pause].
  Future<void> resume() => _run('onResume', lifecycle?.onResume);

  Future<void> _run(String name, List<Map<String, dynamic>>? actions) async {
    if (actions == null || actions.isEmpty) return;
    for (final action in actions) {
      try {
        await execute(action);
      } catch (e) {
        _logger.warning('$label $name failed: $e');
      }
    }
  }
}
