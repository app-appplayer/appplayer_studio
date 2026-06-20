/// Permission validation for MCP UI DSL v1.1 client actions
///
/// Validates paths, domains, and commands against allowlists
/// to ensure secure client action execution.
library permission_checker;

import 'package:path/path.dart' as p;

import '../models/ui_definition.dart';
import '../core/constants/client_action_types.dart';

/// Validates permissions for client actions
class PermissionChecker {
  final PermissionsConfig? _config;

  PermissionChecker(this._config);

  /// Check if a file read operation is allowed
  PermissionResult checkFileRead(String path) {
    if (_config?.fileRead == null) {
      return PermissionResult.denied('File read permission not configured');
    }

    final config = _config!.fileRead!;

    // Validate path security
    final pathResult = _validatePath(path, config.allowedPaths);
    if (!pathResult.allowed) {
      return pathResult;
    }

    // Validate extension if configured
    if (config.allowedExtensions != null &&
        config.allowedExtensions!.isNotEmpty) {
      final ext = p.extension(path).toLowerCase();
      if (!config.allowedExtensions!.contains(ext)) {
        return PermissionResult.denied(
          'File extension "$ext" not in allowed list',
        );
      }
    }

    return PermissionResult.allowed(
      requiresConfirmation: config.requireConfirmation ?? false,
    );
  }

  /// Check if a file write operation is allowed
  PermissionResult checkFileWrite(String path, {int? fileSize}) {
    if (_config?.fileWrite == null) {
      return PermissionResult.denied('File write permission not configured');
    }

    final config = _config!.fileWrite!;

    // Validate path security
    final pathResult = _validatePath(path, config.allowedPaths);
    if (!pathResult.allowed) {
      return pathResult;
    }

    // Validate extension if configured
    if (config.allowedExtensions != null &&
        config.allowedExtensions!.isNotEmpty) {
      final ext = p.extension(path).toLowerCase();
      if (!config.allowedExtensions!.contains(ext)) {
        return PermissionResult.denied(
          'File extension "$ext" not in allowed list',
        );
      }
    }

    // Validate file size if configured
    if (config.maxSize != null && fileSize != null) {
      if (fileSize > config.maxSize!) {
        return PermissionResult.denied(
          'File size $fileSize exceeds maximum ${config.maxSize}',
        );
      }
    }

    return PermissionResult.allowed(
      requiresConfirmation: config.requireConfirmation ?? true,
    );
  }

  /// Check if an HTTP request is allowed
  PermissionResult checkHttp(String url, {String? method}) {
    if (_config?.http == null) {
      return PermissionResult.denied('HTTP permission not configured');
    }

    final config = _config!.http!;

    // Parse URL to get domain
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return PermissionResult.denied('Invalid URL format');
    }

    final domain = uri.host.toLowerCase();

    // Check localhost blocking
    if (config.blockLocalhost) {
      if (_isLocalhost(domain)) {
        return PermissionResult.denied('Localhost access is blocked');
      }
    }

    // Check blocked domains
    if (config.blockedDomains != null) {
      for (final blocked in config.blockedDomains!) {
        if (_domainMatches(domain, blocked)) {
          return PermissionResult.denied('Domain "$domain" is blocked');
        }
      }
    }

    // Check allowed domains
    if (config.allowedDomains != null && config.allowedDomains!.isNotEmpty) {
      bool allowed = false;
      for (final allowedDomain in config.allowedDomains!) {
        if (_domainMatches(domain, allowedDomain)) {
          allowed = true;
          break;
        }
      }
      if (!allowed) {
        return PermissionResult.denied('Domain "$domain" not in allowed list');
      }
    }

    // Check allowed methods
    if (method != null &&
        config.allowedMethods != null &&
        config.allowedMethods!.isNotEmpty) {
      final upperMethod = method.toUpperCase();
      if (!config.allowedMethods!
          .map((m) => m.toUpperCase())
          .contains(upperMethod)) {
        return PermissionResult.denied('HTTP method "$method" not allowed');
      }
    }

    return PermissionResult.allowed();
  }

  /// Check if a shell command is allowed
  PermissionResult checkShellExec(String command, {String? workingDir}) {
    if (_config?.shell == null) {
      return PermissionResult.denied('Shell execution not configured');
    }

    final config = _config!.shell!;

    // Validate command against allowlist
    if (config.allowedCommands == null || config.allowedCommands!.isEmpty) {
      return PermissionResult.denied('No commands in allowlist');
    }

    // Check for shell metacharacters (security)
    if (_containsShellMetacharacters(command)) {
      return PermissionResult.denied(
        'Command contains shell metacharacters',
      );
    }

    // Extract base command (first word)
    final baseCommand = command.split(RegExp(r'\s+')).first;

    // Check if command is in allowlist
    bool commandAllowed = false;
    for (final allowed in config.allowedCommands!) {
      if (baseCommand == allowed || command.startsWith('$allowed ')) {
        commandAllowed = true;
        break;
      }
    }

    if (!commandAllowed) {
      return PermissionResult.denied(
        'Command "$baseCommand" not in allowlist',
      );
    }

    // Validate arguments against deny patterns and allow patterns (PM-13)
    final args = command.split(RegExp(r'\s+')).skip(1).toList();
    final denyArgs = config.denyArgs;
    final allowArgPatterns = config.allowArgPatterns;

    if (denyArgs != null && denyArgs.isNotEmpty) {
      for (final arg in args) {
        if (denyArgs.contains(arg)) {
          return PermissionResult.denied(
            'Argument "$arg" is in deny list',
          );
        }
      }
    }

    if (allowArgPatterns != null && allowArgPatterns.isNotEmpty) {
      for (final arg in args) {
        bool argAllowed = false;
        for (final pattern in allowArgPatterns) {
          if (RegExp(pattern).hasMatch(arg)) {
            argAllowed = true;
            break;
          }
        }
        if (!argAllowed) {
          return PermissionResult.denied(
            'Argument "$arg" does not match any allowed pattern',
          );
        }
      }
    }

    // Check working directory if configured
    if (workingDir != null && config.allowedWorkingDirs != null) {
      final pathResult = _validatePath(workingDir, config.allowedWorkingDirs);
      if (!pathResult.allowed) {
        return PermissionResult.denied(
          'Working directory not in allowed list',
        );
      }
    }

    return PermissionResult.allowed(
      requiresConfirmation: config.requireConfirmation,
      timeout: config.timeout,
    );
  }

  /// Check clipboard permission
  PermissionResult checkClipboard() {
    if (_config?.clipboard != true) {
      return PermissionResult.denied('Clipboard access not permitted');
    }
    return PermissionResult.allowed();
  }

  /// Check notification permission
  PermissionResult checkNotification() {
    if (_config?.notification != true) {
      return PermissionResult.denied('Notification access not permitted');
    }
    return PermissionResult.allowed();
  }

  /// Check system info permission
  PermissionResult checkSystemInfo() {
    if (_config?.systemInfo != true) {
      return PermissionResult.denied('System info access not permitted');
    }
    return PermissionResult.allowed();
  }

  /// Check permission for a client action type
  PermissionResult checkAction(
    String actionType,
    Map<String, dynamic> params,
  ) {
    switch (actionType) {
      case ClientActionTypes.selectFile:
        // `selectFile` opens the OS picker; the concrete path isn't
        // known until the user chooses one. Permission here is a
        // binary "is file read declared?" — the subsequent
        // `readFile` action re-validates the chosen path against
        // the same allowlist before opening it.
        if (_config?.fileRead == null) {
          return PermissionResult.denied(
              'File read permission not configured');
        }
        return PermissionResult.allowed(
          requiresConfirmation:
              _config!.fileRead!.requireConfirmation ?? false,
        );
      case ClientActionTypes.readFile:
      case ClientActionTypes.listFiles:
        final path = params['path'] as String?;
        if (path == null) {
          return PermissionResult.denied('Path parameter required');
        }
        return checkFileRead(path);

      case ClientActionTypes.writeFile:
      case ClientActionTypes.saveFile:
        final path = params['path'] as String?;
        if (path == null) {
          return PermissionResult.denied('Path parameter required');
        }
        final content = params['content'] as String?;
        return checkFileWrite(path, fileSize: content?.length);

      case ClientActionTypes.httpRequest:
        final url = params['url'] as String?;
        if (url == null) {
          return PermissionResult.denied('URL parameter required');
        }
        return checkHttp(url, method: params['method'] as String?);

      case ClientActionTypes.exec:
        final command = params['command'] as String?;
        if (command == null) {
          return PermissionResult.denied('Command parameter required');
        }
        return checkShellExec(
          command,
          workingDir: params['workingDir'] as String?,
        );

      case ClientActionTypes.clipboard:
        return checkClipboard();

      case ClientActionTypes.notification:
        return checkNotification();

      case ClientActionTypes.getSystemInfo:
        return checkSystemInfo();

      case ClientActionTypes.storageGet:
      case ClientActionTypes.storageSet:
      case ClientActionTypes.storageRemove:
        // App-local key/value storage — sandboxed per-app, never
        // touches user-selected paths or network, so it's always
        // allowed without a separate config block (matches the
        // iOS/Android convention of per-app local storage).
        return PermissionResult.allowed();

      default:
        return PermissionResult.denied(
          'PERMISSION_NOT_DECLARED: Permission for action "$actionType" is not declared at screen level',
        );
    }
  }

  // Private helper methods

  /// Validate a path against allowed paths.
  ///
  /// An entry of `'*'` in the allowlist matches any path — intended for
  /// trusted apps where the user has already granted broad file access
  /// and the JIT prompt carries the fine-grained decision. Path
  /// traversal (`..`) is still blocked regardless of the allowlist to
  /// defend against DSL authors trying to reach outside the declared
  /// scope via relative segments.
  PermissionResult _validatePath(String path, List<String>? allowedPaths) {
    // Normalize the path
    final normalized = p.normalize(path);

    // Block path traversal attacks
    if (normalized.contains('..')) {
      return PermissionResult.denied('Path traversal not allowed');
    }

    // If no allowedPaths configured, deny
    if (allowedPaths == null || allowedPaths.isEmpty) {
      return PermissionResult.denied('No paths in allowlist');
    }

    // Wildcard allow-any — author is declaring "any user-selected path
    // is acceptable for this app, defer to the JIT prompt".
    if (allowedPaths.contains('*')) {
      return PermissionResult.allowed();
    }

    // Check if path is within allowed paths
    for (final allowed in allowedPaths) {
      final normalizedAllowed = p.normalize(allowed);
      if (normalized.startsWith(normalizedAllowed) ||
          p.isWithin(normalizedAllowed, normalized)) {
        return PermissionResult.allowed();
      }
    }

    return PermissionResult.denied('Path not in allowed list');
  }

  /// Check if a domain matches. Supports two wildcard forms:
  ///
  /// * `'*'` — matches any domain (use when the app is trusted to
  ///   choose its own endpoints and the JIT prompt owns per-call
  ///   approval).
  /// * `'*.example.com'` — matches the base and any subdomain.
  bool _domainMatches(String domain, String pattern) {
    if (pattern == '*') {
      return true;
    }
    if (pattern.startsWith('*.')) {
      // Wildcard subdomain match
      final baseDomain = pattern.substring(2);
      return domain == baseDomain || domain.endsWith('.$baseDomain');
    }
    return domain == pattern;
  }

  /// Check if a domain is localhost
  bool _isLocalhost(String domain) {
    return domain == 'localhost' ||
        domain == '127.0.0.1' ||
        domain == '::1' ||
        domain.endsWith('.localhost');
  }

  /// Check if a command contains shell metacharacters
  bool _containsShellMetacharacters(String command) {
    // Characters that could lead to shell injection
    const dangerousChars = [
      ';',
      '|',
      '&',
      '\$',
      '`',
      '(',
      ')',
      '{',
      '}',
      '<',
      '>',
      '\n',
      '\r',
    ];

    for (final char in dangerousChars) {
      if (command.contains(char)) {
        return true;
      }
    }
    return false;
  }
}

/// Result of a permission check
class PermissionResult {
  /// Whether the action is allowed
  final bool allowed;

  /// Reason for denial (if not allowed)
  final String? reason;

  /// Whether user confirmation is required
  final bool requiresConfirmation;

  /// Timeout for the action (if applicable)
  final int? timeout;

  const PermissionResult._({
    required this.allowed,
    this.reason,
    this.requiresConfirmation = false,
    this.timeout,
  });

  /// Create an allowed result
  factory PermissionResult.allowed({
    bool requiresConfirmation = false,
    int? timeout,
  }) {
    return PermissionResult._(
      allowed: true,
      requiresConfirmation: requiresConfirmation,
      timeout: timeout,
    );
  }

  /// Create a denied result
  factory PermissionResult.denied(String reason) {
    return PermissionResult._(
      allowed: false,
      reason: reason,
    );
  }

  @override
  String toString() {
    if (allowed) {
      return 'PermissionResult(allowed, confirmation: $requiresConfirmation)';
    }
    return 'PermissionResult(denied: $reason)';
  }
}
