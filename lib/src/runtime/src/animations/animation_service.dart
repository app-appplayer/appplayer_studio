import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart'
    show AnimationActionDefinition;

import '../actions/action_result.dart';
import '../utils/mcp_logger.dart';

/// Centralized animation management service for MCP UI Runtime.
///
/// Coordinates animation execution by dispatching [AnimationActionDefinition]
/// commands to registered animation controllers at the widget level.
/// Tracks active animations and supports cancellation by target ID.
class AnimationService {
  final MCPLogger _logger = MCPLogger('AnimationService');

  /// Active animation targets mapped to their current action
  final Map<String, String> _activeAnimations = {};

  /// Callbacks registered by animation widgets to receive commands
  final Map<String, void Function(String action, int? duration, String? curve)>
      _controllers = {};

  /// Execute an animation action definition.
  ///
  /// Dispatches the animation command to the registered controller for
  /// the target widget. If no controller is registered, the command is
  /// stored for later pickup via state.
  Future<ActionResult> execute(AnimationActionDefinition definition) async {
    final target = definition.target;
    final action = definition.action;

    if (target.isEmpty) {
      return ActionResult.error('Target is required for animation action');
    }

    _logger.debug('Executing animation: $action on $target');

    final controller = _controllers[target];
    if (controller != null) {
      controller(action, definition.duration, definition.curve);
      _activeAnimations[target] = action;
      return ActionResult.success(
        data: {'target': target, 'action': action},
      );
    }

    // No controller registered yet — store for widget-level pickup
    _activeAnimations[target] = action;
    _logger.debug('No controller for $target, stored for later pickup');
    return ActionResult.success(
      data: {'target': target, 'action': action, 'deferred': true},
    );
  }

  /// Cancel a running animation by target ID.
  Future<ActionResult> cancel(String target) async {
    final controller = _controllers[target];
    if (controller != null) {
      controller('stop', null, null);
    }
    _activeAnimations.remove(target);
    _logger.debug('Cancelled animation on $target');
    return ActionResult.success();
  }

  /// Register an animation controller for a target widget.
  ///
  /// Called by animation widgets during initialization to receive
  /// animation commands from the service.
  void registerController(
    String target,
    void Function(String action, int? duration, String? curve) controller,
  ) {
    _controllers[target] = controller;

    // If there's a pending animation for this target, dispatch it
    final pending = _activeAnimations[target];
    if (pending != null) {
      controller(pending, null, null);
    }
  }

  /// Unregister an animation controller when the widget is disposed.
  void unregisterController(String target) {
    _controllers.remove(target);
    _activeAnimations.remove(target);
  }

  /// Get the current action for a target (if any).
  String? getActiveAction(String target) => _activeAnimations[target];

  /// Whether a target has an active animation.
  bool isAnimating(String target) => _activeAnimations.containsKey(target);

  /// Dispose all tracked animations.
  void dispose() {
    _controllers.clear();
    _activeAnimations.clear();
  }
}
