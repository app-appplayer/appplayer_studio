// Philosophy on/off compare. PRD §FM-COMPARE-01.
//
// Picks an existing agent, sends the same prompt to:
//   (a) the agent itself (philosophy applied), and
//   (b) a temporary clone with everything *but* the philosophy fork
//       so the user can see what the philosophy axis is contributing.
//
// The clone is created and deleted inside one call — flowbrain's
// `agents.deleteAgent` removes the conversation store + registry entry
// so the compare stays free of side effects on the workspace.

import 'package:appplayer_studio/builtin_api.dart'
    show AgentReply, AgentRole, ModelSpec;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../registries/member_registry.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';

class PhilosophyComparePage extends ConsumerStatefulWidget {
  const PhilosophyComparePage({super.key});

  @override
  ConsumerState<PhilosophyComparePage> createState() =>
      _PhilosophyComparePageState();
}

class _PhilosophyComparePageState extends ConsumerState<PhilosophyComparePage> {
  String? _agentId;
  final _prompt = TextEditingController();
  bool _busy = false;
  AgentReply? _withPhi;
  AgentReply? _withoutPhi;
  String? _error;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wsId = ref.watch(activeWorkspaceIdProvider);
    if (wsId == null) {
      return Center(
        child: Text(
          'No active workspace.',
          style: TextStyle(color: OpsColors.text3),
        ),
      );
    }
    final membersAsync = ref.watch(workspaceMembersProvider(wsId));
    return membersAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Member list error: $e')),
      data: (members) {
        final agents =
            members
                .whereType<AgentMember>()
                .where((a) => a.philosophyRef.isNotEmpty)
                .toList();
        if (agents.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No agents with a philosophy assigned. Assign one in '
                'Members → agent detail to enable this compare.',
                textAlign: TextAlign.center,
                style: TextStyle(color: OpsColors.text3),
              ),
            ),
          );
        }
        _agentId ??= agents.first.id;
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Philosophy on/off',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Compare an agent with its philosophy applied vs. an '
                'identical clone without the philosophy axis. Differences '
                'isolate what the philosophy is contributing on its own.',
                style: TextStyle(color: OpsColors.text2),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _agentId,
                decoration: const InputDecoration(labelText: 'Agent'),
                items: [
                  for (final a in agents)
                    DropdownMenuItem(
                      value: a.id,
                      child: Text(
                        '${a.displayName} · philosophy: ${a.philosophyRef}',
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _agentId = v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _prompt,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Prompt',
                  hintText: 'e.g. Suggest 5 candidate names for a new feature.',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.balance, size: 16),
                    label: const Text('Compare'),
                    onPressed: _busy ? null : _run,
                  ),
                  const SizedBox(width: 12),
                  if (_busy)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  if (_error != null)
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(color: OpsColors.danger),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: _Pane(
                        title: 'With philosophy',
                        color: OpsColors.accent,
                        reply: _withPhi,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _Pane(
                        title: 'Without philosophy',
                        color: OpsColors.warn,
                        reply: _withoutPhi,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _run() async {
    final init = ref.read(knowledgeInitProvider);
    final agentId = _agentId;
    final prompt = _prompt.text.trim();
    if (agentId == null) return;
    if (prompt.isEmpty) {
      setState(() => _error = 'Prompt is empty.');
      return;
    }
    if (!init.system.isAgentSubsystemActivated) {
      setState(
        () =>
            _error =
                'Agent subsystem not activated — configure an LLM provider in Settings.',
      );
      return;
    }
    final wsId = ref.read(activeWorkspaceIdProvider);
    if (wsId == null) return;
    final source = await init.registries.member.get(agentId);
    if (source is! AgentMember) return;
    setState(() {
      _busy = true;
      _error = null;
      _withPhi = null;
      _withoutPhi = null;
    });
    final tempId =
        '_compare_${agentId}_${DateTime.now().microsecondsSinceEpoch}';
    try {
      // Spawn the no-philosophy clone with the same skills + profile
      // assigned but no philosophy axis. We use the underlying flowbrain
      // facade directly so this temp agent never lands in the
      // MemberRegistry (no AgentMember yaml, no UI noise).
      final agents = init.system.agents;
      final source0 = source;
      final model =
          source0.model ??
          const ModelSpec(provider: 'claude', model: 'claude-sonnet-4-6');
      await agents.createAgent(
        id: tempId,
        displayName: '${source0.displayName} · no-philosophy clone',
        role: AgentRole.worker,
        model: model,
        workspaceId: wsId,
      );
      for (final s in source0.skillIds) {
        try {
          await agents.tryAssignSkillFromPool(tempId, s);
        } catch (_) {
          /* skip */
        }
      }
      if (source0.profileRef.isNotEmpty) {
        try {
          await agents.tryAssignProfileFromPool(tempId, source0.profileRef);
        } catch (_) {
          /* skip */
        }
      }
      // Deliberately skip philosophy assignment on the clone.

      final futureWith = agents.ask(agentId, prompt);
      final futureWithout = agents.ask(tempId, prompt);
      final results = await Future.wait([futureWith, futureWithout]);
      if (!mounted) return;
      setState(() {
        _withPhi = results[0];
        _withoutPhi = results[1];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Compare failed: $e');
    } finally {
      try {
        await init.system.agents.deleteAgent(tempId);
      } catch (_) {
        /* ignore — clone already gone or never created */
      }
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _Pane extends StatelessWidget {
  const _Pane({required this.title, required this.color, required this.reply});
  final String title;
  final Color color;
  final AgentReply? reply;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: OpsColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(
                  fontFamily: OpsType.sans,
                  fontSize: 13,
                  fontWeight: OpsType.semibold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (reply == null)
            Text('No reply yet.', style: TextStyle(color: OpsColors.text3))
          else
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  reply!.content,
                  style: const TextStyle(
                    fontFamily: OpsType.sans,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
