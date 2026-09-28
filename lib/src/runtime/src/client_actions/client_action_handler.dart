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
    // `as Map<String, dynamic>?` throws on the map a document actually
    // carries: JSON decoding and Dart literals both produce `Map<dynamic,
    // dynamic>` in places, and the cast turned "no params" into an internal
    // cast error instead of "the path is missing".
    final rawParams = action['params'];
    final paramsMap =
        rawParams is Map ? Map<String, dynamic>.from(rawParams) : null;
    final confirmMessage = action['confirmMessage'] as String? ??
        paramsMap?['confirmMessage'] as String?;
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
    // executor dispatch. The DSL wraps parameters under a `params`
    // map (`{type: 'client.httpRequest', params: {url, method, ...}}`)
    // but most executors historically read keys from the top-level
    // action map. Flatten `params` onto the action so both shapes
    // resolve identically — keeps the spec honest without rewriting
    // every executor.
    action = _flattenParams(action);

    // Check permissions. `_flattenParams` above is synchronous, but the render
    // context this BuildContext came from can be torn down between the action
    // being dispatched and reaching here (a page popped mid-action), so the
    // surface is re-checked before a prompt can be raised on it.
    // An embedded subtree cannot out-permission its embedder:
    // the effective set is the INTERSECTION, never the union. A device's own
    // document is authored by whoever made the device, so a `view` that could
    // prompt for — and receive — a permission the embedding app never held
    // would let any embedded server escalate through the screen it was given.
    //
    // Enforced before the prompt, not after: a user who is asked already had
    // the request put in front of them, and a denial afterwards is a worse
    // experience than never asking.
    if (context.origin != null) {
      final required = ClientPermissions.getRequiredPermission(type);
      if (required != null && !_permissionManager.isGranted(required)) {
        return ActionResult.error(
          'Permission "$required" is not held by the embedding app — an '
          'embedded view cannot request more than its embedder holds',
          errorCode: 'PERMISSION_DENIED',
        );
      }
    }

    final buildContext = context.buildContext;
    if (buildContext != null && buildContext.mounted) {
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
    } else if (_permissionManager.enabled) {
      // No BuildContext means no PROMPT — it does not mean no CHECK. This
      // whole block used to sit inside the `buildContext != null` branch, so
      // every headless path (a dashboard tile, an action fired after the page
      // that raised it was popped, any render with no mounted context) ran
      // `client.exec`, `client.readFile` and `client.httpRequest` with the
      // gate skipped entirely. The tests over this path asserted only that an
      // `ActionResult` came back.
      //
      // Fail closed: what can be decided without asking is decided here, and
      // anything that would need a prompt is refused rather than allowed.
      final required = ClientPermissions.getRequiredPermission(type);
      if (required != null && !_permissionManager.isGranted(required)) {
        final allowedWithoutPrompt = switch (required) {
          ClientPermissions.fileRead || ClientPermissions.fileWrite =>
            _permissionManager.isPathAllowed(
                (action['path'] ?? action['directory'] ?? '') as String? ?? ''),
          ClientPermissions.http => _permissionManager
              .isDomainAllowed(Uri.tryParse(action['url'] as String? ?? '')?.host ?? ''),
          ClientPermissions.shell => _permissionManager
              .isCommandAllowed((action['command'] as String? ?? '').split(' ').first),
          _ => false,
        };
        if (!allowedWithoutPrompt) {
          return ActionResult.error(
            'Permission "$required" is not granted, and there is no surface to '
            'ask on: a client action cannot be performed unprompted',
            errorCode: 'PERMISSION_DENIED',
          );
        }
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
        final rawInner = action['params'];
        final params = rawInner is Map
            ? Map<String, dynamic>.from(rawInner)
            : <String, dynamic>{};
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
    final raw = action['params'];
    if (raw is! Map) return action;
    // Same reason as above: accept any map shape, then normalise. A document
    // whose params arrived through JSON is not a different document.
    final params = Map<String, dynamic>.from(raw);
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
