/// Permission prompt UI for MCP UI DSL v1.1
///
/// Displays a dialog to request user permission for client actions.
library permission_prompt;

import 'package:flutter/material.dart';

import 'permission_storage.dart';

/// Shows a permission request dialog
class PermissionPrompt {
  /// Show a permission prompt and return the user's decision
  static Future<PermissionDecision?> show({
    required BuildContext context,
    required String permissionType,
    required String title,
    required String description,
    String? scope,
    bool showRememberOption = true,
    List<String>? details,
  }) async {
    return showDialog<PermissionDecision>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _PermissionDialog(
        permissionType: permissionType,
        title: title,
        description: description,
        scope: scope,
        showRememberOption: showRememberOption,
        details: details,
      ),
    );
  }

  /// Show a file access permission prompt
  static Future<PermissionDecision?> showFileAccess({
    required BuildContext context,
    required String path,
    required bool isWrite,
  }) {
    return show(
      context: context,
      permissionType: isWrite ? 'file.write' : 'file.read',
      title: isWrite ? 'File Write Permission' : 'File Read Permission',
      description: isWrite
          ? 'This action wants to write to a file.'
          : 'This action wants to read a file.',
      scope: path,
      details: ['Path: $path'],
    );
  }

  /// Show an HTTP permission prompt
  static Future<PermissionDecision?> showHttpAccess({
    required BuildContext context,
    required String url,
    String? method,
  }) {
    final uri = Uri.tryParse(url);
    final domain = uri?.host ?? url;

    return show(
      context: context,
      permissionType: 'http',
      title: 'Network Access Permission',
      description: 'This action wants to make a network request.',
      scope: domain,
      details: [
        'URL: $url',
        if (method != null) 'Method: $method',
      ],
    );
  }

  /// Show a shell execution permission prompt
  static Future<PermissionDecision?> showShellExec({
    required BuildContext context,
    required String command,
    String? workingDir,
  }) {
    return show(
      context: context,
      permissionType: 'shell',
      title: 'Command Execution Permission',
      description: 'This action wants to execute a shell command.',
      details: [
        'Command: $command',
        if (workingDir != null) 'Working Directory: $workingDir',
      ],
    );
  }
}

class _PermissionDialog extends StatefulWidget {
  final String permissionType;
  final String title;
  final String description;
  final String? scope;
  final bool showRememberOption;
  final List<String>? details;

  const _PermissionDialog({
    required this.permissionType,
    required this.title,
    required this.description,
    this.scope,
    this.showRememberOption = true,
    this.details,
  });

  @override
  State<_PermissionDialog> createState() => _PermissionDialogState();
}

class _PermissionDialogState extends State<_PermissionDialog> {
  bool _remember = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            _getIcon(),
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(widget.title),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.description),
            if (widget.details != null && widget.details!.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: widget.details!
                      .map((detail) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              detail,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                              ),
                            ),
                          ))
                      .toList(),
                ),
              ),
            ],
            if (widget.showRememberOption) ...[
              const SizedBox(height: 16),
              CheckboxListTile(
                value: _remember,
                onChanged: (value) {
                  setState(() {
                    _remember = value ?? false;
                  });
                },
                title: const Text('Remember this decision'),
                subtitle: Text(
                  widget.scope != null
                      ? 'For this ${_getScopeDescription()}'
                      : 'For this session',
                  style: theme.textTheme.bodySmall,
                ),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop(
              PermissionDecision.deny(
                remember: _remember,
                scope: widget.scope,
              ),
            );
          },
          child: const Text('Deny'),
        ),
        OutlinedButton(
          onPressed: () {
            Navigator.of(context).pop(
              PermissionDecision.grantOnce(
                scope: widget.scope,
              ),
            );
          },
          child: const Text('Allow Once'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(
              PermissionDecision.grant(
                remember: _remember,
                scope: widget.scope,
              ),
            );
          },
          child: const Text('Allow'),
        ),
      ],
    );
  }

  IconData _getIcon() {
    switch (widget.permissionType) {
      case 'file.read':
        return Icons.file_open;
      case 'file.write':
        return Icons.save;
      case 'http':
        return Icons.language;
      case 'shell':
        return Icons.terminal;
      case 'clipboard':
        return Icons.content_paste;
      case 'notification':
        return Icons.notifications;
      case 'systemInfo':
        return Icons.info;
      default:
        return Icons.security;
    }
  }

  String _getScopeDescription() {
    switch (widget.permissionType) {
      case 'file.read':
      case 'file.write':
        return 'file path';
      case 'http':
        return 'domain';
      case 'shell':
        return 'command';
      default:
        return 'scope';
    }
  }
}
