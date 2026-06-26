import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart'
    show
        AgentAxis,
        AgentForkSource,
        ForkSource,
        ModelSpec,
        PoolForkSource,
        Procedure,
        SkillBundle,
        SkillManifest;
import 'package:mcp_bundle/mcp_bundle.dart' as bundle;
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart' show BuiltinToolRegistry;
import 'package:appplayer_studio/builtin_api.dart'
    show KernelToolResult, KernelTextContent;
import 'package:yaml/yaml.dart';

import '../config/ops_config.dart';
import '../infra/project_seed.dart' show applyOpsWorkspaceSeed;
import '../infra/ws_paths.dart';
import '../../../base/agent/agent_invoke_queue.dart';
import '../core/inbox_query.dart';
import '../init/knowledge_init.dart';
import '../ops_builtin.dart' show OpsBuiltInApp;
import '../observability/diagnostic_export.dart';
import '../portability/html_report.dart';
import '../portability/opspack.dart';
import '../registries/member_registry.dart';
import '../registries/process_registry.dart';
import '../registries/task_registry.dart';
import '../registries/workspace_registry.dart';
import '../skills/skill_definition.dart';

/// Exposes every UI-available app operation as an MCP tool so internal
/// (built-in) and external LLMs can drive the app over MCP on equal footing.
class SystemTools {
  SystemTools({required KnowledgeInit init}) : _bootInit = init;

  /// Boot-time init captured at `registerHostTools` (standalone, before a
  /// project is bound). Handlers must NOT use this directly — they read
  /// [init], a getter that prefers the project-bound live init. Using the
  /// captured one is the stale-init bug (`workspacesRoot not bound`).
  final KnowledgeInit _bootInit;

  /// Project-bound live init when a project is open; the boot-time one
  /// otherwise. Every handler's `init.registries.*` / `init.projectRoot`
  /// resolves through this.
  KnowledgeInit get init => OpsBuiltInApp.liveInit ?? _bootInit;

  /// Register all system tools on the host endpoint via the
  /// [BuiltinToolRegistry] facade (cleanup: builtins do not see the
  /// raw `KernelServerHost` / `mcp.Server` — see
  /// `diora/design/builtin-os-cleanup-plan-2026-05-28.md`).
  void registerOn(BuiltinToolRegistry server) {
    _register(
      server,
      'config_get',
      'Return the full current settings (config.yaml) as JSON',
      const {},
      (_) async => (await OpsConfig.load()).toJson(),
    );

    _register(
      server,
      'config_set_chromium',
      'Set the Chromium executable path for the host browser engine (empty '
          'disables). The host owns the shared `browser.*` engine; the path is a '
          'host setting, picked up fresh on the next browser call.',
      const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
      },
      (args) async {
        final path = args['path'] as String?;
        // Chromium path is a host setting (the host owns the shared browser
        // engine). Route to the host settings tool instead of an ops adapter.
        await server.callTool('studio.settings.set', <String, dynamic>{
          'key': 'chromiumPath',
          'value': (path == null || path.isEmpty) ? '' : path,
        });
        return {'saved': true, 'chromiumPath': path ?? '', 'scope': 'host'};
      },
    );

    _register(
      server,
      'config_set_llm_provider',
      'Configure internal LLM provider, API key, and model (empty apiKey removes the provider)',
      const {
        'type': 'object',
        'properties': {
          'provider': {
            'type': 'string',
            'enum': ['claude', 'openai'],
          },
          'apiKey': {'type': 'string'},
          'model': {'type': 'string'},
        },
        'required': ['provider'],
      },
      (args) async {
        final cfg = await OpsConfig.load();
        final provider = args['provider'] as String;
        final apiKey = args['apiKey'] as String? ?? '';
        final model = args['model'] as String? ?? '';
        final LlmSettings updatedLlm;
        if (apiKey.isEmpty) {
          updatedLlm = const LlmSettings.empty();
        } else {
          final providers = Map<String, LlmProviderSettings>.from(
            cfg.llm.providers,
          );
          providers[provider] = LlmProviderSettings(
            apiKey: apiKey,
            model: model,
          );
          updatedLlm = LlmSettings(
            defaultProvider: provider,
            providers: providers,
            timeoutSeconds: cfg.llm.timeoutSeconds,
          );
        }
        final updated = _copyConfig(cfg, llm: updatedLlm);
        await updated.save();
        init.notifyConfigChanged(updated);
        return {'saved': true, 'provider': apiKey.isEmpty ? null : provider};
      },
    );

    _register(
      server,
      'config_set_storage',
      'Set the Local KV root path',
      const {
        'type': 'object',
        'properties': {
          'localKvPath': {'type': 'string'},
        },
        'required': ['localKvPath'],
      },
      (args) async {
        final cfg = await OpsConfig.load();
        final updated = _copyConfig(
          cfg,
          storage: StorageSettings(
            localKvPath: args['localKvPath'] as String,
            backupIntervalHours: cfg.storage.backupIntervalHours,
            retentionDays: cfg.storage.retentionDays,
          ),
        );
        await updated.save();
        init.notifyConfigChanged(updated);
        return {'saved': true};
      },
    );

    _register(
      server,
      'config_set_mcp_outbound',
      'Register an external MCP server (outbound)',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'transport': {
            'type': 'string',
            'enum': ['stdio', 'sse'],
          },
          'command': {'type': 'string'},
          'url': {'type': 'string'},
        },
        'required': ['id', 'transport'],
      },
      (args) async {
        final cfg = await OpsConfig.load();
        final newServer = OutboundMcpServer(
          id: args['id'] as String,
          transport: args['transport'] as String,
          command: args['command'] as String?,
          url: args['url'] as String?,
        );
        final existing =
            [...cfg.mcp.outbound]
              ..removeWhere((s) => s.id == newServer.id)
              ..add(newServer);
        final updated = _copyConfig(
          cfg,
          mcp: McpSettings(inbound: cfg.mcp.inbound, outbound: existing),
        );
        await updated.save();
        init.notifyConfigChanged(updated);
        return {'saved': true, 'id': newServer.id};
      },
    );

    // --- Workspace ---

    _register(server, 'workspace_list', 'List all workspaces', const {}, (
      _,
    ) async {
      final list = await init.registries.workspace.list();
      return {
        'activeId': init.registries.workspace.activeId,
        'workspaces': [
          for (final w in list)
            {
              'id': w.id,
              'type': w.type.name,
              'title': w.title,
              'members': w.members,
              'tags': w.tags,
            },
        ],
      };
    });

    _register(
      server,
      'workspace_create',
      'Create an empty workspace inside the currently bound Ops project. '
          'When `projectRoot` is supplied the workspace is materialised '
          'against that directory directly — useful when the host\'s '
          'tab-active wiring has not yet flipped to the Ops tab (the '
          'in-process shell still rebinds via `_bindProject` so both '
          'paths converge on the same on-disk layout).',
      const {
        'type': 'object',
        'properties': {
          'type': {
            'type': 'string',
            'enum': ['org', 'personal', 'project'],
          },
          'slug': {'type': 'string'},
          'title': {'type': 'string'},
          'projectRoot': {
            'type': 'string',
            'description':
                'Absolute path of the Ops project root (the directory '
                'containing `project.opsproj`). Optional — defaults to '
                'whichever project the shell most recently bound through '
                '`OpsBuiltInApp.ensureBoot`.',
          },
        },
        'required': ['type', 'slug'],
      },
      (args) async {
        final type = WorkspaceType.values.firstWhere(
          (t) => t.name == args['type'] as String,
          orElse: () => WorkspaceType.project,
        );
        final slug = args['slug'] as String;
        final title = (args['title'] as String?) ?? slug;
        final explicitRoot = (args['projectRoot'] as String?)?.trim();
        // Prefer the explicit path the caller passed in (external
        // LLMs orchestrating workspace_create over MCP know which
        // project they meant). Otherwise use the same project-bound
        // live init every other handler reads (`init` getter =
        // `OpsBuiltInApp.liveInit ?? _bootInit`). Resolving through
        // `currentBoot` (the latest `_bootFuture`) was the bug: a
        // mount / registerHostTools `ensureBoot(backbone:)` with no
        // project can finish LAST, leaving `currentBoot` UNBOUND while
        // `liveInit` (downgrade-guarded) stays bound — so every other
        // tool saw the project but `workspace_create` reported "No Ops
        // project bound".
        late KnowledgeInit liveInit;
        if (explicitRoot != null && explicitRoot.isNotEmpty) {
          liveInit = await OpsBuiltInApp.ensureBoot(
            currentProject: explicitRoot,
          ).then((r) => r.init);
        } else {
          liveInit = init;
        }
        if (liveInit.projectRoot.isEmpty) {
          return {
            'error':
                'No Ops project bound. Pass `projectRoot` or open a '
                'project in the Ops tab first.',
          };
        }
        final ws = await liveInit.registries.workspace.create(
          type: type,
          slug: slug,
          title: title,
        );
        // Materialise this workspace's `.mbd` bundle alongside the
        // operational data dir so the next boot's BundleActivation
        // loop discovers it. `applyOpsWorkspaceSeed` flattens any
        // slash in `ws.id` so the dir lands at the project root.
        try {
          await applyOpsWorkspaceSeed(liveInit.projectRoot, ws.id, title);
        } catch (_) {
          /* best-effort — registry write already succeeded */
        }
        return {'id': ws.id, 'projectRoot': liveInit.projectRoot};
      },
    );

    _register(
      server,
      'workspace_delete',
      'Delete a workspace',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
      (args) async {
        await init.registries.workspace.delete(args['id'] as String);
        return {'deleted': true};
      },
    );

    _register(
      server,
      'workspace_switch',
      'Switch the active workspace',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
      (args) async {
        final id = args['id'] as String;
        await init.switchWorkspace(id);
        // Persist the active workspace to config so it survives a re-boot
        // (boot restores from `config.activeWorkspace`) and config readers
        // (config_get / the ops.admin agent / `makemind-ops://state`) see the
        // same active workspace as the in-memory registry. Without this the
        // switch is in-memory only and is lost on the next ensureBoot.
        final cfg = await OpsConfig.load();
        if (cfg.activeWorkspace != id) {
          final updated = _copyConfig(cfg, activeWorkspace: id);
          await updated.save();
          init.notifyConfigChanged(updated);
        }
        return {'activeId': init.registries.workspace.activeId};
      },
    );

    _register(
      server,
      'workspace_rename',
      'Change a workspace id (migrates the directory, config, and KV partition). '
          'If it is the active workspace, also updates activeWorkspace in config.yaml.',
      const {
        'type': 'object',
        'properties': {
          'oldId': {'type': 'string'},
          'newId': {'type': 'string'},
          'newTitle': {'type': 'string'},
        },
        'required': ['oldId', 'newId'],
      },
      (args) async {
        final oldId = args['oldId'] as String;
        final newId = args['newId'] as String;
        final newTitle = args['newTitle'] as String?;
        final ws = await init.registries.workspace.rename(
          oldId,
          newId,
          newTitle: newTitle,
        );
        // Persist activeWorkspace rename to on-disk config as well.
        final cfg = await OpsConfig.load();
        if (cfg.activeWorkspace == oldId) {
          final updated = _copyConfig(cfg, activeWorkspace: newId);
          await updated.save();
          init.notifyConfigChanged(updated);
        }
        return {'id': ws.id, 'title': ws.title};
      },
    );

    _register(
      server,
      'workspace_update',
      'Update a workspace title, locale, timezone, or tags',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'title': {'type': 'string'},
          'locale': {'type': 'string'},
          'timezone': {'type': 'string'},
          'tags': {'type': 'object'},
        },
        'required': ['id'],
      },
      (args) async {
        final tags = (args['tags'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        );
        final ws = await init.registries.workspace.update(
          args['id'] as String,
          title: args['title'] as String?,
          locale: args['locale'] as String?,
          timezone: args['timezone'] as String?,
          tags: tags,
        );
        return {
          'id': ws.id,
          'title': ws.title,
          'locale': ws.locale,
          'timezone': ws.timezone,
          'tags': ws.tags,
        };
      },
    );
    _register(
      server,
      'workspace_share',
      'Formally grant another workspace READ-ONLY access to this workspace\'s '
          'facts under `scope` (a fact category, or `*` for all). Owner '
          'defaults to the active workspace. A workspace is a sandbox by '
          'default; this is the explicit cross-team contract — the target '
          'reads the granted scope on top of its own via `knowledge_fact_query`, '
          'the owner\'s other categories stay private. Pass `revoke:true` to '
          'remove the grant. (FR-OPS-014, formal inter-workspace share.)',
      const {
        'type': 'object',
        'properties': {
          'to': {'type': 'string'},
          'scope': {'type': 'string'},
          'ownerId': {'type': 'string'},
          'revoke': {'type': 'boolean'},
        },
        'required': ['to'],
      },
      (args) async {
        final owner =
            (args['ownerId'] as String?) ?? init.registries.workspace.activeId;
        if (owner == null || owner.isEmpty) {
          return {'error': 'no active workspace'};
        }
        final to = args['to'] as String;
        final scope = (args['scope'] as String?) ?? '*';
        if (args['revoke'] == true) {
          final ws = await init.registries.workspace.revokeShare(
            owner,
            to,
            scope: args['scope'] as String?,
          );
          return {
            'owner': ws.id,
            'revoked': {'to': to, 'scope': args['scope'] ?? '*'},
            'shares': [for (final g in ws.shares) g.toMap()],
          };
        }
        final ws = await init.registries.workspace.grantShare(
          owner,
          to,
          scope: scope,
        );
        return {
          'owner': ws.id,
          'granted': {'to': to, 'scope': scope, 'mode': 'read'},
          'shares': [for (final g in ws.shares) g.toMap()],
        };
      },
    );
    _register(
      server,
      'workspace_shares',
      'List share grants for a workspace: `out` = scopes this workspace '
          'exposes to others, `in` = scopes other workspaces expose to it. '
          'Defaults to the active workspace.',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
      },
      (args) async {
        final id =
            (args['id'] as String?) ?? init.registries.workspace.activeId;
        if (id == null || id.isEmpty) return {'error': 'no active workspace'};
        final ws = await init.registries.workspace.get(id);
        final incoming = await init.registries.workspace.incomingShares(id);
        return {
          'workspace': id,
          'out': [for (final g in (ws?.shares ?? const [])) g.toMap()],
          'in': [
            for (final s in incoming)
              {'from': s.fromWorkspaceId, 'scope': s.scope},
          ],
        };
      },
    );
    _register(
      server,
      'workspace_set_parent',
      'Set (or clear) a workspace\'s organization parent — the workspace it '
          'reports to. Builds the org hierarchy axis (e.g. a team workspace '
          'reports to a division workspace). Pass empty/omit `parentId` to '
          'detach. Rejects a missing parent or a cycle. The ancestor chain is '
          'the approval escalation path. (FR-OPS-014, org hierarchy.)',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'parentId': {'type': 'string'},
        },
        'required': ['id'],
      },
      (args) async {
        try {
          final ws = await init.registries.workspace.setParent(
            args['id'] as String,
            args['parentId'] as String?,
          );
          return {'id': ws.id, 'parentId': ws.parentId};
        } on StateError catch (e) {
          return {'error': e.message};
        }
      },
    );
    _register(
      server,
      'workspace_tree',
      'Organization view for a workspace: `ancestors` (escalation chain, '
          'nearest parent first) and `children` (direct reports). Defaults to '
          'the active workspace.',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
      },
      (args) async {
        final id =
            (args['id'] as String?) ?? init.registries.workspace.activeId;
        if (id == null || id.isEmpty) return {'error': 'no active workspace'};
        final ws = await init.registries.workspace.get(id);
        final ancestors = await init.registries.workspace.ancestors(id);
        final children = await init.registries.workspace.children(id);
        return {
          'workspace': id,
          'parentId': ws?.parentId,
          'ancestors': ancestors,
          'children': children,
        };
      },
    );

    // --- Members ---

    _register(
      server,
      'member_list',
      'List members of the current workspace',
      const {},
      (_) async {
        final wsId = init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};
        final members = await init.registries.member.listForWorkspace(wsId);
        return {
          'workspace': wsId,
          'members': [
            for (final m in members)
              {'id': m.id, 'kind': m.kind.name, 'displayName': m.displayName},
          ],
        };
      },
    );

    _register(
      server,
      'member_get',
      'Fetch a single member by id from the active workspace (or workspaceId).',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'workspaceId': {'type': 'string'},
        },
        'required': ['id'],
      },
      (args) async {
        final wsId =
            (args['workspaceId'] as String?) ??
            init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};
        final m = await init.registries.member.get(args['id'] as String);
        if (m == null) return {'error': 'member not found', 'id': args['id']};
        return {
          'id': m.id,
          'kind': m.kind.name,
          'displayName': m.displayName,
          if (m is AgentMember) 'profileRef': m.profileRef,
          if (m is AgentMember) 'skillIds': m.skillIds,
          if (m is AgentMember) 'philosophyRef': m.philosophyRef,
          if (m is AgentMember && m.model != null) 'model': m.model!.toJson(),
          if (m is PersonMember) 'email': m.email,
          if (m is PersonMember) 'roleLabels': m.roleLabels,
          'tags': m.tags,
        };
      },
    );

    _register(
      server,
      'member_create_agent',
      'Create an AI agent in the active workspace. `provider` + `model` '
          'select the per-agent ModelSpec (catalog ids in '
          'lib/util/llm_model_catalog.dart). When omitted, the agent is '
          'created without an explicit ModelSpec — boot resolves to '
          'OpsConfig.llm.defaultProvider, then `stub/stub-1`.',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'displayName': {'type': 'string'},
          'profileRef': {'type': 'string'},
          'skillIds': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'philosophyRef': {'type': 'string'},
          'provider': {
            'type': 'string',
            'description': 'LLM provider id (claude | openai | stub).',
          },
          'model': {
            'type': 'string',
            'description':
                'Model id matching the provider (e.g. claude-sonnet-4-6, gpt-4o).',
          },
          'maxTokens': {'type': 'integer'},
          'temperature': {'type': 'number'},
        },
        'required': ['id', 'displayName'],
      },
      (args) async {
        final wsId = init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};
        // Single-call path: MemberRegistry.createAgent persists the yaml,
        // mirrors into flowbrain, and runs the 4-axis tryAssign* sweep —
        // duplicating any of those steps here would double-create the
        // flowbrain Agent and throw on the second `create`.
        final providerArg = (args['provider'] as String?)?.trim();
        final modelArg = (args['model'] as String?)?.trim();
        final modelSpec =
            (providerArg != null &&
                    providerArg.isNotEmpty &&
                    modelArg != null &&
                    modelArg.isNotEmpty)
                ? ModelSpec(
                  provider: providerArg,
                  model: modelArg,
                  maxTokens: (args['maxTokens'] as num?)?.toInt(),
                  temperature: (args['temperature'] as num?)?.toDouble(),
                )
                : null;
        final agent = await init.registries.member.createAgent(
          id: args['id'] as String,
          // Project + workspace scoped kernel id (member.id stays bare for
          // display) so the adopted host KnowledgeSystem isolates this
          // project's agent + owned forks from other projects.
          agentId: _scopedAgentId(init, wsId, args['id'] as String),
          displayName: args['displayName'] as String,
          profileRef: (args['profileRef'] as String?) ?? 'profiles/default',
          skillIds: (args['skillIds'] as List?)?.cast<String>() ?? const [],
          philosophyRef:
              (args['philosophyRef'] as String?) ?? 'philosophies/default',
          workspaceId: wsId,
          model: modelSpec,
        );
        // P2 (additive) — persist the agent's knowledge definition into
        // the workspace `.mbd` via the universal `studio.builder.addAgent`
        // host tool (sanctioned builtin→host chain — see
        // `BuiltinToolRegistry.callTool`). On reload `BundleActivation`
        // re-registers it. `_system` is not a bundle, so its agents seed
        // the shared `project.mbd` pool. Best-effort: the live
        // `system.agents` + member yaml (createAgent above) already hold
        // the agent this session — a manifest-write failure must not break
        // creation. The agent map uses the canonical `AgentDefinition`
        // shape (`name`/`model`/`profileIds`), which `AgentDefinition`
        // `.fromJson` reads (the tool stores the map verbatim).
        final projRoot = init.projectRoot;
        if (projRoot.isNotEmpty) {
          final targetMbd =
              wsId == '_system'
                  ? '$projRoot/project.mbd'
                  : wsContentRoot(projRoot, wsId);
          try {
            await server.callTool('studio.builder.addAgent', {
              'mbdPath': targetMbd,
              'agent': <String, dynamic>{
                'id': agent.agentId,
                'name': agent.displayName,
                'role': 'worker',
                if (agent.skillIds.isNotEmpty) 'skillIds': agent.skillIds,
                if (agent.profileRef.isNotEmpty)
                  'profileIds': <String>[agent.profileRef],
                if (agent.philosophyRef.isNotEmpty)
                  'philosophyIds': <String>[agent.philosophyRef],
                if (modelSpec != null)
                  'model': <String, dynamic>{
                    'provider': modelSpec.provider,
                    'model': modelSpec.model,
                    if (modelSpec.maxTokens != null)
                      'maxTokens': modelSpec.maxTokens,
                    if (modelSpec.temperature != null)
                      'temperature': modelSpec.temperature,
                  },
              },
            });
          } catch (_) {
            // Best-effort — see note above.
          }
        }
        return {
          'id': agent.id,
          if (modelSpec != null) 'model': modelSpec.toJson(),
        };
      },
    );

    _register(
      server,
      'agent_ask',
      'Send one user-turn message to an agent and get its reply.',
      const {
        'type': 'object',
        'properties': {
          'agentId': {'type': 'string'},
          'message': {'type': 'string'},
        },
        'required': ['agentId', 'message'],
      },
      (args) async {
        if (!init.system.isAgentSubsystemActivated) {
          return {'error': 'Agent Subsystem not activated'};
        }
        final resolvedId = await _resolveAgentId(
          init,
          args['agentId'] as String,
        );
        // Serialize per agent — concurrent requests to the same agent queue
        // and run one at a time (worker model + conversation race-free).
        final reply = await serializePerAgent(
          resolvedId,
          () => init.system.agents.ask(resolvedId, args['message'] as String),
        );
        return {
          'agentId': reply.agentId,
          'content': reply.content,
          'model': reply.model,
          if (reply.finishReason != null) 'finishReason': reply.finishReason,
        };
      },
    );

    _register(
      server,
      'agent_route',
      'Ask a manager-role agent to route a request to the best worker.',
      const {
        'type': 'object',
        'properties': {
          'managerId': {'type': 'string'},
          'request': {'type': 'string'},
          'candidateAgentIds': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
        'required': ['managerId', 'request'],
      },
      (args) async {
        if (!init.system.isAgentSubsystemActivated) {
          return {'error': 'Agent Subsystem not activated'};
        }
        final decision = await init.system.agents.route(
          args['managerId'] as String,
          args['request'] as String,
          candidateAgentIds:
              (args['candidateAgentIds'] as List?)?.cast<String>(),
        );
        return {
          'targetAgentId': decision.targetAgentId,
          'confidence': decision.confidence,
          if (decision.reason != null) 'reason': decision.reason,
        };
      },
    );

    _register(
      server,
      'agent_assign_skill',
      'Fork a skill into an agent. Source is either the workspace pool '
          '(pass `skillId`) or another agent\'s already-evolved owned fork '
          '(pass `fromAgentId` + `fromForkedRef`) — the latter is the '
          'transfer path so a new agent can start from another agent\'s '
          'grown instance instead of the pool seed.',
      const {
        'type': 'object',
        'properties': {
          'agentId': {'type': 'string'},
          'skillId': {
            'type': 'string',
            'description':
                'Pool skill id. Mutually exclusive with '
                '`fromAgentId`/`fromForkedRef`.',
          },
          'fromAgentId': {
            'type': 'string',
            'description':
                'Source agent id when transferring from '
                'another agent\'s owned fork.',
          },
          'fromForkedRef': {
            'type': 'string',
            'description': 'Source forkedRef on the source agent.',
          },
        },
        'required': ['agentId'],
      },
      (args) async {
        if (!init.system.isAgentSubsystemActivated) {
          return {'error': 'Agent Subsystem not activated'};
        }
        final agentId = args['agentId'] as String;
        final fromAgentId = args['fromAgentId'] as String?;
        final fromForkedRef = args['fromForkedRef'] as String?;
        final skillId = args['skillId'] as String?;

        ForkSource source;
        if (fromAgentId != null && fromForkedRef != null) {
          source = AgentForkSource(
            agentId: fromAgentId,
            axis: AgentAxis.skill,
            forkedRef: fromForkedRef,
          );
        } else if (skillId != null && skillId.isNotEmpty) {
          // appSkills / UI surface the raw skill id, but the fork pool
          // keys skills by their `BundleActivation` exposed id
          // (`<bundleId>.<rawId>`). Workspace skills mirror into the
          // shared `project.mbd`, so qualify a bare id with that bundle
          // for the pool lookup to resolve. An already-qualified id
          // (contains a dot) is passed through unchanged.
          final poolBundle = init.sharedPoolBundleId;
          final poolId =
              (!skillId.contains('.') && poolBundle != null)
                  ? '$poolBundle.$skillId'
                  : skillId;
          source = PoolForkSource(poolId);
        } else {
          return {
            'error':
                'Provide either `skillId` (pool source) or both `fromAgentId` '
                'and `fromForkedRef` (transfer from another agent).',
          };
        }
        // Resolve the caller id (bare local id from MCP, or the stored
        // kernel id from the UI) to the member + its scoped kernel agentId so
        // the fork lands on this project's agent, not a same-named agent in
        // another project (the shared host system keys forks by agentId).
        final assignMember = await init.registries.member.get(agentId);
        final kernelAgentId =
            assignMember is AgentMember ? assignMember.agentId : agentId;
        final ok = await init.system.agents.tryAssignSkill(
          kernelAgentId,
          source,
        );
        // Mirror a successful pool assignment onto the member record so the
        // Members list skill count reflects it. The owned fork lives in the
        // Agent Subsystem (AgentDetailView shows it with lineage);
        // `member.skillIds` is the declarative list the Members card reads —
        // `createAgent` seeds both the same way (skillIds + tryAssign sweep),
        // so the post-creation `agent_assign_skill` path must keep them in
        // sync too. Pool source only (a transfer's forkedRef is an evolved
        // instance, not a bare pool id). Best-effort: a missing member (the
        // agent isn't an Ops member) or registry error must not undo the
        // already-succeeded fork.
        if (ok && skillId != null && skillId.isNotEmpty) {
          try {
            final wsId = init.registries.workspace.activeId;
            final m = assignMember;
            if (wsId != null &&
                m is AgentMember &&
                !m.skillIds.contains(skillId)) {
              await init.registries.member.update(
                memberId: m.id,
                workspaceId: wsId,
                skillIds: <String>[...m.skillIds, skillId],
              );
            }
          } catch (_) {
            // Best-effort — the card count is cosmetic; the fork succeeded.
          }
        }
        return {'assigned': ok, 'source': source.encode()};
      },
    );

    _register(
      server,
      'agent_get_history',
      'Return the conversation history of an agent (most recent first).',
      const {
        'type': 'object',
        'properties': {
          'agentId': {'type': 'string'},
          'limit': {'type': 'integer'},
        },
        'required': ['agentId'],
      },
      (args) async {
        if (!init.system.isAgentSubsystemActivated) {
          return {'error': 'Agent Subsystem not activated'};
        }
        final history = await init.system.agents.getHistory(
          await _resolveAgentId(init, args['agentId'] as String),
          limit: args['limit'] as int?,
        );
        return {
          'turns': [
            for (final t in history)
              {
                'userMessage': t.userMessage,
                'assistantReply': t.assistantReply,
                'model': t.model,
                'timestamp': t.timestamp.toIso8601String(),
              },
          ],
        };
      },
    );

    _register(
      server,
      'system_agent_set_model',
      'Update the model used by the system administrator (chat) agent. '
          'Defaults to id="_ops_admin" — pass `agentId` to target a custom '
          'system agent.',
      const {
        'type': 'object',
        'properties': {
          'provider': {'type': 'string'},
          'model': {'type': 'string'},
          'agentId': {'type': 'string'},
        },
        'required': ['provider', 'model'],
      },
      (args) async {
        if (!init.system.isAgentSubsystemActivated) {
          return {'error': 'Agent Subsystem not activated'};
        }
        final agentId = await _resolveAgentId(
          init,
          (args['agentId'] as String?) ?? '_ops_admin',
        );
        final updated = await init.system.agents.updateAgent(
          agentId,
          model: ModelSpec(
            provider: args['provider'] as String,
            model: args['model'] as String,
          ),
        );
        return {
          'id': updated.id,
          'model': '${updated.model.provider}/${updated.model.model}',
        };
      },
    );

    _register(
      server,
      'member_add_person',
      'Add a person member (to the active workspace)',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'displayName': {'type': 'string'},
          'email': {'type': 'string'},
          'roleLabels': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
        'required': ['id', 'displayName'],
      },
      (args) async {
        final wsId = init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};
        final p = await init.registries.member.addPerson(
          id: args['id'] as String,
          displayName: args['displayName'] as String,
          email: args['email'] as String?,
          roleLabels: (args['roleLabels'] as List?)?.cast<String>() ?? const [],
          workspaceId: wsId,
        );
        return {'id': p.id};
      },
    );

    _register(
      server,
      'member_capture_auth',
      'Register an agent\'s AuthProfileRef (member linkage only). '
          'The browser capture + seal is done by the host `browser.auth_capture` '
          'tool; this records the resulting reference on the member.',
      const {
        'type': 'object',
        'properties': {
          'memberId': {'type': 'string'},
          'systemId': {'type': 'string'},
        },
        'required': ['memberId', 'systemId'],
      },
      (args) async {
        final ref = await init.registries.member.captureAuthProfile(
          memberId: args['memberId'] as String,
          systemId: args['systemId'] as String,
        );
        return {
          'memberId': args['memberId'],
          'systemId': ref.systemId,
          'fileRef': ref.fileRef,
          if (ref.capturedAt != null)
            'capturedAt': ref.capturedAt!.toIso8601String(),
        };
      },
    );

    _register(
      server,
      'member_update',
      'Update a member\'s name, profile, skills, philosophy, email, roles, '
          'tags, or — for agents — their LLM ModelSpec. `provider` + `model` '
          'must be supplied together when changing the ModelSpec; passing '
          'only one is rejected. Defaults to the active workspace when '
          'workspaceId is omitted.',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'workspaceId': {'type': 'string'},
          'displayName': {'type': 'string'},
          'profileRef': {'type': 'string'},
          'skillIds': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'philosophyRef': {'type': 'string'},
          'email': {'type': 'string'},
          'roleLabels': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'tags': {'type': 'object'},
          'provider': {'type': 'string'},
          'model': {'type': 'string'},
          'maxTokens': {'type': 'integer'},
          'temperature': {'type': 'number'},
        },
        'required': ['id'],
      },
      (args) async {
        final wsId =
            (args['workspaceId'] as String?) ??
            init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};
        final tags = (args['tags'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        );
        final providerArg = (args['provider'] as String?)?.trim();
        final modelArg = (args['model'] as String?)?.trim();
        final hasProvider = providerArg != null && providerArg.isNotEmpty;
        final hasModel = modelArg != null && modelArg.isNotEmpty;
        if (hasProvider != hasModel) {
          return {
            'error':
                'provider and model must be supplied together (got provider=$hasProvider, model=$hasModel)',
          };
        }
        final modelSpec =
            hasProvider && hasModel
                ? ModelSpec(
                  provider: providerArg,
                  model: modelArg,
                  maxTokens: (args['maxTokens'] as num?)?.toInt(),
                  temperature: (args['temperature'] as num?)?.toDouble(),
                )
                : null;
        final m = await init.registries.member.update(
          memberId: args['id'] as String,
          workspaceId: wsId,
          displayName: args['displayName'] as String?,
          profileRef: args['profileRef'] as String?,
          skillIds: (args['skillIds'] as List?)?.cast<String>(),
          philosophyRef: args['philosophyRef'] as String?,
          email: args['email'] as String?,
          roleLabels: (args['roleLabels'] as List?)?.cast<String>(),
          tags: tags,
          model: modelSpec,
        );
        return {
          'id': m.id,
          'displayName': m.displayName,
          'kind': m.kind.name,
          if (m is AgentMember && m.model != null) 'model': m.model!.toJson(),
        };
      },
    );

    _register(
      server,
      'member_delete',
      'Delete a member (remove from workspaceId). Members with the same id in other workspaces are unaffected.',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'workspaceId': {'type': 'string'},
        },
        'required': ['id'],
      },
      (args) async {
        final wsId =
            (args['workspaceId'] as String?) ??
            init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};
        await init.registries.member.deleteMember(args['id'] as String, wsId);
        return {'deleted': true, 'id': args['id'], 'workspace': wsId};
      },
    );

    _register(
      server,
      'member_attach',
      'Attach an existing member to another workspace (N:M sharing).',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'toWorkspace': {'type': 'string'},
        },
        'required': ['id', 'toWorkspace'],
      },
      (args) async {
        await init.registries.member.attachToWorkspace(
          args['id'] as String,
          args['toWorkspace'] as String,
        );
        return {'attached': true};
      },
    );

    _register(
      server,
      'member_detach',
      'Detach a member from a specific workspace. Memberships in other workspaces are preserved.',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'fromWorkspace': {'type': 'string'},
        },
        'required': ['id', 'fromWorkspace'],
      },
      (args) async {
        await init.registries.member.detachFromWorkspace(
          args['id'] as String,
          args['fromWorkspace'] as String,
        );
        return {'detached': true};
      },
    );

    _register(
      server,
      'member_global_list',
      'Global list of members across all workspaces. '
          'If the same id is attached to multiple workspaces, all are listed in the workspaces array.',
      const {
        'type': 'object',
        'properties': {
          'kind': {
            'type': 'string',
            'enum': ['agent', 'person'],
          },
          'query': {
            'type': 'string',
            'description': 'Name/id substring filter',
          },
        },
      },
      (args) async {
        final kindFilter = args['kind'] as String?;
        final q = (args['query'] as String?)?.toLowerCase();
        final wsList = await init.registries.workspace.list();
        final byId = <String, Map<String, dynamic>>{};
        for (final ws in wsList) {
          final members = await init.registries.member.listForWorkspace(ws.id);
          for (final m in members) {
            if (kindFilter != null && m.kind.name != kindFilter) continue;
            if (q != null &&
                !m.id.toLowerCase().contains(q) &&
                !m.displayName.toLowerCase().contains(q)) {
              continue;
            }
            final entry = byId.putIfAbsent(m.id, () {
              final base = <String, dynamic>{
                'id': m.id,
                'kind': m.kind.name,
                'displayName': m.displayName,
                'tags': m.tags,
                'workspaces': <String>[],
              };
              if (m is AgentMember) {
                base['profileRef'] = m.profileRef;
                base['philosophyRef'] = m.philosophyRef;
                base['skillIds'] = m.skillIds;
              } else if (m is PersonMember) {
                base['email'] = m.email;
                base['roleLabels'] = m.roleLabels;
              }
              return base;
            });
            (entry['workspaces'] as List).add(ws.id);
          }
        }
        return {'members': byId.values.toList(), 'total': byId.length};
      },
    );

    // --- Tasks ---

    _register(
      server,
      'task_list',
      'List tasks in the current workspace',
      const {},
      (_) async {
        final wsId = init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};
        final tasks = await init.registries.task.list(wsId: wsId);
        return {
          'workspace': wsId,
          'tasks': [
            for (final t in tasks)
              {
                'id': t.id,
                'kind': t.kind.name,
                'title': t.title,
                'state': t.state.name,
                'assigneeIds': t.assigneeIds,
                'skillIds': t.skillIds,
                'cron': t.schedule?.cron,
              },
          ],
        };
      },
    );

    _register(
      server,
      'task_get',
      'Fetch a single task by id (full record including runs).',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
      (args) async {
        final t = await init.registries.task.get(args['id'] as String);
        if (t == null) return {'error': 'task not found', 'id': args['id']};
        return {
          'id': t.id,
          'workspaceId': t.workspaceId,
          'kind': t.kind.name,
          'title': t.title,
          'state': t.state.name,
          'assigneeIds': t.assigneeIds,
          'skillIds': t.skillIds,
          'inputs': t.inputs,
          'cron': t.schedule?.cron,
          'createdAt': t.createdAt.toIso8601String(),
          'runs': t.runs.length,
        };
      },
    );

    _register(
      server,
      'task_create',
      'Create a task',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'kind': {
            'type': 'string',
            'enum': ['oneOff', 'recurring', 'sustained'],
          },
          'title': {'type': 'string'},
          'description': {'type': 'string'},
          'assigneeIds': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'skillIds': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'cron': {'type': 'string'},
          'dueAt': {
            'type': 'string',
            'description': 'ISO-8601 due timestamp (optional).',
          },
          'inputs': {'type': 'object'},
        },
        'required': ['id', 'title', 'skillIds'],
      },
      (args) async {
        final wsId = init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};
        final kind = TaskKind.values.firstWhere(
          (k) => k.name == (args['kind'] as String? ?? 'oneOff'),
          orElse: () => TaskKind.oneOff,
        );
        final description = (args['description'] as String?)?.trim();
        final dueRaw = (args['dueAt'] as String?)?.trim();
        final t = Task(
          id: args['id'] as String,
          workspaceId: wsId,
          kind: kind,
          title: args['title'] as String,
          description:
              (description == null || description.isEmpty) ? null : description,
          assigneeIds:
              (args['assigneeIds'] as List?)?.cast<String>() ?? const [],
          skillIds: (args['skillIds'] as List).cast<String>(),
          inputs: (args['inputs'] as Map?)?.cast<String, dynamic>() ?? const {},
          schedule:
              args['cron'] is String
                  ? TaskSchedule(cron: args['cron'] as String)
                  : null,
          dueAt:
              (dueRaw == null || dueRaw.isEmpty)
                  ? null
                  : DateTime.tryParse(dueRaw),
          createdAt: DateTime.now(),
        );
        await init.registries.task.create(t);
        return {'id': t.id};
      },
    );

    _register(
      server,
      'task_run',
      'Run a task immediately',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
      (args) async {
        final ref = await init.registries.task.run(args['id'] as String);
        return {'runId': ref.runId, 'endState': ref.endState.name};
      },
    );

    _register(
      server,
      'task_runs',
      'List run history for a task (start/end timestamps · final state · summary or error).',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'limit': {'type': 'integer'},
        },
        'required': ['id'],
      },
      (args) async {
        final t = await init.registries.task.get(args['id'] as String);
        if (t == null) return {'error': 'task not found', 'id': args['id']};
        final limit = (args['limit'] as int?) ?? 20;
        final runs = t.runs.reversed.take(limit).toList().reversed.toList();
        return {
          'taskId': t.id,
          'workspace': t.workspaceId,
          'runs': [
            for (final r in runs)
              {
                'runId': r.runId,
                'startedAt': r.startedAt.toIso8601String(),
                if (r.endedAt != null) 'endedAt': r.endedAt!.toIso8601String(),
                'endState': r.endState.name,
                if (r.summary != null) 'summary': r.summary,
                if (r.errorCode != null) 'errorCode': r.errorCode,
              },
          ],
        };
      },
    );

    _register(
      server,
      'task_cancel',
      'Cancel a task',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
      (args) async {
        await init.registries.task.cancel(args['id'] as String);
        return {'cancelled': true};
      },
    );

    _register(
      server,
      'task_delete',
      'Delete a task (removes both file and cache)',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
      (args) async {
        await init.registries.task.delete(args['id'] as String);
        return {'deleted': true, 'id': args['id']};
      },
    );

    _register(
      server,
      'task_update',
      'Update a task\'s state or runs. (For definition changes such as title, recreate via task_create with the same id.)',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'state': {
            'type': 'string',
            'enum': [
              'pending',
              'inProgress',
              'blocked',
              'completed',
              'cancelled',
            ],
          },
        },
        'required': ['id'],
      },
      (args) async {
        final t = await init.registries.task.get(args['id'] as String);
        if (t == null) return {'error': 'task not found: ${args['id']}'};
        final stateArg = args['state'] as String?;
        final nextState =
            stateArg == null
                ? t.state
                : TaskState.values.firstWhere(
                  (s) => s.name == stateArg,
                  orElse: () => t.state,
                );
        final updated = await init.registries.task.update(
          t.copyWith(state: nextState),
        );
        return {'id': updated.id, 'state': updated.state.name};
      },
    );

    // --- Processes ---

    _register(server, 'process_list', 'List processes', const {}, (_) async {
      final wsId = init.registries.workspace.activeId;
      if (wsId == null) return {'error': 'no active workspace'};
      final list = await init.registries.process.list(wsId: wsId);
      return {
        'processes': [
          for (final p in list)
            {
              'id': p.id,
              'title': p.title,
              'steps': p.steps.length,
              'trigger': p.trigger.name,
              'gates': p.gates.length,
              'runs': p.runs.length,
              if (p.runs.isNotEmpty) 'lastRunState': p.runs.last.state.name,
            },
        ],
      };
    });

    _register(
      server,
      'process_get',
      'Fetch a single process by id (steps · gates · trigger · run count).',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
      (args) async {
        final p = await init.registries.process.get(args['id'] as String);
        if (p == null) return {'error': 'process not found', 'id': args['id']};
        return {
          'id': p.id,
          'title': p.title,
          'trigger': p.trigger.name,
          'steps': [
            for (final s in p.steps)
              {
                'stepId': s.stepId,
                'assigneeId': s.assigneeId,
                'skillId': s.skillId,
                'inputs': s.inputs,
              },
          ],
          'gates': [
            for (final g in p.gates)
              {
                'afterStep': g.afterStep,
                'kind': g.kind.name,
                'params': g.params,
              },
          ],
          'runs': p.runs.length,
        };
      },
    );

    _register(
      server,
      'process_runs',
      'List run history for a process (start time · current step · state · '
          'pending approval · outcomes per step).',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'limit': {'type': 'integer'},
        },
        'required': ['id'],
      },
      (args) async {
        final p = await init.registries.process.get(args['id'] as String);
        if (p == null) return {'error': 'process not found', 'id': args['id']};
        final limit = (args['limit'] as int?) ?? 20;
        final all = await init.registries.process.listRuns(
          p.id,
          workspaceId: p.workspaceId,
        );
        final runs = all.reversed.take(limit).toList().reversed.toList();
        return {
          'processId': p.id,
          'workspace': p.workspaceId,
          'runs': [
            for (final r in runs)
              {
                'runId': r.runId,
                'startedAt': r.startedAt.toIso8601String(),
                'currentStep': r.currentStep,
                'state': r.state.name,
                if (r.checkpointRef != null) 'checkpointRef': r.checkpointRef,
                if (r.pendingApproval != null)
                  'pendingApproval': {
                    'afterStep': r.pendingApproval!.afterStep,
                    'approverId': r.pendingApproval!.approverId,
                    'requestedAt':
                        r.pendingApproval!.requestedAt.toIso8601String(),
                  },
                if (r.outcomes.isNotEmpty) 'outcomes': r.outcomes,
              },
          ],
        };
      },
    );

    _register(
      server,
      'process_start',
      'Start a process',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'inputs': {'type': 'object'},
        },
        'required': ['id'],
      },
      (args) async {
        final run = await init.registries.process.start(
          args['id'] as String,
          initialInputs: (args['inputs'] as Map?)?.cast<String, dynamic>(),
        );
        return {
          'runId': run.runId,
          'state': run.state.name,
          'currentStep': run.currentStep,
          'outcomes': run.outcomes,
        };
      },
    );

    _register(
      server,
      'process_resume',
      'Resume a paused process',
      const {
        'type': 'object',
        'properties': {
          'runId': {'type': 'string'},
        },
        'required': ['runId'],
      },
      (args) async {
        final run = await init.registries.process.resume(
          args['runId'] as String,
        );
        return {'state': run.state.name, 'currentStep': run.currentStep};
      },
    );

    _register(
      server,
      'process_approve',
      'Approve a process waiting for approval. approverId defaults to the '
          'gate\'s configured approver (params.approverId in the YAML); pass it '
          'explicitly only when an alternate identity needs to be asserted.',
      const {
        'type': 'object',
        'properties': {
          'runId': {'type': 'string'},
          'approverId': {'type': 'string'},
        },
        'required': ['runId'],
      },
      (args) async {
        final runId = args['runId'] as String;
        var approverId = args['approverId'] as String?;
        if (approverId == null) {
          // Default to the gate's expected approver — the run record already
          // names them via pendingApproval.
          final wsId = init.registries.workspace.activeId ?? 'default';
          final raw = await init.adapters.kv.get(
            'ws/$wsId/process_runs/$runId',
          );
          if (raw is Map && raw['pendingApproval'] is Map) {
            final pa = raw['pendingApproval'] as Map;
            approverId = pa['approverId'] as String?;
          }
          if (approverId == null) {
            return {
              'error':
                  'Run has no pendingApproval; nothing to approve. '
                  'Either the run is not in waitingApproval state, or '
                  'process_runs returned a stale snapshot.',
            };
          }
        }
        try {
          final run = await init.registries.process.approve(
            runId,
            approverId: approverId,
          );
          return {'state': run.state.name, 'approverId': approverId};
        } on ApproverMismatch catch (e) {
          // G3 — only the gate's designated approver may advance it.
          return {
            'authorized': false,
            'error': e.toString(),
            'requiredApprover': e.requiredApprover,
            'attemptedBy': e.attemptedBy,
            'afterStep': e.afterStep,
          };
        }
      },
    );

    _register(
      server,
      'process_cancel',
      'Cancel a process',
      const {
        'type': 'object',
        'properties': {
          'runId': {'type': 'string'},
        },
        'required': ['runId'],
      },
      (args) async {
        await init.registries.process.cancel(args['runId'] as String);
        return {'cancelled': true};
      },
    );
    _register(
      server,
      'approvals_pending',
      'The approval inbox — process runs across the project currently waiting '
          'for human (or org-unit) approval. A person is a team member / lead '
          'whose pending approvals only hold their own work; other processes '
          'keep running. With `approverId` set, returns only the runs that '
          'principal may act on: the gate\'s designated approver, plus (org '
          'escalation) any gate whose approver is below them in the workspace '
          'tree. Omit `approverId` to list every pending approval.',
      const {
        'type': 'object',
        'properties': {
          'approverId': {'type': 'string'},
        },
      },
      (args) async {
        final pending = await pendingApprovals(
          init,
          approverId: args['approverId'] as String?,
        );
        return {'pending': pending, 'count': pending.length};
      },
    );
    _register(
      server,
      'step_submit',
      'Mark a human-assigned process step done and continue the run. A step '
          'authored with `skillId: human` (or `manual`) is work a person — a '
          'team member — performs; the run waits at it until that person '
          'submits here. `result` records what they produced, `by` who did it. '
          'Only this run advances; other processes keep running.',
      const {
        'type': 'object',
        'properties': {
          'runId': {'type': 'string'},
          'stepId': {'type': 'string'},
          'by': {'type': 'string'},
          'result': {},
        },
        'required': ['runId', 'stepId'],
      },
      (args) async {
        final run = await init.registries.process.submitStep(
          args['runId'] as String,
          args['stepId'] as String,
          by: args['by'] as String?,
          result: args['result'],
        );
        return {'state': run.state.name, 'currentStep': run.currentStep};
      },
    );
    _register(
      server,
      'tasks_pending',
      'The task inbox — human-assigned process steps across the project that '
          'are waiting for their assignee to do the work and `step_submit`. '
          'With `assigneeId` set, returns only that person\'s tasks. A person '
          'sees their own queue; other work keeps running independently.',
      const {
        'type': 'object',
        'properties': {
          'assigneeId': {'type': 'string'},
        },
      },
      (args) async {
        final tasks = await pendingTasks(
          init,
          assigneeId: args['assigneeId'] as String?,
        );
        return {'tasks': tasks, 'count': tasks.length};
      },
    );

    _register(
      server,
      'process_save',
      'Save a process definition YAML (create/update). If the id already exists, it is overwritten.',
      const {
        'type': 'object',
        'properties': {
          'yaml': {'type': 'string'},
          'workspaceId': {'type': 'string'},
        },
        'required': ['yaml'],
      },
      (args) async {
        final wsId =
            (args['workspaceId'] as String?) ??
            init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};
        final p = await init.registries.process.saveFromYaml(
          args['yaml'] as String,
          wsId,
        );
        // P (additive) — mirror the process into the bundle's behavior
        // section so the unified behavior engine can run it. ProcessRegistry
        // still executes today; this is the Process → behavior migration
        // on-ramp (parallel to agents/skills mirrors). Best-effort: a
        // manifest-write failure must not break the save.
        final projRoot = init.projectRoot;
        if (projRoot.isNotEmpty) {
          // The behavior engine pool is project-level (`BundleActivation`
          // reads `project.mbd.behavior`), and a workspace content `.mbd`
          // carries no manifest — addBehavior there silently fails. Mirror
          // into `project.mbd` so the run exposes as
          // `<projectBundleId>.<processId>` for `bk.behavior.run` (same rule
          // as the skill pool mirror).
          final targetMbd = '$projRoot/project.mbd';
          final behaviorJson = _processToBehavior(p);
          try {
            await server.callTool('studio.builder.addBehavior', {
              'mbdPath': targetMbd,
              'behavior': behaviorJson,
            });
          } catch (_) {
            // Best-effort — see note above.
          }
          // Also register it into the LIVE behavior engine so `process_start`
          // works immediately. The disk mirror above only feeds the next
          // boot's `BundleActivation`; without this a freshly-saved process
          // ran "behavior not found" until a re-open.
          try {
            init.registerProjectBehavior(
              bundle.BehaviorDefinition.fromJson(behaviorJson),
            );
          } catch (_) {
            // Best-effort — disk mirror still lets a re-boot pick it up.
          }
        }
        return {
          'saved': true,
          'id': p.id,
          'steps': p.steps.length,
          'workspace': wsId,
        };
      },
    );

    _register(
      server,
      'process_delete',
      'Delete a process definition (removes both the YAML file and the in-memory cache)',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'workspaceId': {'type': 'string'},
        },
        'required': ['id'],
      },
      (args) async {
        final wsId = args['workspaceId'] as String?;
        await init.registries.process.delete(
          args['id'] as String,
          workspaceId: wsId,
        );
        return {'deleted': true, 'id': args['id']};
      },
    );

    // --- Bundles ---

    _register(server, 'bundle_list', 'List bundles in the catalog', const {}, (
      _,
    ) async {
      final list = await init.registries.bundle.list();
      return {
        'bundles': [
          for (final b in list)
            {
              'id': b.id,
              'name': b.name,
              'version': b.version,
              'type': b.type,
              'targetWorkspaceType': b.targetWorkspaceType,
              'capabilities': b.capabilities,
              'description': b.description,
            },
        ],
      };
    });

    _register(
      server,
      'bundle_installed',
      'Bundles installed in the current workspace',
      const {},
      (_) async {
        final wsId = init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};
        final list = await init.registries.bundleInstaller.listInstalled(wsId);
        return {
          'installs': [
            for (final r in list)
              {
                'bundleId': r.bundleId,
                'version': r.version,
                'installedAt': r.installedAt.toIso8601String(),
                'fileCount': r.copied.length,
                'conflicts': r.conflicts,
              },
          ],
        };
      },
    );

    _register(
      server,
      'bundle_install',
      'Install a bundle into a workspace. Defaults to the active '
          'workspace when `workspaceId` is omitted.',
      const {
        'type': 'object',
        'properties': {
          'bundleId': {'type': 'string'},
          'workspaceId': {'type': 'string'},
        },
        'required': ['bundleId'],
      },
      (args) async {
        final explicitWs = (args['workspaceId'] as String?)?.trim();
        final wsId =
            (explicitWs != null && explicitWs.isNotEmpty)
                ? explicitWs
                : init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};
        final b = await init.registries.bundle.get(args['bundleId'] as String);
        if (b == null) return {'error': 'bundle not found'};
        final rec = await init.registries.bundleInstaller.install(
          bundle: b,
          workspaceId: wsId,
        );
        return {
          'installed': true,
          'bundleId': rec.bundleId,
          'fileCount': rec.copied.length,
        };
      },
    );

    _register(
      server,
      'bundle_uninstall',
      'Uninstall a bundle',
      const {
        'type': 'object',
        'properties': {
          'bundleId': {'type': 'string'},
        },
        'required': ['bundleId'],
      },
      (args) async {
        final wsId = init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};
        await init.registries.bundleInstaller.uninstall(
          bundleId: args['bundleId'] as String,
          workspaceId: wsId,
        );
        return {'uninstalled': true};
      },
    );

    // --- Knowledge ingest ---

    _register(
      server,
      'knowledge_ingest_file',
      'Ingest a file as knowledge. `path` is workspace-relative (e.g. '
          '`knowledge/policy.md`, resolved against the active workspace like '
          '`knowledge_file_write`) or an absolute path for an external file.',
      const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'category': {'type': 'string'},
          'workspaceId': {'type': 'string'},
        },
        'required': ['path'],
      },
      (args) async {
        final rawPath = args['path'] as String;
        // Resolve workspace-relative paths against the active workspace's
        // content root — the same resolution `knowledge_file_write` /
        // `knowledge_file_read` use. Without this a relative path
        // (`knowledge/x.md`) resolved against the process CWD and ingest
        // reported "file not found" for a file `knowledge_file_write` had
        // just written.
        String path = rawPath;
        if (!p.isAbsolute(rawPath)) {
          final wsId =
              (args['workspaceId'] as String?) ??
              init.registries.workspace.activeId;
          if (wsId == null) return {'error': 'no active workspace'};
          path = '${_wsRoot(init, wsId)}/$rawPath';
        }
        final file = File(path);
        if (!await file.exists()) {
          return {'error': 'file not found: $path'};
        }
        // Chunk via the host `ingest.*` capability + extract into the
        // flowbrain FactFacade (both host-owned). No built-in ingest engine.
        // Scope staged candidates to the Ops active workspace so the same
        // workspace's fact query (`knowledge_fact_query`, defaults to
        // `kv.workspaceId`) surfaces them after confirmation — otherwise they
        // landed in the shared system's `default` scope and the operator's
        // workspace-scoped query never saw them.
        final wsId =
            (args['workspaceId'] as String?) ??
            init.registries.workspace.activeId;
        final fragments = await init.skillExecutor.ingestFileToFacts(
          file,
          workspaceId: wsId,
        );
        return {
          'fragmentsEmitted': fragments,
          if (wsId != null) 'workspaceId': wsId,
          'path': path,
        };
      },
    );

    // Form rendering = host `form.*` capability (form.create_document +
    // form.render on the host endpoint). The dead ops FormAdapter wrapper
    // (`form_render`, templates never registered) was removed — built-ins
    // call the host form tools directly.

    // --- Capability: channel notification ---

    _register(
      server,
      'channel_notify',
      'Send a notification through the host `channel.*` capability (default '
          'goes to the in-app feed connector). Used by skills and external drivers '
          'to surface something to a workspace member.',
      const {
        'type': 'object',
        'properties': {
          'recipientId': {'type': 'string'},
          'title': {'type': 'string'},
          'body': {'type': 'string'},
          'notificationId': {'type': 'string'},
          'kind': {
            'type': 'string',
            'enum': ['info', 'success', 'warning', 'error', 'reminder'],
          },
        },
        'required': ['recipientId', 'title'],
      },
      (args) async {
        // Notification → host `channel.send` on the in-app feed (the feed is
        // one channel behind `channel.*`; the messaging engine is host-owned).
        final kind = (args['kind'] as String?) ?? 'info';
        final title = args['title'] as String;
        final body = (args['body'] as String?) ?? '';
        final nid =
            (args['notificationId'] as String?) ??
            'n-${DateTime.now().microsecondsSinceEpoch}';
        final result = await server.callTool('channel.send', <String, dynamic>{
          'channelId': 'in_app',
          'conversationId': args['recipientId'],
          'text': body.isEmpty ? '[$kind] $title' : '[$kind] $title\n$body',
          'replyTo': nid,
        });
        return {
          'notificationId': nid,
          'status': result.isError == true ? 'failed' : 'delivered',
        };
      },
    );

    // --- Skill & bundle catalog ---

    _register(
      server,
      'skill_list',
      'List loaded skills (current workspace + active agent overlay included)',
      const {
        'type': 'object',
        'properties': {
          'actorId': {'type': 'string'},
        },
      },
      (args) async {
        final wsId = init.registries.workspace.activeId;
        final actorId = args['actorId'] as String?;
        final ids = await init.skillResolver.visibleIds(
          workspaceId: wsId,
          actorId: actorId,
        );
        final skills = <Map<String, dynamic>>[];
        for (final id in ids) {
          final def = await init.skillResolver.resolve(
            id,
            workspaceId: wsId,
            actorId: actorId,
          );
          if (def == null) continue;
          skills.add({
            'id': def.id,
            'description': def.description,
            'tags': def.tags,
            'version': def.version,
            'scope': await _resolveScope(id, wsId, actorId),
          });
        }
        return {'skills': skills, 'actorId': actorId, 'workspace': wsId};
      },
    );

    _register(
      server,
      'skill_get',
      'Return a skill\'s final resolved YAML (agent overlay → ws override → template)',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'actorId': {'type': 'string'},
        },
        'required': ['id'],
      },
      (args) async {
        final wsId = init.registries.workspace.activeId;
        final def = await init.skillResolver.resolve(
          args['id'] as String,
          workspaceId: wsId,
          actorId: args['actorId'] as String?,
        );
        if (def == null) return {'error': 'not found'};
        return {
          'id': def.id,
          'version': def.version,
          'description': def.description,
          'inputSchema': def.inputSchema,
          'outputSchema': def.outputSchema,
          'actionBody': _actionBodyToJson(def.actionBody),
          'tags': def.tags,
          'scope': await _resolveScope(
            def.id,
            wsId,
            args['actorId'] as String?,
          ),
        };
      },
    );

    _register(
      server,
      'skill_save',
      'Save a skill YAML. Use scope to choose the target — '
          'template (app built-in), workspace, or agent.',
      const {
        'type': 'object',
        'properties': {
          'yaml': {
            'type': 'string',
            'description': 'Full SkillDefinition YAML string',
          },
          'scope': {
            'type': 'string',
            'enum': ['workspace', 'agent'],
            'description':
                'workspace = ws/skills, agent = ws/members/<id>/skills',
          },
          'actorId': {
            'type': 'string',
            'description': 'Required when scope=agent',
          },
        },
        'required': ['yaml', 'scope'],
      },
      (args) async {
        final wsId = init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};
        final yamlStr = args['yaml'] as String;
        final scope = args['scope'] as String;
        final actorId = args['actorId'] as String?;
        final y = loadYaml(yamlStr);
        if (y is! YamlMap) return {'error': 'yaml root must be a map'};
        final def = SkillDefinition.fromYaml(_yamlToMap(y));
        final String path;
        switch (scope) {
          case 'workspace':
            path =
                init.registries.workspace.activeId == null
                    ? ''
                    : '${_wsRoot(init, wsId)}/skills/${def.id}.yaml';
            break;
          case 'agent':
            if (actorId == null)
              return {'error': 'actorId required for agent scope'};
            path =
                '${_wsRoot(init, wsId)}/members/$actorId/skills/${def.id}.yaml';
            break;
          default:
            return {'error': 'unsupported scope: $scope'};
        }
        final file = File(path);
        await file.parent.create(recursive: true);
        await file.writeAsString(yamlStr);
        // Invalidate resolver cache + reload template map if it was a ws
        // file (which `_loadSkills` would normally pick up).
        init.skillResolver.invalidate(
          workspaceId: wsId,
          actorId: actorId,
          skillId: def.id,
        );
        if (scope == 'workspace') {
          init.skills.register(def);
        }
        // P2 (additive) — mirror the workspace skill into the project-level
        // pool via the universal `studio.builder.addSkill` host tool
        // (sanctioned builtin→host chain). The Agent Subsystem skill pool
        // is the project `SkillRuntime`, which `BundleActivation` seeds from
        // `project.mbd.skills.modules`. So EVERY workspace skill mirrors into
        // `project.mbd` — not the ws content `.mbd`, which carries no manifest
        // and is not a bundle, so `addSkill` there silently fails and
        // `agent_assign_skill` could never fork the skill (the dual-store
        // bug). The loose `ws/skills/<id>.yaml` keeps the per-workspace
        // authoring copy; the pool seed is shared (owned forks stay
        // per-agent). Agent-scoped skills (members/<id>/skills) are per-member
        // runtime overrides, not a knowledge section, so they are not
        // mirrored. Best-effort: the loose-yaml write above already persisted
        // it this session — a manifest-write failure must not break save.
        final projRoot = init.projectRoot;
        if (scope == 'workspace' && projRoot.isNotEmpty) {
          final targetMbd = '$projRoot/project.mbd';
          final skillEntry = Map<String, dynamic>.from(_yamlToMap(y));
          skillEntry['id'] = def.id;
          try {
            await server.callTool('studio.builder.addSkill', {
              'mbdPath': targetMbd,
              'skill': skillEntry,
            });
          } catch (_) {
            // Best-effort — see note above.
          }
          // Live-register into the running `SkillRuntime` pool under the
          // `BundleActivation`-qualified id (`<sharedPoolBundleId>.<id>`) so
          // the skill is forkable via `agent_assign_skill` immediately —
          // without waiting for the next boot's BundleActivation to seed it
          // from `project.mbd`. The `addSkill` mirror above only persists to
          // the manifest (disk); the in-memory pool the assign handler reads
          // (`init.system.skillRuntime`) is otherwise stale until reboot (the
          // live-register gap). Mirrors `BundleActivation.registerSkill`;
          // metadata-only wrapper (execution stays on AppSkillRegistry +
          // SkillExecutor). Same qualified id the assign handler resolves.
          final poolBundle = init.sharedPoolBundleId;
          final runtime = init.system.skillRuntime;
          if (poolBundle != null && runtime != null) {
            try {
              await runtime.registry.registerSkill(
                SkillBundle(
                  schemaVersion: '0.1.0',
                  manifest: SkillManifest(
                    id: '$poolBundle.${def.id}',
                    name: def.id,
                    version: '${def.version}',
                    provider: 'makemind-ops',
                    description:
                        def.description.isEmpty ? null : def.description,
                  ),
                  procedures: [
                    Procedure(
                      id: '${def.id}-default',
                      name: def.id,
                      description:
                          def.description.isEmpty ? null : def.description,
                      steps: const [],
                    ),
                  ],
                  extensions: <String, dynamic>{
                    if (def.tags.isNotEmpty) 'ops:tags': def.tags,
                    if (def.inputSchema.isNotEmpty)
                      'ops:inputSchema': def.inputSchema,
                    if (def.outputSchema.isNotEmpty)
                      'ops:outputSchema': def.outputSchema,
                  },
                ),
              );
            } catch (_) {
              // Best-effort — assign falls back to next-boot activation.
            }
          }
        }
        return {'saved': true, 'id': def.id, 'scope': scope, 'path': path};
      },
    );

    _register(
      server,
      'skill_delete',
      'Delete a skill YAML at the given scope. '
          'scope=workspace: ws/skills/<id>.yaml, scope=agent: ws/members/<actorId>/skills/<id>.yaml. '
          'template scope is not supported (it is bundled into the app).',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'scope': {
            'type': 'string',
            'enum': ['workspace', 'agent'],
          },
          'actorId': {'type': 'string'},
        },
        'required': ['id', 'scope'],
      },
      (args) async {
        final wsId = init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};
        final scope = args['scope'] as String;
        final actorId = args['actorId'] as String?;
        final skillId = args['id'] as String;
        final String path;
        switch (scope) {
          case 'workspace':
            path = '${_wsRoot(init, wsId)}/skills/$skillId.yaml';
            break;
          case 'agent':
            if (actorId == null)
              return {'error': 'actorId required for agent scope'};
            path =
                '${_wsRoot(init, wsId)}/members/$actorId/skills/$skillId.yaml';
            break;
          default:
            return {'error': 'unsupported scope: $scope'};
        }
        final file = File(path);
        if (!await file.exists()) {
          return {'error': 'file not found: $path'};
        }
        await file.delete();
        init.skillResolver.invalidate(
          workspaceId: wsId,
          actorId: actorId,
          skillId: skillId,
        );
        if (scope == 'workspace') {
          init.skills.remove(skillId);
        }
        return {'deleted': true, 'id': skillId, 'scope': scope, 'path': path};
      },
    );

    _register(
      server,
      'skill_global_list',
      'Global skill list across all workspaces and agents. '
          'If the same id exists in multiple scopes, all are listed in the scopes array.',
      const {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'id/description substring filter',
          },
        },
      },
      (args) async {
        final q = (args['query'] as String?)?.toLowerCase();
        final wsList = await init.registries.workspace.list();
        final byId = <String, Map<String, dynamic>>{};

        // Templates (app-level registry).
        for (final def in init.skills.list()) {
          final entry = byId.putIfAbsent(
            def.id,
            () => {
              'id': def.id,
              'description': def.description,
              'tags': def.tags,
              'version': def.version,
              'scopes': <Map<String, dynamic>>[],
            },
          );
          (entry['scopes'] as List).add({'scope': 'template'});
        }

        // Workspace + agent scopes via file scan.
        for (final ws in wsList) {
          final wsSkillsDir = Directory('${_wsRoot(init, ws.id)}/skills');
          if (await wsSkillsDir.exists()) {
            await for (final e in wsSkillsDir.list()) {
              if (e is! File || !e.path.endsWith('.yaml')) continue;
              final id = e.uri.pathSegments.last.replaceAll('.yaml', '');
              final entry = byId.putIfAbsent(
                id,
                () => {'id': id, 'scopes': <Map<String, dynamic>>[]},
              );
              (entry['scopes'] as List).add({
                'scope': 'workspace',
                'workspace': ws.id,
                'path': e.path,
              });
            }
          }
          final membersDir = Directory('${_wsRoot(init, ws.id)}/members');
          if (await membersDir.exists()) {
            await for (final memDir in membersDir.list()) {
              if (memDir is! Directory) continue;
              final agentSkillsDir = Directory('${memDir.path}/skills');
              if (!await agentSkillsDir.exists()) continue;
              final actorId =
                  memDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
              await for (final e in agentSkillsDir.list()) {
                if (e is! File || !e.path.endsWith('.yaml')) continue;
                final id = e.uri.pathSegments.last.replaceAll('.yaml', '');
                final entry = byId.putIfAbsent(
                  id,
                  () => {'id': id, 'scopes': <Map<String, dynamic>>[]},
                );
                (entry['scopes'] as List).add({
                  'scope': 'agent',
                  'workspace': ws.id,
                  'actorId': actorId,
                  'path': e.path,
                });
              }
            }
          }
        }

        final all = byId.values.toList();
        final filtered =
            q == null
                ? all
                : all.where((e) {
                  final id = (e['id'] as String).toLowerCase();
                  final desc =
                      (e['description'] as String? ?? '').toLowerCase();
                  return id.contains(q) || desc.contains(q);
                }).toList();
        return {'skills': filtered, 'total': filtered.length};
      },
    );

    _register(
      server,
      'config_reload',
      'Re-read ~/.makemind-ops/config.yaml from disk and return it '
          '(used so the engine sees an externally edited config)',
      const {},
      (_) async {
        final cfg = await OpsConfig.load();
        return cfg.toJson();
      },
    );

    // --- Knowledge editing ---

    _register(
      server,
      'knowledge_fact_save',
      'Save a knowledge fact at category/key (writes to both FactFacade and KV)',
      const {
        'type': 'object',
        'properties': {
          'category': {'type': 'string'},
          'key': {'type': 'string'},
          'value': {'type': 'string'},
          'metadata': {'type': 'object'},
        },
        'required': ['category', 'key', 'value'],
      },
      (args) async {
        await init.registries.knowledge.saveFact(
          category: args['category'] as String,
          key: args['key'] as String,
          value: args['value'] as Object,
          metadata: (args['metadata'] as Map?)?.cast<String, Object?>(),
        );
        return {'saved': true};
      },
    );

    _register(
      server,
      'knowledge_fact_query',
      'Query knowledge facts. `typeFilter` constrains FactQuery.types '
          '(e.g. `agent.invoked` for an agent timeline). `workspaceId` '
          'overrides the active workspace — useful for the system agent\'s '
          '`_system` ws timeline. `entityId` narrows to one entity (e.g. '
          'one agentId).',
      const {
        'type': 'object',
        'properties': {
          'question': {'type': 'string'},
          'typeFilter': {'type': 'string'},
          'workspaceId': {'type': 'string'},
          'entityId': {'type': 'string'},
          'limit': {'type': 'integer'},
        },
        'required': ['question'],
      },
      (args) async {
        final limit = (args['limit'] as int?) ?? 10;
        final facts = await init.registries.knowledge.query(
          args['question'] as String,
          typeFilter: args['typeFilter'] as String?,
          workspaceId: args['workspaceId'] as String?,
          entityId: args['entityId'] as String?,
          limit: limit,
        );
        final out = <Map<String, dynamic>>[
          for (final f in facts)
            {
              'id': f.id,
              'type': f.type,
              'workspaceId': f.workspaceId,
              if (f.entityId != null) 'entityId': f.entityId,
              'content': f.content,
            },
        ];
        // Formal share overlay (FR-OPS-014): surface facts that other
        // workspaces have granted to this one, read-only, narrowed to the
        // granted scope. The owner's other categories stay private — a
        // workspace is a sandbox; cross-team reads are an explicit contract.
        final target =
            (args['typeFilter'] == null && args['entityId'] == null)
                ? (args['workspaceId'] as String?) ??
                    init.registries.workspace.activeId
                : null;
        if (target != null && target.isNotEmpty) {
          final incoming = await init.registries.workspace.incomingShares(
            target,
          );
          for (final grant in incoming) {
            final shared = await init.registries.knowledge
                .graphFactsForWorkspace(
                  grant.fromWorkspaceId,
                  category: grant.scope,
                  limit: limit,
                );
            for (final f in shared) {
              out.add({
                'id': f.id,
                'type': f.type,
                'workspaceId': f.workspaceId,
                if (f.entityId != null) 'entityId': f.entityId,
                'content': f.content,
                'sharedFrom': grant.fromWorkspaceId,
                'shareScope': grant.scope,
                'readOnly': true,
              });
            }
          }
        }
        return {'facts': out};
      },
    );

    _register(
      server,
      'knowledge_file_list',
      'List files under knowledge/ in the current workspace (recursive; paths are relative to the workspace)',
      const {
        'type': 'object',
        'properties': {
          'workspaceId': {'type': 'string'},
          'subPath': {'type': 'string', 'description': 'Subdirectory filter'},
        },
      },
      (args) async {
        final wsId =
            (args['workspaceId'] as String?) ??
            init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};
        final subPath = args['subPath'] as String? ?? '';
        final base =
            '${_wsRoot(init, wsId)}/knowledge${subPath.isEmpty ? "" : "/$subPath"}';
        final dir = Directory(base);
        if (!await dir.exists()) return {'files': <String>[], 'base': base};
        final files = <Map<String, dynamic>>[];
        await for (final e in dir.list(recursive: true)) {
          if (e is! File) continue;
          final stat = await e.stat();
          files.add({
            'path': e.path.substring('${_wsRoot(init, wsId)}/'.length),
            'size': stat.size,
            'modifiedAt': stat.modified.toIso8601String(),
          });
        }
        return {'files': files, 'workspace': wsId};
      },
    );

    _register(
      server,
      'knowledge_file_read',
      'Return the contents of a file under workspace knowledge/ (text only)',
      const {
        'type': 'object',
        'properties': {
          'workspaceId': {'type': 'string'},
          'path': {
            'type': 'string',
            'description': 'Path relative to the workspace',
          },
        },
        'required': ['path'],
      },
      (args) async {
        final wsId =
            (args['workspaceId'] as String?) ??
            init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};
        final rel = args['path'] as String;
        if (!rel.startsWith('knowledge/')) {
          return {'error': 'path must start with knowledge/'};
        }
        final abs = '${_wsRoot(init, wsId)}/$rel';
        final f = File(abs);
        if (!await f.exists()) return {'error': 'file not found: $abs'};
        return {'path': rel, 'content': await f.readAsString()};
      },
    );

    _register(
      server,
      'knowledge_file_write',
      'Write a file under workspace knowledge/ (created if missing, overwritten if present). '
          'Use this to edit knowledge definition YAML, notes, templates, etc.',
      const {
        'type': 'object',
        'properties': {
          'workspaceId': {'type': 'string'},
          'path': {
            'type': 'string',
            'description':
                'Path relative to the workspace (must start with knowledge/)',
          },
          'content': {'type': 'string'},
        },
        'required': ['path', 'content'],
      },
      (args) async {
        final wsId =
            (args['workspaceId'] as String?) ??
            init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};
        final rel = args['path'] as String;
        if (!rel.startsWith('knowledge/')) {
          return {'error': 'path must start with knowledge/'};
        }
        final abs = '${_wsRoot(init, wsId)}/$rel';
        final f = File(abs);
        await f.parent.create(recursive: true);
        await f.writeAsString(args['content'] as String);
        return {'saved': true, 'path': rel};
      },
    );

    _register(
      server,
      'knowledge_file_delete',
      'Delete a file under workspace knowledge/',
      const {
        'type': 'object',
        'properties': {
          'workspaceId': {'type': 'string'},
          'path': {'type': 'string'},
        },
        'required': ['path'],
      },
      (args) async {
        final wsId =
            (args['workspaceId'] as String?) ??
            init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};
        final rel = args['path'] as String;
        if (!rel.startsWith('knowledge/')) {
          return {'error': 'path must start with knowledge/'};
        }
        final abs = '${_wsRoot(init, wsId)}/$rel';
        final f = File(abs);
        if (!await f.exists()) return {'error': 'file not found: $abs'};
        await f.delete();
        return {'deleted': true, 'path': rel};
      },
    );

    _register(
      server,
      'skill_generate',
      'Generate a skill YAML via an LLM and save it. Tries the internal '
          'provider first; if not configured, falls back to MCP sampling — '
          'i.e., asks the connected client (Claude Desktop / Code, etc.) to '
          'do the completion. External LLMs may also bypass this and inject '
          'their own YAML directly via skill_save.',
      const {
        'type': 'object',
        'properties': {
          'prompt': {'type': 'string'},
          'targetScope': {
            'type': 'string',
            'enum': ['workspace', 'agent'],
          },
          'actorId': {'type': 'string'},
        },
        'required': ['prompt', 'targetScope'],
      },
      (args) async {
        final wsId = init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};

        final designerPrompt =
            'You are the designer who authors skills for makemind Ops. Write one '
            'SkillDefinition YAML that satisfies the requirements below. Output YAML only — no code fences.\n\n'
            'Required fields: id, version (number), description, inputSchema, outputSchema, '
            'actionBody (kind + steps).\n\n'
            'Requirements: ${args['prompt']}';

        String generated = '';
        String source = '';
        if (init.adapters.llm.hasInternalLlm) {
          final res = await init.system.infraPorts.llm?.complete(
            bundle.LlmRequest(prompt: designerPrompt),
          );
          generated = res?.content ?? '';
          source = 'internal';
        } else if (init.skillExecutor.samplingProvider != null) {
          try {
            generated = await init.skillExecutor.samplingProvider!(
              prompt: designerPrompt,
              maxTokens: 2000,
            );
            source = 'sampling';
          } catch (e) {
            return {
              'error':
                  'Sampling fallback failed: $e. Connect a client that '
                  'advertises the `sampling` capability, or configure an '
                  'internal LLM via config_set_llm_provider.',
            };
          }
        } else {
          return {
            'error':
                'No LLM available. Either configure an internal provider via '
                'config_set_llm_provider, or connect an MCP client that '
                'advertises the `sampling` capability. As a last resort, '
                'inject the YAML directly with skill_save.',
          };
        }
        if (generated.isEmpty) {
          return {'error': 'LLM returned empty', 'source': source};
        }
        final yamlStr = _stripCodeFence(generated);
        final saved = await _saveInternal(
          init,
          yamlStr: yamlStr,
          scope: args['targetScope'] as String,
          actorId: args['actorId'] as String?,
        );
        return {...saved, 'source': source};
      },
    );

    _register(
      server,
      'status_snapshot',
      'Engine state snapshot (counts of workspaces, members, tasks, processes, bundles, skills)',
      const {},
      (_) async {
        final wsId = init.registries.workspace.activeId;
        final wsList = await init.registries.workspace.list();
        final members =
            wsId == null
                ? const <dynamic>[]
                : await init.registries.member.listForWorkspace(wsId);
        final tasks =
            wsId == null
                ? const <dynamic>[]
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
        return {
          'activeWorkspace': wsId,
          'workspaceCount': wsList.length,
          'members': members.length,
          'tasks': tasks.length,
          'processes': processes.length,
          'catalogBundles': bundles.length,
          'installedBundles': installed.length,
          'skills': init.skills.length,
          'internalLlm': init.adapters.llm.hasInternalLlm,
          // Sampling fallback available when a connected MCP client
          // advertises the `sampling` capability — skill_generate and
          // `kind: llm` steps borrow the client's LLM via spec
          // `sampling/createMessage`.
          'samplingFallback': init.skillExecutor.samplingProvider != null,
          'anyLlm': init.skillExecutor.hasAnyLlm,
        };
      },
    );

    // ── Showcase / portability tools ─────────────────────────────────────
    // External Claude / Code clients can drive the same operations the GUI
    // exposes in the sidebar — opspack export/import and the diagnostic
    // bundle. PRD §FM-MCP-02.
    //
    // Hardcoded scenario "recipes" (catalog + seeder) were removed: pre-baked
    // sample content must not live in builtin code — the app starts empty and
    // the user creates a project. See feedback_no_hardcoded_sample_seed.

    _register(
      server,
      'opspack_export',
      'Export a workspace as a `.opspack` archive. Returns the file path on disk.',
      const {
        'type': 'object',
        'properties': {
          'workspaceId': {'type': 'string'},
          'outputPath': {
            'type': 'string',
            'description': 'Absolute path to write the .opspack file.',
          },
          'includeFacts': {
            'type': 'boolean',
            'description':
                'When true, the workspace FactGraph is included in the archive.',
          },
        },
        'required': ['workspaceId', 'outputPath'],
      },
      (args) async => _exportOpspack(init, args),
    );

    _register(
      server,
      'opspack_import',
      'Import a `.opspack` file into the configured workspaces root. '
          'Returns the resolved workspace id.',
      const {
        'type': 'object',
        'properties': {
          'packPath': {'type': 'string'},
          'conflictPolicy': {
            'type': 'string',
            'description':
                'rename (default) · skip · overwrite. Controls behavior on duplicate workspace id.',
          },
        },
        'required': ['packPath'],
      },
      (args) async => _importOpspack(init, args),
    );

    _register(
      server,
      'diagnostic_export',
      'Generate a diagnostic `.zip` bundle (boot.log + redacted config + telemetry + recent activity events). Returns the file path on disk.',
      const {
        'type': 'object',
        'properties': {
          'outputPath': {'type': 'string'},
          'recentEvents': {'type': 'integer'},
        },
        'required': ['outputPath'],
      },
      (args) async => _exportDiagnostic(init, args),
    );

    _register(
      server,
      'html_report_export',
      'Render a workspace as a self-contained `.html` report (no external assets). The cloud-free alternative to embed share.',
      const {
        'type': 'object',
        'properties': {
          'workspaceId': {'type': 'string'},
          'outputPath': {
            'type': 'string',
            'description': 'Absolute path to write the .html file.',
          },
          'recentEvents': {
            'type': 'integer',
            'description':
                'Number of recent activity events to include (default 80).',
          },
        },
        'required': ['workspaceId', 'outputPath'],
      },
      (args) async => _exportHtmlReport(init, args),
    );

    // UI debug tools (`ui_capture` / `ui_navigate` / `ui_state` /
    // `ui_page_state` / `ui_open_agent_dialog` / `ui_chat_send` /
    // `ui_chat_history`) live in `tools/ui_debug_tools.dart`. They
    // depend on `dart:ui` via UiDebugBridge so the stdio CLI cannot
    // import them — the GUI entry (`main.dart`) registers them after
    // the booted ProviderScope attaches the bridge.
  }

  // --- showcase tool helpers ---

  Future<Map<String, Object?>> _exportOpspack(
    KnowledgeInit init,
    Map<String, dynamic> args,
  ) async {
    final wsId = args['workspaceId'] as String;
    final outPath = args['outputPath'] as String;
    final includeFacts = args['includeFacts'] == true;
    // Use the live project-bound root (same source as `_wsRoot` / member_* /
    // skill_*). `OpsConfig.load().workspacesRoot` is empty for a freshly bound
    // project (it isn't persisted), which produced "Workspace dir not found:".
    final dir = Directory(wsContentRoot(init.projectRoot, wsId));
    final pack = await Opspack.exportWorkspace(
      workspaceDir: dir,
      workspaceId: wsId,
      includeFacts: includeFacts,
    );
    await File(outPath).writeAsBytes(pack.bytes);
    return {
      'workspaceId': wsId,
      'path': outPath,
      'fileCount': pack.manifest.contents.length,
      'bytes': pack.bytes.length,
      'includeFacts': includeFacts,
    };
  }

  Future<Map<String, Object?>> _importOpspack(
    KnowledgeInit init,
    Map<String, dynamic> args,
  ) async {
    final policy = args['conflictPolicy'] as String? ?? Opspack.conflictRename;
    // Live project-bound root — `OpsConfig.load().workspacesRoot` is empty for
    // a freshly bound project (same fix as _exportOpspack / _wsRoot).
    final id = await Opspack.importWorkspace(
      packFile: File(args['packPath'] as String),
      workspacesRoot: Directory(init.projectRoot),
      conflictPolicy: policy,
    );
    return {'workspaceId': id, 'conflictPolicy': policy};
  }

  Future<Map<String, Object?>> _exportDiagnostic(
    KnowledgeInit init,
    Map<String, dynamic> args,
  ) async {
    final cfg = await OpsConfig.load();
    final outPath = args['outputPath'] as String;
    final recent = (args['recentEvents'] as num?)?.toInt() ?? 200;
    final obs = init.observability;
    if (obs == null) {
      return {'error': 'observability subsystem not active in this binary'};
    }
    final bundle = await DiagnosticExport.build(
      observability: obs,
      config: cfg,
      recentEvents: recent,
    );
    await File(outPath).writeAsBytes(bundle.bytes);
    return {
      'path': outPath,
      'bytes': bundle.bytes.length,
      'summary': bundle.summary,
    };
  }

  Future<Map<String, Object?>> _exportHtmlReport(
    KnowledgeInit init,
    Map<String, dynamic> args,
  ) async {
    final cfg = await OpsConfig.load();
    final wsId = args['workspaceId'] as String;
    final outPath = args['outputPath'] as String;
    final recent = (args['recentEvents'] as num?)?.toInt() ?? 80;
    final result = await HtmlReport.build(
      init: init,
      config: cfg,
      workspaceId: wsId,
      outputPath: outPath,
      observability: init.observability,
      recentEvents: recent,
    );
    return {'workspaceId': wsId, 'path': result.path, 'bytes': result.bytes};
  }

  // --- internals ---

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
        // Friendly required-arg validation — surfaces a clear error instead
        // of the raw `'Null' is not a subtype of 'String'` cast that would
        // otherwise come from `args[k] as String`.
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
          final result = await handler(Map<String, dynamic>.from(args));
          return KernelToolResult(
            content: [KernelTextContent(text: jsonEncode(result))],
          );
        } catch (e, _) {
          // Clean error map on the MCP surface — the response feeds the
          // chat UI and external LLMs, so a raw stack-trace dump is noise.
          // Strip the `Bad state: ` / `Exception: ` prefix the SDK adds so
          // the message reads as a plain sentence.
          var msg = e.toString();
          for (final prefix in const <String>['Bad state: ', 'Exception: ']) {
            if (msg.startsWith(prefix)) msg = msg.substring(prefix.length);
          }
          return KernelToolResult(
            content: [
              KernelTextContent(
                text: jsonEncode(<String, dynamic>{'error': msg}),
              ),
            ],
            isError: true,
          );
        }
      },
    );
  }

  Future<Map<String, dynamic>> _saveInternal(
    KnowledgeInit init, {
    required String yamlStr,
    required String scope,
    String? actorId,
  }) async {
    final wsId = init.registries.workspace.activeId!;
    final y = loadYaml(yamlStr);
    if (y is! YamlMap) return {'error': 'yaml root must be a map'};
    final def = SkillDefinition.fromYaml(_yamlToMap(y));
    final String path;
    switch (scope) {
      case 'workspace':
        path = '${_wsRoot(init, wsId)}/skills/${def.id}.yaml';
        break;
      case 'agent':
        if (actorId == null) return {'error': 'actorId required'};
        path = '${_wsRoot(init, wsId)}/members/$actorId/skills/${def.id}.yaml';
        break;
      default:
        return {'error': 'unsupported scope: $scope'};
    }
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(yamlStr);
    init.skillResolver.invalidate(
      workspaceId: wsId,
      actorId: actorId,
      skillId: def.id,
    );
    if (scope == 'workspace') init.skills.register(def);
    return {'saved': true, 'id': def.id, 'scope': scope, 'path': path};
  }

  /// Mirror a [Process] definition into the unified behavior-engine shape
  /// (`{id, name, steps[]}` for `studio.builder.addBehavior`). Additive —
  /// `ProcessRegistry` still executes today; this is the migration on-ramp
  /// (Process → behavior). Mapping:
  ///   - ProcessStep → an action step (`do: {skill, inputs}`).
  ///   - approval gate → a `when` guard that routes to `wait` until an
  ///     `approved_<step>` flag is set (the human "approve" path — a tool
  ///     sets the flag, then resume re-evaluates).
  ///   - quality gate → an appraise action step + a `when` on its score.
  ///   - philosophy gate → a prohibition-check action + a `when` on its
  ///     verdict. Calls the kernel's `bk.philosophy.check` standard tool
  ///     (registered through `addStandardTools`); the behavior dispatcher
  ///     merges its `hasHardViolation` result into run state so the gate's
  ///     `when` can read it and route to `stop` on a hard violation.
  Map<String, dynamic> _processToBehavior(Process p) {
    final gatesByStep = <String, List<ProcessGate>>{};
    for (final g in p.gates) {
      (gatesByStep[g.afterStep] ??= <ProcessGate>[]).add(g);
    }
    final steps = <Map<String, dynamic>>[];
    String? prev;
    for (final s in p.steps) {
      // A step whose skill is the `agent_ask` / `delegate` sentinel delegates
      // the work to its assignee AGENT through the host `agent_ask` tool. The
      // assignee may live in another workspace — kernel `agents.ask` resolves
      // an agent globally by id (Ops scopes ids `project.ws.local` so they are
      // unique), so a cross-workspace process step runs in the assignee's own
      // agent context. Built-in = wiring: route to the existing host agent
      // tool, no execution logic here (same shape as the philosophy gate's
      // `tool` action below).
      // A step assigned to a PERSON (a team member doing the work, not an
      // agent) is authored with `skillId: human` (or `manual`). It carries no
      // action — instead it suspends the run until that person submits via
      // `step_submit` (which sets `done_<stepId>`), the human-task counterpart
      // to an approval gate. Only this run waits; other work keeps running.
      final isHuman = s.skillId == 'human' || s.skillId == 'manual';
      if (isHuman) {
        steps.add(<String, dynamic>{
          'id': s.stepId,
          'when': 'done_${s.stepId} == true',
          'then': <String, String>{'false': 'wait'},
          if (prev != null) 'dependsOn': <String>[prev],
        });
      } else if (s.skillId == 'io.execute' || s.skillId == 'run') {
        // Real work — run an allowlisted dev command (git/dart/flutter/pub)
        // through the host `io.execute` capability (sandboxed: exe allowlist +
        // allowedRoots + operator role). The step authors `inputs.exe` + a
        // string list `inputs.argv`. Built-in = wiring: route to the host io
        // tool, the io capability owns the sandbox/policy.
        steps.add(<String, dynamic>{
          'id': s.stepId,
          'do': <String, dynamic>{
            'tool': 'io.execute',
            'args': <String, dynamic>{
              'target': 'process',
              'action': 'process.run',
              'args': <String, dynamic>{
                'exe': s.inputs['exe'],
                'argv': s.inputs['argv'] ?? const <String>[],
              },
              'actorId': s.assigneeId,
              'role': 'operator',
            },
          },
          if (prev != null) 'dependsOn': <String>[prev],
        });
      } else {
        final isDelegate = s.skillId == 'agent_ask' || s.skillId == 'delegate';
        final Map<String, dynamic> action =
            isDelegate
                ? <String, dynamic>{
                  'tool': 'agent_ask',
                  'args': <String, dynamic>{
                    'agentId': s.assigneeId,
                    'message':
                        (s.inputs['task'] ??
                                s.inputs['message'] ??
                                s.inputs['prompt'] ??
                                p.title)
                            .toString(),
                  },
                }
                : <String, dynamic>{
                  'skill': s.skillId,
                  'inputs': <String, dynamic>{
                    ...s.inputs,
                    if (s.assigneeId.isNotEmpty) 'actor': s.assigneeId,
                  },
                };
        steps.add(<String, dynamic>{
          'id': s.stepId,
          'do': action,
          if (prev != null) 'dependsOn': <String>[prev],
        });
      }
      var dep = s.stepId;
      // G5 handoff — when a step routes to a channel thread, post a formal
      // handoff notification to it so the next team receives the deliverable
      // signal (cross-team exchange, FR-OPS-014). Routes to the host
      // `channel.send` tool (built-in = wiring). Behavior action args are
      // static (the engine does not template them from state), so the message
      // carries the step + assignee + task; the produced artefact itself flows
      // through process state / knowledge, and the thread is the formal trail.
      if (s.channelThreadId != null && s.channelThreadId!.isNotEmpty) {
        final hid = '${s.stepId}_handoff';
        final task =
            (s.inputs['task'] ?? s.inputs['message'] ?? s.stepId).toString();
        steps.add(<String, dynamic>{
          'id': hid,
          'do': <String, dynamic>{
            'tool': 'channel.send',
            'args': <String, dynamic>{
              'channelId': 'in_app',
              'conversationId': s.channelThreadId,
              'text': '[handoff] ${s.stepId} done by ${s.assigneeId}: $task',
              'replyTo': '${p.id}/${s.stepId}',
            },
          },
          'dependsOn': <String>[dep],
        });
        dep = hid;
      }
      for (final g in gatesByStep[s.stepId] ?? const <ProcessGate>[]) {
        switch (g.kind) {
          case GateKind.approval:
            final gid = 'gate_approval_${s.stepId}';
            steps.add(<String, dynamic>{
              'id': gid,
              'when': 'approved_${s.stepId} == true',
              'then': <String, String>{'false': 'wait'},
              'dependsOn': <String>[dep],
            });
            dep = gid;
            break;
          case GateKind.quality:
            final metric =
                (g.params['metric'] as String?) ?? 'editorial_quality';
            final min = (g.params['min'] as num?)?.toDouble() ?? 0.7;
            final skill = (g.params['skill'] as String?) ?? 'quality_appraise';
            final evalId = 'gate_quality_eval_${s.stepId}';
            final gid = 'gate_quality_${s.stepId}';
            steps.add(<String, dynamic>{
              'id': evalId,
              'do': <String, dynamic>{
                'skill': skill,
                'inputs': <String, dynamic>{
                  'metric': metric,
                  if (s.assigneeId.isNotEmpty) 'actor': s.assigneeId,
                },
              },
              'dependsOn': <String>[dep],
            });
            steps.add(<String, dynamic>{
              'id': gid,
              'when': '$evalId.score >= $min',
              'then': <String, String>{'false': 'stop'},
              'dependsOn': <String>[evalId],
            });
            dep = gid;
            break;
          case GateKind.philosophy:
            final evalId = 'gate_philosophy_eval_${s.stepId}';
            final gid = 'gate_philosophy_${s.stepId}';
            steps.add(<String, dynamic>{
              'id': evalId,
              'do': <String, dynamic>{
                'tool': 'bk.philosophy.check',
                'args': <String, dynamic>{
                  'action': s.skillId,
                  if (s.assigneeId.isNotEmpty) 'actor': s.assigneeId,
                },
              },
              'dependsOn': <String>[dep],
            });
            steps.add(<String, dynamic>{
              'id': gid,
              'when': '$evalId.hasHardViolation == false',
              'then': <String, String>{'false': 'stop'},
              'dependsOn': <String>[evalId],
            });
            dep = gid;
            break;
        }
      }
      prev = dep;
    }
    return <String, dynamic>{'id': p.id, 'name': p.title, 'steps': steps};
  }

  String _wsRoot(KnowledgeInit init, String wsId) {
    // Use the live project-bound root — the same source member_* handlers
    // and the behavior mirror use. A config.yaml re-read was empty for a
    // freshly bound project (`/skills` read-only bug); `init` here is the
    // live getter so `projectRoot` is the open project's root.
    return wsContentRoot(init.projectRoot, wsId);
  }

  /// Kernel agent id for a freshly created Ops member — project + workspace
  /// scoped. In studio (hosted) mode Ops adopts the host's process-global
  /// `KnowledgeSystem`, whose Agent Subsystem keys agents and their owned
  /// forks by *bare* agentId. Without a scope the same local id (e.g.
  /// `editor`) reused across projects/workspaces collides — one agent's
  /// owned forks bleed into another's. The kernel stays generic (it stores
  /// whatever id it is handed); this is host-side wiring providing the
  /// per-unit scope, mirroring the per-unit chat agent scoping. Falls back
  /// to the bare id when no project is bound (welcome) or the id is already
  /// qualified. `member.id` stays the bare local id for display.
  String _scopedAgentId(KnowledgeInit init, String wsId, String localId) {
    final root = init.projectRoot;
    if (root.isEmpty || localId.contains('.')) return localId;
    return '${p.basename(root)}.${wsId.replaceAll('/', '_')}.$localId';
  }

  /// Resolve a caller-supplied agent id to the kernel agentId. MCP callers
  /// pass the bare local id (`editor`); the Members UI passes the stored
  /// `member.agentId` already. Looking the member up returns its stored
  /// `agentId` (the scoped kernel id for agents created after scoping
  /// landed); an unknown id (already-scoped, or a host agent like
  /// `_ops_admin`) passes through unchanged. Existing pre-scoping members
  /// keep their bare stored agentId, so nothing breaks.
  Future<String> _resolveAgentId(KnowledgeInit init, String idOrScoped) async {
    final m = await init.registries.member.get(idOrScoped);
    if (m is AgentMember) return m.agentId;
    return idOrScoped;
  }

  Future<String> _resolveScope(
    String skillId,
    String? wsId,
    String? actorId,
  ) async {
    if (wsId != null && actorId != null) {
      final f = File(
        '${_wsRoot(init, wsId)}/members/$actorId/skills/$skillId.yaml',
      );
      if (await f.exists()) return 'agent';
    }
    if (wsId != null) {
      final f = File('${_wsRoot(init, wsId)}/skills/$skillId.yaml');
      if (await f.exists()) return 'workspace';
    }
    return 'template';
  }

  String _stripCodeFence(String s) {
    var t = s.trim();
    if (t.startsWith('```')) {
      final firstNl = t.indexOf('\n');
      if (firstNl > 0) t = t.substring(firstNl + 1);
      if (t.endsWith('```')) t = t.substring(0, t.length - 3).trimRight();
    }
    return t;
  }

  Map<String, dynamic> _yamlToMap(YamlMap m) {
    final out = <String, dynamic>{};
    m.forEach((k, v) {
      out[k.toString()] =
          v is YamlMap
              ? _yamlToMap(v)
              : v is YamlList
              ? v.map((e) => e is YamlMap ? _yamlToMap(e) : e).toList()
              : v;
    });
    return out;
  }

  Map<String, dynamic> _actionBodyToJson(ActionBody b) => {
    'kind': b.kind,
    'steps': [
      for (final s in b.steps)
        {
          'kind': s.kind,
          if (s.id != null) 'id': s.id,
          if (s.output != null) 'output': s.output,
          'inputs': s.inputs,
          'data': s.data,
        },
    ],
    'data': b.data,
  };

  OpsConfig _copyConfig(
    OpsConfig src, {
    LlmSettings? llm,
    McpSettings? mcp,
    BrowserSettings? browser,
    StorageSettings? storage,
    ChannelSettings? channel,
    SecuritySettings? security,
    String? activeWorkspace,
  }) => OpsConfig(
    version: src.version,
    appName: src.appName,
    activeWorkspace: activeWorkspace ?? src.activeWorkspace,
    workspacesRoot: src.workspacesRoot,
    llm: llm ?? src.llm,
    mcp: mcp ?? src.mcp,
    browser: browser ?? src.browser,
    storage: storage ?? src.storage,
    channel: channel ?? src.channel,
    security: security ?? src.security,
  );
}
