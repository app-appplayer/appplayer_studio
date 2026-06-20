/// Shell action executor for MCP UI DSL v1.1
///
/// Handles shell command execution with security restrictions.
library shell_action_executor;

import 'dart:io';
import 'package:flutter/foundation.dart';

import '../../actions/action_result.dart';
import '../../renderer/render_context.dart';

/// Executes shell command client actions
///
/// SECURITY: This executor should only be used with proper permission
/// checking via PermissionManager. Commands are validated against
/// an allowlist before execution.
class ShellActionExecutor {
  /// Execute a shell command
  Future<ActionResult> exec(
    Map<String, dynamic> action,
    RenderContext context,
  ) async {
    // Shell execution not available on web
    if (kIsWeb) {
      return ActionResult.error(
        'Shell execution not supported on web platform',
      );
    }

    try {
      final command = action['command'] as String?;
      if (command == null || command.isEmpty) {
        return ActionResult.error('Command parameter is required');
      }

      // Accept both 'cwd' (spec) and 'workingDir' (impl) (CA-09)
      final workingDir = action['cwd'] as String? ??
          action['workingDir'] as String?;
      final timeout = action['timeout'] as int? ?? 30000;
      final environment = _parseEnvironment(action['environment']);

      // Accept separate args array (CA-08) or parse from command string
      final explicitArgs = (action['args'] as List<dynamic>?)?.cast<String>();

      String executable;
      List<String> arguments;

      if (explicitArgs != null) {
        executable = command;
        arguments = explicitArgs;
      } else {
        final parts = _parseCommand(command);
        if (parts.isEmpty) {
          return ActionResult.error('Invalid command format');
        }
        executable = parts.first;
        arguments = parts.length > 1 ? parts.sublist(1) : <String>[];
      }

      // Validate working directory exists
      if (workingDir != null) {
        final dir = Directory(workingDir);
        if (!await dir.exists()) {
          return ActionResult.error(
            'Working directory does not exist: $workingDir',
          );
        }
      }

      // Execute command
      final process = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDir,
        environment: environment,
        runInShell: false, // SECURITY: Don't use shell to prevent injection
      );

      // Collect output with timeout
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      process.stdout.transform(const SystemEncoding().decoder).listen(
            (data) => stdout.write(data),
          );

      process.stderr.transform(const SystemEncoding().decoder).listen(
            (data) => stderr.write(data),
          );

      // Wait for completion with timeout
      final exitCode = await process.exitCode.timeout(
        Duration(milliseconds: timeout),
        onTimeout: () {
          process.kill(ProcessSignal.sigterm);
          throw TimeoutException('Command timed out after ${timeout}ms');
        },
      );

      return ActionResult.success(data: {
        'code': exitCode,
        'stdout': stdout.toString(),
        'stderr': stderr.toString(),
        'command': command,
        'success': exitCode == 0,
      });
    } on TimeoutException catch (e) {
      return ActionResult.error('Command execution timed out: $e');
    } catch (e) {
      return ActionResult.error('Failed to execute command: $e');
    }
  }

  /// Parse command string into parts
  ///
  /// Handles basic quoting for arguments with spaces.
  List<String> _parseCommand(String command) {
    final parts = <String>[];
    final buffer = StringBuffer();
    var inQuote = false;
    var quoteChar = '';

    for (var i = 0; i < command.length; i++) {
      final char = command[i];

      if ((char == '"' || char == "'") && !inQuote) {
        inQuote = true;
        quoteChar = char;
      } else if (char == quoteChar && inQuote) {
        inQuote = false;
        quoteChar = '';
      } else if (char == ' ' && !inQuote) {
        if (buffer.isNotEmpty) {
          parts.add(buffer.toString());
          buffer.clear();
        }
      } else {
        buffer.write(char);
      }
    }

    if (buffer.isNotEmpty) {
      parts.add(buffer.toString());
    }

    return parts;
  }

  /// Parse environment variables from action
  Map<String, String>? _parseEnvironment(dynamic env) {
    if (env == null) return null;

    if (env is Map) {
      return env.map((key, value) => MapEntry(
            key.toString(),
            value.toString(),
          ));
    }

    return null;
  }
}

/// Exception for command timeout
class TimeoutException implements Exception {
  final String message;
  TimeoutException(this.message);

  @override
  String toString() => message;
}
