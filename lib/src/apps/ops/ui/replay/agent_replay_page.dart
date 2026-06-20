// Conversation replay + A/B compare. PRD §FM-POWER-03 / 04.
//
// Pick agent A. Optionally pick agent B for a side-by-side ask. The page
// shows the per-agent ConversationTurn history (read via flowbrain's
// `agents.getHistory`) and a prompt box that fans the same input out
// to both agents in parallel.

import 'package:appplayer_studio/builtin_api.dart'
    show AgentReply, ConversationTurn;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/empty_state.dart';

class AgentReplayPage extends ConsumerStatefulWidget {
  const AgentReplayPage({super.key});

  @override
  ConsumerState<AgentReplayPage> createState() => _AgentReplayPageState();
}

class _AgentReplayPageState extends ConsumerState<AgentReplayPage> {
  String? _agentA;
  String? _agentB;
  final _prompt = TextEditingController();
  bool _busy = false;
  AgentReply? _replyA;
  AgentReply? _replyB;
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
      return const _Placeholder('No active workspace.');
    }
    final membersAsync = ref.watch(workspaceMembersProvider(wsId));
    return membersAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _Placeholder('Member list error: $e'),
      data: (members) {
        final agents =
            members
                .where((m) => m.runtimeType.toString().contains('Agent'))
                .toList();
        if (agents.isEmpty) {
          return const _Placeholder(
            'No agents in this workspace. Create one in Members or seed a recipe.',
          );
        }
        _agentA ??= agents.first.id;
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Replay & A/B compare',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Re-run the same prompt against one or two agents. Reply '
                'differences expose how skill / profile / philosophy / '
                'model choices shape the output.',
                style: TextStyle(color: OpsColors.text2),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _agentDropdown('Agent A', agents, _agentA, (v) {
                      setState(() => _agentA = v);
                    }),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _agentDropdown(
                      'Agent B (optional)',
                      agents,
                      _agentB,
                      (v) {
                        setState(() => _agentB = v);
                      },
                      allowNone: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _prompt,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Prompt',
                  hintText: 'Type a question — both agents will answer it.',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.compare_arrows, size: 16),
                    label: const Text('Run'),
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
                      child: _ReplyPane(
                        title: _agentA ?? 'Agent A',
                        reply: _replyA,
                      ),
                    ),
                    VerticalDivider(width: 16, color: OpsColors.border),
                    Expanded(
                      child: _ReplyPane(
                        title: _agentB ?? 'Agent B',
                        reply: _replyB,
                        empty:
                            _agentB == null
                                ? 'Pick a second agent to compare.'
                                : 'No reply yet.',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (_agentA != null) _HistoryStrip(agentId: _agentA!),
            ],
          ),
        );
      },
    );
  }

  Widget _agentDropdown(
    String label,
    List<dynamic> agents,
    String? current,
    ValueChanged<String?> onChanged, {
    bool allowNone = false,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: current,
      decoration: InputDecoration(labelText: label),
      items: [
        if (allowNone)
          const DropdownMenuItem<String>(value: null, child: Text('— none —')),
        for (final a in agents)
          DropdownMenuItem<String>(
            value: a.id as String,
            child: Text(
              '${(a as dynamic).displayName as String} (${a.id as String})',
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }

  Future<void> _run() async {
    final init = ref.read(knowledgeInitProvider);
    final p = _prompt.text.trim();
    if (p.isEmpty) {
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
    setState(() {
      _busy = true;
      _error = null;
      _replyA = null;
      _replyB = null;
    });
    try {
      final ag = init.system.agents;
      final futureA =
          _agentA == null
              ? Future<AgentReply?>.value(null)
              : ag.ask(_agentA!, p);
      final futureB =
          _agentB == null
              ? Future<AgentReply?>.value(null)
              : ag.ask(_agentB!, p);
      final results = await Future.wait([futureA, futureB]);
      if (!mounted) return;
      setState(() {
        _replyA = results[0];
        _replyB = results[1];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Run failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _ReplyPane extends StatelessWidget {
  const _ReplyPane({
    required this.title,
    required this.reply,
    this.empty = 'No reply yet.',
  });
  final String title;
  final AgentReply? reply;
  final String empty;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: OpsColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: OpsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontFamily: OpsType.sans,
              fontSize: 13,
              fontWeight: OpsType.semibold,
            ),
          ),
          const SizedBox(height: 6),
          if (reply == null)
            Text(empty, style: TextStyle(color: OpsColors.text3))
          else ...[
            Text(
              'model: ${reply!.model} · '
              '${reply!.tokenUsage?.promptTokens ?? 0}→'
              '${reply!.tokenUsage?.completionTokens ?? 0} tok',
              style: TextStyle(
                fontFamily: OpsType.mono,
                fontSize: 10,
                color: OpsColors.text3,
              ),
            ),
            const SizedBox(height: 8),
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
        ],
      ),
    );
  }
}

class _HistoryStrip extends ConsumerWidget {
  const _HistoryStrip({required this.agentId});
  final String agentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final init = ref.watch(knowledgeInitProvider);
    if (!init.system.isAgentSubsystemActivated) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<List<ConversationTurn>>(
      future: init.system.agents.getHistory(agentId, limit: 5),
      builder: (ctx, snap) {
        if (!snap.hasData || snap.data!.isEmpty) {
          return const SizedBox.shrink();
        }
        return SizedBox(
          height: 90,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: snap.data!.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (ctx, i) {
              final t = snap.data![i];
              return Container(
                width: 240,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: OpsColors.surface1,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: OpsColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.userMessage,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: OpsType.sans,
                        fontSize: 11,
                        fontWeight: OpsType.semibold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: Text(
                        t.assistantReply,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: OpsType.sans,
                          fontSize: 11,
                          color: OpsColors.text2,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder(this.message);
  final String message;
  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.history_outlined,
      headline: 'Replay needs an agent',
      hint: message,
    );
  }
}
