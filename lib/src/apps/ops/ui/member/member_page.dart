import 'package:appplayer_studio/builtin_api.dart' show ModelSpec;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../registries/member_registry.dart';
import '../../registries/workspace_registry.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../util/llm_model_catalog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_with_action.dart';
import '../../widgets/llm_model_dropdown.dart';
import '../../widgets/ops_atoms.dart';
import '../../widgets/ops_models.dart' as ds;
import 'agent_detail_dialog.dart';

/// Member management page. Scope is driven by [globalScopeProvider] (the
/// shell-level globe toggle in the AppBar). The header chip mirrors and
/// can also flip the same provider.
class MemberPage extends ConsumerWidget {
  const MemberPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final globalScope = ref.watch(globalScopeProvider);
    return Column(
      children: [
        _Header(
          globalScope: globalScope,
          onToggle: (v) => ref.read(globalScopeProvider.notifier).state = v,
        ),
        const Divider(height: 1),
        Expanded(
          child:
              globalScope
                  ? const _GlobalMemberList()
                  : const _WorkspaceMemberList(),
        ),
      ],
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.globalScope, required this.onToggle});
  final bool globalScope;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wsId = ref.watch(activeWorkspaceIdProvider);
    final label =
        globalScope ? 'Members · All' : 'Members · ${wsId ?? "none selected"}';
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.titleLarge),
          ),
          _ScopeToggle(value: globalScope, onChanged: onToggle),
          const SizedBox(width: 12),
          if (!globalScope && wsId != null)
            FilledButton.icon(
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Add agent'),
              onPressed: () => _showAgentForm(context, ref, wsId, null),
            ),
        ],
      ),
    );
  }
}

class _ScopeToggle extends StatelessWidget {
  const _ScopeToggle({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message:
          value
              ? 'Switch to current workspace only'
              : 'Switch to all workspaces',
      child: FilterChip(
        avatar: Icon(value ? Icons.public : Icons.person_outline, size: 18),
        label: Text(value ? 'All' : 'This workspace'),
        selected: value,
        onSelected: onChanged,
      ),
    );
  }
}

// --- Workspace-scoped list ---------------------------------------------

class _WorkspaceMemberList extends ConsumerWidget {
  const _WorkspaceMemberList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wsId = ref.watch(activeWorkspaceIdProvider);
    if (wsId == null) {
      return const EmptyState(
        icon: Icons.folder_open_outlined,
        headline: 'Select a workspace',
        hint: 'Pick or create a workspace from the sidebar to see its members.',
      );
    }
    final membersAsync = ref.watch(workspaceMembersProvider(wsId));
    return membersAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error:
          (e, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: ErrorWithAction(
              message: 'Could not load members.',
              detail: '$e',
              actions: [
                ErrorAction(
                  label: 'Retry',
                  icon: Icons.refresh,
                  primary: true,
                  onPressed:
                      () => ref.invalidate(workspaceMembersProvider(wsId)),
                ),
              ],
            ),
          ),
      data: (members) {
        if (members.isEmpty) {
          return EmptyState(
            icon: Icons.group_outlined,
            headline: 'No members yet',
            hint:
                'Add an AI agent to delegate work, or seed a recipe for a ready-made team.',
            actionLabel: 'Try a recipe',
            onAction:
                () => ref.read(shellRouteProvider.notifier).state = 'recipes',
          );
        }
        return ListView.builder(
          itemCount: members.length,
          itemBuilder:
              (_, i) => _MemberTile(member: members[i], workspaceId: wsId),
        );
      },
    );
  }
}

class _MemberTile extends ConsumerWidget {
  const _MemberTile({required this.member, required this.workspaceId});
  final Member member;
  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAgent = member is AgentMember;
    final agent = isAgent ? member as AgentMember : null;
    final actor = ds.ActivityActor(
      kind: isAgent ? ds.ActorKind.agent : ds.ActorKind.human,
      label: member.displayName,
    );
    final dsKind = isAgent ? ds.MemberKind.ai : ds.MemberKind.human;
    final subtitle =
        member.id + (agent != null ? ' · ${agent.skillIds.length} skills' : '');

    return InkWell(
      onTap:
          agent == null
              ? null
              : () => showAgentDetailDialog(
                context,
                ref,
                agentId: agent.agentId,
                displayName: agent.displayName,
              ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: OpsColors.border)),
        ),
        child: Row(
          children: [
            OpsActorAvatar(actor: actor, size: 32, online: isAgent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          member.displayName,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: OpsType.semibold,
                            color: OpsColors.text2,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OpsRoleTag(kind: dsKind),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: OpsType.mono,
                      fontSize: 10,
                      color: OpsColors.text3,
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz, size: 16),
              onSelected: (value) async {
                switch (value) {
                  case 'capture':
                    if (agent != null) {
                      await _captureAuth(context, ref, workspaceId, agent);
                      ref.invalidate(workspaceMembersProvider(workspaceId));
                    }
                    break;
                  case 'edit':
                    if (agent != null) {
                      _showAgentForm(context, ref, workspaceId, agent);
                    }
                    break;
                  case 'detach':
                    await opsCallTool(ref, 'member_detach', <String, dynamic>{
                      'id': member.id,
                      'fromWorkspace': workspaceId,
                    });
                    ref.invalidate(workspaceMembersProvider(workspaceId));
                    break;
                }
              },
              itemBuilder:
                  (_) => [
                    if (isAgent)
                      const PopupMenuItem(
                        height: 32,
                        value: 'capture',
                        child: Text('Capture AuthProfile'),
                      ),
                    if (isAgent)
                      const PopupMenuItem(
                        height: 32,
                        value: 'edit',
                        child: Text('Edit'),
                      ),
                    const PopupMenuItem(
                      height: 32,
                      value: 'detach',
                      child: Text('Remove from workspace'),
                    ),
                  ],
            ),
          ],
        ),
      ),
    );
  }
}

// --- Global (cross-workspace) list -------------------------------------

class _GlobalMemberRow {
  _GlobalMemberRow({
    required this.id,
    required this.displayName,
    required this.kind,
  });
  final String id;
  final String displayName;
  final MemberKind kind;
  final Set<String> workspaces = {};
}

class _GlobalMemberList extends ConsumerWidget {
  const _GlobalMemberList();

  Future<List<_GlobalMemberRow>> _load(
    dynamic init,
    List<Workspace> wsList,
  ) async {
    final byId = <String, _GlobalMemberRow>{};
    for (final ws in wsList) {
      // Legacy KV path — Ops's own MemberRegistry. Kept while Phase C-2
      // dual-sources the listing so the regression surface is visible
      // side-by-side with the manifest-driven kernel path.
      final members = await init.registries.member.listForWorkspace(ws.id);
      for (final m in members) {
        final row = byId.putIfAbsent(
          m.id,
          () => _GlobalMemberRow(
            id: m.id,
            displayName: m.displayName,
            kind: m.kind,
          ),
        );
        row.workspaces.add(ws.id);
      }
      // Kernel path — agents registered through BundleActivation against
      // `<projectName>.<wsId>.mbd`. Read through the standard
      // `KnowledgeSystem.agents` facade so manifest mutators flow into
      // the same list the operator sees.
      final kernelAgents = await init.listKernelAgentsForWorkspace(ws.id);
      for (final a in kernelAgents) {
        final row = byId.putIfAbsent(
          a.id,
          () => _GlobalMemberRow(
            id: a.id,
            displayName: a.displayName,
            kind: MemberKind.agent,
          ),
        );
        row.workspaces.add(ws.id);
      }
    }
    final list = byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    return list;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(memberChangesProvider);
    final init = ref.watch(knowledgeInitProvider);
    final wsAsync = ref.watch(workspaceListProvider);
    return wsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data:
          (wsList) => FutureBuilder<List<_GlobalMemberRow>>(
            future: _load(init, wsList),
            builder: (_, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final rows = snap.data ?? const <_GlobalMemberRow>[];
              if (rows.isEmpty) {
                return const Center(child: Text('No members'));
              }
              return ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder:
                    (_, i) => _globalMemberTile(context, ref, rows[i], wsList),
              );
            },
          ),
    );
  }

  Widget _globalMemberTile(
    BuildContext context,
    WidgetRef ref,
    _GlobalMemberRow row,
    List<Workspace> wsList,
  ) {
    return ListTile(
      leading: Icon(
        row.kind == MemberKind.agent
            ? Icons.smart_toy_outlined
            : Icons.person_outline,
      ),
      title: Text('${row.displayName} · ${row.id}'),
      subtitle: Text('${row.kind.name} · ws: ${row.workspaces.join(", ")}'),
      trailing: PopupMenuButton<String>(
        onSelected:
            (action) => _handleGlobalAction(context, ref, row, wsList, action),
        itemBuilder:
            (_) => [
              const PopupMenuItem(
                height: 32,
                value: 'attach',
                child: Text('Attach to workspace'),
              ),
              for (final ws in row.workspaces)
                PopupMenuItem(
                  height: 32,
                  value: 'detach:$ws',
                  child: Text('Detach: $ws'),
                ),
            ],
      ),
    );
  }

  Future<void> _handleGlobalAction(
    BuildContext context,
    WidgetRef ref,
    _GlobalMemberRow row,
    List<Workspace> wsList,
    String action,
  ) async {
    if (action == 'attach') {
      final available =
          wsList
              .map((w) => w.id)
              .where((id) => !row.workspaces.contains(id))
              .toList();
      if (available.isEmpty) return;
      final target = await showDialog<String>(
        context: context,
        builder:
            (_) => SimpleDialog(
              title: const Text('Which workspace should we attach to?'),
              children: [
                for (final id in available)
                  SimpleDialogOption(
                    child: Text(id),
                    onPressed: () => Navigator.pop(context, id),
                  ),
              ],
            ),
      );
      if (target == null) return;
      await opsCallTool(ref, 'member_attach', <String, dynamic>{
        'id': row.id,
        'toWorkspace': target,
      });
    } else if (action.startsWith('detach:')) {
      final ws = action.substring('detach:'.length);
      await opsCallTool(ref, 'member_detach', <String, dynamic>{
        'id': row.id,
        'fromWorkspace': ws,
      });
    }
  }
}

// ---- Agent form (create / attach existing / edit) --------------------

Future<void> _showAgentForm(
  BuildContext context,
  WidgetRef ref,
  String wsId,
  AgentMember? existing,
) async {
  // Edit mode stays single-tab (the same agent's fields). Create mode
  // offers two modes: brand-new agent vs. attach an existing member
  // (from any other workspace).
  final isEdit = existing != null;
  final idCtrl = TextEditingController(text: existing?.id ?? '');
  final nameCtrl = TextEditingController(text: existing?.displayName ?? '');
  final profileCtrl = TextEditingController(
    text: existing?.profileRef ?? 'profiles/default',
  );
  final philoCtrl = TextEditingController(
    text: existing?.philosophyRef ?? 'philosophies/default',
  );
  final selectedSkills = <String>{...?existing?.skillIds};
  final availableSkills = ref.read(appSkillListProvider);

  // ── LLM provider/model selection ───────────────────────────────────────
  // Initial: existing.model when editing → fall back to OpsConfig default
  // → fall back to catalog's first provider's first model. If the saved
  // value points to a non-catalog id, render Custom… preset.
  final cfg = ref.read(opsConfigProvider);
  final cfgDefault = cfg.llm.defaultProvider;
  final cfgProviderModel = cfg.llm.providers[cfgDefault]?.model ?? '';
  String providerId =
      existing?.model?.provider ??
      (cfgDefault.isNotEmpty ? cfgDefault : kLlmProviderCatalog.first.id);
  final initialModelId =
      existing?.model?.model ??
      (cfgProviderModel.isNotEmpty ? cfgProviderModel : '');
  final providerOpt = findProviderOption(providerId);
  String modelId;
  if (initialModelId.isEmpty) {
    modelId = providerOpt?.defaultModel.id ?? kCustomModelOption.id;
  } else if (providerOpt != null &&
      providerOpt.models.any((m) => m.id == initialModelId)) {
    modelId = initialModelId;
  } else {
    modelId = kCustomModelOption.id;
  }
  final customModelCtrl = TextEditingController(
    text: modelId == kCustomModelOption.id ? initialModelId : '',
  );

  // Attach-mode state
  int mode = 0; // 0 = create, 1 = attach-existing
  List<_AttachableMember> attachables = const [];
  final selectedToAttach = <String>{};
  bool attachablesLoaded = false;

  Future<void> ensureAttachables(
    void Function(void Function()) setState,
  ) async {
    if (attachablesLoaded) return;
    final init = ref.read(knowledgeInitProvider);
    final wsList = await init.registries.workspace.list();
    final byId = <String, _AttachableMember>{};
    for (final ws in wsList) {
      final list = await init.registries.member.listForWorkspace(ws.id);
      for (final m in list) {
        final row = byId.putIfAbsent(
          m.id,
          () => _AttachableMember(
            id: m.id,
            displayName: m.displayName,
            kind: m.kind,
          ),
        );
        row.workspaces.add(ws.id);
      }
    }
    // Exclude members already in this workspace.
    final filtered =
        byId.values.where((m) => !m.workspaces.contains(wsId)).toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    setState(() {
      attachables = filtered;
      attachablesLoaded = true;
    });
  }

  await showDialog(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              title: Text(isEdit ? 'Edit agent' : 'Add member'),
              content: SizedBox(
                width: 520,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (!isEdit)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: SegmentedButton<int>(
                          segments: const [
                            ButtonSegment(
                              value: 0,
                              label: Text('New agent'),
                              icon: Icon(Icons.person_add_alt_1),
                            ),
                            ButtonSegment(
                              value: 1,
                              label: Text('Pick existing'),
                              icon: Icon(Icons.group_add_outlined),
                            ),
                          ],
                          selected: {mode},
                          onSelectionChanged: (s) {
                            final next = s.first;
                            setState(() => mode = next);
                            if (next == 1) ensureAttachables(setState);
                          },
                        ),
                      ),
                    if (mode == 0) ...[
                      TextField(
                        controller: idCtrl,
                        enabled: !isEdit,
                        decoration: const InputDecoration(labelText: 'id'),
                      ),
                      TextField(
                        controller: nameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'displayName',
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'LLM',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      DropdownButtonFormField<String>(
                        initialValue: providerId,
                        decoration: const InputDecoration(
                          labelText: 'Provider',
                        ),
                        items: [
                          for (final p in kLlmProviderCatalog)
                            DropdownMenuItem(value: p.id, child: Text(p.label)),
                        ],
                        onChanged: (v) {
                          if (v == null || v == providerId) return;
                          setState(() {
                            providerId = v;
                            final opt = findProviderOption(v);
                            modelId =
                                opt?.defaultModel.id ?? kCustomModelOption.id;
                            customModelCtrl.text = '';
                          });
                        },
                      ),
                      const SizedBox(height: 8),
                      LlmModelDropdown(
                        providerId: providerId,
                        modelId: modelId,
                        customController: customModelCtrl,
                        onChanged: (v) => setState(() => modelId = v),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: profileCtrl,
                        decoration: const InputDecoration(
                          labelText: 'profileRef',
                        ),
                      ),
                      TextField(
                        controller: philoCtrl,
                        decoration: const InputDecoration(
                          labelText: 'philosophyRef',
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Skills',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      ...availableSkills.map(
                        (s) => CheckboxListTile(
                          dense: true,
                          title: Text(s),
                          value: selectedSkills.contains(s),
                          onChanged:
                              (v) => setState(() {
                                if (v == true) {
                                  selectedSkills.add(s);
                                } else {
                                  selectedSkills.remove(s);
                                }
                              }),
                        ),
                      ),
                    ] else ...[
                      if (!attachablesLoaded)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (attachables.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            'No other members can be attached to this workspace.',
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                      else ...[
                        const Text(
                          'Members from other workspaces (check to attach here)',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        ...attachables.map(
                          (m) => CheckboxListTile(
                            dense: true,
                            title: Text('${m.displayName} · ${m.id}'),
                            subtitle: Text(
                              '${m.kind.name} · current memberships: ${m.workspaces.join(", ")}',
                              style: const TextStyle(fontSize: 11),
                            ),
                            value: selectedToAttach.contains(m.id),
                            onChanged:
                                (v) => setState(() {
                                  if (v == true) {
                                    selectedToAttach.add(m.id);
                                  } else {
                                    selectedToAttach.remove(m.id);
                                  }
                                }),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    if (mode == 0) {
                      // Resolve catalog selection → ModelSpec. Empty model id
                      // (impossible from the catalog, only via Custom… cleared)
                      // means "leave it null and let boot fall back to config".
                      final resolvedModelId =
                          modelId == kCustomModelOption.id
                              ? customModelCtrl.text.trim()
                              : modelId;
                      final modelSpec =
                          resolvedModelId.isEmpty
                              ? null
                              : ModelSpec(
                                provider: providerId,
                                model: resolvedModelId,
                              );
                      // `provider` + `model` go to the tool as a pair (the
                      // tool rebuilds the ModelSpec); omitted together when
                      // null so boot falls back to config.
                      final modelArgs = <String, dynamic>{
                        if (modelSpec != null) ...<String, dynamic>{
                          'provider': modelSpec.provider,
                          'model': modelSpec.model,
                        },
                      };
                      if (isEdit) {
                        await opsCallTool(
                          ref,
                          'member_update',
                          <String, dynamic>{
                            'id': existing.id,
                            'workspaceId': wsId,
                            'displayName': nameCtrl.text,
                            'profileRef': profileCtrl.text,
                            'philosophyRef': philoCtrl.text,
                            'skillIds': selectedSkills.toList(),
                            ...modelArgs,
                          },
                        );
                      } else {
                        await opsCallTool(
                          ref,
                          'member_create_agent',
                          <String, dynamic>{
                            'id': idCtrl.text,
                            'displayName': nameCtrl.text,
                            'profileRef': profileCtrl.text,
                            'skillIds': selectedSkills.toList(),
                            'philosophyRef': philoCtrl.text,
                            ...modelArgs,
                          },
                        );
                      }
                    } else {
                      for (final id in selectedToAttach) {
                        await opsCallTool(
                          ref,
                          'member_attach',
                          <String, dynamic>{'id': id, 'toWorkspace': wsId},
                        );
                      }
                    }
                    ref.invalidate(workspaceMembersProvider(wsId));
                    if (context.mounted) Navigator.pop(ctx);
                  },
                  child: Text(
                    isEdit ? 'Save' : (mode == 0 ? 'Create' : 'Add selected'),
                  ),
                ),
              ],
            );
          },
        ),
  );
}

class _AttachableMember {
  _AttachableMember({
    required this.id,
    required this.displayName,
    required this.kind,
  });
  final String id;
  final String displayName;
  final MemberKind kind;
  final Set<String> workspaces = {};
}

// ---- Auth capture flow ------------------------------------------------

Future<void> _captureAuth(
  BuildContext context,
  WidgetRef ref,
  String wsId,
  AgentMember agent,
) async {
  final init = ref.read(knowledgeInitProvider);
  final systemId = await showDialog<String>(
    context: context,
    builder: (ctx) {
      final ctrl = TextEditingController(
        text:
            agent.authProfiles.isNotEmpty
                ? agent.authProfiles.first.systemId
                : 'makemind_dev',
      );
      return AlertDialog(
        title: const Text('Target system'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'systemId'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Start'),
          ),
        ],
      );
    },
  );
  if (systemId == null || systemId.isEmpty) return;

  final site = await init.registries.knowledge.loadSystemSchema(systemId);
  final spec = site.authSpec ?? <String, dynamic>{};
  final loginUrl = (spec['loginUrl'] as String?) ?? '';

  // Open the login page in the host's headful (visible) auth browser so the
  // user can sign in. The window stays open until capture. (adapt-browser.md
  // §7 — auth capture uses headful Chromium.)
  String contextId;
  try {
    final opened = await opsCallTool(
      ref,
      'browser.open_login',
      <String, dynamic>{'url': loginUrl, 'tenantId': systemId},
    );
    contextId = opened['contextId'] as String? ?? '';
    if (contextId.isEmpty) {
      throw StateError('open_login returned no contextId');
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to open login (browser disabled?): $e')),
      );
    }
    return;
  }

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder:
        (ctx) => AlertDialog(
          title: const Text('Sign in, then press Done'),
          content: Text(
            'The $systemId page has opened in a browser window. After completing '
            'sign-in, press Done to capture and save the session.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  // Seal the logged-in session into the host auth store, then
                  // record the AuthProfileRef on the member.
                  await opsCallTool(
                    ref,
                    'browser.auth_capture',
                    <String, dynamic>{
                      'member': agent.id,
                      'system': systemId,
                      'contextId': contextId,
                    },
                  );
                  await opsCallTool(
                    ref,
                    'member_capture_auth',
                    <String, dynamic>{
                      'memberId': agent.id,
                      'systemId': systemId,
                    },
                  );
                  if (ctx.mounted) {
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text('Auth saved for $systemId')),
                    );
                  }
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text('Capture failed: $e')),
                    );
                  }
                }
              },
              child: const Text('Done'),
            ),
          ],
        ),
  );
}
