// After r8 (2026-05-28), the prompts surface is also registered through
// BuiltinToolRegistry — the raw `mcp.Server` backdoor was removed.
import 'dart:convert' show jsonEncode;

import 'package:appplayer_studio/base.dart' show BuiltinToolRegistry;
import 'package:appplayer_studio/builtin_api.dart'
    show KernelToolResult, KernelTextContent;

import '../init/knowledge_init.dart';
import '../observability/observability_module.dart';
import '../skills/skill_definition.dart';
import '../tools/docs_tools.dart';
import '../tools/system_tools.dart';
import '../tools/tool_dispatcher.dart';
import '../util/log.dart';

/// Ops tool-surface registrar.
///
/// Principle — a builtin is an app on top of the OS. Paths where ops stands up
/// its own transport (SSE / HTTP) or holds a separate sampling handle have all
/// been removed (zero usages). The host endpoint
/// (`http://127.0.0.1:7840/mcp`) is the single entry — ops only registers its
/// own tool handlers through `BuiltinToolRegistry`.
///
/// Other vibe_studio builtins (App Builder · Scene Builder) follow the same
/// path — aligned with this cleanup's
/// `diora/design/builtin-os-cleanup-plan-2026-05-28.md`.
class McpInbound {
  McpInbound._();

  /// Register every Skill, system, and docs tool (including prompts after
  /// cherry r8) on the host endpoint via the [BuiltinToolRegistry] facade.
  /// Browser ops are NOT registered here — built-ins use the host's shared
  /// `browser.*` capability (parity rule); skill steps route through it via
  /// `SkillExecutor._runBrowser`. Single entry — no raw kernel handle
  /// escapes into builtin code.
  static void registerToolsOn(
    BuiltinToolRegistry server,
    KnowledgeInit init, {
    ObservabilityModule? observability,
  }) {
    final dispatcher = ToolDispatcher(init: init, observability: observability);
    final system = SystemTools(init: init);
    final docs = DocsTools(init: init);

    // Give skill steps a handle to the host's own tools (host endpoint), so
    // capability-backed steps (browser.*) route to the host's shared engine
    // rather than a built-in-owned one. Not `infraPorts.mcp` — that reaches
    // the external configured MCP servers, not the host capabilities.
    init.skillExecutor.bindHostCallTool(server.callTool);

    docs.registerOn(server);
    system.registerOn(server);

    // Skill tools — system tools are registered first, so a skill whose
    // id collides with a system tool name is skipped (addTool would
    // throw on duplicate registration and abort boot).
    for (final skill in init.skills.list()) {
      _registerSkillTool(server, dispatcher, skill);
    }
  }

  static void _registerSkillTool(
    BuiltinToolRegistry server,
    ToolDispatcher dispatcher,
    SkillDefinition skill,
  ) {
    try {
      server.addTool(
        name: skill.id,
        description: skill.description.isEmpty ? skill.id : skill.description,
        inputSchema:
            skill.inputSchema.isEmpty
                ? const {'type': 'object'}
                : Map<String, dynamic>.from(skill.inputSchema),
        handler: (args) async {
          try {
            final result = await dispatcher.dispatch(
              skill.id,
              Map<String, dynamic>.from(args),
            );
            // JSON (like the system tools) so callers — including the
            // Process/Task runner dispatch — can decode structured fields,
            // not a Dart `Map.toString()`.
            return KernelToolResult(
              content: [KernelTextContent(text: jsonEncode(result))],
            );
          } catch (e) {
            return KernelToolResult(
              content: [
                KernelTextContent(text: jsonEncode({'error': '$e'})),
              ],
              isError: true,
            );
          }
        },
      );
    } catch (e) {
      OpsLog.warn('mcp', 'skill tool "${skill.id}" not registered: $e');
    }
  }
}
