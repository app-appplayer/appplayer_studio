/// Permission manager for MCP UI DSL v1.1
///
/// Orchestrates permission checking, storage, and prompts for client actions.
library permission_manager;

import 'package:flutter/material.dart';

import '../models/ui_definition.dart';
import '../core/constants/client_action_types.dart';
import 'permission_checker.dart';
import 'permission_groups.dart';
import 'permission_storage.dart';
import 'permission_prompt.dart';
import 'trust_level.dart';

/// Manages permissions for client actions
class PermissionManager {
  /// Permission checker for validation
  final PermissionChecker _checker;

  /// Storage for user decisions
  final PermissionStorage _storage;

  /// Trust level manager for hierarchical permission enforcement
  final TrustLevelManager _trustLevelManager = TrustLevelManager();

  /// Permission group manager for grouped permission handling
  final PermissionGroupManager _groupManager = PermissionGroupManager();

  /// Whether permissions are enabled
  bool enabled = true;

  /// The current trust level governing permission access
  TrustLevel get trustLevel => _trustLevelManager.currentLevel;

  /// Set the trust level for this permission manager
  set trustLevel(TrustLevel level) {
    _trustLevelManager.setLevel(level);
  }

  /// When permission requests are presented to the user
  PermissionRequestTiming requestTiming = PermissionRequestTiming.justInTime;

  /// How permission prompts are displayed
  PermissionPromptVariant promptVariant = PermissionPromptVariant.modal;

  /// Access the permission group manager
  PermissionGroupManager get groupManager => _groupManager;

  /// Set of currently granted permission identifiers
  final Set<String> _grantedPermissions = {};

  /// Set of currently granted permission identifiers
  Set<String> get grantedPermissions => Set.unmodifiable(_grantedPermissions);

  /// Grant a permission by identifier
  void grant(String permission) {
    _grantedPermissions.add(_normalizePermissionType(permission));
  }

  /// Create a permission manager with the given configuration
  PermissionManager(PermissionsConfig? config)
      : _checker = PermissionChecker(config),
        _storage = PermissionStorage();

  /// Initialize the permission manager
  Future<void> init() async {
    await _storage.init();
    await _storage.cleanupExpired();
  }

  /// Check if an action is allowed and prompt if needed
  ///
  /// Returns true if the action is allowed, false otherwise.
  Future<PermissionCheckResult> checkAndPrompt({
    required BuildContext context,
    required String actionType,
    required Map<String, dynamic> params,
  }) async {
    // If permissions are disabled, allow everything
    if (!enabled) {
      return PermissionCheckResult.allowed();
    }

    // Enforce trust level before any other checks
    final requiredPermission =
        ClientPermissions.getRequiredPermission(actionType);
    if (requiredPermission != null &&
        !_trustLevelManager.isPermissionAllowed(requiredPermission)) {
      return PermissionCheckResult.denied(
        'Trust level "${trustLevel.name}" insufficient for '
        '"$requiredPermission" (requires '
        '"${_trustLevelManager.getRequiredLevel(requiredPermission).name}")',
      );
    }

    // Check if this is a client action
    if (!ClientActionTypes.isClientAction(actionType)) {
      return PermissionCheckResult.allowed();
    }

    // Check permission against configuration
    final checkResult = _checker.checkAction(actionType, params);

    if (!checkResult.allowed) {
      return PermissionCheckResult.denied(checkResult.reason ?? 'Permission denied');
    }

    // Check for stored decision
    final rawPermissionType = ClientPermissions.getRequiredPermission(actionType);
    final permissionType = rawPermissionType != null
        ? _normalizePermissionType(rawPermissionType)
        : null;
    if (permissionType != null) {
      final scope = _getScope(actionType, params);
      final storedDecision = await _storage.getDecision(permissionType, scope);

      if (storedDecision != null && !_storage.isExpired(storedDecision) &&
          !storedDecision.revoked) {
        if (storedDecision.granted) {
          return PermissionCheckResult.allowed(
            timeout: checkResult.timeout,
          );
        } else {
          return PermissionCheckResult.denied('Permission previously denied');
        }
      }
    }

    // If confirmation is required, prompt the user
    if (checkResult.requiresConfirmation) {
      // ignore: use_build_context_synchronously - Dialog is user-blocking
      final decision = await _promptUser(context, actionType, params);

      if (decision == null) {
        return PermissionCheckResult.denied('Permission prompt cancelled');
      }

      // Store the decision if user chose to remember
      if (decision.remember && permissionType != null) {
        await _storage.storeDecision(
          permissionType,
          decision.scope,
          decision,
        );
      }

      if (!decision.granted) {
        return PermissionCheckResult.denied('Permission denied by user');
      }
    }

    return PermissionCheckResult.allowed(
      timeout: checkResult.timeout,
    );
  }

  /// Check permission without prompting
  PermissionResult checkOnly(String actionType, Map<String, dynamic> params) {
    if (!enabled) {
      return PermissionResult.allowed();
    }

    return _checker.checkAction(actionType, params);
  }

  /// Set the server identifier for per-server permission scoping (PM-08)
  void setServerId(String? serverId) {
    _storage.setServerId(serverId);
  }

  /// Get permission status as a string enum (PM-14)
  /// Returns: 'granted', 'denied', 'pending', 'revoked', 'unavailable'
  Future<String> getPermissionStatus(
    String permissionType, {
    String? scope,
  }) async {
    if (!enabled) return 'granted';

    // Check if the permission type is configured at all
    final checkResult = _checker.checkAction(
      _actionTypeFromPermission(permissionType),
      {},
    );

    if (!checkResult.allowed && checkResult.reason?.contains('not configured') == true) {
      return 'unavailable';
    }

    // Check stored decision
    final storedDecision = await _storage.getDecision(permissionType, scope);
    if (storedDecision == null) return 'pending';

    if (_storage.isExpired(storedDecision)) return 'pending';

    if (storedDecision.revoked) return 'revoked';

    return storedDecision.granted ? 'granted' : 'denied';
  }

  /// Normalize a permission type string to its canonical dot-namespaced form
  ///
  /// Handles common aliases and variations:
  /// - 'fileRead' / 'file-read' -> 'file.read'
  /// - 'fileWrite' / 'file-write' -> 'file.write'
  /// - 'httpRequest' / 'network' / 'http' -> 'network.http'
  /// - 'shellExec' / 'shell-exec' / 'exec' / 'shell' -> 'system.exec'
  /// - 'clipboard' / 'clipboardRead' / 'clipboardWrite' -> 'system.clipboard'
  /// - 'notification' -> 'system.notification'
  /// - 'systemInfo' / 'system-info' -> 'system.info'
  String _normalizePermissionType(String permissionType) {
    switch (permissionType.toLowerCase()) {
      case 'fileread':
      case 'file-read':
      case 'file_read':
      case 'file.read':
        return 'file.read';
      case 'filewrite':
      case 'file-write':
      case 'file_write':
      case 'file.write':
        return 'file.write';
      case 'httprequest':
      case 'http-request':
      case 'http_request':
      case 'network':
      case 'http':
      case 'network.http':
        return 'network.http';
      case 'websocket':
      case 'web-socket':
      case 'web_socket':
      case 'network.websocket':
        return 'network.websocket';
      case 'shellexec':
      case 'shell-exec':
      case 'shell_exec':
      case 'exec':
      case 'shell':
      case 'system.exec':
        return 'system.exec';
      case 'clipboardread':
      case 'clipboardwrite':
      case 'clipboard-read':
      case 'clipboard-write':
      case 'clipboard':
      case 'system.clipboard':
        return 'system.clipboard';
      case 'notification':
      case 'system.notification':
        return 'system.notification';
      case 'systeminfo':
      case 'system-info':
      case 'system_info':
      case 'system.info':
        return 'system.info';
      default:
        return permissionType;
    }
  }

  /// Map permission type back to a representative action type
  String _actionTypeFromPermission(String permissionType) {
    switch (permissionType) {
      case 'file.read':
        return ClientActionTypes.readFile;
      case 'file.write':
        return ClientActionTypes.writeFile;
      case 'network.http':
        return ClientActionTypes.httpRequest;
      case 'system.exec':
        return ClientActionTypes.exec;
      case 'system.clipboard':
        return ClientActionTypes.clipboard;
      case 'system.notification':
        return ClientActionTypes.notification;
      case 'system.info':
        return ClientActionTypes.getSystemInfo;
      default:
        return permissionType;
    }
  }

  /// Revoke a stored permission decision
  ///
  /// Stores a revoked marker so [getPermissionStatus] can distinguish
  /// a revoked permission from one that was never requested.
  Future<void> revokePermission(String permissionType, {String? scope}) async {
    await _storage.storeDecision(
      permissionType,
      scope,
      PermissionDecision.revoke(scope: scope),
    );
  }

  /// Revoke all stored permissions
  ///
  /// Replaces each stored decision with a revoked marker so
  /// [getPermissionStatus] returns 'revoked' instead of 'pending'.
  Future<void> revokeAllPermissions() async {
    final decisions = await _storage.getAllDecisions();
    for (final entry in decisions.entries) {
      final parts = entry.key.split(':');
      final permissionType = parts.first;
      final scope = parts.length > 1 ? parts.sublist(1).join(':') : null;
      await _storage.storeDecision(
        permissionType,
        scope,
        PermissionDecision.revoke(scope: scope),
      );
    }
  }

  /// Get all stored permission decisions
  Future<Map<String, PermissionDecision>> getAllDecisions() async {
    return _storage.getAllDecisions();
  }

  /// Batch request permissions for multiple permission types
  ///
  /// When a [context] is provided, prompts the user for any permissions
  /// that don't have a stored decision. Without [context], falls back
  /// to deny for unknown permissions.
  Future<Map<String, PermissionDecision>> requestAll(
    List<String> permissions, {
    BuildContext? context,
  }) async {
    final results = <String, PermissionDecision>{};

    for (final permission in permissions) {
      final normalized = _normalizePermissionType(permission);
      final storedDecision = await _storage.getDecision(normalized, null);
      if (storedDecision != null && !_storage.isExpired(storedDecision) &&
          !storedDecision.revoked) {
        results[permission] = storedDecision;
      } else if (context != null) {
        // Prompt the user for permission
        // ignore: use_build_context_synchronously - Dialog is user-blocking
        final decision = await PermissionPrompt.show(
          context: context,
          permissionType: normalized,
          title: 'Permission Required',
          description: 'This application requires "$permission" permission.',
        );

        if (decision != null) {
          if (decision.remember) {
            await _storage.storeDecision(normalized, decision.scope, decision);
          }
          results[permission] = decision;
        } else {
          results[permission] = PermissionDecision.deny();
        }
      } else {
        results[permission] = PermissionDecision.deny();
      }
    }

    return results;
  }

  /// Check if a file path is allowed by the permission configuration
  bool isPathAllowed(String path) {
    if (!enabled) return true;

    final readResult = _checker.checkFileRead(path);
    if (readResult.allowed) return true;

    final writeResult = _checker.checkFileWrite(path);
    return writeResult.allowed;
  }

  /// Check if a domain is allowed by the permission configuration
  bool isDomainAllowed(String domain) {
    if (!enabled) return true;

    final url = 'https://$domain/';
    final result = _checker.checkHttp(url);
    return result.allowed;
  }

  /// Check if a command is allowed by the permission configuration
  bool isCommandAllowed(String command) {
    if (!enabled) return true;

    final result = _checker.checkShellExec(command);
    return result.allowed;
  }

  /// Request all required and group permissions upfront (at page load)
  ///
  /// Collects all permissions from registered groups (required groups first),
  /// then batch-requests them via [requestAll]. Intended for use when
  /// [requestTiming] is [PermissionRequestTiming.upfront].
  Future<Map<String, PermissionDecision>> requestPermissionsUpfront({
    BuildContext? context,
  }) async {
    final allPermissions = <String>[];

    // Collect required groups first, then optional
    final requiredGroups =
        _groupManager.groups.where((g) => g.required).toList();
    final optionalGroups =
        _groupManager.groups.where((g) => !g.required).toList();

    for (final group in [...requiredGroups, ...optionalGroups]) {
      allPermissions.addAll(group.permissions);
    }

    if (allPermissions.isEmpty) {
      return {};
    }

    return requestAll(allPermissions, context: context);
  }

  /// Request permissions contextually with an explanation context
  ///
  /// Requests only the permissions relevant to the given [permissionContext]
  /// string, which is matched against group IDs. Intended for use when
  /// [requestTiming] is [PermissionRequestTiming.contextual].
  Future<Map<String, PermissionDecision>> requestPermissionsContextual(
    String permissionContext, {
    BuildContext? context,
  }) async {
    // Find the group matching the context
    final group = _groupManager.getGroup(permissionContext);
    if (group == null) {
      return {};
    }

    return requestAll(group.permissions, context: context);
  }

  /// Custom prompt handler for permission UI
  Function? _promptHandler;

  /// Register a custom prompt handler for permission UI
  void registerPromptHandler(Function handler) {
    _promptHandler = handler;
  }

  // Private helpers

  /// Get the scope for a permission decision
  String? _getScope(String actionType, Map<String, dynamic> params) {
    switch (actionType) {
      case ClientActionTypes.readFile:
      case ClientActionTypes.writeFile:
      case ClientActionTypes.selectFile:
        return params['path'] as String?;

      case ClientActionTypes.httpRequest:
        final url = params['url'] as String?;
        if (url != null) {
          final uri = Uri.tryParse(url);
          return uri?.host;
        }
        return null;

      case ClientActionTypes.exec:
        final command = params['command'] as String?;
        if (command != null) {
          return command.split(RegExp(r'\s+')).first;
        }
        return null;

      default:
        return null;
    }
  }

  /// Prompt the user for permission
  Future<PermissionDecision?> _promptUser(
    BuildContext context,
    String actionType,
    Map<String, dynamic> params,
  ) async {
    // Use custom prompt handler if registered
    if (_promptHandler != null) {
      final result = await Function.apply(
        _promptHandler!,
        [context, actionType, params],
      );
      if (result is PermissionDecision?) {
        return result;
      }
    }

    switch (actionType) {
      case ClientActionTypes.readFile:
      case ClientActionTypes.selectFile:
        return PermissionPrompt.showFileAccess(
          context: context,
          path: params['path'] as String? ?? 'Unknown',
          isWrite: false,
        );

      case ClientActionTypes.writeFile:
        return PermissionPrompt.showFileAccess(
          context: context,
          path: params['path'] as String? ?? 'Unknown',
          isWrite: true,
        );

      case ClientActionTypes.httpRequest:
        return PermissionPrompt.showHttpAccess(
          context: context,
          url: params['url'] as String? ?? 'Unknown',
          method: params['method'] as String?,
        );

      case ClientActionTypes.exec:
        return PermissionPrompt.showShellExec(
          context: context,
          command: params['command'] as String? ?? 'Unknown',
          workingDir: params['workingDir'] as String?,
        );

      default:
        return PermissionPrompt.show(
          context: context,
          permissionType:
              ClientPermissions.getRequiredPermission(actionType) ?? 'unknown',
          title: 'Permission Required',
          description: 'This action requires your permission.',
        );
    }
  }
}

/// Result of a permission check with prompt
class PermissionCheckResult {
  /// Whether the action is allowed
  final bool allowed;

  /// Reason for denial (if not allowed)
  final String? reason;

  /// Timeout for the action (if applicable)
  final int? timeout;

  const PermissionCheckResult._({
    required this.allowed,
    this.reason,
    this.timeout,
  });

  /// Create an allowed result
  factory PermissionCheckResult.allowed({int? timeout}) {
    return PermissionCheckResult._(
      allowed: true,
      timeout: timeout,
    );
  }

  /// Create a denied result
  factory PermissionCheckResult.denied(String reason) {
    return PermissionCheckResult._(
      allowed: false,
      reason: reason,
    );
  }

  @override
  String toString() {
    if (allowed) {
      return 'PermissionCheckResult(allowed)';
    }
    return 'PermissionCheckResult(denied: $reason)';
  }
}
