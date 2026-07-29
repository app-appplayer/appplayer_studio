import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart'
    show
        AgentAxis,
        AgentForkSource,
        AgentRole,
        ForkSource,
        ModelSpec,
        PoolForkSource,
        Procedure,
        SkillBundle,
        SkillManifest;
import 'package:http/http.dart' as http;
import 'package:appplayer_secure/appplayer_secure.dart'
    show SecureStorage, FlutterSecureStorageBackend;

import '../../../base/infra/project_paths.dart';
import '../../../base/install/capability_recipes/capability_recipes.dart'
    show CredentialMigrator;
import '../../../base/install/knowledge_persistence/knowledge_persistence.dart'
    show exportProject, importProject, purgeProject;
import 'package:mcp_bundle/mcp_bundle.dart' as bundle;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart' show BuiltinToolRegistry;
import 'package:appplayer_studio/builtin_api.dart'
    show KernelToolResult, KernelTextContent;
import 'package:yaml/yaml.dart';

import '../config/ops_config.dart';
import '../infra/project_seed.dart' show applyOpsWorkspaceSeed;
import '../infra/ws_paths.dart';
import '../../../base/agent/agent_host.dart' show AgentHost;
import '../../../base/agent/agent_invoke_queue.dart';
import '../core/inbox_query.dart';
import '../init/knowledge_init.dart';
import '../triggers/trigger_events.dart';
import '../init/workspace_context.dart';
import '../ops_builtin.dart' show OpsBuiltInApp;
import '../observability/activity_event.dart';
import '../observability/diagnostic_export.dart';
import '../portability/html_report.dart';
import '../portability/opspack.dart';
import '../registries/member_registry.dart';
import '../registries/process_registry.dart';
import '../registries/task_registry.dart';
import '../registries/workspace_registry.dart';
import '../skills/skill_definition.dart';

/// Orders a workspace's members for display: persons (the principals —
/// owner / CEO) first, then agents by orchestration role — manager (the
/// unit's lead / department head) ahead of reviewer ahead of worker — then by
/// id.
/// Shared by `member_list` (single workspace) and `member_global_list`
/// (cross-workspace) so both read the same way: the human principals on top,
/// each unit's manager leading its roster, then the rest.
@visibleForTesting
List<Member> membersInListingOrder(List<Member> members) {
  int rank(Member m) {
    if (m.kind == MemberKind.person) return 0;
    if (m is AgentMember) {
      return switch (m.role) {
        AgentRole.manager => 1,
        AgentRole.reviewer => 2,
        AgentRole.worker => 3,
      };
    }
    return 3;
  }

  return [...members]..sort((a, b) {
    final ra = rank(a);
    final rb = rank(b);
    return ra != rb ? ra - rb : a.id.compareTo(b.id);
  });
}

/// Aggregates per-workspace member lists into the `member_global_list` rows.
///
/// Keyed by `(workspaceId, id)` — member ids are unique only WITHIN a
/// workspace (every department owns its own `lead`, `qa`, …), so deduping on
/// the short id alone silently merges distinct members (10 different
/// department `lead`s collapse into one row, undercounting the org). The
/// composite key keeps every workspace membership as its own entry, so the
/// total equals the sum of the per-workspace `member_list` counts.
///
/// The caller passes workspaces in org-tree order (see
/// [orderWorkspacesHierarchical]); within each workspace, persons (the
/// principals — owner / CEO) sort above agents, then by id. Combined, the
/// listing reads hierarchically: the root's owner on top, each department's
/// members following their unit. Each row carries `depth` +
/// `parentWorkspaceId` so a consumer can indent the tree.
@visibleForTesting
Map<String, dynamic> buildGlobalMemberList(
  List<({String wsId, String? parentId, int depth, List<Member> members})>
      perWorkspace, {
  String? kindFilter,
  String? query,
}) {
  final q = query?.toLowerCase();
  final byKey = <String, Map<String, dynamic>>{};
  for (final ws in perWorkspace) {
    final sorted = membersInListingOrder(ws.members);
    for (final m in sorted) {
      if (kindFilter != null && m.kind.name != kindFilter) continue;
      if (q != null &&
          !m.id.toLowerCase().contains(q) &&
          !m.displayName.toLowerCase().contains(q)) {
        continue;
      }
      final base = <String, dynamic>{
        'id': m.id,
        'workspaceId': ws.wsId,
        if (ws.parentId != null && ws.parentId!.isNotEmpty)
          'parentWorkspaceId': ws.parentId,
        'depth': ws.depth,
        'kind': m.kind.name,
        'displayName': m.displayName,
        'tags': m.tags,
      };
      if (m is AgentMember) {
        base['agentId'] = m.agentId;
        base['profileRef'] = m.profileRef;
        base['philosophyRef'] = m.philosophyRef;
        base['skillIds'] = m.skillIds;
      } else if (m is PersonMember) {
        base['email'] = m.email;
        base['roleLabels'] = m.roleLabels;
      }
      byKey['${ws.wsId} ${m.id}'] = base;
    }
  }
  return {'members': byKey.values.toList(), 'total': byKey.length};
}

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

  /// Resolve the workspace a handler operates on without depending on the
  /// global mutable active (which concurrent actors flip via
  /// `workspace_switch`). Order: explicit `workspaceId`/`workspace` arg → the
  /// caller's execution-scoped workspace → active (UI fallback). See
  /// [resolveWorkspaceId] / [WorkspaceExecutionContext]. Handlers that took a
  /// tool-specific selector arg (`id`, `ownerId`) pass it via [explicit].
  String? _wsId(Map<String, dynamic> args, {String? explicit}) {
    if (explicit != null && explicit.isNotEmpty) return explicit;
    return resolveWorkspaceId(
      args,
      execWorkspaceId: WorkspaceExecutionContext.current,
      activeWorkspaceId: init.registries.workspace.activeId,
    );
  }

  /// The workspace that OWNS a fully-qualified agentId, or null for a bare id
  /// (`lead`) or an unknown agentId. Authoritative: scans every workspace for
  /// a member whose `.agentId` matches exactly — no fragile decode of the
  /// `<ns>.<wsEncoded>.<member>` string. Used so `agent_ask` routes to the
  /// department NAMED by the agentId rather than the active-lens workspace,
  /// which would silently mis-deliver a cross-department ask to a same-named
  /// member (every division has a `lead`).
  Future<String?> _workspaceOfAgentId(
    KnowledgeInit init,
    String agentId,
  ) async {
    if (!agentId.contains('.')) return null; // bare member id — no encoded ws
    for (final ws in await init.registries.workspace.list()) {
      final members = await init.registries.member.listForWorkspace(ws.id);
      if (members.any((m) => m is AgentMember && m.agentId == agentId)) {
        return ws.id;
      }
    }
    return null;
  }

  /// Fire an [AgentWorkCompleted] on the trigger bus, best-effort (a bad
  /// listener must not fail the tool). Fire-and-forget — the bus's seams are
  /// internally guarded.
  void _emitWork({
    required String source,
    required String workspaceId,
    required WorkKind kind,
    required String refId,
    String? summary,
    String state = 'completed',
  }) {
    try {
      init.triggerBus.emit(
        AgentWorkCompleted(
          sourceAgentId: source,
          workspaceId: workspaceId,
          kind: kind,
          refId: refId,
          state: state,
          at: DateTime.now(),
          summary: summary,
        ),
      );
    } catch (_) {
      // Best-effort — the tool result stands regardless.
    }
  }

  /// Emit an agent-turn activity event (`agentAsk` / `agentReply`) so the Live
  /// Activity feed shows the conversation traffic the generic `mcpInbound`
  /// wrapper deliberately skips for these tools. Best-effort. [headline] is
  /// truncated to keep the feed row scannable.
  void _emitAgentTurn(
    String actor,
    String prefix,
    String body,
    ActivityKind kind, {
    String? workspaceId,
  }) {
    final bus = init.observability?.bus;
    if (bus == null) return;
    final one = body.replaceAll('\n', ' ').trim();
    final clipped = one.length > 120 ? '${one.substring(0, 117)}…' : one;
    bus.info(
      actor,
      '$prefix$clipped',
      kind: kind,
      workspaceId: workspaceId,
    );
  }

  /// Schema fragment for the optional, uniform `workspaceId` parameter added
  /// to workspace-scoped tools (konpi "active workspace" inquiry). Omitting it
  /// resolves through [_wsId]; supplying it targets a specific department per
  /// call (cross-department staff).
  static const Map<String, dynamic> _workspaceIdParam = <String, dynamic>{
    'type': 'string',
    'description':
        'Target workspace id. Optional — defaults to the caller\'s '
        'execution workspace, then the active (UI) workspace. Pass explicitly '
        'to operate on a specific department regardless of the UI lens.',
  };

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

    _register(
      server,
      'workspace_list',
      'List workspaces. Archived (deactivated-but-retained) ones are hidden '
          'unless `includeArchived` is true; each entry carries an `archived` '
          'flag so a restore picker can surface them.',
      const {
        'type': 'object',
        'properties': {
          'includeArchived': {'type': 'boolean'},
        },
      },
      (args) async {
        final includeArchived = args['includeArchived'] == true;
        final list = await init.registries.workspace.list(
          includeArchived: includeArchived,
        );
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
                'archived': w.archived,
                if (w.archivedAt != null) 'archivedAt': w.archivedAt,
              },
          ],
        };
      },
    );

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
        // A slash in the slug composes an id (`<type>/<slug>`) whose metadata
        // dir nests one level deeper than the registry's reload scan reads —
        // the workspace is created and works in-session, then silently
        // VANISHES from `workspace_list` on the next boot (round-trip hole,
        // live-caught 2026-07-03). Reject with guidance instead of losing
        // data later: hierarchy is `workspace_set_parent`, not a path slug.
        if (slug.contains('/')) {
          return {
            'error':
                'slug must not contain "/" (got "$slug"). Use a flat slug; '
                'organizational nesting is expressed with '
                'workspace_set_parent, not a path-like slug.',
          };
        }
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
        // Land on the just-created workspace when nothing real is selected yet
        // (the active lens is still the empty reserved `_system` slot — e.g.
        // the first workspace in a fresh project). Otherwise Home would sit on
        // an empty slot right after creating content. switchWorkspace persists
        // it, so the choice survives a reboot.
        final active = liveInit.registries.workspace.activeId;
        if (active == null || active == systemWorkspaceSlot) {
          await liveInit.switchWorkspace(ws.id);
        }
        return {'id': ws.id, 'projectRoot': liveInit.projectRoot};
      },
    );

    _register(
      server,
      'workspace_delete',
      'Deactivate (archive) or purge a workspace. Default `archive` RETAINS '
          'all data (members/agents, owned knowledge, skills, charter, KV) and '
          'only hides the workspace from listings — an org\'s history survives '
          'and is restorable via `workspace_restore`. `mode:purge` '
          'hard-deletes the workspace and cascades its agents (irreversible).',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'mode': {
            'type': 'string',
            'enum': ['archive', 'purge'],
            'description':
                'archive (default) = deactivate + retain all data; '
                'purge = irreversible hard delete + agent cascade.',
          },
        },
        'required': ['id'],
      },
      (args) async {
        final id = args['id'] as String;
        final mode = (args['mode'] as String?) ?? 'archive';
        final wasActive = init.registries.workspace.activeId == id;
        int? agentsPurged;
        if (mode == 'purge') {
          // PURGE (explicit, irreversible) — cascade the members' kernel-owned
          // knowledge BEFORE dropping the workspace. `workspace.delete` clears
          // the registry, the `.mbd` bundle, and the agent registry entries —
          // but each agent's OWNED axis stores
          // (`agent_owned_skill|philosophy|index/<agentId>/…`) are keyed by
          // agent id OUTSIDE the workspace partition, so they orphan. The
          // coordinator's knowledge query then surfaces a DELETED org's skills
          // / charter as the current org (stale recall — live-caught
          // 2026-07-08). `deleteAgent` removes the agent's conversation + every
          // owned axis via its index. Snapshot members FIRST — after
          // `workspace.delete` they no longer resolve. Best-effort per agent:
          // one already-gone member must not block the rest or the delete.
          var purged = 0;
          if (init.system.isAgentSubsystemActivated) {
            try {
              final members =
                  await init.registries.member.listForWorkspace(id);
              for (final m in members) {
                if (m is AgentMember && m.agentId.isNotEmpty) {
                  try {
                    await init.system.agents.deleteAgent(m.agentId);
                    purged++;
                  } catch (_) {
                    /* agent already absent — nothing to cascade */
                  }
                }
              }
            } catch (_) {
              /* member enumeration failed — still drop the workspace below */
            }
          }
          agentsPurged = purged;
          await init.registries.workspace.delete(id);
          // workspace.delete clears the on-disk `.mbd` bundle, but the member
          // registry caches members per-workspace — evict so the purge is
          // consistent in-session (no members resolvable by a deleted id).
          init.registries.member.evictWorkspace(id);
          // Purge the org's CHARTER ethos too. It lives in the per-project
          // ethos store keyed `charter.<wsId>` (see `workspace_set_charter`),
          // OUTSIDE the `.mbd` bundle + KV `ws/<id>/` partition that
          // `workspace.delete` clears — so it would otherwise orphan and the
          // coordinator keeps loading a deleted org's charter (stale recall).
          // Delete is an optional port capability (`EthosStoreDelete`); skip
          // cleanly when the wired adapter lacks it.
          final ethosStore = init.ethosStore;
          if (ethosStore is bundle.EthosStoreDelete) {
            final deletable = ethosStore as bundle.EthosStoreDelete;
            try {
              await deletable.deleteEthos('charter.$id');
            } catch (_) {
              /* best-effort — record may be absent */
            }
          }
        } else {
          // ARCHIVE (default) — deactivate + RETAIN everything. An org's
          // accumulated agents / knowledge / skills are institutional memory
          // and must survive a delete; nothing is wiped and no agent is
          // cascaded. Restore with `workspace_restore`.
          await init.registries.workspace.deactivate(id);
        }
        // Removing the ACTIVE lens (either mode) leaves nothing selected (Home
        // goes empty) — reselect the first remaining (non-archived) workspace
        // so a sensible default shows (falls back to the reserved `_system`
        // slot when the last one is gone). switchWorkspace persists the new
        // pointer, so it survives a reboot.
        if (wasActive) {
          final remaining = await init.registries.workspace.list();
          await init.switchWorkspace(
            remaining.isNotEmpty ? remaining.first.id : systemWorkspaceSlot,
          );
        }
        return mode == 'purge'
            ? {'purged': true, 'agentsPurged': agentsPurged}
            : {'archived': true, 'id': id};
      },
    );

    _register(
      server,
      'workspace_restore',
      'Reactivate an archived workspace — the inverse of `workspace_delete` '
          '(archive mode). Restores it to listings with all data intact.',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
      (args) async {
        final id = args['id'] as String;
        final ws = await init.registries.workspace.reactivate(id);
        return {'restored': true, 'id': ws.id};
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
        // switchWorkspace persists the per-project active pointer
        // (`<projectRoot>/.makemind-ops-active`, the boot-restore source read by
        // `_withProjectRoot`) — a switch here NEVER clobbers another project/host
        // via the shared global config.
        await init.switchWorkspace(id);
        // Mirror into the in-memory config so this session's live readers
        // (config_get / the ops.manager agent / `makemind-ops://state`) match
        // the registry — but do NOT persist it to the shared global
        // `~/.makemind-ops/config.yaml`. That single global field is what
        // cross-contaminated hosts/projects (a debug switch overwrote it with a
        // foreign ws id → the release boot fell back to `_system` → empty Home).
        // The per-project file above is now the sole persisted boot-restore
        // source; the global file is left untouched.
        final cfg = await OpsConfig.load();
        if (cfg.activeWorkspace != id) {
          init.notifyConfigChanged(_copyConfig(cfg, activeWorkspace: id));
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
      'workspace_set_lead',
      'Set (or clear) a workspace\'s **lead** (unit head) — the member '
          'who heads the team this workspace represents. Renders at the top of '
          'the unit in the org chart (lead → members) and is the natural '
          'default approver / escalation target. Pass empty/omit `memberId` to '
          'clear. (Workspace = recursive org unit; realizes the team-lead tier '
          'of specs/platform/12-flowbrain-runtime.)',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'memberId': {'type': 'string'},
        },
        'required': ['id'],
      },
      (args) async {
        try {
          final ws = await init.registries.workspace.setLead(
            args['id'] as String,
            args['memberId'] as String?,
          );
          return {'id': ws.id, 'leadMemberId': ws.leadMemberId};
        } on StateError catch (e) {
          return {'error': e.message};
        }
      },
    );
    _register(
      server,
      'workspace_set_unit_role',
      'Classify a workspace as a **line** (operational/business) or **staff** '
          '(support: management support, legal, finance, HR) org unit. The org '
          'chart hangs a staff unit off its parent as a direct side-branch '
          'while line units sit in the main child row; listings sort staff '
          'siblings before line. Defaults to line.',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'unitRole': {
            'type': 'string',
            'enum': ['line', 'staff'],
          },
        },
        'required': ['id', 'unitRole'],
      },
      (args) async {
        final role = WorkspaceUnitRole.values.firstWhere(
          (r) => r.name == (args['unitRole'] as String? ?? 'line'),
          orElse: () => WorkspaceUnitRole.line,
        );
        try {
          final ws = await init.registries.workspace.setUnitRole(
            args['id'] as String,
            role,
          );
          return {'id': ws.id, 'unitRole': ws.unitRole.name};
        } on StateError catch (e) {
          return {'error': e.message};
        }
      },
    );
    _register(
      server,
      'workspace_set_order',
      'Set a workspace\'s explicit sibling ordering hint. Siblings in the org '
          'chart / listings sort by this ascending; `0` = unset, sorting after '
          'any explicitly ordered sibling (then staff-before-line, then id). '
          'Lets an operator lay units out in management-logic order without '
          'renaming slugs (slugs stay stable so agent ids / knowledge / tasks '
          'keyed on them keep working).',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'order': {'type': 'integer'},
        },
        'required': ['id', 'order'],
      },
      (args) async {
        final order = (args['order'] as num?)?.toInt() ?? 0;
        try {
          final ws = await init.registries.workspace.setSortOrder(
            args['id'] as String,
            order,
          );
          return {'id': ws.id, 'sortOrder': ws.sortOrder};
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
      'List members of a workspace (defaults to the caller/active workspace).',
      {
        'type': 'object',
        'properties': {'workspaceId': _workspaceIdParam},
      },
      (args) async {
        final wsId = _wsId(args);
        if (wsId == null) return {'error': 'no active workspace'};
        final members = membersInListingOrder(
          await init.registries.member.listForWorkspace(wsId),
        );
        return {
          'workspace': wsId,
          'members': [
            // Mirror member_get's projection so the identity axes (profileRef /
            // philosophyRef / skillIds) that write tools persist are actually
            // visible on read — a bare {id,kind,displayName} list hid the
            // per-agent individuation and read as "unset".
            for (final m in members)
              {
                'id': m.id,
                'kind': m.kind.name,
                'displayName': m.displayName,
                if (m is AgentMember) 'agentId': m.agentId,
                if (m is AgentMember) 'profileRef': m.profileRef,
                if (m is AgentMember) 'skillIds': m.skillIds,
                if (m is AgentMember) 'philosophyRef': m.philosophyRef,
                if (m is AgentMember && m.model != null) 'model': m.model!.toJson(),
                if (m is PersonMember) 'email': m.email,
                if (m is PersonMember) 'roleLabels': m.roleLabels,
                'tags': m.tags,
              },
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
        final wsId = _wsId(args);
        if (wsId == null) return {'error': 'no active workspace'};
        // Scope by workspace — org member ids collide across departments
        // (every division has a `lead`), so an unscoped lookup returns the
        // global first match (wrong member). Pass wsId so `id` resolves within
        // the requested workspace.
        final m = await init.registries.member.get(
          args['id'] as String,
          wsId: wsId,
        );
        if (m == null) return {'error': 'member not found', 'id': args['id']};
        return {
          'id': m.id,
          'kind': m.kind.name,
          'displayName': m.displayName,
          if (m is AgentMember) 'agentId': m.agentId,
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
      'Create an AI agent in the target workspace (`workspaceId`, defaults to '
          'the active workspace). `provider` + `model` '
          'select the per-agent ModelSpec (catalog ids in '
          'lib/util/llm_model_catalog.dart). When omitted, the agent is '
          'created without an explicit ModelSpec — boot resolves to '
          'OpsConfig.llm.defaultProvider, then `stub/stub-1`.',
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
          'role': {
            'type': 'string',
            'description':
                'Orchestration role — worker | manager | reviewer (manager '
                'routes, reviewer verdicts). Omit to inherit the assigned '
                'profile\'s `defaultRole` (profile = the persona/role), else '
                'worker.',
          },
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
        // Target the requested workspace (defaults to active) so callers can
        // create into a specific department without workspace_switch — matches
        // member_get / member_update / member_delete scoping.
        final wsId =
            (args['workspaceId'] as String?) ??
            init.registries.workspace.activeId;
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
        final profileRef =
            (args['profileRef'] as String?) ?? 'profiles/default';
        // Orchestration role: explicit arg > the assigned profile's
        // `defaultRole` (profile = the persona/role, so the role travels with
        // it) > worker.
        final roleStr = (args['role'] as String?)?.trim().isNotEmpty == true
            ? (args['role'] as String).trim()
            : await _profileDefaultRole(init, wsId, profileRef);
        final agent = await init.registries.member.createAgent(
          id: args['id'] as String,
          // Project + workspace scoped kernel id (member.id stays bare for
          // display) so the adopted host KnowledgeSystem isolates this
          // project's agent + owned forks from other projects.
          agentId: _scopedAgentId(init, wsId, args['id'] as String),
          displayName: args['displayName'] as String,
          profileRef: profileRef,
          skillIds: (args['skillIds'] as List?)?.cast<String>() ?? const [],
          philosophyRef:
              (args['philosophyRef'] as String?) ?? 'philosophies/default',
          workspaceId: wsId,
          model: modelSpec,
          role: _agentRoleFromString(roleStr),
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
        // Live Activity feed: a new agent was provisioned (forkAssigned).
        // Richer than the generic mcpInbound the wrapper skips for this tool.
        init.observability?.bus.info(
          agent.displayName,
          'provisioned in $wsId',
          kind: ActivityKind.forkAssigned,
          workspaceId: wsId,
          meta: {'agentId': agent.agentId},
        );
        return {
          'id': agent.id,
          if (modelSpec != null) 'model': modelSpec.toJson(),
        };
      },
    );

    _register(
      server,
      'agent_ask',
      'Send one user-turn message to an agent and get its reply. Pass '
          '`background:true` to hand it off as an async task instead of waiting '
          '— use this for long work that would otherwise block / time out; the '
          'agent still runs it, and its completion is announced through the '
          'trigger bus (live-chat relay + feed notice) so you are pinged when '
          'it lands.',
      {
        'type': 'object',
        'properties': {
          'agentId': {'type': 'string'},
          'message': {'type': 'string'},
          'background': {
            'type': 'boolean',
            'description':
                'Run asynchronously as a tracked task (no synchronous wait). '
                'Returns a taskId; completion notifies via the trigger bus.',
          },
          'workspaceId': _workspaceIdParam,
        },
        'required': ['agentId', 'message'],
      },
      (args) async {
        if (!init.system.isAgentSubsystemActivated) {
          return {'error': 'Agent Subsystem not activated'};
        }
        // Pin the agent run to a stable workspace (explicit arg → workspace
        // ENCODED in a fully-qualified agentId → inherited execution pin →
        // active snapshot at ask-time), so the agent's own tool calls during
        // the run don't drift when another actor flips the UI lens mid-run.
        // Resolve the member WITHIN this workspace so an explicit,
        // not-yet-opened workspaceId hydrates before the lookup (bare resolve
        // only scans already-loaded workspaces → AgentNotFound).
        //
        // A fully-qualified agentId (`<ns>.<wsEncoded>.<member>`) names its OWN
        // workspace. When the caller omits `workspaceId`, honor that encoded
        // workspace instead of the active lens — otherwise a cross-department
        // ask like `<ns>.org_content.lead` from an org/packages lens would file
        // the task under org/packages and resolve the bare `lead` to a
        // DIFFERENT person (org/packages lead), i.e. mis-deliver to the wrong
        // department. Explicit `workspaceId` still wins.
        final explicitWs = (args['workspaceId'] as String?)?.trim();
        final hasExplicitWs = explicitWs != null && explicitWs.isNotEmpty;
        final agentIdArg = args['agentId'] as String;
        final derivedWs = (!hasExplicitWs && agentIdArg.contains('.'))
            ? await _workspaceOfAgentId(init, agentIdArg)
            : null;
        // A qualified agentId (`<ns>.<wsEncoded>.<member>`) that matches NO
        // member's `.agentId` in any workspace is a typo'd / unknown id. With
        // `workspaceId` omitted it would otherwise trailing-dot fall back to a
        // bare `lead` in the ACTIVE lens — silently mis-delivering to a
        // same-named member in the wrong department. Fail loud instead. (Bare
        // ids and explicit-workspace calls are unaffected.)
        if (!hasExplicitWs && agentIdArg.contains('.') && derivedWs == null) {
          return {
            'error':
                'unknown agent "$agentIdArg" — no member has this qualified '
                'agentId in any workspace; pass a bare member id or an '
                'explicit workspaceId',
          };
        }
        final wsId = _wsId(args, explicit: derivedWs);
        final resolvedId = await _resolveAgentId(
          init,
          args['agentId'] as String,
          wsId: wsId,
        );
        // R6 — opt-in async delegation: instead of blocking the caller on a
        // synchronous turn (which can time out on long work), create a tracked
        // task assigned to the SAME agent and return immediately. The task's
        // assignee run drives the agent (the `agentRun` seam = the same
        // `agents.ask`), and its completion flows back through the trigger bus
        // (R1 → live-chat relay / feed notice), so the caller is pinged when it
        // lands rather than polling.
        if (args['background'] == true) {
          if (wsId == null || wsId.isEmpty) {
            return {'error': 'no workspace resolved for background delegation'};
          }
          final message = args['message'] as String;
          // Canonicalize the assignee to the BARE member id BEFORE creating the
          // task. The caller (often a manager LLM) may pass either the bare id
          // (`proto`) or the full scoped agentId (`<ns>.<ws>.proto`); storing
          // the raw scoped form made the assignee run miss `member.get` and the
          // task silently blocked ("not a runnable agent") → no completion →
          // no report-back. Resolving up front also lets us fail LOUD here
          // (explicit error) instead of creating a doomed task that dies
          // invisibly. The bare id keeps the completion event's sourceAgentId
          // consistent with the once-sub filter below.
          final delegate =
              await init.registries.member.resolve(
                args['agentId'] as String,
                wsId: wsId,
              );
          if (delegate is! AgentMember) {
            return {
              'error':
                  'assignee "${args['agentId']}" is not a runnable agent '
                  'member in workspace "$wsId" — cannot delegate in background',
            };
          }
          final assigneeId = delegate.id;
          final taskId = 'ask-async-${DateTime.now().microsecondsSinceEpoch}';
          await init.registries.task.create(
            Task(
              id: taskId,
              workspaceId: wsId,
              kind: TaskKind.oneOff,
              title: message.length > 60
                  ? '${message.substring(0, 60)}…'
                  : message,
              description: message,
              assigneeIds: [assigneeId],
              skillIds: const [],
              createdAt: DateTime.now(),
            ),
          );
          // Auto report-back: if this delegation was issued from a live chat
          // (the user talking to a coordinator), wire a ONE-SHOT subscription
          // so the completion wakes that coordinator to report in the chat
          // window the user is watching — without the coordinator having to
          // know its own scoped id or hand-write a subscription. Skipped for
          // headless/MCP delegations with no active chat, and never targets the
          // delegated agent itself.
          final coordinator = OpsBuiltInApp.activeCoordinatorId;
          var reportBack = false;
          // Filter the once-sub on the SAME bare id the completion event will
          // carry as sourceAgentId (`_emitCompleted` uses the task assignee),
          // so the report-back reliably matches. Never wire a self-report if
          // the coordinator is itself the delegate.
          if (coordinator != null &&
              coordinator != assigneeId &&
              coordinator != delegate.agentId) {
            await init.triggers.subscribe(
              workspaceId: wsId,
              targetAgentId: coordinator,
              sourceAgentId: assigneeId,
              kind: WorkKind.task,
              once: true,
              requestTemplate:
                  'The background task you delegated just completed: {summary} '
                  '(from {sourceAgentId}). Report the result to the user.',
            );
            reportBack = true;
          }
          unawaited(init.registries.task.run(taskId));
          return {
            'agentId': resolvedId,
            'assigneeResolved': assigneeId,
            'background': true,
            'taskId': taskId,
            'reportBackTo': reportBack ? coordinator : null,
            'note': reportBack
                ? 'Delegated as async task; on completion the active chat '
                    'coordinator is woken to report back.'
                : 'Delegated as async task; completion notifies via the '
                    'trigger bus.',
          };
        }
        // Resolve the feed actor to a displayName — never the raw qualified
        // agentId (audit P1.3; the Activity feed renders `event.actor` as-is).
        final askMembers = (wsId == null || wsId.isEmpty)
            ? const <Member>[]
            : await init.registries.member.listForWorkspace(wsId);
        // Live Activity feed: the incoming user turn (agentAsk). Paired with
        // the agentReply below so the feed shows both sides of the exchange.
        _emitAgentTurn(
          memberDisplayNameFor(askMembers, resolvedId),
          'asked: ',
          args['message'] as String,
          ActivityKind.agentAsk,
          workspaceId: wsId,
        );
        // Serialize per agent — concurrent requests to the same agent queue
        // and run one at a time (worker model + conversation race-free).
        final reply = await serializePerAgent(
          resolvedId,
          () => WorkspaceExecutionContext.run(
            wsId,
            () => init.system.agents.ask(resolvedId, args['message'] as String),
          ),
        );
        // Live Activity feed: the agent's reply (agentReply).
        _emitAgentTurn(
          memberDisplayNameFor(askMembers, reply.agentId),
          'replied · ',
          reply.content,
          ActivityKind.agentReply,
          workspaceId: wsId,
        );
        // Trigger bus (R1): the answering agent completed an ask. Emitted for
        // subscriptions / observability; a synchronous ask is not relayed to
        // the live chat (the caller already has the reply — see the R3 seam).
        _emitWork(
          source: reply.agentId,
          workspaceId: wsId ?? '',
          kind: WorkKind.ask,
          refId: 'ask:${reply.agentId}:${DateTime.now().microsecondsSinceEpoch}',
          summary: reply.content,
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
      'A manager/lead agent divides work: routes a request to the best-fit '
          'member. Pass `execute:true` to also RUN the chosen member on the '
          'request and return their deliverable (`deliverable` + '
          '`deliveredBy`) — the "assign + request output" flow (lead → member '
          '→ result). Ids may be bare member ids (`dev1`, `ops.manager.<ws>_*`); '
          'they are resolved to the kernel the same way `agent_ask` does.',
      const {
        'type': 'object',
        'properties': {
          'managerId': {'type': 'string'},
          'request': {'type': 'string'},
          'candidateAgentIds': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'execute': {
            'type': 'boolean',
            'description':
                'When true, run the routed member on the request and return '
                'their deliverable (assign + collect in one call).',
          },
        },
        'required': ['managerId', 'request'],
      },
      (args) async {
        if (!init.system.isAgentSubsystemActivated) {
          return {'error': 'Agent Subsystem not activated'};
        }
        // Resolve manager + candidate ids to their scoped kernel agent ids —
        // callers pass bare member ids, which the kernel `route()` otherwise
        // cannot find (AgentNotFoundException). Keep a scoped→bare map so the
        // decision reads back in the caller's terms.
        final managerId = await _resolveAgentId(
          init,
          args['managerId'] as String,
        );
        final rawCandidates =
            (args['candidateAgentIds'] as List?)?.cast<String>();
        List<String>? candidates;
        final scopedToBare = <String, String>{};
        if (rawCandidates != null) {
          candidates = <String>[];
          for (final c in rawCandidates) {
            final scoped = await _resolveAgentId(init, c);
            candidates.add(scoped);
            scopedToBare[scoped] = c;
          }
        }
        final decision = await init.system.agents.route(
          managerId,
          args['request'] as String,
          candidateAgentIds: candidates,
        );
        final target = decision.targetAgentId;
        final result = <String, dynamic>{
          'targetAgentId': scopedToBare[target] ?? target,
          'confidence': decision.confidence,
          if (decision.reason != null) 'reason': decision.reason,
        };
        // Persist the delegation as an `agent.routed` fact — the decision
        // used to be returned and dropped, leaving no from→to trail, so the
        // org chart could never show WHO handed work to WHOM (the living
        // org chart's delegation edges and the artifact-journey view both
        // read this).
        final routedWs = init.registries.knowledge.kv.workspaceId;
        if (routedWs != null && target.isNotEmpty) {
          final now = DateTime.now();
          await init.registries.knowledge.knowledgeSystem.facts
              .writeFacts(<bundle.FactRecord>[
            bundle.FactRecord(
              id: 'agent.routed/${now.microsecondsSinceEpoch}',
              workspaceId: routedWs,
              type: 'agent.routed',
              entityId: scopedToBare[target] ?? target,
              content: <String, dynamic>{
                'fromAgentId': args['managerId'],
                'targetAgentId': scopedToBare[target] ?? target,
                'workspaceId': routedWs,
                'confidence': decision.confidence,
                if (decision.reason != null) 'reason': decision.reason,
              },
              confidence: 1.0,
              createdAt: now,
            ),
          ]);
        }
        // Assign + collect: actually run the routed member so the lead gets a
        // real deliverable back (member history records the turn — no
        // fabricated "member reported" from the manager).
        if (args['execute'] == true && target.isNotEmpty) {
          final reply = await serializePerAgent(
            target,
            () => init.system.agents.ask(target, args['request'] as String),
          );
          result['deliveredBy'] = scopedToBare[target] ?? reply.agentId;
          result['deliverable'] = reply.content;
          if (reply.finishReason != null) {
            result['finishReason'] = reply.finishReason;
          }
          // Live Activity feed: the routed member's deliverable (agentReply) —
          // actor resolved to displayName, never the raw agentId (audit P1.3).
          final routeMembers = (routedWs == null || routedWs.isEmpty)
              ? const <Member>[]
              : await init.registries.member.listForWorkspace(routedWs);
          _emitAgentTurn(
            memberDisplayNameFor(
              routeMembers,
              scopedToBare[target] ?? reply.agentId,
            ),
            'delivered · ',
            reply.content,
            ActivityKind.agentReply,
            workspaceId: routedWs,
          );
          // Trigger bus (R1): the routed member completed the delegated work.
          // Emitted for subscriptions / observability; synchronous, so not
          // relayed to the live chat (the manager already holds the result).
          _emitWork(
            source: scopedToBare[target] ?? reply.agentId,
            workspaceId: routedWs ?? '',
            kind: WorkKind.route,
            refId:
                'route:${args['managerId']}->${scopedToBare[target] ?? target}',
            summary: reply.content,
          );
        }
        return result;
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
      'Update the model used by a chat / system agent. Defaults to '
          'id="_ops_admin"; pass `agentId` to target a custom system agent or '
          'a workspace-scoped chat manager (e.g. "ops.manager.<unit>").',
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
        final agentId = await _resolveAgentId(
          init,
          (args['agentId'] as String?) ?? '_ops_admin',
        );
        final spec = ModelSpec(
          provider: args['provider'] as String,
          model: args['model'] as String,
        );
        // Route to the registry that actually owns the agent. Worker /
        // system agents created through the per-project member path live in
        // `init.system`; workspace-scoped chat managers
        // (`ops.manager.<unit>`) are created by `AgentHost.ensureScopedManager`
        // in the GLOBAL host system (chat dispatch runs through that shared
        // host). Try per-project first, then fall back to the shared host so
        // set_model reaches either without the caller knowing the topology.
        if (init.system.isAgentSubsystemActivated &&
            await init.system.agents.getAgent(agentId) != null) {
          final updated = await init.system.agents.updateAgent(
            agentId,
            model: spec,
          );
          return {
            'id': updated.id,
            'model': '${updated.model.provider}/${updated.model.model}',
            'scope': 'project',
          };
        }
        final hostAgents = AgentHost.shared?.flowbrain.system.agents;
        if (hostAgents != null && await hostAgents.getAgent(agentId) != null) {
          final updated = await hostAgents.updateAgent(agentId, model: spec);
          return {
            'id': updated.id,
            'model': '${updated.model.provider}/${updated.model.model}',
            'scope': 'host',
          };
        }
        return {
          'error':
              'agent not found: $agentId (neither the per-project system nor '
              'the host scoped-manager registry holds it)',
        };
      },
    );

    // --- Org charter (per-project active anchor ethos) ---
    // The workspace charter IS the per-project active ethos (cherry-confirmed
    // per-project routing). `workspace_set_charter` writes + activates it;
    // `philosophy_check` is the per-project gate path (replaces the global
    // `bk.philosophy.check`); `workspace_get_charter` reads it for display.
    _register(
      server,
      'philosophy_check',
      'Check a proposed action / output against the ACTIVE workspace charter '
          '(per-project ethos). Returns `{hasHardViolation, hardViolationIds, '
          'softViolationIds}`. The process philosophy gate routes here so it '
          'judges against this workspace\'s charter, not a global ethos.',
      const {
        'type': 'object',
        'properties': {
          'action': {'type': 'string'},
          'actor': {'type': 'string'},
          'output': {'type': 'string'},
        },
      },
      (args) async {
        // Enforce the charter inherited along THIS workspace's own ancestor
        // chain: the prohibitions of the company ∘ department ∘ own
        // charter all gate (same-line only). Deterministic seam =
        // `forbiddenPatterns` substring (the NL seam is unwired), applied here
        // across the whole chain instead of a single per-project active ethos.
        final wsId = init.registries.workspace.activeId ?? '_system';
        final chain = await _charterChain(init, wsId);
        if (chain.sources.isEmpty) {
          // No charter anywhere on the chain → fail open (as before).
          return <String, dynamic>{
            'hasHardViolation': false,
            'hardViolationIds': <String>[],
            'softViolationIds': <String>[],
          };
        }
        final haystack =
            '${args['action'] ?? ''}\n${args['output'] ?? ''}'.toLowerCase();
        final hard = <String>[];
        final soft = <String>[];
        for (final p in chain.prohibitions) {
          final hit = p.patterns.any(
            (pat) => pat.isNotEmpty && haystack.contains(pat.toLowerCase()),
          );
          if (hit) (p.hard ? hard : soft).add(p.id);
        }
        return <String, dynamic>{
          'hasHardViolation': hard.isNotEmpty,
          'hardViolationIds': hard,
          'softViolationIds': soft,
          'charterSources': chain.sources, // which org levels contributed
        };
      },
    );

    _register(
      server,
      'workspace_set_charter',
      'Set the active (bound) workspace\'s org charter — mission / values / '
          'prohibitions / north-star — as the per-project active anchor ethos. '
          'It then governs the workspace: the process philosophy gate + '
          'opted-in agents judge against it; members inherit it (override only '
          'via an explicit per-member philosophy fork). Reuses the kernel Ethos '
          '(prohibitions = the rules that actually gate; mission / values / '
          'north-star are descriptive, carried in metadata).',
      const {
        'type': 'object',
        'properties': {
          'mission': {'type': 'string'},
          'values': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          // Each item: a string (statement; relies on the NL judgment seam)
          // or `{statement, patterns:[..]}` — patterns are the deterministic
          // forbidden substrings that actually gate (mcp_philosophy honors
          // `forbiddenPatterns`), so a charter that must HARD-block supplies
          // patterns. String-only prohibitions are advisory until the NL seam
          // is wired.
          'prohibitions': {'type': 'array'},
          'doctrineRef': {'type': 'string'},
          'northStar': {'type': 'string'},
        },
      },
      (args) async {
        final store = init.ethosStore;
        if (store == null) {
          return {'error': 'no per-project ethos store — open a project first'};
        }
        final wsId = init.registries.workspace.activeId ?? '_system';
        final mission = (args['mission'] as String?)?.trim() ?? '';
        final values =
            (args['values'] as List?)?.cast<String>() ?? const <String>[];
        // Normalise prohibitions to {statement, patterns[]} — tolerate plain
        // strings.
        final prohibitions = <({String statement, List<String> patterns})>[];
        for (final raw in (args['prohibitions'] as List? ?? const [])) {
          if (raw is String) {
            prohibitions.add((statement: raw, patterns: const <String>[]));
          } else if (raw is Map) {
            final stmt = (raw['statement'] as String?)?.trim() ?? '';
            if (stmt.isEmpty) continue;
            prohibitions.add((
              statement: stmt,
              patterns:
                  (raw['patterns'] as List?)?.cast<String>() ?? const <String>[],
            ));
          }
        }
        final northStar = (args['northStar'] as String?)?.trim() ?? '';
        final doctrineRef = (args['doctrineRef'] as String?)?.trim() ?? '';
        final now = DateTime.now();
        final ethosId = 'charter.$wsId';
        final ethos = bundle.Ethos(
          id: ethosId,
          name: mission.isEmpty ? '$wsId charter' : mission,
          valuePriorities: const [],
          prohibitions: <bundle.Prohibition>[
            for (var i = 0; i < prohibitions.length; i++)
              bundle.Prohibition(
                id: 'charter_p$i',
                statement: prohibitions[i].statement,
                severity: bundle.ProhibitionSeverity.hard,
                rationale: 'org charter',
                forbiddenPatterns: prohibitions[i].patterns,
              ),
          ],
          metadata: bundle.EthosMetadata(
            version: '1',
            createdAt: now,
            updatedAt: now,
            context: jsonEncode(<String, dynamic>{
              'kind': 'charter',
              'workspaceId': wsId,
              if (mission.isNotEmpty) 'mission': mission,
              if (values.isNotEmpty) 'values': values,
              if (northStar.isNotEmpty) 'northStar': northStar,
              if (doctrineRef.isNotEmpty) 'doctrineRef': doctrineRef,
            }),
            tags: const <String>['charter', 'anchor'],
          ),
        );
        // Ethos governance — provenance lives at
        // the ethos payload top level: `payload.provenance = {kind: 'anchor'}`.
        // A charter is an anchor (a principle), so it activates immediately;
        // member overrides are `derived` (serves: this charter) via their own
        // fork. (Charter writes the per-project store directly, not the global
        // `bk.philosophy.put` — cherry's per-project routing decision.)
        await store.putEthos(
          bundle.EthosRecord(
            id: ethosId,
            name: ethos.name,
            version: '1',
            payload: <String, dynamic>{
              ...ethos.toJson(),
              'provenance': <String, dynamic>{'kind': 'anchor'},
            },
            createdAt: now,
          ),
        );
        await store.activateEthos(ethosId);
        return <String, dynamic>{
          'ok': true,
          'workspace': wsId,
          'ethosId': ethosId,
          'prohibitions': prohibitions.length,
        };
      },
    );

    _register(
      server,
      'workspace_get_charter',
      'Read a workspace\'s EFFECTIVE charter — resolved along its own '
          'org ancestor chain (07 §182, same line only): prohibitions '
          'accumulate (company + department + own), mission / values / '
          'north-star take the nearest (self-first) value. `inheritedFrom` '
          'lists the org levels that contributed. `charter` is null when no '
          'charter is set anywhere on the chain. Defaults to the caller/active '
          'workspace; pass workspaceId to target another.',
      {
        'type': 'object',
        'properties': {'workspaceId': _workspaceIdParam},
      },
      (args) async {
        final wsId = _wsId(args) ?? '_system';
        final chain = await _charterChain(init, wsId);
        if (chain.sources.isEmpty) return <String, dynamic>{'charter': null};
        return <String, dynamic>{
          'charter': <String, dynamic>{
            'workspace': wsId,
            'mission': chain.descriptive['mission'],
            'values': chain.descriptive['values'],
            'northStar': chain.descriptive['northStar'],
            'doctrineRef': chain.descriptive['doctrineRef'],
            // Accumulated prohibitions with the org level that set each.
            'prohibitions': <Map<String, dynamic>>[
              for (final p in chain.prohibitions)
                <String, dynamic>{
                  'statement': p.statement,
                  'from': p.source,
                  'hard': p.hard,
                },
            ],
            'inheritedFrom': chain.sources, // self → ancestors (nearest first)
            'isCharter': true,
          },
        };
      },
    );

    // --- Org memory (RFC4) — lessons the ORG accumulates, not a member's.
    // Stored as workspace-scoped facts (`category:"org_lesson"`) in the
    // per-project FactGraph, so they survive member churn and agents already
    // retrieve them through the existing workspace knowledge query (the
    // "learning loop"). No new kernel / store — reuses `saveFact`.
    _register(
      server,
      'workspace_record_lesson',
      'Record an org-level lesson for a workspace — what worked / a '
          'rejection pattern / a learning — so it persists at the organization '
          '(not the member) and outlives member turnover. Stored as a '
          '`category:"org_lesson"` workspace fact in the per-project FactGraph. '
          '`workspaceId` targets a specific department (defaults to the active / '
          'execution-pinned workspace).',
      {
        'type': 'object',
        'properties': {
          'learning': {'type': 'string'},
          'situation': {'type': 'string'},
          'outcome': {'type': 'string'},
          'tags': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'workspaceId': _workspaceIdParam,
        },
        'required': ['learning'],
      },
      (args) async {
        final learning = (args['learning'] as String?)?.trim() ?? '';
        if (learning.isEmpty) return {'error': 'learning required'};
        final key = 'lesson_${DateTime.now().millisecondsSinceEpoch}';
        await init.registries.knowledge.saveFact(
          category: 'org_lesson',
          key: key,
          value: learning,
          metadata: <String, Object?>{
            if ((args['situation'] as String?)?.isNotEmpty ?? false)
              'situation': args['situation'],
            if ((args['outcome'] as String?)?.isNotEmpty ?? false)
              'outcome': args['outcome'],
            if (args['tags'] != null) 'tags': args['tags'],
          },
          workspaceId: _wsId(args),
        );
        return {'ok': true, 'key': key};
      },
    );

    _register(
      server,
      'workspace_lessons',
      'List the active workspace\'s accumulated org lessons '
          '(`category:"org_lesson"`), newest first.',
      const {
        'type': 'object',
        'properties': {
          'limit': {'type': 'integer'},
        },
      },
      (args) async {
        final facts = await init.registries.knowledge.listKvFacts();
        final lessons =
            facts.where((f) => f.category == 'org_lesson').toList()
              ..sort((a, b) => (b.savedAt ?? '').compareTo(a.savedAt ?? ''));
        final limit = (args['limit'] as num?)?.toInt() ?? 50;
        return <String, dynamic>{
          'lessons': <Map<String, dynamic>>[
            for (final l in lessons.take(limit))
              <String, dynamic>{
                'key': l.key,
                'learning': l.value,
                'situation': l.metadata['situation'],
                'outcome': l.metadata['outcome'],
                'savedAt': l.savedAt,
              },
          ],
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
          'tags, or — for agents — their LLM ModelSpec and orchestration '
          '`role` (worker | manager | reviewer). Re-role is IN PLACE: the '
          'kernel agent record is updated without delete/recreate, so the '
          'individual\'s FactGraph · owned forks · history are preserved. '
          '`provider` + `model` must be supplied together when changing the '
          'ModelSpec; passing only one is rejected. Defaults to the active '
          'workspace when workspaceId is omitted.',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'workspaceId': {'type': 'string'},
          'displayName': {'type': 'string'},
          'role': {
            'type': 'string',
            'enum': ['worker', 'manager', 'reviewer'],
            'description': 'Orchestration role — changed in place '
                '(individuality preserved).',
          },
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
        final roleArg = (args['role'] as String?)?.trim();
        AgentRole? role;
        if (roleArg != null && roleArg.isNotEmpty) {
          role = AgentRole.values.asNameMap()[roleArg];
          // Unknown role = reject (no silent default) — same contract as
          // the kernel's bk.agent.update.
          if (role == null) {
            return {
              'error':
                  'unknown role "$roleArg" — expected worker | manager | '
                  'reviewer',
            };
          }
        }
        final m = await init.registries.member.update(
          memberId: args['id'] as String,
          workspaceId: wsId,
          displayName: args['displayName'] as String?,
          role: role,
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
          if (m is AgentMember) 'role': m.role.name,
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
      'Global list of members across all workspaces — every workspace member '
          'is a distinct row. Member ids are unique only WITHIN a workspace '
          '(each department has its own `lead`, `qa`, …), so the same id in '
          'two workspaces are two different members and are keyed by '
          '`(workspaceId, id)`. The total equals the sum of the per-workspace '
          'member_list counts. Rows are ordered hierarchically like the org '
          'chart: workspaces in org-tree order (root first, each parent '
          'followed by its children), and within a workspace persons '
          '(owner / CEO) above agents. Each row carries `depth` and '
          '`parentWorkspaceId` for rendering the tree.',
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
        final q = args['query'] as String?;
        // Order workspaces by the org tree (root → children) so the flat list
        // reads hierarchically, matching the visual org chart.
        final ordered = orderWorkspacesHierarchical(
          await init.registries.workspace.list(),
        );
        final perWorkspace =
            <({String wsId, String? parentId, int depth, List<Member> members})>[];
        for (final e in ordered) {
          perWorkspace.add((
            wsId: e.ws.id,
            parentId: e.ws.parentId,
            depth: e.depth,
            members: await init.registries.member.listForWorkspace(e.ws.id),
          ));
        }
        return buildGlobalMemberList(
          perWorkspace,
          kindFilter: kindFilter,
          query: q,
        );
      },
    );

    // --- Tasks ---

    _register(
      server,
      'task_list',
      'List tasks in a workspace (defaults to the caller/active workspace).',
      {
        'type': 'object',
        'properties': {'workspaceId': _workspaceIdParam},
      },
      (args) async {
        final wsId = _wsId(args);
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
          'workspaceId': _workspaceIdParam,
        },
        'required': ['id', 'title', 'skillIds'],
      },
      (args) async {
        final wsId = _wsId(args);
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
        return {
          'runId': ref.runId,
          'endState': ref.endState.name,
          // The assignee agent's deliverable (or skill result) — so the caller
          // sees the produced output, not just a completed flag.
          if (ref.summary != null) 'summary': ref.summary,
        };
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

    _register(server, 'process_list', 'List processes (defaults to the '
        'caller/active workspace).', {
      'type': 'object',
      'properties': {'workspaceId': _workspaceIdParam},
    }, (args) async {
      final wsId = _wsId(args);
      if (wsId == null) return {'error': 'no active workspace'};
      final list = await init.registries.process.list(wsId: wsId);
      final processes = <Map<String, dynamic>>[];
      for (final p in list) {
        // Runs live in the `process_runs` checkpoint partition (read via
        // listRuns), NOT the in-memory `Process.runs` field — that field is
        // never populated on a YAML-loaded process, so `p.runs.length` was
        // always 0 and disagreed with the Board's live count (konpi live
        // re-verify). Count the real checkpoints.
        final runs = await init.registries.process.listRuns(
          p.id,
          workspaceId: wsId,
        );
        processes.add({
          'id': p.id,
          'title': p.title,
          'steps': p.steps.length,
          'trigger': p.trigger.name,
          'gates': p.gates.length,
          'runs': runs.length,
          if (runs.isNotEmpty) 'lastRunState': runs.last.state.name,
        });
      }
      return {'processes': processes};
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
        // Run count from the checkpoint partition, not the always-empty
        // in-memory `Process.runs` field (see process_list note).
        final runs = await init.registries.process.listRuns(p.id);
        return {
          'id': p.id,
          'title': p.title,
          'trigger': p.trigger.name,
          // Cross-process event chain (trigger: event) — echoed so a tool
          // reader sees the same topology the disk YAML carries.
          if (p.triggerSource != null && p.triggerSource!.isNotEmpty)
            'triggerSource': p.triggerSource,
          'steps': [
            for (final s in p.steps)
              {
                'stepId': s.stepId,
                'assigneeId': s.assigneeId,
                'skillId': s.skillId,
                'inputs': s.inputs,
                // Explicit DAG deps — omitted when empty (default linear
                // chain), so readers can distinguish "no topology" from
                // "depends on nothing".
                if (s.dependsOn.isNotEmpty) 'dependsOn': s.dependsOn,
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
          'runs': runs.length,
          if (runs.isNotEmpty) 'lastRunState': runs.last.state.name,
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
      'Start a process. Pass async:true to return immediately with a running '
          'run and drive it in the background — use for long pipelines whose '
          'agent steps each take an LLM turn (a synchronous start would block '
          'the caller for the whole run). Then poll process_get / process_runs '
          'for the gate / completion.',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'inputs': {'type': 'object'},
          'async': {'type': 'boolean'},
        },
        'required': ['id'],
      },
      (args) async {
        final pid = args['id'] as String;
        // Re-mirror the process from its current YAML into the LIVE behavior
        // engine before running, so the engine executes the latest
        // `_processToBehavior` compilation. The on-disk `project.mbd` mirror is
        // only refreshed by `process_save`; without this just-in-time re-mirror
        // a compiler improvement (or a process edited outside the tool) would
        // run a STALE behavior until a manual re-save. Live registration only
        // (no disk write / no `.history` churn) — best-effort.
        try {
          final p = await init.registries.process.get(pid);
          if (p != null) {
            final behaviorJson = await _processToBehavior(p);
            init.registerProjectBehavior(
              bundle.BehaviorDefinition.fromJson(behaviorJson),
            );
          }
        } catch (_) {
          // Fall back to whatever behavior is already registered.
        }
        final run = await init.registries.process.start(
          pid,
          initialInputs: (args['inputs'] as Map?)?.cast<String, dynamic>(),
          background: args['async'] == true,
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
          'explicitly only when an alternate identity needs to be asserted. '
          'Pass async:true to return immediately (running) and drive the '
          'approved steps in the background when they dispatch agent turns — '
          'then poll process_get / process_runs.',
      const {
        'type': 'object',
        'properties': {
          'runId': {'type': 'string'},
          'approverId': {'type': 'string'},
          'async': {'type': 'boolean'},
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
            background: args['async'] == true,
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
        final wsId = _wsId(args);
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
          final behaviorJson = await _processToBehavior(p);
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
          // Signal the silent no-op: a 0-fragment ingest means the file was
          // read but nothing was chunked/extracted into searchable facts
          // (no embedding/extraction provider wired). Without this note the
          // caller mistakes the empty result for a successful RAG ingest.
          if (fragments == 0)
            'note':
                'No fragments emitted — nothing was chunked into searchable '
                'facts (no ingest/embedding provider is configured), so this '
                'file will NOT appear in fact/RAG queries. Use '
                'knowledge_file_write/read for verbatim storage, or wire an '
                'ingest provider to enable RAG.',
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

    // --- Trigger subscriptions (agent↔agent completion wakes, R2) ---

    _register(
      server,
      'trigger_subscribe',
      'Wake an agent when another agent completes work. When a completion '
          'matches the filters (sourceAgentId / kind / onState, each optional = '
          'any), the target agent is asked with the rendered request — the '
          'event-driven "A finished → B continues" chaining the process '
          'completion chain does for processes. Placeholders in requestTemplate: '
          '{summary} {sourceAgentId} {refId} {kind} {state} {artifactRef}.',
      const {
        'type': 'object',
        'properties': {
          'targetAgentId': {
            'type': 'string',
            'description': 'Member id of the agent to wake.',
          },
          'sourceAgentId': {
            'type': 'string',
            'description': 'Only when THIS agent completes (default: any).',
          },
          'kind': {
            'type': 'string',
            'enum': ['task', 'route', 'ask', 'step'],
            'description': 'Only this work kind (default: any).',
          },
          'onState': {
            'type': 'string',
            'enum': ['completed', 'blocked', 'any'],
            'description': 'React to this completion state (default: completed).',
          },
          'requestTemplate': {
            'type': 'string',
            'description': 'Request handed to the target agent when fired.',
          },
          'workspaceId': _workspaceIdParam,
        },
        'required': ['targetAgentId'],
      },
      (args) async {
        final wsId = _wsId(args);
        if (wsId == null || wsId.isEmpty) {
          return {'ok': false, 'error': 'no workspace resolved'};
        }
        final kindName = args['kind'] as String?;
        final sub = await init.triggers.subscribe(
          workspaceId: wsId,
          targetAgentId: args['targetAgentId'] as String,
          sourceAgentId: args['sourceAgentId'] as String?,
          kind: kindName == null
              ? null
              : WorkKind.values.firstWhere(
                  (k) => k.name == kindName,
                  orElse: () => WorkKind.task,
                ),
          onState: (args['onState'] as String?) ?? 'completed',
          requestTemplate: args['requestTemplate'] as String?,
        );
        return {'ok': true, 'id': sub.id, 'workspaceId': wsId, ...sub.toJson()};
      },
    );

    _register(
      server,
      'trigger_list',
      'List the agent-completion trigger subscriptions in a workspace.',
      const {
        'type': 'object',
        'properties': {'workspaceId': _workspaceIdParam},
      },
      (args) async {
        final wsId = _wsId(args);
        final subs = await init.triggers.list(wsId: wsId);
        return {
          'triggers': subs
              .map((s) => {'workspaceId': s.workspaceId, ...s.toJson()})
              .toList(),
        };
      },
    );

    _register(
      server,
      'trigger_unsubscribe',
      'Remove an agent-completion trigger subscription by id.',
      const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
      (args) async {
        final ok = await init.triggers.unsubscribe(args['id'] as String);
        return {'ok': ok};
      },
    );

    // --- Skill & bundle catalog ---

    _register(
      server,
      'skill_list',
      'List loaded skills (workspace + agent overlay). Defaults to the '
          'caller/active workspace; pass workspaceId to target another.',
      {
        'type': 'object',
        'properties': {
          'actorId': {'type': 'string'},
          'workspaceId': _workspaceIdParam,
        },
      },
      (args) async {
        final wsId = _wsId(args);
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
      {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'actorId': {'type': 'string'},
          'workspaceId': _workspaceIdParam,
        },
        'required': ['id'],
      },
      (args) async {
        final wsId = _wsId(args);
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
          'workspaceId': _workspaceIdParam,
        },
        'required': ['yaml', 'scope'],
      },
      (args) async {
        final wsId = _wsId(args);
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
            path = '${_wsRoot(init, wsId)}/skills/${def.id}.yaml';
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
          init.skills.register(def, workspaceId: wsId);
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

    // --- Asset operation (ops-asset-management P3) ---

    _register(
      server,
      'asset_open',
      'Operate an asset registered in this workspace (a `category:"asset"` '
          'fact) through its capability — `fs.read` / `db.query` / '
          '`browser.page_view`, or an authenticated HTTP GET for an '
          'api/homepage asset. The `credentialRef` is resolved from the OS '
          'keychain INTERNALLY and used by the operation; the secret is never '
          'returned — only the result and a `credentialUsed` flag.',
      const {
        'type': 'object',
        'properties': {
          'assetId': {'type': 'string'},
        },
        'required': ['assetId'],
      },
      (args) async {
        final id = (args['assetId'] as String?) ?? '';
        final facts = await init.registries.knowledge.listKvFacts();
        final hit = facts.where((f) => f.category == 'asset' && f.key == id);
        if (hit.isEmpty) {
          return <String, dynamic>{'ok': false, 'error': 'asset not found: $id'};
        }
        final m = hit.first.metadata;
        final capability = (m['capability'] ?? '').toString();
        final locator = (m['locator'] ?? '').toString();
        final credentialRef = (m['credentialRef'] ?? '').toString();
        // Resolve the credential internally — never returned to the caller.
        String? secret;
        if (credentialRef.isNotEmpty) {
          final SecureStorage store = FlutterSecureStorageBackend();
          secret = await store.read(
            credentialRef,
            namespace: 'appplayer.credentials',
          );
        }
        final credentialUsed = secret != null && secret.isNotEmpty;

        Future<Map<String, dynamic>> hostJson(
          String tool,
          Map<String, dynamic> a,
        ) async {
          final r = await server.callTool(tool, a);
          final t = r.content
              .whereType<KernelTextContent>()
              .map((c) => c.text)
              .join();
          try {
            final d = jsonDecode(t);
            return d is Map
                ? d.cast<String, dynamic>()
                : <String, dynamic>{'value': d};
          } catch (_) {
            return <String, dynamic>{'text': t};
          }
        }

        String clip(String s) => s.length > 400 ? '${s.substring(0, 400)}…' : s;

        Map<String, dynamic> result;
        switch (capability) {
          case 'fs':
            // Use the project-aware host fs capability so a project-relative
            // locator resolves against the active project (portable across
            // folder rename/copy/move). `studio.fs.read` returns `content`.
            final r = await hostJson('studio.fs.read', {'path': locator});
            result = {
              'preview': clip((r['content'] ?? r['text'] ?? '').toString()),
            };
            break;
          case 'db':
            result = await hostJson('db.query', {
              'statement':
                  "SELECT name FROM sqlite_master WHERE type='table' LIMIT 20",
            });
            break;
          case 'browser':
            result = await hostJson('browser.page_view', {'url': locator});
            break;
          default:
            if (locator.startsWith('http')) {
              final headers = <String, String>{};
              if (credentialUsed) headers['Authorization'] = 'Bearer $secret';
              final res = await http.get(Uri.parse(locator), headers: headers);
              result = {
                'status': res.statusCode,
                'bodyPreview': clip(res.body),
              };
            } else {
              result = {
                'note': 'no operation wired for capability "$capability"',
              };
            }
        }
        return <String, dynamic>{
          'ok': true,
          'assetId': id,
          'capability': capability,
          'locator': locator,
          'credentialUsed': credentialUsed,
          'result': result,
        };
      },
    );

    // --- Credential migration (ops-asset-management P4) ---
    // Seal this workspace's asset credentials under a passphrase so they can be
    // carried to another computer. The OS-keychain key never leaves the machine;
    // only the passphrase (held by the operator) and the opaque sealed blob do.
    _register(
      server,
      'credentials_export',
      'Seal the asset credentials of this workspace under a passphrase, '
          'returning a portable opaque blob (PBKDF2 + AEAD via the platform '
          'PassphraseSealer). Collects every `credentialRef` declared by a '
          '`category:"asset"` fact, reads each secret from the OS keychain, and '
          'seals the `{ref: secret}` map. Secrets are NEVER returned in '
          'plaintext — only the encrypted blob and the list of refs included. '
          'Restore on the target machine with `credentials_import`.',
      const {
        'type': 'object',
        'properties': {
          'passphrase': {'type': 'string'},
        },
        'required': ['passphrase'],
      },
      (args) async {
        final passphrase = (args['passphrase'] as String?) ?? '';
        if (passphrase.isEmpty) {
          return <String, dynamic>{'ok': false, 'error': 'passphrase required'};
        }
        final refs = await _assetCredentialRefs(init);
        if (refs.isEmpty) {
          return <String, dynamic>{
            'ok': false,
            'error': 'no asset credentials declared in this workspace',
          };
        }
        // Seal via the vendored recipe's CredentialMigrator (vault read + seal);
        // the host only decides which refs (from asset facts).
        final sealed = await _migrator().seal(refs, passphrase);
        if (sealed.blob == null) {
          return <String, dynamic>{
            'ok': false,
            'error': 'no stored credentials to export',
            'refsDeclared': refs.toList()..sort(),
          };
        }
        return <String, dynamic>{
          'ok': true,
          'count': sealed.count,
          'refsDeclared': refs.toList()..sort(),
          'sealed': sealed.blob,
        };
      },
    );

    _register(
      server,
      'credentials_import',
      'Unseal a blob produced by `credentials_export` with its passphrase and '
          'restore each credential into the OS keychain. Returns the refs '
          'restored — secret values are never echoed. A wrong passphrase or a '
          'tampered blob fails authentication and writes nothing.',
      const {
        'type': 'object',
        'properties': {
          'passphrase': {'type': 'string'},
          'sealed': {'type': 'string'},
        },
        'required': ['passphrase', 'sealed'],
      },
      (args) async {
        final passphrase = (args['passphrase'] as String?) ?? '';
        final sealed = (args['sealed'] as String?) ?? '';
        if (passphrase.isEmpty || sealed.isEmpty) {
          return <String, dynamic>{
            'ok': false,
            'error': 'passphrase and sealed are required',
          };
        }
        List<String> restored;
        try {
          // Unseal + restore to keychain via the recipe's CredentialMigrator.
          restored = await _migrator().restore(sealed, passphrase);
        } catch (_) {
          // Wrong passphrase / tampered blob / malformed — nothing written.
          return <String, dynamic>{
            'ok': false,
            'error': 'unseal failed (wrong passphrase or corrupt blob)',
          };
        }
        return <String, dynamic>{'ok': true, 'restored': restored};
      },
    );

    // --- Knowledge editing ---

    _register(
      server,
      'knowledge_fact_save',
      'Save a knowledge fact at category/key (writes to both FactFacade and KV). '
          '`workspaceId` attributes the fact to a specific department (defaults '
          'to the active / execution-pinned workspace) — e.g. record a fact '
          'ABOUT an `org/media` member while pinned elsewhere.',
      {
        'type': 'object',
        'properties': {
          'category': {'type': 'string'},
          'key': {'type': 'string'},
          'value': {'type': 'string'},
          'metadata': {'type': 'object'},
          'workspaceId': _workspaceIdParam,
        },
        'required': ['category', 'key', 'value'],
      },
      (args) async {
        final category = args['category'] as String;
        final wsId = _wsId(args);
        var metadata = (args['metadata'] as Map?)?.cast<String, Object?>();
        // Project portability: an asset's `fs` locator is stored PROJECT-ROOT
        // RELATIVE so renaming / copying / moving the project folder never
        // breaks the link. Resolution happens at read time — the host `fs.*`
        // capability resolves a relative locator against the active project
        // root ([registerFsTools.activeProjectRoot]). URLs / external refs and
        // non-`fs` capabilities pass through unchanged.
        if (category == 'asset' &&
            metadata != null &&
            init.projectRoot.isNotEmpty) {
          final cap = (metadata['capability'] ?? '').toString();
          final loc = (metadata['locator'] ?? '').toString();
          if (cap == 'fs' && loc.isNotEmpty) {
            // Relativise against the SAME anchor the host `fs.*` capability
            // resolves against at read time — the ops PROJECT root (the single
            // per-project chat / fs anchor). Workspaces are logical lenses;
            // assets are project-shared and connect to a workspace / agent by
            // reference, not by a separate per-workspace filesystem base — so
            // `asset_open` round-trips after a folder rename / copy / move.
            final anchor = init.projectRoot;
            metadata = <String, Object?>{
              ...metadata,
              'locator': ProjectPaths.toRelative(anchor, loc),
            };
          }
        }
        await init.registries.knowledge.saveFact(
          category: category,
          key: args['key'] as String,
          value: args['value'] as Object,
          metadata: metadata,
          workspaceId: wsId,
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
        // Formal share overlay: surface facts that other
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

    // --- Per-project FactGraph portability (vendored knowledge_persistence
    // recipe). The bound project's graph lives on disk at
    // `<projectRoot>/.factgraph`; these tools back up, restore, and delete
    // that store. Disk-level operations take effect when the project is next
    // (re)opened — the live in-memory runtime is rebuilt at boot, so callers
    // get `reopenRequired: true` to signal a reopen is needed to observe the
    // change in the current session.
    _register(
      server,
      'knowledge_fact_export',
      'Export the bound project\'s FactGraph as a portable map keyed by '
          'collection name (backup / transfer). Reads the on-disk graph at '
          '`<projectRoot>/.factgraph`. Fails when no project is bound '
          '(welcome state uses an in-memory graph with nothing on disk).',
      const {'type': 'object', 'properties': {}},
      (args) async {
        final dir = init.factGraphDir;
        if (dir == null) {
          return <String, dynamic>{
            'ok': false,
            'error': 'no project bound — open a project to export its graph',
          };
        }
        final data = await exportProject(dir);
        final counts = <String, int>{
          for (final e in data.entries) e.key: e.value.length,
        };
        return <String, dynamic>{'ok': true, 'counts': counts, 'data': data};
      },
    );

    _register(
      server,
      'knowledge_fact_import',
      'Import a previously exported FactGraph map into the bound project\'s '
          'on-disk graph (`<projectRoot>/.factgraph`), replacing the named '
          'collections. Reopen the project to load the imported graph into '
          'the live runtime.',
      const {
        'type': 'object',
        'properties': {
          'data': {
            'type': 'object',
            'description':
                'Map of collection-name -> list of records, as produced by '
                'knowledge_fact_export.',
          },
        },
        'required': ['data'],
      },
      (args) async {
        final dir = init.factGraphDir;
        if (dir == null) {
          return <String, dynamic>{
            'ok': false,
            'error': 'no project bound — open a project to import a graph',
          };
        }
        final raw = args['data'];
        if (raw is! Map) {
          return <String, dynamic>{'ok': false, 'error': 'data must be a map'};
        }
        final data = <String, List<Map<String, dynamic>>>{};
        for (final e in raw.entries) {
          final list = e.value;
          if (list is List) {
            data[e.key as String] = <Map<String, dynamic>>[
              for (final item in list)
                if (item is Map) item.cast<String, dynamic>(),
            ];
          }
        }
        await importProject(dir, data);
        return <String, dynamic>{
          'ok': true,
          'imported': <String, int>{
            for (final e in data.entries) e.key: e.value.length,
          },
          'reopenRequired': true,
        };
      },
    );

    _register(
      server,
      'knowledge_purge',
      'Delete the bound project\'s entire on-disk FactGraph '
          '(`<projectRoot>/.factgraph`). This is the complete purge for the '
          'per-project model — the project\'s facts live only here. Requires '
          '`confirm: true`. Reopen the project to rebuild an empty graph.',
      const {
        'type': 'object',
        'properties': {
          'confirm': {
            'type': 'boolean',
            'description': 'Must be true — purge is irreversible.',
          },
        },
        'required': ['confirm'],
      },
      (args) async {
        if (args['confirm'] != true) {
          return <String, dynamic>{
            'ok': false,
            'error': 'confirm must be true to purge',
          };
        }
        final dir = init.factGraphDir;
        if (dir == null) {
          return <String, dynamic>{
            'ok': false,
            'error': 'no project bound — nothing on disk to purge',
          };
        }
        await purgeProject(dir);
        return <String, dynamic>{
          'ok': true,
          'purged': dir,
          'reopenRequired': true,
        };
      },
    );

    _register(
      server,
      'knowledge_file_list',
      'List files under knowledge/ for the workspace, INCLUDING those inherited '
          'from its org ancestor chain (07 §182, same line only — parent → '
          'grandparent → …, never a sibling branch). The workspace\'s own file '
          'shadows an ancestor file at the same path. Inherited entries carry '
          '`inheritedFrom` (the ancestor that owns them). Recursive; paths '
          'relative to the owning workspace.',
      const {
        'type': 'object',
        'properties': {
          'workspaceId': {'type': 'string'},
          'subPath': {'type': 'string', 'description': 'Subdirectory filter'},
          'ownOnly': {
            'type': 'boolean',
            'description': 'true = skip ancestor inheritance (own files only).',
          },
        },
      },
      (args) async {
        final wsId =
            (args['workspaceId'] as String?) ??
            init.registries.workspace.activeId;
        if (wsId == null) return {'error': 'no active workspace'};
        final subPath = args['subPath'] as String? ?? '';
        final ownOnly = args['ownOnly'] == true;
        // Self first, then the parentId chain — own shadows ancestor.
        final chain = <String>[
          wsId,
          if (!ownOnly) ...await init.registries.workspace.ancestors(wsId),
        ];
        final files = <Map<String, dynamic>>[];
        final seen = <String>{}; // relative path — nearer level wins
        for (var i = 0; i < chain.length; i++) {
          final owner = chain[i];
          final root = _wsRoot(init, owner);
          final base =
              '$root/knowledge${subPath.isEmpty ? "" : "/$subPath"}';
          final dir = Directory(base);
          if (!await dir.exists()) continue;
          await for (final e in dir.list(recursive: true)) {
            if (e is! File) continue;
            final rel = e.path.substring('$root/'.length);
            if (!seen.add(rel)) continue; // a nearer level already provided it
            final stat = await e.stat();
            files.add({
              'path': rel,
              'size': stat.size,
              'modifiedAt': stat.modified.toIso8601String(),
              if (i > 0) 'inheritedFrom': owner,
            });
          }
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
        // Own file first, then inherit down the org ancestor chain (same line).
        final chain = <String>[
          wsId,
          ...await init.registries.workspace.ancestors(wsId),
        ];
        for (var i = 0; i < chain.length; i++) {
          final owner = chain[i];
          final f = File('${_wsRoot(init, owner)}/$rel');
          if (await f.exists()) {
            return {
              'path': rel,
              'content': await f.readAsString(),
              if (i > 0) 'inheritedFrom': owner,
            };
          }
        }
        return {'error': 'file not found on workspace or its ancestor chain: $rel'};
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
      'Engine state snapshot (counts of workspaces, members, tasks, processes, '
          'bundles, skills). Per-workspace counts default to the caller/active '
          'workspace; pass workspaceId to snapshot another.',
      {
        'type': 'object',
        'properties': {'workspaceId': _workspaceIdParam},
      },
      (args) async {
        final wsId = _wsId(args);
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
        // Count the skills actually visible in this workspace (disk + shared
        // + agent overlay), matching `skill_list`. `init.skills` is only the
        // static boot app-skill list, so it under-reported (e.g. 2 vs 12).
        final skillIds = wsId == null
            ? const <String>[]
            : await init.skillResolver.visibleIds(
                workspaceId: wsId,
                actorId: null,
              );
        return {
          'activeWorkspace': wsId,
          'workspaceCount': wsList.length,
          'members': members.length,
          'tasks': tasks.length,
          'processes': processes.length,
          'catalogBundles': bundles.length,
          'installedBundles': installed.length,
          'skills': skillIds.length,
          'internalLlm': init.adapters.llm.hasInternalLlm,
          // Sampling fallback available when a connected MCP client
          // advertises the `sampling` capability — skill_generate and
          // `kind: llm` steps borrow the client's LLM via spec
          // `sampling/createMessage`.
          'samplingFallback': init.skillExecutor.samplingProvider != null,
          // Whether AGENT turns (agent_ask / member work) can actually run.
          // The agent subsystem is LLM-backed via the claude-code KEYLESS
          // kernel fallback (agentLlmSessions, wired at host boot) even when
          // NO internal provider is configured — so a status report must NOT
          // read `internalLlm=false` as "no LLM, config required". This is the
          // signal that reflects reality: agents are backed and running.
          'agentLlm': init.system.isAgentSubsystemActivated,
          // Any LLM path reachable at all — internal provider OR MCP sampling
          // OR the keyless agent kernel. Union so a configured-provider-only
          // check can't report `false` while agents run fine on the fallback.
          'anyLlm': init.skillExecutor.hasAnyLlm ||
              init.system.isAgentSubsystemActivated,
        };
      },
    );

    // ── Showcase / portability tools ─────────────────────────────────────
    // External Claude / Code clients can drive the same operations the GUI
    // exposes in the sidebar — opspack export/import and the diagnostic
    // bundle.
    //
    // Hardcoded scenario "recipes" (catalog + seeder) were removed: pre-baked
    // sample content must not live in builtin code — the app starts empty and
    // the user creates a project. See feedback_no_hardcoded_sample_seed.

    _register(
      server,
      'opspack_export',
      'Export a workspace as a `.opspack` archive. Returns the file path on disk. '
          'With `includeSecrets:true` + a `passphrase`, the active workspace\'s '
          'asset credentials are passphrase-sealed and embedded so the pack '
          'carries them to another machine (the secrets stay encrypted — opspack '
          'never sees plaintext).',
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
          'includeSecrets': {
            'type': 'boolean',
            'description':
                'When true, seal the active workspace\'s asset credentials '
                'into the pack. Requires `passphrase` and `workspaceId` to be '
                'the active workspace.',
          },
          'passphrase': {
            'type': 'string',
            'description': 'Required when `includeSecrets` is true.',
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
          'Returns the resolved workspace id. If the pack carries sealed '
          'credentials and a `passphrase` is supplied, the asset credentials '
          'are unsealed and restored into this machine\'s keychain.',
      const {
        'type': 'object',
        'properties': {
          'packPath': {'type': 'string'},
          'conflictPolicy': {
            'type': 'string',
            'description':
                'rename (default) · skip · overwrite. Controls behavior on duplicate workspace id.',
          },
          'passphrase': {
            'type': 'string',
            'description':
                'When the pack carries sealed credentials, the passphrase to '
                'unseal and restore them into the OS keychain.',
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
    final includeSecrets = args['includeSecrets'] == true;
    final passphrase = (args['passphrase'] as String?) ?? '';

    // Seal the active workspace's asset credentials when asked. Scoped to the
    // active workspace (the credential collector reads active-workspace facts),
    // so the export target must be active.
    String? sealedCredentials;
    int sealedCount = 0;
    if (includeSecrets) {
      if (passphrase.isEmpty) {
        return {'error': 'includeSecrets requires a passphrase'};
      }
      final active = init.registries.workspace.activeId;
      if (wsId != active) {
        return {
          'error':
              'includeSecrets seals the ACTIVE workspace ($active); switch to '
              '$wsId before exporting its secrets.',
        };
      }
      final sealed = await _sealActiveCredentials(init, passphrase);
      sealedCredentials = sealed.blob;
      sealedCount = sealed.count;
    }

    // Use the live project-bound root (same source as `_wsRoot` / member_* /
    // skill_*). `OpsConfig.load().workspacesRoot` is empty for a freshly bound
    // project (it isn't persisted), which produced "Workspace dir not found:".
    final dir = Directory(wsContentRoot(init.projectRoot, wsId));
    // When facts are requested, carry the project-level disk FactGraph
    // (`<projectRoot>/.factgraph`) — it lives above the workspace subtree, so
    // we serialize it via the recipe and hand the snapshot to opspack.
    Map<String, List<Map<String, dynamic>>>? factGraph;
    final graphDir = init.factGraphDir;
    if (includeFacts && graphDir != null) {
      factGraph = await exportProject(graphDir);
    }
    final pack = await Opspack.exportWorkspace(
      workspaceDir: dir,
      workspaceId: wsId,
      includeFacts: includeFacts,
      sealedCredentials: sealedCredentials,
      factGraph: factGraph,
    );
    await File(outPath).writeAsBytes(pack.bytes);
    return {
      'workspaceId': wsId,
      'path': outPath,
      'fileCount': pack.manifest.contents.length,
      'bytes': pack.bytes.length,
      'includeFacts': includeFacts,
      'includeSecrets': pack.manifest.includeSecrets,
      'sealedCredentialCount': sealedCount,
    };
  }

  Future<Map<String, Object?>> _importOpspack(
    KnowledgeInit init,
    Map<String, dynamic> args,
  ) async {
    final policy = args['conflictPolicy'] as String? ?? Opspack.conflictRename;
    final passphrase = (args['passphrase'] as String?) ?? '';
    final packFile = File(args['packPath'] as String);
    // Live project-bound root — `OpsConfig.load().workspacesRoot` is empty for
    // a freshly bound project (same fix as _exportOpspack / _wsRoot).
    final id = await Opspack.importWorkspace(
      packFile: packFile,
      workspacesRoot: Directory(init.projectRoot),
      conflictPolicy: policy,
    );

    // Restore sealed credentials into the keychain when the pack carries them
    // and a passphrase is supplied. Never echoes plaintext.
    final result = <String, Object?>{'workspaceId': id, 'conflictPolicy': policy};
    final packBytes = await packFile.readAsBytes();

    // Rehydrate the project FactGraph snapshot, if the pack carries one, into
    // this project's disk graph (`<projectRoot>/.factgraph`). The live runtime
    // is rebuilt at boot, so a reopen is needed to observe it this session.
    final graphDir = init.factGraphDir;
    final packedGraph = Opspack.extractFactGraph(packBytes);
    if (packedGraph != null && graphDir != null) {
      await importProject(graphDir, packedGraph);
      result['factGraphImported'] = <String, int>{
        for (final e in packedGraph.entries) e.key: e.value.length,
      };
      result['reopenRequired'] = true;
    }

    final sealed = Opspack.extractSealedCredentials(packBytes);
    if (sealed != null) {
      if (passphrase.isEmpty) {
        result['credentials'] = 'present but not restored (no passphrase)';
      } else {
        try {
          final restored = await _restoreSealedCredentials(sealed, passphrase);
          result['credentialsRestored'] = restored;
        } catch (_) {
          result['credentials'] = 'restore failed (wrong passphrase or corrupt)';
        }
      }
    }
    return result;
  }

  /// Credential refs declared by the active workspace's `asset` facts. Deciding
  /// which refs to migrate is the host's job; the crypto + vault I/O is the
  /// vendored recipe's [CredentialMigrator].
  Future<Set<String>> _assetCredentialRefs(KnowledgeInit init) async {
    final facts = await init.registries.knowledge.listKvFacts();
    return <String>{
      for (final f in facts)
        if (f.category == 'asset')
          (f.metadata['credentialRef'] ?? '').toString(),
    }..removeWhere((r) => r.isEmpty);
  }

  /// Recipe migrator over the OS keychain (default `appplayer.credentials` ns).
  CredentialMigrator _migrator() =>
      CredentialMigrator(FlutterSecureStorageBackend());

  /// Seal the active workspace's asset credentials under [passphrase].
  /// Null blob when none are stored.
  Future<({String? blob, int count})> _sealActiveCredentials(
    KnowledgeInit init,
    String passphrase,
  ) async =>
      _migrator().seal(await _assetCredentialRefs(init), passphrase);

  /// Unseal [sealed] and write each credential back into the OS keychain.
  Future<List<String>> _restoreSealedCredentials(
    String sealed,
    String passphrase,
  ) =>
      _migrator().restore(sealed, passphrase);

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
        final sw = Stopwatch()..start();
        try {
          final result = await handler(Map<String, dynamic>.from(args));
          _emitInbound(name, sw.elapsedMilliseconds, error: false);
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
          _emitInbound(name, sw.elapsedMilliseconds, error: true, detail: msg);
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

  /// Tools that publish their OWN richer activity event (`agent_ask` /
  /// `agent_route` emit `agentAsk` / `agentReply`). The generic `_register`
  /// wrapper skips them so a single call is not double-logged.
  static const Set<String> _selfReportingTools = <String>{
    'agent_ask',
    'agent_route',
    'member_create_agent',
  };

  /// Emit an [ActivityKind.mcpInbound] event so the Live Activity feed reflects
  /// control-plane traffic — every system-tool call an external client or an
  /// acting agent makes lands here. UI reads go straight through
  /// `init.registries.*` (not these handlers), so this is genuine inbound
  /// traffic, not the boards' own polling. Best-effort — observability is
  /// optional (a stdio CLI runs without it).
  void _emitInbound(
    String tool,
    int ms, {
    required bool error,
    String? detail,
  }) {
    if (_selfReportingTools.contains(tool)) return;
    final bus = init.observability?.bus;
    if (bus == null) return;
    if (error) {
      bus.error(
        'mcp',
        'Tool $tool failed · ${ms}ms',
        kind: ActivityKind.mcpInbound,
        meta: {'tool': tool, if (detail != null) 'detail': detail},
      );
    } else {
      bus.info(
        'mcp',
        'Tool $tool · ${ms}ms',
        kind: ActivityKind.mcpInbound,
        meta: {'tool': tool},
      );
    }
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
    if (scope == 'workspace') init.skills.register(def, workspaceId: wsId);
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
  ///     verdict. Calls the per-project `philosophy_check` Ops tool (which
  ///     reads THIS workspace's active charter ethos via
  ///     `init.system.philosophy`), NOT the global `bk.philosophy.check`
  ///     (which binds `backbone.app`); the behavior dispatcher merges its
  ///     `hasHardViolation` result into run state so the gate's `when` can
  ///     read it and route to `stop` on a hard violation.
  Future<Map<String, dynamic>> _processToBehavior(Process p) async {
    final gatesByStep = <String, List<ProcessGate>>{};
    for (final g in p.gates) {
      (gatesByStep[g.afterStep] ??= <ProcessGate>[]).add(g);
    }
    final steps = <Map<String, dynamic>>[];
    // Maps a process stepId → the behavior node that marks its completion
    // (the step's own node, or the last gate/handoff node chained after it).
    // An explicit `dependsOn` on a later step is resolved against this so the
    // dependency points at the predecessor's *terminal* node, not a mid-chain
    // gate. Absent map entry ⇒ depend on the raw step id (forward ref / typo
    // tolerated).
    final stepTerminal = <String, String>{};
    String? prev;
    for (final s in p.steps) {
      // The action node's upstream deps: explicit `dependsOn` (a real DAG —
      // independent branches run in parallel) resolved to terminal nodes, else
      // the textually-previous step (the default linear chain).
      final List<String> stepDeps =
          s.dependsOn.isNotEmpty
              ? [for (final d in s.dependsOn) stepTerminal[d] ?? d]
              : (prev != null ? <String>[prev] : const <String>[]);
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
          if (stepDeps.isNotEmpty) 'dependsOn': stepDeps,
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
          if (stepDeps.isNotEmpty) 'dependsOn': stepDeps,
        });
      } else {
        // A work step drives its assignee the SAME way `task_run` does (the
        // documented assignee-aware contract): when the assignee is an AGENT
        // member, run that agent for a turn — it applies its own skill /
        // accumulated expertise — through the host `agent_ask` tool; a person /
        // unknown / empty assignee falls back to headless skill dispatch.
        // Without this, an agent-assigned step ran the skill BODY headless, and
        // a body-less skill (the common case — skills are declared while the
        // agent does the thinking) then no-ops, so the run reached `completed`
        // with zero agent work. Assignee kind is resolved at mirror time (the
        // member exists when the process is saved); cross-workspace assignees
        // resolve via the registry's global scan.
        final isDelegate = s.skillId == 'agent_ask' || s.skillId == 'delegate';
        final assignee = s.assigneeId;
        final assigneeIsAgent =
            !isDelegate &&
            assignee.isNotEmpty &&
            (await init.registries.member.get(
                  assignee,
                  wsId: p.workspaceId,
                ))?.kind ==
                MemberKind.agent;
        final Map<String, dynamic> action;
        if (isDelegate || assigneeIsAgent) {
          final directive =
              (s.inputs['task'] ?? s.inputs['message'] ?? s.inputs['prompt'])
                  ?.toString();
          final message =
              isDelegate
                  ? (directive ?? p.title)
                  : (directive ??
                          'Carry out your "${s.skillId}" responsibility for this step.') +
                      (s.inputs.isEmpty ? '' : '\nContext: ${s.inputs}');
          action = <String, dynamic>{
            'tool': 'agent_ask',
            'args': <String, dynamic>{'agentId': assignee, 'message': message},
          };
        } else {
          action = <String, dynamic>{
            'skill': s.skillId,
            'inputs': <String, dynamic>{
              ...s.inputs,
              if (assignee.isNotEmpty) 'actor': assignee,
            },
          };
        }
        steps.add(<String, dynamic>{
          'id': s.stepId,
          'do': action,
          if (stepDeps.isNotEmpty) 'dependsOn': stepDeps,
        });
      }
      var dep = s.stepId;
      // G5 handoff — when a step routes to a channel thread, post a formal
      // handoff notification to it so the next team receives the deliverable
      // signal (cross-team exchange). Routes to the host
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
                // Per-project charter gate (`philosophy_check`) — judges
                // against THIS workspace's active charter ethos, not the
                // global `bk.philosophy.check` (which binds `backbone.app`).
                'tool': 'philosophy_check',
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
      stepTerminal[s.stepId] = dep;
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

  /// Resolve the **effective charter along a workspace's own ancestor chain**
  /// (top-down inheritance, same line only). Walks `[wsId, …ancestors]`
  /// — `WorkspaceRegistry.ancestors` follows the `parentId` chain and NEVER a
  /// sibling / other branch, so a workspace only inherits from its own line.
  /// Prohibitions **accumulate** up the chain (company ∘ dept ∘ own); mission /
  /// northStar / values / doctrineRef take the **nearest** (self-first) value.
  /// Returns the collected prohibitions (with source level), the nearest
  /// descriptive fields, and the source levels that contributed.
  Future<
      ({
        List<
                ({
                  String id,
                  String source,
                  String statement,
                  List<String> patterns,
                  bool hard
                })>
            prohibitions,
        Map<String, dynamic> descriptive,
        List<String> sources,
      })> _charterChain(KnowledgeInit init, String wsId) async {
    final phil = init.system.philosophy;
    final prohibitions = <({
      String id,
      String source,
      String statement,
      List<String> patterns,
      bool hard
    })>[];
    final descriptive = <String, dynamic>{};
    final sources = <String>[];
    if (!phil.isAvailable) {
      return (prohibitions: prohibitions, descriptive: descriptive, sources: sources);
    }
    // Self first, then the parentId chain (nearest ancestor → root). Same line
    // only — ancestors() excludes siblings / other branches by construction.
    final chain = <String>[
      wsId,
      ...await init.registries.workspace.ancestors(wsId),
    ];
    for (final id in chain) {
      final charterId = 'charter.$id';
      try {
        final e = await phil.getEthosById(charterId);
        // Guard: getEthosById may fall back to the active ethos for an unknown
        // id — only accept the ethos that is THIS level's charter.
        if (e.id != charterId) continue;
        sources.add(id);
        for (final pr in e.prohibitions) {
          prohibitions.add((
            id: '$id/${pr.id}',
            source: id,
            statement: pr.statement,
            patterns: pr.forbiddenPatterns,
            hard: pr.severity == bundle.ProhibitionSeverity.hard,
          ));
        }
        final c = e.metadata.context;
        if (c != null && c.isNotEmpty) {
          try {
            final ctx = jsonDecode(c) as Map<String, dynamic>;
            for (final k in const ['mission', 'northStar', 'doctrineRef', 'values']) {
              if (descriptive[k] == null && ctx[k] != null) {
                descriptive[k] = ctx[k];
              }
            }
          } catch (_) {}
        }
      } catch (_) {
        // No charter at this level — skip; a higher ancestor may still have one.
      }
    }
    return (prohibitions: prohibitions, descriptive: descriptive, sources: sources);
  }

  /// Map a role string to [AgentRole]; unknown / null → worker.
  AgentRole _agentRoleFromString(String? s) {
    switch ((s ?? '').trim().toLowerCase()) {
      case 'manager':
        return AgentRole.manager;
      case 'reviewer':
        return AgentRole.reviewer;
      default:
        return AgentRole.worker;
    }
  }

  /// The assigned profile's `defaultRole` (profile = the persona/role, so the
  /// orchestration role travels with it). Best-effort file read from the
  /// workspace's `profiles/<id>.yaml`; null when absent. `profileRef` may be
  /// `profiles/<id>` or a bare `<id>`.
  Future<String?> _profileDefaultRole(
    KnowledgeInit init,
    String wsId,
    String profileRef,
  ) async {
    if (profileRef.isEmpty || init.projectRoot.isEmpty) return null;
    final id = profileRef.replaceFirst(RegExp(r'^profiles/'), '');
    try {
      final f = File('${wsContentRoot(init.projectRoot, wsId)}/profiles/$id.yaml');
      if (!await f.exists()) return null;
      final y = loadYaml(await f.readAsString());
      if (y is Map && y['defaultRole'] is String) {
        return y['defaultRole'] as String;
      }
    } catch (_) {
      /* best-effort */
    }
    return null;
  }

  /// Resolve a caller-supplied agent id to the kernel agentId. MCP callers
  /// pass the bare local id (`editor`); the Members UI passes the stored
  /// `member.agentId` already. Looking the member up returns its stored
  /// `agentId` (the scoped kernel id for agents created after scoping
  /// landed); an unknown id (already-scoped, or a host agent like
  /// `_ops_admin`) passes through unchanged. Existing pre-scoping members
  /// keep their bare stored agentId, so nothing breaks.
  Future<String> _resolveAgentId(
    KnowledgeInit init,
    String idOrScoped, {
    String? wsId,
  }) async {
    // When the caller pinned an explicit workspace, resolve the member
    // WITHIN it so a not-yet-opened workspace hydrates before the lookup
    // (otherwise the bare scan misses it and we hand the kernel a bare id it
    // cannot find → AgentNotFoundException; D4).
    final m = await init.registries.member.get(idOrScoped, wsId: wsId);
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
      // Inherited from an org ancestor — still a workspace skill, just owned
      // higher up the chain.
      for (final ancestor in await init.registries.workspace.ancestorIds(wsId)) {
        final af = File('${_wsRoot(init, ancestor)}/skills/$skillId.yaml');
        if (await af.exists()) return 'workspace';
      }
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
