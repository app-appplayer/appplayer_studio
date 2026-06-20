/// MCP tool registration for the UI debug bridge (`UiDebugBridge`).
///
/// Kept in a separate file so the stdio CLI entry
/// (`bin/makemind_ops_mcp.dart`) can register the rest of the tool
/// surface without dragging in `dart:ui`. Only the GUI entry
/// (`main.dart`) imports this file and registers the five `ui_*`
/// tools after the booted ProviderScope has attached the bridge.
library;

import 'dart:convert';

import 'package:appplayer_studio/base.dart' show BuiltinToolRegistry;
import 'package:appplayer_studio/builtin_api.dart'
    show KernelToolResult, KernelTextContent;

import '../debug/ui_debug_bridge.dart';

class UiDebugTools {
  const UiDebugTools();

  /// Register the five UI debug tools on the given concrete server.
  /// Idempotent only if the underlying mcp_server instance allows
  /// duplicate registration; callers should ensure they invoke this
  /// once per `mcp.Server` instance.
  void registerOn(BuiltinToolRegistry server) {
    _register(
      server,
      'ui_capture',
      'Capture the current GUI as a base64-encoded PNG. Captures the whole '
          'render view, so root-navigator dialogs/overlays are included '
          '(not just the Ops shell). Use after `ui_navigate` to verify a '
          'route change visually.',
      const {
        'type': 'object',
        'properties': {
          'pixelRatio': {
            'type': 'number',
            'description': 'Render density. Default 1.5 (legible + compact).',
          },
        },
      },
      (args) async {
        final pr = (args['pixelRatio'] as num?)?.toDouble() ?? 1.5;
        final png = await UiDebugBridge.capturePngBase64(pixelRatio: pr);
        if (png == null) {
          return {
            'error':
                'GUI not booted yet (UiDebugBridge unattached or '
                'RepaintBoundary missing)',
          };
        }
        return {
          'mimeType': 'image/png',
          'pixelRatio': pr,
          'base64': png,
          'sizeBytes': png.length * 3 ~/ 4,
        };
      },
    );

    _register(
      server,
      'ui_navigate',
      'Set the sidebar route — same as a human clicking a sidebar item. '
          'Valid routes (OpsRoute): home · observability · members · '
          'knowledge · skills · profiles · tasks · philosophies · processes · '
          'workspaces · bundles · audit · about.',
      const {
        'type': 'object',
        'properties': {
          'route': {'type': 'string'},
        },
        'required': ['route'],
      },
      (args) async {
        final route = args['route'] as String;
        UiDebugBridge.navigate(route);
        return {'route': UiDebugBridge.activeRoute() ?? route};
      },
    );

    _register(
      server,
      'ui_state',
      'Read the active GUI state — current sidebar route, active '
          'workspace, and a brief context sentence the LLM can use to know '
          'what the human (or itself, after `ui_navigate`) is looking at.',
      const {'type': 'object'},
      (args) async {
        return {
          'activeRoute': UiDebugBridge.activeRoute(),
          'activeWorkspaceId': UiDebugBridge.activeWorkspaceId(),
          'attached': UiDebugBridge.activeRoute() != null,
        };
      },
    );

    _register(
      server,
      'ui_page_state',
      'Snapshot of the active page\'s data — what an external LLM would '
          'see by reading the GUI. Branches by active route: `members` → '
          'member list with skillIds; `knowledge` → fact counts + type / '
          'entity histograms; `skills`/`profiles`/`philosophies` → '
          'IntegratedAxisEntry summary (pool/owned counts + sample); '
          '`tasks`/`processes` → registry summary. Useful for diagnosing '
          'UI display state without reading screenshots.',
      const {'type': 'object'},
      (args) async {
        return UiDebugBridge.pageStateSnapshot();
      },
    );

    _register(
      server,
      'ui_open_agent_dialog',
      'Open the agent detail dialog (4-axis cards + lifecycle timeline) '
          'for the given agent — same effect as a human clicking the '
          'member tile. Combine with `ui_capture` on the next breath to '
          'inspect the dialog content visually.',
      const {
        'type': 'object',
        'properties': {
          'agentId': {'type': 'string'},
          'displayName': {'type': 'string'},
        },
        'required': ['agentId'],
      },
      (args) async {
        final ok = UiDebugBridge.requestOpenAgentDialog(
          args['agentId'] as String,
          displayName: args['displayName'] as String?,
        );
        return {'requested': ok};
      },
    );

    // `ui_chat_send` / `ui_chat_history` retired — chat surface
    // collapsed onto the host's shared chat panel (MOD-APPS-007
    // "Chat / Settings unified surface"). External LLM chat
    // automation routes through the host's
    // `chromeBridge.activeChatAgentId` + host
    // `KernelApp.system.agents.ask` path instead.
  }

  void _register(
    BuiltinToolRegistry server,
    String name,
    String description,
    Map<String, dynamic> inputSchema,
    Future<dynamic> Function(Map<String, dynamic>) handler,
  ) {
    final required =
        (inputSchema['required'] as List?)?.cast<String>() ?? const <String>[];
    server.addTool(
      name: name,
      description: description,
      inputSchema: inputSchema.isEmpty ? const {'type': 'object'} : inputSchema,
      handler: (args) async {
        final missing = <String>[
          for (final k in required)
            if (args[k] == null) k,
        ];
        if (missing.isNotEmpty) {
          return KernelToolResult(
            content: [
              KernelTextContent(
                text: jsonEncode({
                  'error': 'missing required argument(s)',
                  'missing': missing,
                  'tool': name,
                }),
              ),
            ],
            isError: true,
          );
        }
        try {
          final result = await handler(args);
          return KernelToolResult(
            content: [KernelTextContent(text: jsonEncode(result))],
          );
        } catch (e, st) {
          return KernelToolResult(
            content: [
              KernelTextContent(
                text: jsonEncode({
                  'error': e.toString(),
                  'stack': st.toString(),
                  'tool': name,
                }),
              ),
            ],
            isError: true,
          );
        }
      },
    );
  }
}
