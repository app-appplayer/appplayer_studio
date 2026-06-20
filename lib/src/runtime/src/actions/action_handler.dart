import 'dart:async' show Future, TimeoutException;
import 'dart:convert' show jsonDecode;
import 'dart:math' show pow;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart' show ActionDefinition;

import '../renderer/render_context.dart';
import '../utils/mcp_logger.dart';
import '../services/dialog_service.dart';
import '../services/navigation_service.dart';
import '../core/constants/client_action_types.dart';
import '../client_actions/client_action_handler.dart';
import '../plugins/plugin_hooks.dart';
import '../channels/channel_manager.dart';
import '../models/ui_definition.dart' show PermissionsConfig;
import '../permissions/permission_manager.dart';
import 'action_result.dart';

/// Handles action execution
class ActionHandler {
  final Map<String, ActionExecutor> _executors = {};
  final Map<String, Function> _toolExecutors = {};
  final MCPLogger _logger = MCPLogger('ActionHandler');

  ActionHandler() {
    _registerDefaultExecutors();
  }

  void _registerDefaultExecutors() {
    final toolExecutor = ToolActionExecutor();
    toolExecutor._toolExecutors =
        _toolExecutors; // Connect the tool executors map
    _executors['tool'] = toolExecutor;
    _executors['navigation'] = NavigationActionExecutor();
    _executors['state'] = StateActionExecutor();
    _executors['resource'] = ResourceActionExecutor();
    _executors['dialog'] = DialogActionExecutor();

    final batchExecutor = BatchActionExecutor();
    batchExecutor._actionHandler = this; // Connect the action handler
    _executors['batch'] = batchExecutor;

    final conditionalExecutor = ConditionalActionExecutor();
    conditionalExecutor._actionHandler = this; // Connect the action handler
    _executors['conditional'] = conditionalExecutor;
    _executors['addRandomWidget'] = TestActionExecutor();
    _executors['deleteRandomWidget'] = TestActionExecutor();
    _executors['shuffleWidgets'] = TestActionExecutor();
    _executors['clearWidgets'] = TestActionExecutor();
    _executors['addHeavyWidget'] = TestActionExecutor();
    _executors['increment'] =
        StateActionExecutor(); // Alias for state increment

    // v1.1 Client action executors
    final clientHandler = ClientActionHandler(null);
    final clientExecutor = ClientActionExecutorWrapper(clientHandler);
    for (final actionType in ClientActionTypes.all) {
      _executors[actionType] = clientExecutor;
    }

    // v1.1 Channel action executors. Canonical dispatch uses the bare
    // subsystem key (`_executors['channel']`); the executor resolves the
    // sub-operation from `action['action']` per spec §4.13. Dotted-flat
    // keys remain registered as legacy aliases for backward compatibility
    // (§17.3.4).
    final channelExecutor = ChannelActionExecutor();
    _executors['channel'] = channelExecutor;
    _executors['channel.start'] = channelExecutor;
    _executors['channel.stop'] = channelExecutor;
    _executors['channel.toggle'] = channelExecutor;
    _executors['channel.restart'] = channelExecutor;
    _executors['channel.send'] = channelExecutor;

    // v1.1 Animation and cancel executors
    _executors['animation'] = AnimationActionExecutor();
    final cancelExecutor = CancelActionExecutor();
    cancelExecutor._actionHandler = this;
    _executors['cancel'] = cancelExecutor;

    // v1.1 Permission revoke executor
    // Permission actions. Canonical `_executors['permission']` resolves
    // the sub-operation from `action['action']`. Flat legacy
    // `permission.revoke` key remains for backward compatibility (§17.3.4).
    final permissionExecutor = PermissionRevokeActionExecutor();
    _executors['permission'] = permissionExecutor;
    _executors['permission.revoke'] = permissionExecutor;

    // v1.1 Parallel/Sequence/Notification executors
    final parallelExecutor = ParallelActionExecutor();
    parallelExecutor._actionHandler = this;
    _executors['parallel'] = parallelExecutor;

    final sequenceExecutor = SequenceActionExecutor();
    sequenceExecutor._actionHandler = this;
    _executors['sequence'] = sequenceExecutor;

    _executors['notification'] = NotificationActionExecutor();

    // v1.1 Event bus executor
    _executors['event'] = EventActionExecutor();
  }

  /// Register a tool executor function
  void registerToolExecutor(String toolName, Function executor) {
    _toolExecutors[toolName] = executor;
  }

  /// Unregister a tool executor function
  void unregisterToolExecutor(String toolName) {
    _toolExecutors.remove(toolName);
  }

  /// Set the channel manager for v1.1 channel actions
  void setChannelManager(ChannelManager manager) {
    final executor = _executors['channel.start'];
    if (executor is ChannelActionExecutor) {
      executor.channelManager = manager;
    }
  }

  /// Set the permissions config for v1.1 client actions
  ///
  /// Replaces the default ClientActionHandler (created with null config)
  /// with one that uses the actual permissions from UIDefinition.
  void setPermissionsConfig(PermissionsConfig? config) {
    if (config == null) return;
    final clientHandler = ClientActionHandler(config);
    final clientExecutor = ClientActionExecutorWrapper(clientHandler);
    for (final actionType in ClientActionTypes.all) {
      _executors[actionType] = clientExecutor;
    }
  }

  /// Gets the current ClientActionHandler's PermissionManager (v1.1)
  PermissionManager? get permissionManager {
    for (final executor in _executors.values) {
      if (executor is ClientActionExecutorWrapper) {
        return executor.permissionManager;
      }
    }
    return null;
  }

  /// Execute an action
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    final type = action['type'] as String?;
    if (type == null) {
      return ActionResult.error('Action type is required');
    }

    // Check for confirmation requirement before executing
    // Only show confirm dialog for client actions (type starts with 'client.')
    final requireConfirmation = action['requireConfirmation'] as bool? ?? false;
    final confirmMessage = action['confirmMessage'] as String?;

    // Skip confirm for non-client action types (state, navigation, dialog, batch,
    // conditional, event, channel, resource)
    final isClientAction = type.startsWith('client.');
    if (isClientAction && (requireConfirmation || confirmMessage != null)) {
      final buildContext = context.buildContext;
      if (buildContext != null && buildContext.mounted) {
        final confirmed = await showDialog<bool>(
          context: buildContext,
          builder: (ctx) => AlertDialog(
            title: const Text('Confirmation Required'),
            content: Text(confirmMessage ?? 'Are you sure you want to proceed?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Confirm'),
              ),
            ],
          ),
        );
        if (confirmed != true) {
          return ActionResult.error('Action cancelled by user');
        }
      }
    }

    final executor = _executors[type];
    if (executor == null) {
      _logger.error(
          'Unknown action type: $type - Available: ${_executors.keys.toList()}');
      return ActionResult.error('Unknown action type: $type');
    }

    try {
      // Pass dependencies to executor if needed
      if (executor is ToolActionExecutor) {
        executor._toolExecutors = _toolExecutors;
      } else if (executor is BatchActionExecutor) {
        executor._actionHandler = this;
      } else if (executor is ConditionalActionExecutor) {
        executor._actionHandler = this;
      }

      _logger.debug(
          'About to execute action with executor: ${executor.runtimeType}');
      final result = await executor.execute(action, context);
      _logger.debug(
          'Executor returned result: ${result.success} - ${result.data}');

      // Handle success/error callbacks per spec §4.4.2: child context exposes
      // the response (or structured error) under the canonical `event` key,
      // making `{{event.<field>}}` resolvable via binding_engine's event.*
      // prefix path.
      //
      // Spec §4.4.2 response shape table:
      //   - Map response   → `event.<key>` per top-level key (event itself = full Map).
      //   - Non-Map (list, scalar, null) → full response exposed as `event.value`;
      //     other `event.*` keys resolve to null.
      if (result.success) {
        final onSuccess = action['onSuccess'] as Map<String, dynamic>?;
        if (onSuccess != null) {
          // Wrap non-Map responses so `{{event.value}}` resolves per spec.
          final eventData = result.data is Map<String, dynamic>
              ? result.data as Map<String, dynamic>
              : <String, dynamic>{'value': result.data};
          final successContext = context.createChildContext(
            variables: {
              'event': eventData,
            },
          );
          await execute(onSuccess, successContext);
        }
      } else {
        final onError = action['onError'] as Map<String, dynamic>?;
        if (onError != null) {
          final errorContext = context.createChildContext(
            variables: {
              'event': {
                'code': result.errorCode,
                'message': result.error ?? 'Unknown error',
                'details': result.errorDetails,
              },
            },
          );
          await execute(onError, errorContext);
        }
      }

      return result;
    } catch (e) {
      // Re-throw validation errors (ArgumentError, Exception with validation messages)
      if (e is ArgumentError ||
          (e is Exception && e.toString().contains('required'))) {
        rethrow;
      }
      // Fire plugin onError hook
      PluginHookManager.instance.fireHookSync(
        PluginHookType.onError,
        data: {'source': 'actionHandler', 'actionType': type, 'error': e.toString()},
      );

      // Catch and wrap other errors (network, tool execution, etc.)
      return ActionResult.error(e.toString());
    }
  }

  /// Register a custom action executor
  void registerExecutor(String type, ActionExecutor executor) {
    _executors[type] = executor;
  }

  /// Alias for [registerExecutor] for design doc compatibility
  void registerHandler(String type, ActionExecutor executor) {
    registerExecutor(type, executor);
  }

  /// Debug: Get registered tool executors
  Map<String, Function> get toolExecutors => Map.from(_toolExecutors);

  /// Execute a strongly-typed ActionDefinition
  /// Converts to JSON internally for backward compatibility with executors.
  Future<ActionResult> executeDefinition(
    ActionDefinition action,
    RenderContext context,
  ) async {
    return execute(action.toJson(), context);
  }

  /// Register navigation handler globally
  void registerNavigationHandler(
      bool Function(String action, String route, Map<String, dynamic> params)
          handler) {
    _logger.info('ActionHandler: Registering navigation handler');
    NavigationActionExecutor.setGlobalNavigationHandler(handler);
    _logger.info('ActionHandler: Navigation handler registered');
  }
}

/// Base class for action executors
abstract class ActionExecutor {
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  );
}

/// Executes tool actions
class ToolActionExecutor extends ActionExecutor {
  final MCPLogger _logger = MCPLogger('ToolActionExecutor');
  Map<String, Function>? _toolExecutors;

  // Deprecation-notice gates: emit once per process per legacy path to
  // alert tool authors / hosts without flooding logs.
  static bool _warnedEnvelopeUnwrap = false;
  static bool _warnedNamespacedMirror = false;

  /// Test-only hook for resetting the deprecation latch so unit tests that
  /// assert the warning fires repeatedly can isolate their state. Not part
  /// of the public API surface.
  @visibleForTesting
  static void resetDeprecationWarningsForTesting() {
    _warnedEnvelopeUnwrap = false;
    _warnedNamespacedMirror = false;
  }

  /// Unwrap the MCP wire shape `{content: [{type: 'text', text: S}], isError}`
  /// into its parsed inner payload. Returns the original [result] unchanged
  /// when it does not match the wire shape.
  ///
  /// MCP servers return `CallToolResult.content` as a list of content items;
  /// most servers emit a single `TextContent` whose `text` is a JSON-encoded
  /// payload. Hosts (e.g. AppPlayer's `ToolDispatcher`) typically strip this
  /// envelope before forwarding to the runtime, but when a host wires
  /// `_onToolCall` to forward the raw `CallToolResult.toJson()` shape, the
  /// runtime must perform the unwrap itself so the downstream §3.10
  /// auto-merge logic sees the actual response body. The `isError` bit is
  /// preserved by mapping a true value to an error ActionResult upstream of
  /// auto-merge.
  ///
  /// Returns either:
  ///   - the parsed inner JSON (typically a Map for spec-compliant tools),
  ///   - the original text string when JSON parsing fails (caller logs warn),
  ///   - the original [result] unchanged when the shape does not match.
  dynamic _maybeUnwrapMcpWire(dynamic result, String toolName) {
    if (result is! Map) return result;
    if (!result.containsKey('content')) return result;
    final content = result['content'];
    if (content is! List || content.isEmpty) return result;
    final first = content.first;
    if (first is! Map) return result;
    if (first['type'] != 'text') return result;
    final text = first['text'];
    if (text is! String) return result;

    try {
      return jsonDecode(text);
    } catch (e) {
      _logger.warning(
          'Tool "$toolName" returned MCP wire shape with non-JSON text payload: $e');
      return text;
    }
  }

  @override
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    final tool = action['tool'] as String?;
    if (tool == null) {
      _logger.error('Tool action error: Tool name is required');
      return ActionResult.error('Tool name is required');
    }

    _logger.debug('Executing tool action: $tool with action: $action');

    // Try to find specific tool executor, fallback to 'default' handler
    final toolExecutor = _toolExecutors?[tool] ?? _toolExecutors?['default'];
    if (toolExecutor == null) {
      _logger.error(
          'Tool executor not found: $tool, available: ${_toolExecutors?.keys}');
      return ActionResult.error('Tool executor not found: $tool');
    }

    _logger.debug('Found tool executor for: $tool');
    _logger.debug('About to extract params from action');

    // Backward compatibility removed: using 'args' will cause an error
    if (action.containsKey('args')) {
      throw ArgumentError(
          'Use "params" instead of deprecated "args" for tool actions');
    }

    Map<String, dynamic> params;
    try {
      // MCP UI DSL v1.0 always uses 'params'
      final rawParams = action['params'];
      if (rawParams == null) {
        params = {};
      } else if (rawParams is Map<String, dynamic>) {
        params = rawParams;
      } else if (rawParams is Map) {
        // Convert Map<dynamic, dynamic> to Map<String, dynamic>
        params = Map<String, dynamic>.from(rawParams);
      } else {
        params = {};
      }
      _logger.debug('Successfully extracted params');
      _logger.debug('Params: $params');
    } catch (e, stack) {
      _logger.error('Error extracting params', e, stack);
      return ActionResult.error('Error extracting params: $e');
    }

    // Resolve parameter values
    final resolvedParams = <String, dynamic>{};
    try {
      params.forEach((key, value) {
        resolvedParams[key] = context.resolve(value);
      });
      _logger.debug('Resolved params: $resolvedParams');
    } catch (e) {
      _logger.error('Error resolving params: $e');
      return ActionResult.error('Error resolving params: $e');
    }

    // Handle loading state - accepts string binding or map with binding+text+indicator
    final loadingRaw = action['loading'];
    String? loadingBinding;
    String? loadingText;
    String? loadingIndicator;
    if (loadingRaw is String) {
      // Simple string binding path
      loadingBinding = loadingRaw;
    } else if (loadingRaw is Map<String, dynamic>) {
      loadingBinding = loadingRaw['binding'] as String?;
      loadingText = loadingRaw['text'] as String?;
      loadingIndicator = loadingRaw['indicator'] as String?;
    }
    if (loadingBinding != null) {
      context.setValue(loadingBinding, true);
      if (loadingText != null) {
        context.setValue('$loadingBinding.text', loadingText);
      }
      if (loadingIndicator != null) {
        context.setValue('$loadingBinding.indicator', loadingIndicator);
      }
    }

    try {
      dynamic result;
      // Default timeout of 30000ms if not specified
      final timeout = action['timeout'] as int? ?? 30000;

      // Create the execution future
      Future<dynamic> executionFuture() async {
        if (_toolExecutors?[tool] == null && _toolExecutors?['default'] != null) {
          _logger.debug(
              'Calling default tool executor with tool=$tool, params=$resolvedParams');
          return await toolExecutor(tool, resolvedParams);
        } else {
          _logger.debug(
              'Calling specific tool executor with params=$resolvedParams');
          return await toolExecutor(resolvedParams);
        }
      }

      // Handle retry strategy
      final retryConfig = action['retry'] as Map<String, dynamic>?;
      final maxAttempts = retryConfig?['maxAttempts'] as int? ?? 1;
      final retryDelay = retryConfig?['delay'] as int? ?? 1000;
      final backoff = retryConfig?['backoff'] as String? ?? 'exponential';
      final multiplier = (retryConfig?['multiplier'] as num?)?.toDouble() ?? 2.0;
      final maxDelay = retryConfig?['maxDelay'] as int?;
      final retryOn = (retryConfig?['retryOn'] as List<dynamic>?)?.cast<String>();

      int attempt = 0;
      dynamic lastError;

      while (attempt < maxAttempts) {
        try {
          // Handle timeout
          if (timeout > 0) {
            result = await executionFuture()
                .timeout(Duration(milliseconds: timeout));
          } else {
            result = await executionFuture();
          }
          lastError = null;
          break;
        } on TimeoutException {
          lastError = 'Tool execution timed out after ${timeout}ms';
          // Execute onTimeout action if defined
          final onTimeout = action['onTimeout'] as Map<String, dynamic>?;
          if (onTimeout != null) {
            await context.actionHandler.execute(onTimeout, context);
          }
          attempt++;
        } catch (e) {
          lastError = e;
          attempt++;

          // Only retry if retryOn is not specified or the error code matches
          if (retryOn != null && retryOn.isNotEmpty) {
            final errorCode = e.toString();
            final shouldRetry = retryOn.any((code) => errorCode.contains(code));
            if (!shouldRetry) {
              break;
            }
          }

          if (attempt < maxAttempts) {
            // Calculate retry delay with backoff
            int currentDelay = retryDelay;
            if (backoff == 'exponential') {
              currentDelay = (retryDelay * pow(multiplier, attempt - 1)).toInt();
            } else if (backoff == 'linear') {
              currentDelay = retryDelay * attempt;
            }
            if (maxDelay != null && currentDelay > maxDelay) {
              currentDelay = maxDelay;
            }
            await Future.delayed(Duration(milliseconds: currentDelay));
          }
        }
      }

      if (lastError != null) {
        if (loadingBinding != null) {
          context.setValue(loadingBinding, false);
          if (loadingText != null) {
            context.setValue('$loadingBinding.text', null);
          }
          if (loadingIndicator != null) {
            context.setValue('$loadingBinding.indicator', null);
          }
        }
        return ActionResult.error(lastError.toString());
      }

      _logger.debug('Tool executor returned: $result');

      // Spec §3.10 / §4.4 — tool response handling.
      //
      // The runtime accepts response shapes in this order of preference:
      //
      //   1. MCP wire shape `{content: [{type: 'text', text: <json>}],
      //      isError: <bool>}` — the raw shape an MCP server returns when a
      //      host forwards `CallToolResult.toJson()` verbatim. The runtime
      //      parses the inner text as JSON, maps `isError: true` to an
      //      ActionResult.error, and treats the parsed body as the response
      //      for the remaining steps. Spec-compliant.
      //
      //   2. Plain Map (canonical, spec §3.10) — top-level keys auto-merge
      //      into page state via `stateManager.mergeState`. Spec-compliant.
      //
      //   3. Envelope `{success: <bool>, result, message?, error?}` — LEGACY,
      //      not in spec. Retained for backward compatibility with hosts /
      //      tool implementations that wrap responses (older AppPlayer
      //      ToolDispatcher fold, vibe self-host wrapping). The inner
      //      `result` is treated as the response body for auto-merge.
      //      DEPRECATED: slated for removal in 0.6.0. Tool authors should
      //      return the response body directly and signal failure via the
      //      MCP wire `isError` flag (CallToolResult.isError).
      //
      // The `tools.<toolName>.result` namespaced mirror written below is
      // also a LEGACY convenience binding outside the spec. DEPRECATED:
      // slated for removal in 0.6.0. Authors should use explicit
      // `bindResult` or rely on auto-merged top-level keys.

      // Step 1: detect and unwrap the MCP wire shape, capturing isError.
      bool? mcpWireIsError;
      if (result is Map && result.containsKey('content')) {
        final unwrapped = _maybeUnwrapMcpWire(result, tool);
        // Only treat as wire shape when the unwrap actually changed something.
        // ignore: identical(unwrapped, result) — intentional reference check
        if (!identical(unwrapped, result)) {
          mcpWireIsError = result['isError'] as bool? ?? false;
          result = unwrapped;
        }
      }

      // Step 2: if wire shape said isError, return error without auto-merge.
      if (mcpWireIsError == true) {
        if (loadingBinding != null) {
          context.setValue(loadingBinding, false);
          if (loadingText != null) {
            context.setValue('$loadingBinding.text', null);
          }
          if (loadingIndicator != null) {
            context.setValue('$loadingBinding.indicator', null);
          }
        }
        // Error message extraction: if the body is a Map with a `message` or
        // `error` field, surface it; otherwise stringify.
        String errMsg;
        if (result is Map) {
          errMsg = (result['message'] ?? result['error'] ?? result).toString();
        } else {
          errMsg = result?.toString() ?? 'Tool execution failed';
        }
        return ActionResult.error(errMsg);
      }

      // Step 3: legacy envelope shape — backward-compatible unwrap.
      if (result is Map<String, dynamic> && result.containsKey('success')) {
        if (!_warnedEnvelopeUnwrap) {
          _warnedEnvelopeUnwrap = true;
          _logger.warning(
              'Tool "$tool" returned legacy envelope shape `{success, result, message}`. '
              'This shape is DEPRECATED and slated for removal in 0.6.0. '
              'Return the response body directly and signal failure via the MCP '
              '`isError` flag (CallToolResult.isError).');
        }
        final isSuccess = result['success'] as bool? ?? false;
        final resultData = result['result'];
        final message = result['message'] as String?;

        // LEGACY mirror: namespaced `tools.<tool>.result`. See deprecation
        // note above. Behavior preserved for one release.
        if (isSuccess) {
          if (!_warnedNamespacedMirror) {
            _warnedNamespacedMirror = true;
            _logger.warning(
                'Writing legacy namespaced mirror at `tools.$tool.result`. '
                'This mirror is DEPRECATED and slated for removal in 0.6.0. '
                'Use explicit `bindResult` or auto-merged top-level keys.');
          }
          context.setValue('tools.$tool.result', resultData);
        }

        // Explicit bindResult overrides auto-merge path
        final bindResult = action['bindResult'] as String?;
        if (bindResult != null) {
          context.setValue(bindResult, resultData);
        } else if (isSuccess && resultData is Map<String, dynamic>) {
          // Spec §3.10: top-level keys of the response auto-merge into
          // page state. For envelope responses the response body is the
          // envelope's inner `result` field.
          context.stateManager.mergeState(resultData);
        }

        if (loadingBinding != null) {
          context.setValue(loadingBinding, false);
          if (loadingText != null) {
            context.setValue('$loadingBinding.text', null);
          }
          if (loadingIndicator != null) {
            context.setValue('$loadingBinding.indicator', null);
          }
        }

        if (isSuccess) {
          return ActionResult.success(data: resultData);
        } else {
          final error =
              result['error'] as String? ?? message ?? 'Tool execution failed';
          return ActionResult.error(error);
        }
      }

      // Step 4: plain canonical response (spec §3.10).
      //
      // LEGACY mirror: namespaced `tools.<tool>.result`. See deprecation
      // note above. Behavior preserved for one release.
      if (!_warnedNamespacedMirror) {
        _warnedNamespacedMirror = true;
        _logger.warning(
            'Writing legacy namespaced mirror at `tools.$tool.result`. '
            'This mirror is DEPRECATED and slated for removal in 0.6.0. '
            'Use explicit `bindResult` or auto-merged top-level keys.');
      }
      context.setValue('tools.$tool.result', result);

      // Explicit bindResult overrides auto-merge path
      final bindResult = action['bindResult'] as String?;
      if (bindResult != null) {
        context.setValue(bindResult, result);
      } else if (result is Map<String, dynamic>) {
        // Spec §3.10: top-level keys auto-merge into page state.
        context.stateManager.mergeState(result);
      } else if (result is Map) {
        // Accept Map<dynamic, dynamic> from JSON decoders that produce a
        // non-typed map (e.g. jsonDecode result). Normalize then merge.
        context.stateManager
            .mergeState(Map<String, dynamic>.from(result));
      }

      if (loadingBinding != null) {
        context.setValue(loadingBinding, false);
        if (loadingText != null) {
          context.setValue('$loadingBinding.text', null);
        }
        if (loadingIndicator != null) {
          context.setValue('$loadingBinding.indicator', null);
        }
      }

      return ActionResult.success(data: result);
    } catch (e) {
      if (loadingBinding != null) {
        context.setValue(loadingBinding, false);
        if (loadingText != null) {
          context.setValue('$loadingBinding.text', null);
        }
        if (loadingIndicator != null) {
          context.setValue('$loadingBinding.indicator', null);
        }
      }
      _logger.error('Tool executor error: $e');
      return ActionResult.error(e.toString());
    }
  }
}

/// Executes navigation actions
///
/// This executor handles navigation actions from UI components like buttons.
/// It supports three levels of navigation handlers:
/// 1. Context-specific handler (highest priority)
/// 2. Renderer-specific handler
/// 3. Global handler (lowest priority, used by ApplicationShell)
///
/// When used with ApplicationShell, the global handler converts route-based
/// navigation to index-based navigation for drawer/tab/bottom navigation.
class NavigationActionExecutor extends ActionExecutor {
  static bool Function(
          String action, String route, Map<String, dynamic> params)?
      _globalNavigationHandler;

  // Get navigator key from NavigationService
  static GlobalKey<NavigatorState> get navigatorKey =>
      NavigationService().navigatorKey;

  /// Sets the global navigation handler
  /// This is typically used by ApplicationShell to handle navigation
  /// from buttons and other UI components
  static void setGlobalNavigationHandler(
      bool Function(String action, String route, Map<String, dynamic> params)?
          handler) {
    MCPLogger('NavigationActionExecutor')
        .info('Setting global navigation handler: ${handler != null}');
    _globalNavigationHandler = handler;
    MCPLogger('NavigationActionExecutor')
        .info('Global handler is now: ${_globalNavigationHandler != null}');
  }

  static void clearGlobalNavigationHandler() {
    _globalNavigationHandler = null;
  }

  static VoidCallback? _onExitCallback;

  /// Registers the host onExit callback for the exitApp action and the
  /// host-inserted close button (spec §2.8.1 / §4.3.2).
  static void setOnExitCallback(VoidCallback callback) {
    _onExitCallback = callback;
  }

  /// Clears any previously registered onExit callback. Primarily used by
  /// tests to isolate state across cases.
  static void clearOnExitCallback() {
    _onExitCallback = null;
  }

  /// Returns true if an onExit callback is registered.
  static bool get hasOnExit => _onExitCallback != null;

  /// Invokes the onExit callback if registered.
  static void invokeOnExit() {
    _onExitCallback?.call();
  }

  /// Host-provided handler for the `openApp` navigation sub-action
  /// (spec §4.3.1). When the runtime is embedded inside a launcher —
  /// e.g. a dashboard slot that lives outside the hosted app's own
  /// `Navigator` — the built-in `Navigator.pushNamedAndRemoveUntil`
  /// cannot reach the launcher's route table. Hosts inject a callback
  /// that performs the actual transition (`context.push('/app/$id')`
  /// in go_router terms). `appId` defaults to the caller-provided
  /// `appId` field; `route` is the DSL-requested initial route.
  static void Function(String? appId, String? route)? _onOpenAppCallback;

  static void setOnOpenAppCallback(
      void Function(String? appId, String? route)? callback) {
    _onOpenAppCallback = callback;
  }

  static void clearOnOpenAppCallback() {
    _onOpenAppCallback = null;
  }

  @override
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    final actionType = action['action'] as String? ?? 'push';
    final route = action['route'] as String?;
    final params = action['params'] as Map<String, dynamic>?;
    final index = action['index'] as int?;

    // Route is only required for push and replace actions
    if (route == null && ['push', 'replace'].contains(actionType)) {
      return ActionResult.error(
          'Route is required for $actionType navigation action');
    }

    // For demo purposes, just log the navigation action
    if (kDebugMode) {
      MCPLogger('NavigationActionExecutor').debug(
          'Navigation action: $actionType to $route with params: $params');
    }

    // Spec §4.3.1 openApp / §4.3.2 exitApp must always be routed to the
    // host callback when one is registered. These actions cross the
    // runtime boundary (dashboard -> full app, app -> launcher) and the
    // host is the only layer that knows how to perform the transition.
    // This check runs before the per-app navigation handler below so that
    // an ApplicationShell handler registered for push/replace cannot
    // reject openApp/exitApp by returning false.
    if (actionType == 'openApp' && _onOpenAppCallback != null) {
      final appId = action['appId'] as String?;
      MCPLogger('NavigationActionExecutor')
          .debug('openApp: delegating to host callback');
      _onOpenAppCallback!(appId, route);
      return ActionResult.success();
    }
    if (actionType == 'exitApp' && _onExitCallback != null) {
      _onExitCallback!.call();
      return ActionResult.success();
    }

    // Then try custom navigation handlers
    var handler = context.navigationHandler;
    MCPLogger('NavigationActionExecutor')
        .debug('Context handler: ${handler != null}');
    if (handler == null && context.renderer.navigationHandler != null) {
      handler = context.renderer.navigationHandler;
      MCPLogger('NavigationActionExecutor')
          .debug('Using renderer handler: ${handler != null}');
    }
    if (handler == null) {
      handler = _globalNavigationHandler;
      MCPLogger('NavigationActionExecutor')
          .debug('Using global handler: ${handler != null}');
    }

    // If custom handler is available, use it
    if (handler != null) {
      final navParams = Map<String, dynamic>.from(params ?? {});
      if (index != null) {
        navParams['index'] = index;
      }
      final handled = handler(actionType, route ?? '', navParams);
      if (!handled) {
        return ActionResult.error('Navigation handler rejected the navigation');
      }
      return ActionResult.success();
    }

    // Otherwise, use the global navigator key for actual navigation
    MCPLogger('NavigationActionExecutor')
        .debug('Getting navigatorKey from NavigationService');
    MCPLogger('NavigationActionExecutor').debug('NavigatorKey: $navigatorKey');
    MCPLogger('NavigationActionExecutor')
        .debug('NavigatorKey hashCode: ${navigatorKey.hashCode}');

    final navigatorState = navigatorKey.currentState;
    MCPLogger('NavigationActionExecutor')
        .debug('Navigator currentState: $navigatorState');

    if (navigatorState == null) {
      MCPLogger('NavigationActionExecutor')
          .debug('Navigator state is null - navigation not possible');
      MCPLogger('NavigationActionExecutor')
          .debug('NavigationService instance: ${NavigationService.instance}');
      MCPLogger('NavigationActionExecutor').debug(
          'NavigationService navigatorKey: ${NavigationService.instance.navigatorKey}');
      MCPLogger('NavigationActionExecutor').debug(
          'NavigationService navigatorKey hashCode: ${NavigationService.instance.navigatorKey.hashCode}');
      return ActionResult.success(); // Return success to avoid breaking the app
    }

    try {
      switch (actionType) {
        case 'push':
          await navigatorState.pushNamed(route!, arguments: params);
          break;
        case 'replace':
          await navigatorState.pushReplacementNamed(route!, arguments: params);
          break;
        case 'pop':
          navigatorState.pop(params);
          break;
        case 'popToRoot':
          navigatorState.popUntil((route) => route.isFirst);
          break;
        case 'pushAndClear':
          // Push new route and remove all previous routes from the stack
          await navigatorState.pushNamedAndRemoveUntil(
            route!,
            (route) => false,
            arguments: params,
          );
          break;
        case 'openApp':
          // Spec §4.3.1 — transition from dashboard rendering mode to full
          // application rendering. When a host callback is registered the
          // launcher handles the transition (e.g. push /app/:id via
          // go_router). Otherwise fall back to the internal Navigator for
          // in-runtime dashboards.
          final appId = action['appId'] as String?;
          if (_onOpenAppCallback != null) {
            MCPLogger('NavigationActionExecutor')
                .debug('openApp: delegating to host callback');
            _onOpenAppCallback!(appId, route);
          } else {
            final appRoute = route ?? '/';
            final appParams = Map<String, dynamic>.from(params ?? {});
            MCPLogger('NavigationActionExecutor')
                .debug('openApp: transitioning to app route: $appRoute');
            await navigatorState.pushNamedAndRemoveUntil(
              appRoute,
              (route) => false,
              arguments: appParams,
            );
          }
          break;
        case 'exitApp':
          if (_onExitCallback != null) {
            _onExitCallback!.call();
          }
          break;
        case 'setIndex': // Index-based navigation for tabs/bottom nav
          // setIndex requires a navigation handler (e.g., ApplicationShell)
          // and an index parameter per spec
          if (index == null) {
            return ActionResult.error(
                'setIndex requires an index parameter');
          }
          return ActionResult.error(
              'setIndex requires a navigation handler (e.g., ApplicationShell)');

        default:
          return ActionResult.error('Unknown navigation action: $actionType');
      }

      MCPLogger('NavigationActionExecutor')
          .debug('Navigation completed: $actionType to $route');
      return ActionResult.success();
    } catch (e) {
      MCPLogger('NavigationActionExecutor').error('Navigation error: $e');
      return ActionResult.error('Navigation failed: $e');
    }
  }
}

/// Executes state actions
///
/// All mutations tag the resulting [StateChangeEvent] with source = `'action'`
/// per spec §3.11 ("User-triggered via a `state` action"). Hosts watching the
/// state change stream can therefore distinguish author-driven mutations
/// from tool-merge / subscription / system updates.
class StateActionExecutor extends ActionExecutor {
  // Spec §3.11 source classification for `state` actions.
  static const String _source = 'action';

  @override
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    final actionType = action['action'] as String? ?? 'set';
    final binding = action['binding'] as String? ?? action['path'] as String?;

    if (binding == null) {
      throw Exception('Binding or path is required for state action');
    }

    try {
      switch (actionType) {
        case 'set':
          final value = context.resolve(action['value']);
          context.setValue(binding, value, source: _source);
          break;

        case 'increment':
          final amount = action['amount'] as num? ?? action['value'] as num? ?? 1;
          final current = context.getValue(binding) as num? ?? 0;
          context.setValue(binding, current + amount, source: _source);
          break;

        case 'decrement':
          final amount = action['amount'] as num? ?? action['value'] as num? ?? 1;
          final current = context.getValue(binding) as num? ?? 0;
          context.setValue(binding, current - amount, source: _source);
          break;

        case 'toggle':
          final current = context.getValue(binding) as bool? ?? false;
          context.setValue(binding, !current, source: _source);
          break;

        case 'append':
        case 'push': // Alias for append (ActionSpecRegistry compatibility)
          final value = context.resolve(action['value']);
          final current = context.getValue(binding) as List? ?? [];
          if (value is List) {
            context.setValue(binding, [...current, ...value], source: _source);
          } else {
            context.setValue(binding, [...current, value], source: _source);
          }
          break;

        case 'pop': // Remove last element from list (ActionSpecRegistry compatibility)
          final currentList = context.getValue(binding) as List?;
          if (currentList != null && currentList.isNotEmpty) {
            final newList = List.from(currentList)..removeLast();
            context.setValue(binding, newList, source: _source);
          }
          break;

        case 'remove':
          // Support both value-based and index-based removal
          final index = context.resolve(action['index']);
          if (index != null) {
            // Index-based removal
            final indexNum =
                index is int ? index : int.tryParse(index.toString());
            if (indexNum != null) {
              final current = context.getValue(binding) as List? ?? [];
              if (indexNum >= 0 && indexNum < current.length) {
                final newList = List.from(current);
                newList.removeAt(indexNum);
                context.setValue(binding, newList, source: _source);
              }
            }
          } else {
            // Value-based removal
            final value = context.resolve(action['value']);
            final current = context.getValue(binding) as List? ?? [];
            final newList = List.from(current);
            final removeIndex = newList.indexOf(value);
            if (removeIndex != -1) {
              newList.removeAt(removeIndex);
            }
            context.setValue(binding, newList, source: _source);
          }
          break;

        case 'removeAt':
          // Support both 'index' and 'value' key names
          final index = (action['index'] ?? action['value']) as int?;
          if (index == null) {
            return ActionResult.error('Index is required for removeAt action');
          }
          final current = context.getValue(binding) as List? ?? [];
          if (index >= 0 && index < current.length) {
            final newList = List.from(current);
            newList.removeAt(index);
            context.setValue(binding, newList, source: _source);
          }
          break;

        default:
          return ActionResult.error('Unknown state action: $actionType');
      }

      return ActionResult.success();
    } catch (e) {
      return ActionResult.error(e.toString());
    }
  }
}

/// Executes resource actions
class ResourceActionExecutor extends ActionExecutor {
  static final _logger = MCPLogger('ResourceActionExecutor');

  @override
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    // Check if this is an HTTP-style resource action
    final method = action['method'] as String?;
    // Use 'binding' as primary key, fall back to 'target' for backward compatibility
    final target = action['binding'] as String? ?? action['target'] as String?;
    final resourceName = action['resource'] as String?;

    if (method != null && target != null) {
      // HTTP-style resource action
      _logger.debug('HTTP-style resource action: $method $target');

      // Call resource handler if available
      if (context.resourceHandler != null) {
        final data = action['data'];
        final result = await context.resourceHandler!(
            resourceName ?? 'default', method, target, data);

        // Bind result if specified
        final bindResult = action['bindResult'] as String?;
        if (bindResult != null) {
          context.setValue(bindResult, result);
        }

        return ActionResult.success(data: result);
      } else {
        return ActionResult.error('No resource handler configured');
      }
    }

    // Otherwise, handle subscription-style resource actions
    final actionType = action['action'] as String?;
    final uri = action['uri'] as String?;

    _logger.debug(
        'ResourceActionExecutor called with action: $actionType, uri: $uri');

    if (actionType == null) {
      return ActionResult.error('Action is required for resource action');
    }

    if (uri == null) {
      return ActionResult.error('URI is required for resource action');
    }

    try {
      switch (actionType) {
        case 'subscribe':
          final binding = action['binding'] as String?;
          if (binding == null) {
            return ActionResult.error(
                'Binding is required for subscribe action');
          }

          // Register the subscription in the runtime engine
          if (context.engine != null) {
            context.engine.registerResourceSubscription(uri, binding);
          }

          // Call the resource subscribe handler. If the host throws (e.g.
          // connection refused, server returned an error), dispatch the
          // author-provided `onSubscriptionError` action per spec §4.5 and
          // bubble the failure up as an ActionResult.error.
          _logger.debug(
              'Checking onResourceSubscribe handler: ${context.onResourceSubscribe != null}');
          if (context.onResourceSubscribe != null) {
            try {
              _logger.debug(
                  'Calling onResourceSubscribe handler for $uri -> $binding');
              await context.onResourceSubscribe!(uri, binding);
              _logger.debug('onResourceSubscribe handler completed');
            } catch (subscribeError, stack) {
              _logger.error(
                  'Resource subscribe failed for $uri', subscribeError, stack);
              // Roll back the registration since the host did not actually
              // start the subscription.
              if (context.engine != null) {
                context.engine.unregisterResourceSubscription(uri);
              }
              final onSubscriptionError =
                  action['onSubscriptionError'] as Map<String, dynamic>?;
              if (onSubscriptionError != null) {
                final errorContext = context.createChildContext(
                  variables: {
                    'event': {
                      'uri': uri,
                      'binding': binding,
                      'message': subscribeError.toString(),
                    },
                  },
                );
                await context.actionHandler
                    .execute(onSubscriptionError, errorContext);
              }
              return ActionResult.error(
                  'Resource subscription failed for $uri: $subscribeError');
            }
          } else {
            _logger.warning('No resource subscribe handler configured');
          }
          break;

        case 'unsubscribe':
          _logger.debug('Processing unsubscribe for URI: $uri');

          // Unregister the subscription in the runtime engine
          if (context.engine != null) {
            context.engine.unregisterResourceSubscription(uri);
          }

          // Call the resource unsubscribe handler
          _logger.debug(
              'Checking onResourceUnsubscribe handler: ${context.onResourceUnsubscribe != null}');
          if (context.onResourceUnsubscribe != null) {
            _logger.debug('Calling onResourceUnsubscribe handler for $uri');
            await context.onResourceUnsubscribe!(uri);
            _logger.debug('onResourceUnsubscribe handler completed');
          } else {
            _logger.warning('No resource unsubscribe handler configured');
          }
          break;

        case 'read': // Spec §4.5: one-shot fetch — store result at binding
          final binding = action['binding'] as String? ?? uri;
          _logger.debug(
              'Processing read (one-shot) for URI: $uri -> binding: $binding');
          // Prefer the dedicated host callback when registered. Falls back
          // to `onResourceSubscribe` for backward compatibility with hosts
          // that have not adopted the separate read callback.
          if (context.onResourceRead != null) {
            await context.onResourceRead!(uri, binding);
          } else if (context.onResourceSubscribe != null) {
            await context.onResourceSubscribe!(uri, binding);
            // Legacy fallback behavior: when read borrows the subscribe
            // callback (which may return a collection), surface the first
            // item so the binding holds a single resource.
            final result = context.getValue(binding);
            if (result is List && result.isNotEmpty) {
              context.setValue(binding, result.first);
            }
          } else {
            _logger.warning('No resource read handler configured');
          }
          break;

        case 'list': // Spec §4.5: directory query — store list at binding
          final binding = action['binding'] as String? ?? uri;
          _logger.debug(
              'Processing list (collection) for URI: $uri -> binding: $binding');
          // Prefer the dedicated host callback when registered. Falls back
          // to `onResourceSubscribe` for backward compatibility.
          if (context.onResourceList != null) {
            await context.onResourceList!(uri, binding);
          } else if (context.onResourceSubscribe != null) {
            await context.onResourceSubscribe!(uri, binding);
            // Legacy fallback behavior: ensure the binding holds a List
            // even when the subscribe callback returned a scalar.
            final result = context.getValue(binding);
            if (result != null && result is! List) {
              context.setValue(binding, [result]);
            }
          } else {
            _logger.warning('No resource list handler configured');
          }
          break;

        default:
          return ActionResult.error('Unknown resource action: $actionType');
      }

      return ActionResult.success();
    } catch (e) {
      return ActionResult.error(e.toString());
    }
  }
}

/// Executes batch actions
class BatchActionExecutor extends ActionExecutor {
  ActionHandler? _actionHandler;

  @override
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    if (_actionHandler == null) {
      return ActionResult.error('Action handler not configured');
    }

    final actions = action['actions'] as List<dynamic>?;
    if (actions == null || actions.isEmpty) {
      return ActionResult.error('Actions list is required for batch');
    }

    final parallel = action['parallel'] as bool? ?? false;
    // Default stopOnError to false for graceful degradation
    final stopOnError = action['stopOnError'] as bool? ?? false;

    try {
      if (parallel) {
        // Execute all actions in parallel
        final futures = actions
            .map((a) =>
                _actionHandler!.execute(a as Map<String, dynamic>, context))
            .toList();

        final results = await Future.wait(futures);

        // Check if any failed
        final failed = results.any((r) => !r.success);
        if (failed && stopOnError) {
          return ActionResult.error('One or more actions failed');
        }
      } else {
        // Execute actions sequentially
        for (final a in actions) {
          final result = await _actionHandler!.execute(
            a as Map<String, dynamic>,
            context,
          );

          if (!result.success && stopOnError) {
            return result;
          }
        }
      }

      return ActionResult.success();
    } catch (e) {
      return ActionResult.error(e.toString());
    }
  }
}

/// Executes conditional actions
class ConditionalActionExecutor extends ActionExecutor {
  ActionHandler? _actionHandler;

  @override
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    if (_actionHandler == null) {
      return ActionResult.error('Action handler not configured');
    }

    final condition = action['condition'] as String?;
    if (condition == null) {
      return ActionResult.error('Condition is required for conditional action');
    }

    try {
      // Evaluate condition
      final conditionResult = context.resolve<bool>(condition);

      if (conditionResult) {
        final thenAction = action['then'] as Map<String, dynamic>?;
        if (thenAction != null) {
          return await _actionHandler!.execute(thenAction, context);
        }
      } else {
        final elseAction = action['else'] as Map<String, dynamic>?;
        if (elseAction != null) {
          return await _actionHandler!.execute(elseAction, context);
        }
      }

      return ActionResult.success();
    } catch (e) {
      return ActionResult.error(e.toString());
    }
  }
}

/// Executes dialog actions
class DialogActionExecutor extends ActionExecutor {
  static final _logger = MCPLogger('DialogActionExecutor');
  static final _dialogService = DialogService();

  @override
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    final dialog = action['dialog'] as Map<String, dynamic>?;

    if (dialog == null) {
      return ActionResult.error('Dialog configuration is required');
    }

    // Canonical type names (spec §2.11) with short-form aliases for
    // backwards compatibility.
    final rawType = dialog['type'] as String? ?? 'alert';
    final dialogType = _canonicalDialogType(rawType);
    final title = context.resolve(dialog['title']) as String?;
    // `content` may be either a string (alertDialog / snackBar) or a widget
    // definition (legacy bottomSheet / customDialog). Widget forms are
    // resolved from `child` first (canonical per §2.11), falling back to a
    // Map-shaped `content` for backwards compatibility.
    final contentRaw = dialog['content'];
    final content = contentRaw is String
        ? context.resolve(contentRaw) as String?
        : null;
    final dismissible = dialog['dismissible'] as bool? ?? true;
    final actions = dialog['actions'] as List<dynamic>?;

    try {
      bool? result;

      switch (dialogType) {
        case 'alert':
          // Convert actions to DialogAction objects. Spec §2.11.1: each entry
          // uses `onTap` as the canonical handler; legacy authors may pass
          // `action` with the same meaning.
          final dialogActions = actions?.map((actionDef) {
            final label = actionDef['label'] as String? ?? '';
            final handler = actionDef['onTap'] ?? actionDef['action'];
            final primary = actionDef['primary'] as bool? ?? false;

            return DialogAction(
              text: label,
              onPressed: () async {
                final navigatorContext =
                    DialogService.navigatorKey.currentContext;
                if (navigatorContext == null) return;

                if (handler == 'close') {
                  Navigator.of(navigatorContext).pop();
                  return;
                }
                if (handler is Map<String, dynamic>) {
                  // Close first, then fire the action, so the page rebuild
                  // happens after the dialog is no longer on top of the
                  // Navigator — avoids rendering the page with the dialog
                  // still partially disposed.
                  Navigator.of(navigatorContext).pop();
                  await context.actionHandler.execute(handler, context);
                  return;
                }
                // No handler provided — just close the dialog.
                Navigator.of(navigatorContext).pop();
              },
              isDefault: primary,
            );
          }).toList();

          await _dialogService.show(
            content: Text(content ?? ''),
            title: title,
            actions: dialogActions,
            barrierDismissible: dismissible,
            type: DialogType.alert,
          );
          result = true;
          break;

        case 'simple':
          final options = dialog['options'] as List<dynamic>?;
          if (options != null && options.isNotEmpty) {
            final onSelect =
                dialog['onSelect'] as Map<String, dynamic>?;
            final simpleActions = options.map((opt) {
              final optMap = opt as Map<String, dynamic>;
              final label = optMap['label']?.toString() ?? '';
              final value = optMap['value'];
              return DialogAction(
                text: label,
                onPressed: () async {
                  final navigatorContext =
                      DialogService.navigatorKey.currentContext;
                  if (navigatorContext == null) return;
                  Navigator.of(navigatorContext).pop();
                  if (onSelect != null) {
                    final eventContext = context.createChildContext(
                      variables: {
                        'event': {'value': value, 'type': 'select'},
                      },
                    );
                    await context.actionHandler
                        .execute(onSelect, eventContext);
                  }
                },
              );
            }).toList();
            await _dialogService.show(
              content: const SizedBox.shrink(),
              title: title,
              actions: simpleActions,
              barrierDismissible: dismissible,
              type: DialogType.alert,
            );
            result = true;
          } else {
            await _dialogService.showAlert(
              message: content ?? '',
              title: title,
            );
            result = true;
          }
          break;

        case 'bottomSheet':
          final childDef = _dialogChild(dialog);
          if (childDef != null) {
            // Spec §2.11.5: `isDismissible` (Flutter-style canonical for
            // bottomSheet); `dismissible` accepted as shared dialog alias.
            final sheetDismissible =
                (dialog['isDismissible'] as bool?) ?? dismissible;
            result = await _dialogService.showBottomSheet<bool>(
              content: context.renderer.renderWidget(childDef, context),
              isDismissible: sheetDismissible,
              enableDrag: dialog['enableDrag'] as bool? ?? true,
              backgroundColor: dialog['backgroundColor'] != null
                  ? _parseColor(dialog['backgroundColor'] as String)
                  : null,
            );
          }
          break;

        case 'custom':
          final childDef = _dialogChild(dialog);
          if (childDef != null) {
            result = await _dialogService.show<bool>(
              content: context.renderer.renderWidget(childDef, context),
              title: title,
              barrierDismissible: dismissible,
              type: DialogType.custom,
            );
          }
          break;

        case 'snackBar':
          final message = contentRaw is String
              ? context.resolve<String?>(contentRaw) ?? ''
              : (dialog['message'] as String? ?? '');
          final duration =
              (dialog['duration'] as num?)?.toInt() ?? 4000;
          final snackAction =
              dialog['action'] as Map<String, dynamic>?;
          final navigatorContext =
              DialogService.navigatorKey.currentContext;
          if (navigatorContext != null) {
            SnackBarAction? uiAction;
            if (snackAction != null) {
              final label = snackAction['label']?.toString() ?? '';
              final tapAction =
                  snackAction['onTap'] as Map<String, dynamic>?;
              uiAction = SnackBarAction(
                label: label,
                onPressed: () {
                  if (tapAction != null) {
                    context.actionHandler.execute(tapAction, context);
                  }
                },
              );
            }
            ScaffoldMessenger.of(navigatorContext).showSnackBar(
              SnackBar(
                content: Text(message),
                duration: Duration(milliseconds: duration),
                action: uiAction,
              ),
            );
          }
          result = true;
          break;

        default:
          return ActionResult.error('Unknown dialog type: $dialogType');
      }

      // Handle onDismiss action if dialog was dismissed
      if (result == null && action['onDismiss'] != null) {
        final onDismiss = action['onDismiss'] as Map<String, dynamic>;
        await context.actionHandler.execute(onDismiss, context);
      }

      return ActionResult.success(data: result);
    } catch (e) {
      _logger.error('Error showing dialog: $e');
      return ActionResult.error(e.toString());
    }
  }

  Color? _parseColor(String colorString) {
    if (colorString.startsWith('#')) {
      return Color(int.parse(colorString.substring(1), radix: 16));
    }
    return null;
  }

  /// Resolves the widget content for `customDialog` / `bottomSheet`.
  /// Canonical key is `child` per spec §2.11; legacy authors may pass a
  /// widget-shaped `content`.
  Map<String, dynamic>? _dialogChild(Map<String, dynamic> dialog) {
    final child = dialog['child'];
    if (child is Map<String, dynamic>) return child;
    final content = dialog['content'];
    if (content is Map<String, dynamic>) return content;
    return null;
  }

  /// Maps canonical dialog widget type names (spec §2.11) to internal
  /// short-form keys used by the switch above.
  String _canonicalDialogType(String raw) {
    switch (raw) {
      case 'alertDialog':
      case 'alert':
        return 'alert';
      case 'simpleDialog':
      case 'simple':
        return 'simple';
      case 'customDialog':
      case 'custom':
        return 'custom';
      case 'bottomSheet':
        return 'bottomSheet';
      case 'snackBar':
        return 'snackBar';
      default:
        return raw;
    }
  }
}

/// Executes test actions for UI testing scenarios
class TestActionExecutor extends ActionExecutor {
  @override
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    // For test purposes, just return success
    // In a real application, these would be actual implementations
    return ActionResult.success();
  }
}

/// Wrapper executor for v1.1 client actions
class ClientActionExecutorWrapper extends ActionExecutor {
  final ClientActionHandler _clientHandler;

  ClientActionExecutorWrapper(this._clientHandler);

  /// Expose the underlying PermissionManager for external access
  PermissionManager get permissionManager => _clientHandler.permissionManager;

  @override
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    return _clientHandler.execute(action, context);
  }
}

/// Executes v1.1 channel actions (start, stop, toggle)
class ChannelActionExecutor extends ActionExecutor {
  static final _logger = MCPLogger('ChannelActionExecutor');

  /// External channel manager reference, set by runtime engine
  ChannelManager? channelManager;

  @override
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    final type = action['type'] as String?;
    final channelName = action['channel'] as String?;

    if (type == null) {
      return ActionResult.error('Channel action type is required');
    }

    // Resolve the sub-operation. Spec §4.13 canonical: bare form
    // `{type: 'channel', action: 'start'}`. §17.3.4 also accepts the
    // dotted legacy `action: 'channel.start'` and the v1.1 flat
    // `type: 'channel.start'` forms — normalized to bare for dispatch.
    String op;
    if (type == 'channel') {
      final sub = action['action'] as String?;
      if (sub == null || sub.isEmpty) {
        return ActionResult.error(
            'Channel action requires an `action` sub-operation');
      }
      op = sub.startsWith('channel.') ? sub.substring('channel.'.length) : sub;
    } else if (type.startsWith('channel.')) {
      // Legacy flat shape: `{type: 'channel.start', ...}`.
      op = type.substring('channel.'.length);
    } else {
      return ActionResult.error('Unknown channel type: $type');
    }

    if (channelName == null || channelName.isEmpty) {
      return ActionResult.error('Channel name is required for channel.$op');
    }

    if (channelManager == null) {
      _logger.warning('No ChannelManager available for channel.$op');
      return ActionResult.error('ChannelManager not configured');
    }

    final manager = channelManager!;

    if (!manager.hasChannel(channelName)) {
      // Graceful degradation: warn and skip instead of error (P2)
      _logger.warning('Channel not found: $channelName - skipping action');
      return ActionResult.success();
    }

    try {
      switch (op) {
        case 'start':
          await manager.startChannel(channelName);
          _logger.debug('Channel started: $channelName');
          return ActionResult.success();

        case 'stop':
          await manager.stopChannel(channelName);
          _logger.debug('Channel stopped: $channelName');
          return ActionResult.success();

        case 'toggle':
          await manager.toggleChannel(channelName);
          _logger.debug('Channel toggled: $channelName');
          return ActionResult.success();

        case 'restart':
          await manager.stopChannel(channelName);
          await manager.startChannel(channelName);
          _logger.debug('Channel restarted: $channelName');
          return ActionResult.success();

        case 'send':
          final data = action['data'];
          _logger.debug('Channel send to $channelName: $data');
          await manager.sendToChannel(channelName, data);
          return ActionResult.success();

        default:
          return ActionResult.error('Unknown channel sub-action: $op');
      }
    } catch (e) {
      _logger.error('Channel action error: $e');
      return ActionResult.error('Channel action failed: $e');
    }
  }
}

/// Executes multiple actions in parallel (v1.1)
class ParallelActionExecutor extends ActionExecutor {
  ActionHandler? _actionHandler;

  @override
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    if (_actionHandler == null) {
      return ActionResult.error('Action handler not configured');
    }

    final actions = action['actions'] as List<dynamic>?;
    if (actions == null || actions.isEmpty) {
      return ActionResult.error('Actions list is required for parallel');
    }

    try {
      final futures = actions
          .map((a) =>
              _actionHandler!.execute(a as Map<String, dynamic>, context))
          .toList();

      final results = await Future.wait(futures);
      final hasError = results.any((r) => !r.success);

      // Execute onAnyError callback if any action errored
      if (hasError) {
        final onAnyError = action['onAnyError'] as Map<String, dynamic>?;
        if (onAnyError != null) {
          await _actionHandler!.execute(onAnyError, context);
        }
      }

      // Execute onAllComplete callback after all parallel actions complete
      final onAllComplete = action['onAllComplete'] as Map<String, dynamic>?;
      if (onAllComplete != null) {
        await _actionHandler!.execute(onAllComplete, context);
      }

      if (hasError) {
        return ActionResult.error('One or more parallel actions failed');
      }

      return ActionResult.success();
    } catch (e) {
      return ActionResult.error(e.toString());
    }
  }
}

/// Executes multiple actions sequentially with ordering guarantees (v1.1)
class SequenceActionExecutor extends ActionExecutor {
  ActionHandler? _actionHandler;

  @override
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    if (_actionHandler == null) {
      return ActionResult.error('Action handler not configured');
    }

    final actions = action['actions'] as List<dynamic>?;
    if (actions == null || actions.isEmpty) {
      return ActionResult.error('Actions list is required for sequence');
    }

    // Default stopOnError to true for sequence (Spec v1.0 L2976)
    final stopOnError = action['stopOnError'] as bool? ?? true;

    try {
      for (final a in actions) {
        final result = await _actionHandler!.execute(
          a as Map<String, dynamic>,
          context,
        );

        if (!result.success && stopOnError) {
          return result;
        }
      }

      // Execute onComplete callback after all sequential actions complete
      final onComplete = action['onComplete'] as Map<String, dynamic>?;
      if (onComplete != null) {
        await _actionHandler!.execute(onComplete, context);
      }

      return ActionResult.success();
    } catch (e) {
      return ActionResult.error(e.toString());
    }
  }
}

/// Executes notification actions (v1.1)
class NotificationActionExecutor extends ActionExecutor {
  @override
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    final message = action['message'] as String?;
    if (message == null || message.isEmpty) {
      return ActionResult.error('Message is required for notification action');
    }

    final severity = action['severity'] as String? ?? 'info';
    final duration = action['duration'] as int? ?? 3000;
    final position = action['position'] as String? ?? 'bottom';
    // Try 'action' key first, then fallback to 'actionButton'
    final actionButton = (action['action'] ?? action['actionButton']) as Map<String, dynamic>?;

    try {
      final buildContext = context.buildContext;
      if (buildContext != null && buildContext.mounted) {
        SnackBarAction? snackBarAction;
        if (actionButton != null) {
          final label = actionButton['label'] as String? ?? 'Action';
          final clickAction = actionButton['click'] as Map<String, dynamic>?;
          snackBarAction = SnackBarAction(
            label: label,
            onPressed: () {
              if (clickAction != null) {
                context.handleAction(clickAction);
              }
            },
          );
        }

        final snackBar = SnackBar(
          content: Text(context.resolve(message) as String? ?? message),
          duration: Duration(milliseconds: duration),
          backgroundColor: _severityColor(severity),
          behavior: position == 'top'
              ? SnackBarBehavior.floating
              : SnackBarBehavior.fixed,
          margin: position == 'top'
              ? EdgeInsets.only(
                  bottom: MediaQuery.of(buildContext).size.height - 150,
                  left: 16,
                  right: 16,
                )
              : null,
          action: snackBarAction,
        );
        ScaffoldMessenger.of(buildContext).showSnackBar(snackBar);
      }
      return ActionResult.success();
    } catch (e) {
      return ActionResult.error(e.toString());
    }
  }

  Color? _severityColor(String severity) {
    switch (severity) {
      case 'success':
        return const Color(0xFF4CAF50);
      case 'warning':
        return const Color(0xFFFF9800);
      case 'error':
        return const Color(0xFFF44336);
      case 'info':
      default:
        return null;
    }
  }
}

/// Executes animation actions (v1.1)
class AnimationActionExecutor extends ActionExecutor {
  static final _logger = MCPLogger('AnimationActionExecutor');

  @override
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    final animAction = action['action'] as String? ?? 'play';
    final target = action['target'] as String?;

    if (target == null || target.isEmpty) {
      return ActionResult.error('Target is required for animation action');
    }

    _logger.debug('Animation action: $animAction on target: $target');

    // Animation actions are resolved at the widget level via animation controllers
    // Store the animation command in state for the target widget to pick up
    context.setValue('_animations.$target.action', animAction);
    if (action['duration'] != null) {
      context.setValue('_animations.$target.duration', action['duration']);
    }
    if (action['curve'] != null) {
      context.setValue('_animations.$target.curve', action['curve']);
    }

    return ActionResult.success();
  }
}

/// Executes cancel actions (v1.1) - cancels a running action by target ID
class CancelActionExecutor extends ActionExecutor {
  static final _logger = MCPLogger('CancelActionExecutor');
  // ignore: unused_field
  ActionHandler? _actionHandler;

  @override
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    final target = action['target'] as String?;

    if (target == null || target.isEmpty) {
      return ActionResult.error('Target is required for cancel action');
    }

    _logger.debug('Cancelling action: $target');

    // Store cancellation signal in state for the target action to check
    context.setValue('_cancellations.$target', true);

    // Execute onCancel callback if provided
    final onCancel = action['onCancel'] as Map<String, dynamic>?;
    if (onCancel != null) {
      try {
        await context.handleAction(onCancel);
      } catch (e) {
        _logger.error('Error executing onCancel callback: $e');
      }
    }

    return ActionResult.success();
  }
}

/// Executes permission revoke actions (v1.1)
class PermissionRevokeActionExecutor extends ActionExecutor {
  static final _logger = MCPLogger('PermissionRevokeActionExecutor');

  @override
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    // Validate the sub-operation. Spec §4.14 canonical:
    // `{type: 'permission', action: 'revoke', permissions: [...]}`.
    // §17.3.4 legacy: `{type: 'permission.revoke', permissions: [...]}`.
    final type = action['type'] as String?;
    final String op;
    if (type == 'permission') {
      final sub = action['action'] as String?;
      if (sub == null || sub.isEmpty) {
        return ActionResult.error(
            'Permission action requires an `action` sub-operation');
      }
      op =
          sub.startsWith('permission.') ? sub.substring('permission.'.length) : sub;
    } else if (type == 'permission.revoke') {
      op = 'revoke';
    } else {
      return ActionResult.error('Unknown permission type: $type');
    }
    if (op != 'revoke') {
      return ActionResult.error('Unknown permission sub-action: $op');
    }

    // Support plural 'permissions' (List) with fallback to singular 'permission'
    final List<String> permissions;
    final rawPermissions = action['permissions'];
    if (rawPermissions is List) {
      permissions = rawPermissions.cast<String>();
    } else {
      final permission = action['permission'] as String?;
      if (permission == null || permission.isEmpty) {
        return ActionResult.error(
            'Permission type is required for revoke action');
      }
      permissions = [permission];
    }

    if (permissions.isEmpty) {
      return ActionResult.error(
          'Permission type is required for revoke action');
    }

    for (final permission in permissions) {
      _logger.debug('Revoking permission: $permission');
      // Update permission state binding
      context.setValue('permissions.$permission.status', 'revoked');
    }

    return ActionResult.success();
  }
}

/// Executes event bus actions (v1.1) - emits events via EventBus
class EventActionExecutor extends ActionExecutor {
  static final _logger = MCPLogger('EventActionExecutor');

  @override
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    final eventAction = action['action'] as String? ?? 'emit';
    final event = action['event'] as String?;

    if (event == null || event.isEmpty) {
      return ActionResult.error('Event name is required for event action');
    }

    if (eventAction == 'emit') {
      final data = action['data'];
      _logger.debug('Emitting event: $event');
      // Store event data in state for listeners to pick up
      context.setValue('_events.$event.data', data);
      context.setValue('_events.$event.timestamp', DateTime.now().toIso8601String());
      return ActionResult.success();
    }

    return ActionResult.error('Unknown event action: $eventAction');
  }
}
