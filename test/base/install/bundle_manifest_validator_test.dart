/// Unit tests for `BundleManifestValidator` — the activation-time checker.
/// All tests build minimal `mb.McpBundle` instances in-memory (no disk I/O).
///
///   v1  empty bundle → no issues
///   v2  agent with empty id → AGENT_ID_MISSING error
///   v3  duplicate agent ids → AGENT_ID_DUPLICATE error
///   v4  agent with whitespace-only model.model → AGENT_MODEL_EMPTY warning
///   v5  tool with empty name → TOOL_NAME_MISSING error
///   v6  duplicate tool names → TOOL_NAME_DUPLICATE error
///   v7  tool kind=mcp invalid transport → TOOL_MCP_TRANSPORT_INVALID
///   v8  tool kind=mcp transport=http missing url → TOOL_MCP_URL_MISSING
///   v9  tool kind=mcp transport=stdio missing command → TOOL_MCP_COMMAND_MISSING
///   v10 tool kind=js missing entry → TOOL_JS_ENTRY_MISSING
///   v11 tool kind=js missing fn → TOOL_JS_FN_MISSING
///   v12 tool kind=unknown → TOOL_KIND_MISSING
///   v13 tool kind=host → no issue
///   v14 tool kind=cloud → no issue
///   v15 agentScope refers to undeclared agent → TOOL_AGENT_SCOPE_UNKNOWN warning
///   v16 ui.kind missing → UI_KIND_MISSING error
///   v17 ui.kind unknown renderer → UI_KIND_UNKNOWN warning
///   v18 ui.path missing → UI_PATH_MISSING error
///   v19 ui.kind='mcp_ui_dsl' + path present → no ui issues
///   v20 requires duplicate builtinTools → REQUIRES_TOOL_DUPLICATE warning
///   v21 requires duplicate builtinAtoms → REQUIRES_ATOM_DUPLICATE warning
///   v22 requires unique tools/atoms → no issue
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:appplayer_studio/src/base/install/bundle_manifest_validator.dart';

// ---------------------------------------------------------------------------
// Minimal bundle helpers
// ---------------------------------------------------------------------------

mb.McpBundle _bundle({
  String id = 'com.example.test',
  mb.AgentsSection? agents,
  mb.ToolsSection? tools,
  mb.UiSection? ui,
  mb.RequiresSection? requires,
}) {
  return mb.McpBundle(
    manifest: mb.BundleManifest(id: id, name: 'Test', version: '1.0'),
    agents: agents,
    tools: tools,
    ui: ui,
    requires: requires,
  );
}

mb.AgentDefinition _agent(String id, {String? modelId}) {
  return mb.AgentDefinition(
    id: id,
    name: id,
    role: 'worker',
    model: modelId != null ? mb.AgentModelConfig(model: modelId) : null,
  );
}

mb.ToolEntry _tool(
  String name, {
  mb.ToolKind kind = mb.ToolKind.js,
  Map<String, dynamic> target = const {'entry': 'tools/x.js', 'fn': 'run'},
  List<String>? agentScope,
}) {
  return mb.ToolEntry(
    name: name,
    kind: kind,
    target: target,
    agentScope: agentScope,
  );
}

mb.UiSection _uiSection(Map<String, dynamic> raw) => mb.UiSection(raw: raw);

mb.RequiresSection _requires({
  List<String> tools = const [],
  List<String> atoms = const [],
}) {
  return mb.RequiresSection(builtinTools: tools, builtinAtoms: atoms);
}

bool _hasCode(List<ManifestIssue> issues, String code) =>
    issues.any((i) => i.code == code);

ManifestIssueSeverity _severity(List<ManifestIssue> issues, String code) =>
    issues.firstWhere((i) => i.code == code).severity;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
void main() {
  group('BundleManifestValidator.validate', () {
    // v1
    test('v1 empty bundle produces no issues', () {
      final issues = BundleManifestValidator.validate(_bundle());
      expect(issues, isEmpty);
    });

    // v2
    test('v2 agent with empty id → AGENT_ID_MISSING error', () {
      final b = _bundle(agents: mb.AgentsSection(agents: [_agent('')]));
      final issues = BundleManifestValidator.validate(b);
      expect(_hasCode(issues, 'AGENT_ID_MISSING'), isTrue);
      expect(
        _severity(issues, 'AGENT_ID_MISSING'),
        ManifestIssueSeverity.error,
      );
    });

    // v3
    test('v3 duplicate agent ids → AGENT_ID_DUPLICATE error', () {
      final b = _bundle(
        agents: mb.AgentsSection(agents: [_agent('dup'), _agent('dup')]),
      );
      final issues = BundleManifestValidator.validate(b);
      expect(_hasCode(issues, 'AGENT_ID_DUPLICATE'), isTrue);
      expect(
        _severity(issues, 'AGENT_ID_DUPLICATE'),
        ManifestIssueSeverity.error,
      );
    });

    // v4
    test(
      'v4 agent with whitespace-only model.model → AGENT_MODEL_EMPTY warning',
      () {
        final b = _bundle(
          agents: mb.AgentsSection(agents: [_agent('a1', modelId: '   ')]),
        );
        final issues = BundleManifestValidator.validate(b);
        expect(_hasCode(issues, 'AGENT_MODEL_EMPTY'), isTrue);
        expect(
          _severity(issues, 'AGENT_MODEL_EMPTY'),
          ManifestIssueSeverity.warning,
        );
      },
    );

    // v5
    test('v5 tool with empty name → TOOL_NAME_MISSING error', () {
      final b = _bundle(
        tools: mb.ToolsSection(
          tools: [
            const mb.ToolEntry(
              name: '',
              kind: mb.ToolKind.js,
              target: {'entry': 'x.js', 'fn': 'run'},
            ),
          ],
        ),
      );
      final issues = BundleManifestValidator.validate(b);
      expect(_hasCode(issues, 'TOOL_NAME_MISSING'), isTrue);
    });

    // v6
    test('v6 duplicate tool names → TOOL_NAME_DUPLICATE error', () {
      final b = _bundle(
        tools: mb.ToolsSection(tools: [_tool('t1'), _tool('t1')]),
      );
      final issues = BundleManifestValidator.validate(b);
      expect(_hasCode(issues, 'TOOL_NAME_DUPLICATE'), isTrue);
    });

    // v7
    test('v7 tool kind=mcp invalid transport → TOOL_MCP_TRANSPORT_INVALID', () {
      final b = _bundle(
        tools: mb.ToolsSection(
          tools: [
            _tool(
              'bad',
              kind: mb.ToolKind.mcp,
              target: {'transport': 'ftp', 'url': 'http://x'},
            ),
          ],
        ),
      );
      final issues = BundleManifestValidator.validate(b);
      expect(_hasCode(issues, 'TOOL_MCP_TRANSPORT_INVALID'), isTrue);
    });

    // v8
    test(
      'v8 tool kind=mcp transport=http missing url → TOOL_MCP_URL_MISSING',
      () {
        final b = _bundle(
          tools: mb.ToolsSection(
            tools: [
              _tool('t', kind: mb.ToolKind.mcp, target: {'transport': 'http'}),
            ],
          ),
        );
        final issues = BundleManifestValidator.validate(b);
        expect(_hasCode(issues, 'TOOL_MCP_URL_MISSING'), isTrue);
      },
    );

    // v9
    test(
      'v9 tool kind=mcp transport=stdio missing command → TOOL_MCP_COMMAND_MISSING',
      () {
        final b = _bundle(
          tools: mb.ToolsSection(
            tools: [
              _tool('t', kind: mb.ToolKind.mcp, target: {'transport': 'stdio'}),
            ],
          ),
        );
        final issues = BundleManifestValidator.validate(b);
        expect(_hasCode(issues, 'TOOL_MCP_COMMAND_MISSING'), isTrue);
      },
    );

    // v10
    test('v10 tool kind=js missing entry → TOOL_JS_ENTRY_MISSING', () {
      final b = _bundle(
        tools: mb.ToolsSection(
          tools: [
            _tool('t', kind: mb.ToolKind.js, target: {'fn': 'run'}),
          ],
        ),
      );
      final issues = BundleManifestValidator.validate(b);
      expect(_hasCode(issues, 'TOOL_JS_ENTRY_MISSING'), isTrue);
    });

    // v11
    test('v11 tool kind=js missing fn → TOOL_JS_FN_MISSING', () {
      final b = _bundle(
        tools: mb.ToolsSection(
          tools: [
            _tool('t', kind: mb.ToolKind.js, target: {'entry': 'x.js'}),
          ],
        ),
      );
      final issues = BundleManifestValidator.validate(b);
      expect(_hasCode(issues, 'TOOL_JS_FN_MISSING'), isTrue);
    });

    // v12
    test('v12 tool kind=unknown → TOOL_KIND_MISSING error', () {
      final b = _bundle(
        tools: mb.ToolsSection(
          tools: [_tool('t', kind: mb.ToolKind.unknown, target: {})],
        ),
      );
      final issues = BundleManifestValidator.validate(b);
      expect(_hasCode(issues, 'TOOL_KIND_MISSING'), isTrue);
    });

    // v13
    test('v13 tool kind=host → no issue from host branch', () {
      final b = _bundle(
        tools: mb.ToolsSection(
          tools: [_tool('h', kind: mb.ToolKind.host, target: {})],
        ),
      );
      final issues = BundleManifestValidator.validate(b);
      expect(issues.where((i) => i.code.startsWith('TOOL_HOST')), isEmpty);
    });

    // v14
    test('v14 tool kind=cloud → no issue from cloud branch', () {
      final b = _bundle(
        tools: mb.ToolsSection(
          tools: [_tool('c', kind: mb.ToolKind.cloud, target: {})],
        ),
      );
      final issues = BundleManifestValidator.validate(b);
      expect(issues.where((i) => i.code.startsWith('TOOL_CLOUD')), isEmpty);
    });

    // v15
    test(
      'v15 agentScope refers to undeclared agent → TOOL_AGENT_SCOPE_UNKNOWN warning',
      () {
        final b = _bundle(
          tools: mb.ToolsSection(
            tools: [
              _tool('t', agentScope: ['ghost']),
            ],
          ),
        );
        final issues = BundleManifestValidator.validate(b);
        expect(_hasCode(issues, 'TOOL_AGENT_SCOPE_UNKNOWN'), isTrue);
        expect(
          _severity(issues, 'TOOL_AGENT_SCOPE_UNKNOWN'),
          ManifestIssueSeverity.warning,
        );
      },
    );

    test(
      'v15b agentScope for a declared agent → no TOOL_AGENT_SCOPE_UNKNOWN',
      () {
        final b = _bundle(
          agents: mb.AgentsSection(agents: [_agent('a1')]),
          tools: mb.ToolsSection(
            tools: [
              _tool('t', agentScope: ['a1']),
            ],
          ),
        );
        final issues = BundleManifestValidator.validate(b);
        expect(_hasCode(issues, 'TOOL_AGENT_SCOPE_UNKNOWN'), isFalse);
      },
    );

    // v16
    test('v16 ui.kind missing (not a String) → UI_KIND_MISSING error', () {
      final b = _bundle(ui: _uiSection({'path': 'ui/app.json'}));
      final issues = BundleManifestValidator.validate(b);
      expect(_hasCode(issues, 'UI_KIND_MISSING'), isTrue);
      expect(_severity(issues, 'UI_KIND_MISSING'), ManifestIssueSeverity.error);
    });

    // v17
    test('v17 ui.kind unknown renderer → UI_KIND_UNKNOWN warning', () {
      final b = _bundle(
        ui: _uiSection({'kind': 'react_native', 'path': 'ui/app.json'}),
      );
      final issues = BundleManifestValidator.validate(b);
      expect(_hasCode(issues, 'UI_KIND_UNKNOWN'), isTrue);
      expect(
        _severity(issues, 'UI_KIND_UNKNOWN'),
        ManifestIssueSeverity.warning,
      );
    });

    // v18
    test('v18 ui.path missing → UI_PATH_MISSING error', () {
      final b = _bundle(ui: _uiSection({'kind': 'mcp_ui_dsl'}));
      final issues = BundleManifestValidator.validate(b);
      expect(_hasCode(issues, 'UI_PATH_MISSING'), isTrue);
    });

    // v19
    test('v19 ui kind=mcp_ui_dsl + path present → no ui issues', () {
      final b = _bundle(
        ui: _uiSection({'kind': 'mcp_ui_dsl', 'path': 'ui/app.json'}),
      );
      final issues = BundleManifestValidator.validate(b);
      expect(issues.where((i) => i.code.startsWith('UI_')), isEmpty);
    });

    test('v19b ui kind=studio_ui + path present → no ui issues', () {
      final b = _bundle(
        ui: _uiSection({'kind': 'studio_ui', 'path': 'ui/app.json'}),
      );
      final issues = BundleManifestValidator.validate(b);
      expect(issues.where((i) => i.code.startsWith('UI_')), isEmpty);
    });

    // v20
    test(
      'v20 requires duplicate builtinTools → REQUIRES_TOOL_DUPLICATE warning',
      () {
        final b = _bundle(
          requires: _requires(tools: ['studio.fs.read', 'studio.fs.read']),
        );
        final issues = BundleManifestValidator.validate(b);
        expect(_hasCode(issues, 'REQUIRES_TOOL_DUPLICATE'), isTrue);
        expect(
          _severity(issues, 'REQUIRES_TOOL_DUPLICATE'),
          ManifestIssueSeverity.warning,
        );
      },
    );

    // v21
    test(
      'v21 requires duplicate builtinAtoms → REQUIRES_ATOM_DUPLICATE warning',
      () {
        final b = _bundle(requires: _requires(atoms: ['fs', 'fs']));
        final issues = BundleManifestValidator.validate(b);
        expect(_hasCode(issues, 'REQUIRES_ATOM_DUPLICATE'), isTrue);
      },
    );

    // v22
    test('v22 unique tools/atoms in requires → no REQUIRES_* issues', () {
      final b = _bundle(
        requires: _requires(
          tools: ['studio.fs.read', 'studio.search.query'],
          atoms: ['fs', 'http'],
        ),
      );
      final issues = BundleManifestValidator.validate(b);
      expect(issues.where((i) => i.code.startsWith('REQUIRES_')), isEmpty);
    });

    test('valid js tool → no js-specific issues', () {
      final b = _bundle(
        tools: mb.ToolsSection(
          tools: [
            _tool('ok', target: {'entry': 'tools/ok.js', 'fn': 'run'}),
          ],
        ),
      );
      final issues = BundleManifestValidator.validate(b);
      expect(issues.where((i) => i.code.startsWith('TOOL_JS_')), isEmpty);
    });

    test('valid mcp http tool → no mcp-specific issues', () {
      final b = _bundle(
        tools: mb.ToolsSection(
          tools: [
            _tool(
              'mcp_t',
              kind: mb.ToolKind.mcp,
              target: {'transport': 'http', 'url': 'http://server/mcp'},
            ),
          ],
        ),
      );
      final issues = BundleManifestValidator.validate(b);
      expect(issues.where((i) => i.code.startsWith('TOOL_MCP_')), isEmpty);
    });

    test('valid mcp stdio tool → no mcp-specific issues', () {
      final b = _bundle(
        tools: mb.ToolsSection(
          tools: [
            _tool(
              'mcp_s',
              kind: mb.ToolKind.mcp,
              target: {'transport': 'stdio', 'command': 'my-server'},
            ),
          ],
        ),
      );
      final issues = BundleManifestValidator.validate(b);
      expect(issues.where((i) => i.code.startsWith('TOOL_MCP_')), isEmpty);
    });

    // ManifestIssue value fields
    test('ManifestIssue carries code, pointer, severity, message', () {
      final b = _bundle(agents: mb.AgentsSection(agents: [_agent('')]));
      final issues = BundleManifestValidator.validate(b);
      final issue = issues.firstWhere((i) => i.code == 'AGENT_ID_MISSING');
      expect(issue.pointer, isNotEmpty);
      expect(issue.message, isNotEmpty);
      expect(issue.severity, ManifestIssueSeverity.error);
    });

    // ManifestIssueSeverity enum
    test('ManifestIssueSeverity has error, warning, info', () {
      expect(
        ManifestIssueSeverity.values,
        containsAll(<ManifestIssueSeverity>[
          ManifestIssueSeverity.error,
          ManifestIssueSeverity.warning,
          ManifestIssueSeverity.info,
        ]),
      );
    });
  });
}
