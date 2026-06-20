/// Client action handler for MCP UI DSL v1.1
///
/// Routes and executes client-side actions with permission checking.
library client_action_handler;

import 'package:flutter/material.dart';

import '../actions/action_result.dart';
import '../renderer/render_context.dart';
import '../core/constants/client_action_types.dart';
import '../permissions/permission_manager.dart';
import '../models/ui_definition.dart';
import 'executors/file_action_executor.dart';
import 'executors/http_action_executor.dart';
import 'executors/storage_action_executor.dart';
import 'executors/system_action_executor.dart';
import 'executors/shell_action_executor.dart';

/// Handles client-side action execution
class ClientActionHandler {
  final PermissionManager _permissionManager;
  final FileActionExecutor _fileExecutor;
  final HttpActionExecutor _httpExecutor;
  final StorageActionExecutor _storageExecutor;
  final SystemActionExecutor _systemExecutor;
  final ShellActionExecutor _shellExecutor;

  /// Create a client action handler with the given permission config
  ClientActionHandler(PermissionsConfig? permissionsConfig)
      : _permissionManager = PermissionManager(permissionsConfig),
        _fileExecutor = FileActionExecutor(),
        _httpExecutor = HttpActionExecutor(),
        _storageExecutor = StorageActionExecutor(),
        _systemExecutor = SystemActionExecutor(),
        _shellExecutor = ShellActionExecutor();

  /// Initialize the handler
  Future<void> init() async {
    await _permissionManager.init();
  }

  /// Check if an action type is a client action
  bool isClientAction(String? actionType) {
    return ClientActionTypes.isClientAction(actionType);
  }

  /// Execute a client action
  Future<ActionResult> execute(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    final type = action['type'] as String?;
    if (type == null) {
      return ActionResult.error('Action type is required');
    }

    if (!isClientAction(type)) {
      return ActionResult.error('Not a client action: $type');
    }

    // CA-14: Handle confirmMessage - show confirmation before sensitive actions
    final confirmMessage = action['confirmMessage'] as String? ??
        (action['params'] as Map<String, dynamic>?)?['confirmMessage'] as String?;
    final requireConfirmation = action['requireConfirmation'] as bool? ?? false;

    if ((confirmMessage != null || requireConfirmation) &&
        context.buildContext != null &&
        context.buildContext!.mounted) {
      final confirmed = await _showConfirmation(
        context.buildContext!,
        confirmMessage ?? 'Are you sure you want to proceed?',
      );
      if (!confirmed) {
        return ActionResult.error('Action cancelled by user', errorCode: 'USER_CANCELLED');
      }
    }

    // Normalize the action shape before permission checks and
    // executor dispatch. Spec §6 wraps parameters under a `params`
    // map (`{type: 'client.httpRequest', params: {url, method, ...}}`)
    // but most executors historically read keys from the top-level
    // action map. Flatten `params` onto the action so both shapes
    // resolve identically — keeps the spec honest without rewriting
    // every executor.
    action = _flattenParams(action);

    // Check permissions
    final buildContext = context.buildContext;
    if (buildContext != null) {
      final permissionResult = await _permissionManager.checkAndPrompt(
        context: buildContext,
        actionType: type,
        params: action,
      );

      if (!permissionResult.allowed) {
        return ActionResult.error(
          permissionResult.reason ?? 'Permission denied',
          errorCode: 'PERMISSION_DENIED',
        );
      }
    }

    // Route to appropriate executor
    switch (type) {
      case ClientActionTypes.selectFile:
        return _fileExecutor.selectFile(action, context);
      case ClientActionTypes.readFile:
        return _fileExecutor.readFile(action, context);
      case ClientActionTypes.writeFile:
        return _fileExecutor.writeFile(action, context);
      case ClientActionTypes.saveFile:
        return _fileExecutor.saveFile(action, context);
      case ClientActionTypes.listFiles:
        return _fileExecutor.listFiles(action, context);
      case ClientActionTypes.httpRequest:
        return _httpExecutor.request(action, context);
      case ClientActionTypes.getSystemInfo:
        return _systemExecutor.getSystemInfo(action, context);
      case ClientActionTypes.exec:
        return _shellExecutor.exec(action, context);
      case ClientActionTypes.clipboard:
        final params = action['params'] as Map<String, dynamic>? ?? {};
        final clipAction = params['action'] as String? ?? 'read';
        if (clipAction == 'write') {
          return _systemExecutor.clipboardWrite(action, context);
        }
        return _systemExecutor.clipboardRead(action, context);
      case ClientActionTypes.notification:
        return _systemExecutor.showNotification(action, context);
      case ClientActionTypes.storageGet:
      case ClientActionTypes.storageSet:
      case ClientActionTypes.storageRemove:
        return _storageExecutor.execute(type, action, context);
      default:
        return Future.value(ActionResult.error('Unknown client action: $type'));
    }
  }

  /// Merge the spec's `params` map onto the action's top level so
  /// executors that read flat keys (e.g. `action['url']`) and those
  /// that read `action['params']['url']` both see the same value.
  /// Explicit top-level keys win over nested duplicates.
  Map<String, dynamic> _flattenParams(Map<String, dynamic> action) {
    final params = action['params'];
    if (params is! Map<String, dynamic>) return action;
    final merged = <String, dynamic>{...params, ...action};
    merged['params'] = params;
    return merged;
  }

  /// Get the permission manager for external configuration
  PermissionManager get permissionManager => _permissionManager;

  /// Show a confirmation dialog before executing a sensitive action
  Future<bool> _showConfirmation(BuildContext context, String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmation Required'),
        content: Text(message),
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
    return result ?? false;
  }
}
