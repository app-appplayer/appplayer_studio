/// Validation for the activation-relevant sections of an mb.McpBundle
/// (`agents` / `tools` / `requires` / `ui`). Distinct from
/// mcp_bundle's own validators which check storage schema — this one
/// runs at activation time and surfaces issues to the install /
/// activation UX so authors see problems before the activation
/// contract fires.
///
/// **Step 3 absorption** — input is canonical [mb.McpBundle], not a
/// fork class. Field names mirror the canonical schema
/// (`AgentDefinition.name` / `ToolEntry.kind` /
/// `RequiresSection.builtinTools` etc.).
library;

import 'package:mcp_bundle/mcp_bundle.dart' as mb;

/// Severity of a single validation issue.
enum ManifestIssueSeverity { error, warning, info }

class ManifestIssue {
  const ManifestIssue({
    required this.severity,
    required this.code,
    required this.pointer,
    required this.message,
  });

  final ManifestIssueSeverity severity;

  /// Stable code for filtering / suppression. UPPER_SNAKE_CASE.
  final String code;

  /// JSON pointer into `manifest.json` (`/agents/agents/0/role`).
  final String pointer;

  final String message;
}

class BundleManifestValidator {
  /// Validate the activation-relevant sections of [bundle]. Returns
  /// the full issue list — empty when nothing is wrong. Caller
  /// decides whether to block activation on errors.
  static List<ManifestIssue> validate(mb.McpBundle bundle) {
    final issues = <ManifestIssue>[];

    // Agents — id required (parser enforces). Cross-check uniqueness
    // and surface obvious config gaps (empty model id) as warnings.
    final agentIds = <String>{};
    final agents = bundle.agents?.agents ?? const <mb.AgentDefinition>[];
    for (var i = 0; i < agents.length; i++) {
      final a = agents[i];
      if (a.id.isEmpty) {
        issues.add(
          ManifestIssue(
            severity: ManifestIssueSeverity.error,
            code: 'AGENT_ID_MISSING',
            pointer: '/agents/agents/$i/id',
            message: 'Agent at index $i has no id.',
          ),
        );
        continue;
      }
      if (!agentIds.add(a.id)) {
        issues.add(
          ManifestIssue(
            severity: ManifestIssueSeverity.error,
            code: 'AGENT_ID_DUPLICATE',
            pointer: '/agents/agents/$i/id',
            message: 'Agent id "${a.id}" is declared more than once.',
          ),
        );
      }
      final modelId = a.model?.model;
      if (modelId != null && modelId.trim().isEmpty) {
        issues.add(
          ManifestIssue(
            severity: ManifestIssueSeverity.warning,
            code: 'AGENT_MODEL_EMPTY',
            pointer: '/agents/agents/$i/model/model',
            message:
                'model.model is present but empty — host will fall back to default.',
          ),
        );
      }
    }

    // Tools — name + kind required. Cross-check uniqueness + kind-
    // specific target shape.
    final toolNames = <String>{};
    final tools = bundle.tools?.tools ?? const <mb.ToolEntry>[];
    for (var i = 0; i < tools.length; i++) {
      final t = tools[i];
      if (t.name.isEmpty) {
        issues.add(
          ManifestIssue(
            severity: ManifestIssueSeverity.error,
            code: 'TOOL_NAME_MISSING',
            pointer: '/tools/tools/$i/name',
            message: 'Tool at index $i has no name.',
          ),
        );
        continue;
      }
      if (!toolNames.add(t.name)) {
        issues.add(
          ManifestIssue(
            severity: ManifestIssueSeverity.error,
            code: 'TOOL_NAME_DUPLICATE',
            pointer: '/tools/tools/$i/name',
            message: 'Tool name "${t.name}" is declared more than once.',
          ),
        );
      }
      switch (t.kind) {
        case mb.ToolKind.mcp:
          final transport = t.target['transport'];
          if (transport != 'http' && transport != 'stdio') {
            issues.add(
              ManifestIssue(
                severity: ManifestIssueSeverity.error,
                code: 'TOOL_MCP_TRANSPORT_INVALID',
                pointer: '/tools/tools/$i/target/transport',
                message:
                    'Tool kind=mcp requires target.transport to be '
                    '"http" or "stdio".',
              ),
            );
          }
          if (transport == 'http' &&
              (t.target['url'] is! String ||
                  (t.target['url'] as String).isEmpty)) {
            issues.add(
              ManifestIssue(
                severity: ManifestIssueSeverity.error,
                code: 'TOOL_MCP_URL_MISSING',
                pointer: '/tools/tools/$i/target/url',
                message: 'Tool kind=mcp transport=http requires target.url.',
              ),
            );
          }
          if (transport == 'stdio' &&
              (t.target['command'] is! String ||
                  (t.target['command'] as String).isEmpty)) {
            issues.add(
              ManifestIssue(
                severity: ManifestIssueSeverity.error,
                code: 'TOOL_MCP_COMMAND_MISSING',
                pointer: '/tools/tools/$i/target/command',
                message:
                    'Tool kind=mcp transport=stdio requires target.command.',
              ),
            );
          }
          break;
        case mb.ToolKind.js:
          if (t.target['entry'] is! String ||
              (t.target['entry'] as String).isEmpty) {
            issues.add(
              ManifestIssue(
                severity: ManifestIssueSeverity.error,
                code: 'TOOL_JS_ENTRY_MISSING',
                pointer: '/tools/tools/$i/target/entry',
                message:
                    'Tool kind=js requires target.entry pointing to a .js file.',
              ),
            );
          }
          if (t.target['fn'] is! String || (t.target['fn'] as String).isEmpty) {
            issues.add(
              ManifestIssue(
                severity: ManifestIssueSeverity.error,
                code: 'TOOL_JS_FN_MISSING',
                pointer: '/tools/tools/$i/target/fn',
                message: 'Tool kind=js requires target.fn (export name).',
              ),
            );
          }
          break;
        case mb.ToolKind.unknown:
          issues.add(
            ManifestIssue(
              severity: ManifestIssueSeverity.error,
              code: 'TOOL_KIND_MISSING',
              pointer: '/tools/tools/$i/kind',
              message: 'Tool "${t.name}" has no kind.',
            ),
          );
          break;
        case mb.ToolKind.host:
        case mb.ToolKind.cloud:
          // host (in-process builtin) + cloud (HTTPS) — validator does
          // not enforce target shape per 0.3.3 lenient policy.
          break;
      }
      // Cross-check: agentScope refers to declared agents only.
      if (t.agentScope != null) {
        for (var j = 0; j < t.agentScope!.length; j++) {
          if (!agentIds.contains(t.agentScope![j])) {
            issues.add(
              ManifestIssue(
                severity: ManifestIssueSeverity.warning,
                code: 'TOOL_AGENT_SCOPE_UNKNOWN',
                pointer: '/tools/tools/$i/agentScope/$j',
                message:
                    'agentScope references undeclared agent '
                    '"${t.agentScope![j]}".',
              ),
            );
          }
        }
      }
    }

    // UI — host-shaped entry pulled out of `ui.raw` per the
    // activation contract (kind/path discriminator). When present,
    // both fields must be non-empty and kind must be one of the
    // recognised renderers.
    final uiRaw = bundle.ui?.raw;
    if (uiRaw != null && (uiRaw['kind'] != null || uiRaw['path'] != null)) {
      final kind = uiRaw['kind'];
      final path = uiRaw['path'];
      if (kind is! String || kind.isEmpty) {
        issues.add(
          const ManifestIssue(
            severity: ManifestIssueSeverity.error,
            code: 'UI_KIND_MISSING',
            pointer: '/ui/kind',
            message: 'ui.kind must be a non-empty string when ui is present.',
          ),
        );
      } else if (kind != 'mcp_ui_dsl' && kind != 'studio_ui') {
        issues.add(
          ManifestIssue(
            severity: ManifestIssueSeverity.warning,
            code: 'UI_KIND_UNKNOWN',
            pointer: '/ui/kind',
            message:
                'ui.kind "$kind" is not one of the recognised renderers '
                '("mcp_ui_dsl" / "studio_ui").',
          ),
        );
      }
      if (path is! String || path.isEmpty) {
        issues.add(
          const ManifestIssue(
            severity: ManifestIssueSeverity.error,
            code: 'UI_PATH_MISSING',
            pointer: '/ui/path',
            message: 'ui.path must be a non-empty string when ui is present.',
          ),
        );
      }
    }

    // requires — duplicate detection only. Whether a declared host
    // tool actually exists is checked by the activation pipeline
    // against the live MCP server (Phase 5.5); whether an atom key is
    // known is the JsHostBridge's job (Phase 5.3) — both have to use
    // live state the validator can't see.
    final req = bundle.requires;
    if (req != null) {
      final seenTools = <String>{};
      for (var i = 0; i < req.builtinTools.length; i++) {
        final t = req.builtinTools[i];
        if (!seenTools.add(t)) {
          issues.add(
            ManifestIssue(
              severity: ManifestIssueSeverity.warning,
              code: 'REQUIRES_TOOL_DUPLICATE',
              pointer: '/requires/builtinTools/$i',
              message: 'Built-in tool "$t" is listed more than once.',
            ),
          );
        }
      }
      final seenAtoms = <String>{};
      for (var i = 0; i < req.builtinAtoms.length; i++) {
        final a = req.builtinAtoms[i];
        if (!seenAtoms.add(a)) {
          issues.add(
            ManifestIssue(
              severity: ManifestIssueSeverity.warning,
              code: 'REQUIRES_ATOM_DUPLICATE',
              pointer: '/requires/builtinAtoms/$i',
              message: 'Built-in atom "$a" is listed more than once.',
            ),
          );
        }
      }
    }

    return issues;
  }
}
