import 'dart:convert';

import 'package:appplayer_studio/base.dart' show BuiltinToolRegistry;
import 'package:appplayer_studio/builtin_api.dart'
    show
        KernelGetPromptResult,
        KernelPromptArgument,
        KernelPromptMessage,
        KernelReadResourceResult,
        KernelResourceContent,
        KernelTextContent;

import '../init/knowledge_init.dart';
import '../ops_builtin.dart' show OpsBuiltInApp;
import '../registries/member_registry.dart' show Member;
import '../registries/task_registry.dart' show Task;

/// Exposes makemind-ops usage docs as MCP **Resources** and **Prompts** so any
/// LLM connecting over MCP (internal or external) can discover:
///   - what this app is
///   - the core concepts (workspace · member · skill · task · process · bundle · fact)
///   - the 3-layer skill scope (template · workspace · agent)
///   - common workflows with the exact tool-call sequences
///   - current live state (active workspace, members, installed bundles)
///
/// Any LLM should call the `getting_started` prompt first (or read
/// `makemind-ops://guide`) before driving the app.
class DocsTools {
  DocsTools({required KnowledgeInit init}) : _bootInit = init;

  // Mirror SystemTools: resolve through the live (re-bound) init after a
  // project-open re-boot, falling back to the boot-time init. Without this the
  // `makemind-ops://state` resource captured the stale unbound init (showing
  // finw1 / internalLlm:false) while the real ops was already bound.
  final KnowledgeInit _bootInit;
  KnowledgeInit get init => OpsBuiltInApp.liveInit ?? _bootInit;

  /// Register Ops docs resources + prompts on the host endpoint via the
  /// [BuiltinToolRegistry] facade. After the introduction of `addPrompt` in
  /// r8 (2026-05-28), the raw `mcp.Server` backdoor was removed — registry is
  /// the single path.
  void registerOn(BuiltinToolRegistry server) {
    _registerResources(server);
    _registerPrompts(server);
  }

  void _registerResources(BuiltinToolRegistry server) {
    server.addResource(
      uri: 'makemind-ops://guide',
      name: 'makemind-ops user guide',
      description:
          'Full guide to what this app is, how it is structured conceptually, and the tool-call order an LLM should use to drive it.',
      mimeType: 'text/markdown',
      handler:
          (uri, params) async => KernelReadResourceResult(
            contents: [
              KernelResourceContent(
                uri: uri,
                mimeType: 'text/markdown',
                text: _guideMarkdown,
              ),
            ],
          ),
    );

    server.addResource(
      uri: 'makemind-ops://concepts',
      name: 'Core concept summary',
      description:
          'Definitions and relationships for Workspace, Member, Skill, Task, Process, Bundle, Fact, and the 3-layer scope.',
      mimeType: 'text/markdown',
      handler:
          (uri, params) async => KernelReadResourceResult(
            contents: [
              KernelResourceContent(
                uri: uri,
                mimeType: 'text/markdown',
                text: _conceptsMarkdown,
              ),
            ],
          ),
    );

    server.addResource(
      uri: 'makemind-ops://workflows',
      name: 'Common workflows',
      description:
          'MCP tool-call sequences for representative flows from workspace creation to skill execution.',
      mimeType: 'text/markdown',
      handler:
          (uri, params) async => KernelReadResourceResult(
            contents: [
              KernelResourceContent(
                uri: uri,
                mimeType: 'text/markdown',
                text: _workflowsMarkdown,
              ),
            ],
          ),
    );

    server.addResource(
      uri: 'makemind-ops://tool-catalog',
      name: 'Tool catalog (by group)',
      description: 'All MCP tools grouped and explained by category.',
      mimeType: 'text/markdown',
      handler:
          (uri, params) async => KernelReadResourceResult(
            contents: [
              KernelResourceContent(
                uri: uri,
                mimeType: 'text/markdown',
                text: _toolCatalogMarkdown,
              ),
            ],
          ),
    );

    server.addResource(
      uri: 'makemind-ops://state',
      name: 'Current engine state (dynamic)',
      description:
          'Live snapshot: activeWorkspace, members, tasks, processes, installedBundles, skills, internalLlm.',
      mimeType: 'application/json',
      handler: (uri, params) async {
        final wsId = init.registries.workspace.activeId;
        final wsList = await init.registries.workspace.list();
        // Keep these statically typed (not `List<dynamic>`): `.name` on the
        // `MemberKind` / `TaskKind` / `TaskState` enums is the `EnumName`
        // extension getter, which resolves statically. A `List<dynamic>`
        // fallback turns `m.kind.name` into a dynamic dispatch that throws
        // `NoSuchMethodError: ... has no instance getter 'name'` once a
        // workspace actually has members/tasks.
        final List<Member> members =
            wsId == null
                ? const <Member>[]
                : await init.registries.member.listForWorkspace(wsId);
        final List<Task> tasks =
            wsId == null
                ? const <Task>[]
                : await init.registries.task.list(wsId: wsId);
        final processes =
            wsId == null
                ? const <dynamic>[]
                : await init.registries.process.list(wsId: wsId);
        final bundles = await init.registries.bundle.list();
        final installed =
            wsId == null
                ? const <dynamic>[]
                : await init.registries.bundleInstaller.listInstalled(wsId);
        return KernelReadResourceResult(
          contents: [
            KernelResourceContent(
              uri: uri,
              mimeType: 'application/json',
              text: const JsonEncoder.withIndent('  ').convert({
                'activeWorkspace': wsId,
                'workspaces': [
                  for (final w in wsList)
                    {'id': w.id, 'type': w.type.name, 'title': w.title},
                ],
                'members': [
                  for (final m in members) {'id': m.id, 'kind': m.kind.name},
                ],
                'tasks': [
                  for (final t in tasks)
                    {'id': t.id, 'kind': t.kind.name, 'state': t.state.name},
                ],
                'processes': [
                  for (final p in processes) {'id': p.id, 'title': p.title},
                ],
                'catalogBundles': [
                  for (final b in bundles) {'id': b.id, 'version': b.version},
                ],
                'installedBundles': [
                  for (final r in installed)
                    {'bundleId': r.bundleId, 'version': r.version},
                ],
                'skills': init.skills.length,
                'internalLlm': init.adapters.llm.hasInternalLlm,
              }),
            ),
          ],
        );
      },
    );

    server.addResource(
      uri: 'makemind-ops://error-codes',
      name: 'Error code table',
      description:
          'Meanings of OpsError codes (E1xxx, E2xxx, E3xxx, …) and how to resolve them.',
      mimeType: 'text/markdown',
      handler:
          (uri, params) async => KernelReadResourceResult(
            contents: [
              KernelResourceContent(
                uri: uri,
                mimeType: 'text/markdown',
                text: _errorCodesMarkdown,
              ),
            ],
          ),
    );

    server.addResource(
      uri: 'makemind-ops://skill-schema',
      name: 'Skill YAML schema',
      description:
          'Field definitions and examples for the YAML injected via skill_save / skill_generate.',
      mimeType: 'text/markdown',
      handler:
          (uri, params) async => KernelReadResourceResult(
            contents: [
              KernelResourceContent(
                uri: uri,
                mimeType: 'text/markdown',
                text: _skillSchemaMarkdown,
              ),
            ],
          ),
    );
  }

  void _registerPrompts(BuiltinToolRegistry server) {
    server.addPrompt(
      name: 'getting_started',
      description:
          'Orientation for an LLM operating makemind-ops for the first time: what it is, what it can do, and where to start.',
      arguments: const [],
      handler: (args) async {
        return KernelGetPromptResult(
          description: 'makemind-ops orientation',
          messages: [
            KernelPromptMessage(
              role: 'user',
              content: KernelTextContent(text: _gettingStartedPrompt),
            ),
          ],
        );
      },
    );

    server.addPrompt(
      name: 'drive_workspace',
      description: 'Prompt preset for performing work in a specific workspace.',
      arguments: [
        KernelPromptArgument(
          name: 'workspaceId',
          description: 'Target workspace id (e.g. org/makemind-dev)',
          required: true,
        ),
        KernelPromptArgument(
          name: 'goal',
          description: 'Goal to accomplish, in natural language',
          required: true,
        ),
      ],
      handler: (args) async {
        final wsId = args['workspaceId'] as String? ?? '';
        final goal = args['goal'] as String? ?? '';
        return KernelGetPromptResult(
          description: 'workspace operation brief',
          messages: [
            KernelPromptMessage(
              role: 'user',
              content: KernelTextContent(
                text: '''
Accomplish the following goal in workspace $wsId.
Goal: $goal

Principles:
1. First read resource `makemind-ops://state` to understand the current state.
2. If needed, switch to $wsId via `workspace_switch`.
3. Use `*_list` to inspect the members / tasks / processes / skills needed.
4. Create anything missing via `*_create` / `skill_save`.
5. Final execution goes through `task_run`, `process_start`, or an individual skill tool.
6. After every state change, re-read `makemind-ops://state` at least once to verify.
''',
              ),
            ),
          ],
        );
      },
    );

    server.addPrompt(
      name: 'author_skill',
      description:
          'Author a new skill or adapt an existing skill for an agent/workspace.',
      arguments: [
        KernelPromptArgument(
          name: 'skillId',
          description: 'Skill id to create',
          required: true,
        ),
        KernelPromptArgument(
          name: 'scope',
          description: 'workspace | agent',
          required: true,
        ),
        KernelPromptArgument(
          name: 'actorId',
          description: 'Member id when scope=agent',
          required: false,
        ),
        KernelPromptArgument(
          name: 'goal',
          description: 'Problem the skill should solve',
          required: true,
        ),
      ],
      handler: (args) async {
        final skillId = args['skillId'] as String? ?? '';
        final scope = args['scope'] as String? ?? 'workspace';
        final actorId = args['actorId'] as String? ?? '';
        final goal = args['goal'] as String? ?? '';
        return KernelGetPromptResult(
          description: 'skill authoring brief',
          messages: [
            KernelPromptMessage(
              role: 'user',
              content: KernelTextContent(
                text: '''
Write a skill YAML that matches the following requirements, then save it.
id: $skillId
scope: $scope ${scope == "agent" ? "(actorId=$actorId)" : ""}
goal: $goal

Procedure:
1. Read the YAML schema from the `makemind-ops://skill-schema` resource.
2. Draft a YAML that includes inputSchema / outputSchema / actionBody (kind + steps).
3. Inject via `skill_save` (scope + yaml + actorId).
4. Verify resolution via `skill_get`.
5. If needed, run `task_create` + `task_run` to validate execution.
''',
              ),
            ),
          ],
        );
      },
    );

    server.addPrompt(
      name: 'evolve_agent',
      description:
          'Guide for incrementally evolving a specific agent\'s skill/profile/philosophy to match new situations.',
      arguments: [
        KernelPromptArgument(
          name: 'actorId',
          description: 'Target agent id',
          required: true,
        ),
        KernelPromptArgument(
          name: 'feedback',
          description: 'Observed issues or desired changes',
          required: true,
        ),
      ],
      handler: (args) async {
        final actorId = args['actorId'] as String? ?? '';
        final feedback = args['feedback'] as String? ?? '';
        return KernelGetPromptResult(
          description: 'agent evolution brief',
          messages: [
            KernelPromptMessage(
              role: 'user',
              content: KernelTextContent(
                text: '''
Evolve agent $actorId's behavior to match the feedback below.
Feedback: $feedback

Procedure:
1. Use `skill_list(actorId=$actorId)` to inspect the skills visible to this agent and each scope.
2. Look up the current definition of the offending skill via `skill_get(skillId, actorId=$actorId)`.
3. Write an improved YAML — the diff against the original must be clear.
4. Save the overlay via `skill_save(scope=agent, actorId=$actorId, yaml=...)`.
5. Validate: run the same `skillId` on a different agent (original is preserved) and on this agent (improvements applied).
6. Record the change in FactGraph via `knowledge_save(category=skill_evolution, ...)`.
''',
              ),
            ),
          ],
        );
      },
    );

    server.addPrompt(
      name: 'compose_process',
      description:
          'Guide for authoring a process definition that ties multiple skills together.',
      arguments: [
        KernelPromptArgument(
          name: 'processId',
          description: 'Process id to create',
          required: true,
        ),
        KernelPromptArgument(
          name: 'goal',
          description: 'Goal the pipeline should achieve',
          required: true,
        ),
      ],
      handler: (args) async {
        return KernelGetPromptResult(
          description: 'process compose brief',
          messages: [
            KernelPromptMessage(
              role: 'user',
              content: KernelTextContent(
                text: '''
Define a process matching the goal below.
id: ${args['processId']}
goal: ${args['goal']}

Procedure:
1. Use `skill_list` to inspect available skills.
2. For each step toward the goal, design which skill to assign to which member.
3. Place any required Gates (philosophy / quality / approval) between steps.
4. Process YAML format: `workspaces/<ws>/processes/<id>.yaml` — id, title, steps[], gates[], trigger.
5. After saving, verify via `process_list` and run via `process_start`.
''',
              ),
            ),
          ],
        );
      },
    );
  }

  // --- markdown bodies ---

  static const _guideMarkdown = r'''
# makemind Ops — LLM Usage Guide

This app is a **virtual organization platform built on the flowbrain knowledge system**. The user (or an LLM) creates workspaces, places members (AI agents + people), and defines tasks and processes that run repeatedly. External web systems are reached via `mcp_browser`, member-to-member communication via `mcp_channel`, and knowledge ingestion via `mcp_ingest`.

## When an LLM first encounters this app

1. `makemind-ops://state` (resource) — Inspect the current active workspace and counts of members / tasks / processes / bundles / skills.
2. `makemind-ops://concepts` — Learn the core concepts.
3. `makemind-ops://tool-catalog` — Skim the tool catalog.
4. `tools/list` — Directly list MCP standard tools.

## What you can do

- **Workspace CRUD**: `workspace_list/create/switch/delete`
- **Members**: `member_list/create_agent`
- **Tasks**: `task_list/create/run/cancel`
- **Processes**: `process_list/start/resume/approve/cancel`
- **Bundles**: `bundle_list/installed/install/uninstall`
- **Knowledge**: `knowledge_save/query/ingest_file`
- **Skills**: `skill_list/get/save/generate` — 3-layer (template → workspace → agent)
- **Config**: `config_get/set_chromium/set_llm_provider/set_storage/set_mcp_outbound`
- **External web operations**: 9 browser primitives (`page_view`, `extract`, `submit_form`, `crawl`, `web_search`, `monitor`, `page_audit_role`, `download`, `page_compare_actors`)

## Core rules

1. Before any write, read `makemind-ops://state` once to understand the current state.
2. Skills are resolved through a **3-layer** lookup. The same id can behave differently per agent. Use this to **personalize agents**.
3. Skills are not static. You can add or modify them anytime with `skill_save(scope=workspace|agent)`. An LLM may author and inject them directly.
4. After completing a task, record the fact in FactGraph via `knowledge_save` so **organizational knowledge accumulates**.
5. On errors, look up the code meaning in `makemind-ops://error-codes`.
''';

  static const _conceptsMarkdown = r'''
# Core Concepts

## Workspace
The data boundary for a virtual organization, team, project, or individual. Multiple workspaces coexist in one app instance; people and agents can belong to many workspaces N:M. Types: `org`, `personal`, `project`.

## Member
A workspace member. Two kinds:
- **Person**: A human. Carries only an identifier + email + role labels.
- **Agent (AI)**: A combination of FlowBrain's Profile (tone) + Skill set (capabilities) + Philosophy (principles) + AuthProfile (external system sessions). Grows with operational history.

## Skill
A unit capability an agent performs. YAML definition:
- `id`, `version`, `description`, `inputSchema`, `outputSchema`
- `actionBody` — kind (llm · browser · mcp · fact.save · fact.query · ingest · channel · composite · map) + steps. (Form rendering = host `form.*` tools via a `kind: mcp` step.)

**3-layer resolution order**:
1. agent overlay: `workspaces/<ws>/members/<agentId>/skills/<id>.yaml` (individual)
2. workspace override: `workspaces/<ws>/skills/<id>.yaml` (organization shared)
3. template: app built-ins + installed bundle `skills/` (global default)

## Task
- Short-term (oneOff), recurring (cron), or sustained
- Defined by one or more assignees (members) and skillIds
- Run manually via `task_run`; recurring tasks fire automatically from the internal scheduler

## Process
A collaborative workflow where multiple members participate sequentially. Each step assigns an assignee/skill, with optional Gates (philosophy / quality / approval) in between. Can be paused and resumed via checkpoints.

## Bundle
A reusable knowledge pack (McpBundle schema). Install = copy bundle files into the workspace + register skills into AppSkillRegistry. Multiple bundles can be layered in one workspace.

## FactGraph (Fact)
flowbrain's L0 knowledge store. `knowledge_save`, skill execution events, messages, etc. accumulate as Evidence → Candidate → Fact → Summary → Pattern. The foundation for agent growth and organizational knowledge.

## 3-layer scope (Profile and Philosophy follow the same model as Skills)
- template: global default
- workspace: organization-shared override
- agent: individual overlay — evolves into its own version as the agent operates
''';

  static const _workflowsMarkdown = r'''
# Common Workflows

## 1) Set up a new organization
```
workspace_create { type: "org", slug: "acme", title: "ACME Corp" }
bundle_list
bundle_install { bundleId: "makemind-dev-ops" }   # install needed bundles
member_list
member_create_agent {
  id: "editor",
  displayName: "Default editor",
  profileRef: "profiles/editor-default",
  skillIds: ["content_draft", "content_translate"],
  philosophyRef: "philosophies/editorial-core"
}
```

## 2) An external LLM (you) authoring an organization-shared skill
```
# 1. Inspect current skills
skill_list {}

# 2. Write YAML and save
skill_save {
  scope: "workspace",
  yaml: "id: weekly_digest\nversion: 1\n..."
}

# 3. Verify
skill_get { skillId: "weekly_digest" }
```

## 3) An agent-specific skill variant
```
# editor's own content_draft variant
skill_save {
  scope: "agent",
  actorId: "editor",
  yaml: "id: content_draft\nversion: 2\n# editor-specific tone\n..."
}

# Verify: compare resolution under editor vs another agent
skill_get { skillId: "content_draft", actorId: "editor" }
skill_get { skillId: "content_draft" }
```

## 4) Run a task
```
task_create {
  id: "daily-digest",
  kind: "recurring",
  title: "Daily digest",
  assigneeIds: ["editor"],
  skillIds: ["weekly_digest"],
  cron: "0 9 * * *"
}
task_run { id: "daily-digest" }
```

## 5) Multi-agent collaboration via process
```
# Process YAML lives at workspaces/<ws>/processes/ as files. To inject
# from outside, currently use filesystem operations. A `process_save`
# tool may be added later.
process_list {}
process_start { id: "content-publish", inputs: { topic: "..." } }
```

## 6) Drive external web systems (browser)
```
# Configure Chromium path (one time)
config_set_chromium { path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" }

# Open a page and capture text
page_view {
  url: "https://example.com",
  actor: "editor",
  capture: ["text", "screenshot"]
}

# Submit a form
submit_form {
  url: "https://admin.example.com/posts/new",
  steps: [
    { selector: "input[name=title]", action: "type", value: "..." },
    { selector: "button[type=submit]", action: "click" }
  ]
}
```

## 7) Ingest knowledge
```
knowledge_save {
  category: "company_policy",
  key: "expense_limit",
  value: "Expenses above 3M KRW require dual approval"
}
knowledge_ingest_file {
  path: "/Users/me/docs/company_handbook.pdf",
  category: "policy"
}
knowledge_query { question: "What is the spending approval limit?", limit: 5 }
```
''';

  static const _toolCatalogMarkdown = r'''
# Tool Catalog

## Config
- `config_get` — return the full config.yaml
- `config_set_chromium` — Chromium path
- `config_set_llm_provider` — internal LLM provider + apiKey + model (empty apiKey removes it)
- `config_set_storage` — Local KV path
- `config_set_mcp_outbound` — add or replace an external MCP server

## Workspace
- `workspace_list` / `workspace_create` / `workspace_delete` / `workspace_switch`

## Member
- `member_list` / `member_create_agent`

## Task
- `task_list` / `task_create` / `task_run` / `task_cancel`

## Process
- `process_list` / `process_start` / `process_resume` / `process_approve` / `process_cancel`

## Bundle
- `bundle_list` (catalog) / `bundle_installed` (current ws) / `bundle_install` / `bundle_uninstall`

## Skill (dynamic)
- `skill_list` — visible skills based on current ws + actor, with scope shown
- `skill_get` — final YAML resolved in agent → workspace → template order
- `skill_save` — save YAML at scope=workspace|agent
- `skill_generate` — generate YAML via the internal LLM and save

## Knowledge (FactGraph)
- `knowledge_save` / `knowledge_query` / `knowledge_ingest_file`

## Content skills (provided by bundles)
- `content_draft` / `content_translate` / `content_review` / `content_publish` / `content_check_duplicate` / `content_plan_suggest` / `quality_appraise`

## Ads skills (provided by bundles)
- `ad_review` / `ad_publish`

## Status
- `status_snapshot` / `status_report` / `skill_list`

## Browser primitives (mcp_browser)
- `page_view` / `page_audit_role` / `web_search` / `extract` / `crawl` / `monitor` / `submit_form` / `download` / `page_compare_actors`
''';

  static const _errorCodesMarkdown = r'''
# OpsError Codes

| Code | Meaning | Resolution |
|------|---------|------------|
| E1001 | Failed to read config file | Check path/permissions |
| E1002 | Argument validation failure | Check field types and required values |
| E1003 | MCP transport init failure | Check whether the port is already bound |
| E1004 | flowbrain init failure | See logs |
| E1006 | Capability disabled / unknown tool | Enable via `config_set_*`, verify tool name |
| E1007 | Chromium launch failure | Check the `config_set_chromium` path |
| E1008 | Capability runtime error | See the underlying exception detail |
| E2001 | No active workspace | `workspace_switch` |
| E2002 | Workspace id collision/format error | Re-check slug/type |
| E3001 | Philosophy hard prohibition | The action is forbidden — review the policy document |
| E8000+ | Skill execution | Definition/inputs mismatch or runtime error |
| E9999 | Unexpected error | Inspect the stack trace |
''';

  static const _skillSchemaMarkdown = r'''
# Skill YAML Schema

```yaml
id: content_draft            # required: skill identifier
version: 1                   # integer
description: |               # skill description (basis for an LLM to decide when to use it)
  Generate a site content draft.
inputSchema:                 # JSON Schema
  type: object
  properties:
    title:    { type: string }
    category: { type: string }
    body:     { type: string }
  required: [title, category]
outputSchema:
  type: object
  properties:
    postId:  { type: string }
    summary: { type: string }
actionBody:
  kind: composite            # llm | browser | mcp | fact.save | fact.query
                             # | ingest | form | channel | composite | map | noop
  steps:                     # executed sequentially when composite
    - kind: llm
      id: draft               # step identifier (referenced by other steps)
      output: draft           # this step's result becomes ctx.step.draft
      prompt: |
        Write a draft under the conditions...
        Title: {{ in.title }}
        Category: {{ in.category }}
      maxTokens: 2000
    - kind: fact.save
      category: draft_created
      inputs:
        content: "{{ step.draft.text }}"
budget:
  llmTokens: 3000
  timeMs: 30000
tags: [content, write]
```

## Template substitution

- `{{ in.xxx }}` — skill inputs
- `{{ step.<id>.<field> }}` — output of a prior step
- `{{ actor }}`, `{{ workspace }}` — execution context

## Supported action kinds

| kind | behavior |
|------|----------|
| `llm` | `system.ports.llm.complete(prompt, temperature, maxTokens)` → returns text |
| `browser` | `operations.get(operation).handler(inputs)` — 9 primitives |
| `mcp` | Call a tool on an external MCP server (`server`, `tool`, inputs) |
| `fact.save` | Add Evidence to FactGraph |
| `fact.query` | FactFacade.queryFacts (workspaceId auto-applied) |
| `ingest` | File path → host `ingest.run` chunking → flowbrain FactFacade |
| `mcp` (`form.*`) | Render a document via the host form capability |
| `channel` | Send a notification/message |
| `composite` | Run multiple steps sequentially |
| `map` | Return inputs as-is wrapped in `{value: inputs}` (for transformation) |
| `noop` | Return an empty map |

## Storage paths

- `scope: workspace` → `workspaces/<ws>/skills/<id>.yaml` (organization shared)
- `scope: agent` → `workspaces/<ws>/members/<actorId>/skills/<id>.yaml` (individual)
''';

  static const _gettingStartedPrompt = r'''
You are an LLM newly connected to makemind Ops. Before using any tool, follow this order to orient yourself.

1. `resources/read` makemind-ops://guide (full usage)
2. `resources/read` makemind-ops://concepts (concepts)
3. `resources/read` makemind-ops://state (current state)
4. `tools/list` to enumerate executable tools
5. Plan tool calls that match the user's goal
6. Before each tool call, verify required arguments, permissions, and prerequisites
7. After every state change, re-verify by reading `makemind-ops://state`

Hard rules:
- When authoring a new skill, choose agent/workspace scope deliberately — agent overlay personalizes; workspace impacts the whole organization.
- External web operations must run only inside an agent context that holds an AuthProfile for that site.
- A personal workspace (type=personal) operates independently of organization policy.
- When saving knowledge, use a meaningful category (e.g. policy, culture, reference, skill_evolution).
''';
}
