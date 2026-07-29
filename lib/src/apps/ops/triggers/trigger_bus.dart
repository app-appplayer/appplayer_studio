/// The agent-completion event bus — the one place a completion fans out to
/// (a) the source agent's live chat [R3], (b) subscribed agents that should
/// wake [R2], and (c) a best-effort feed notice [R5]. Pure orchestration: every
/// side effect is an injected seam, wired at boot (`ops_builtin`), so this stays
/// testable and layer-clean.
library;

import 'dart:async';

import '../util/log.dart';
import 'trigger_events.dart';
import 'trigger_subscription.dart';

/// Wakes [targetAgentId] with [request] in reaction to [cause]. Returns when the
/// wake has been dispatched (implementations may run the agent asynchronously).
typedef WakeAgent =
    Future<void> Function(
      String targetAgentId,
      String request,
      AgentWorkCompleted cause,
    );

/// Surfaces a completion into a live conversation / feed (R3 / R5).
typedef CompletionSink = Future<void> Function(AgentWorkCompleted event);

class OpsTriggerBus {
  OpsTriggerBus({
    required this.subscriptions,
    this.wakeAgent,
    this.injectIntoActiveChat,
    this.notify,
    this.maxHops = 4,
  });

  /// Persisted R2 rules.
  final TriggerRegistry subscriptions;

  /// R2 — wake a subscribed agent. Null → subscriptions are recorded but never
  /// fired (e.g. agent subsystem off). Late-injected at boot (`ops_builtin`),
  /// like `TaskRegistry.agentRun`.
  WakeAgent? wakeAgent;

  /// R3 — surface the completion into the source agent's active chat.
  /// Late-injected at boot.
  CompletionSink? injectIntoActiveChat;

  /// R5 — best-effort feed notice, independent of any subscription.
  /// Late-injected at boot.
  CompletionSink? notify;

  /// Cause-chain backstop: past this depth, R2 subscriptions are not fired so a
  /// mis-configured cycle cannot run away.
  final int maxHops;

  final _events = StreamController<AgentWorkCompleted>.broadcast();

  /// Observability stream — the living-org-chart / live feed can watch raw
  /// completions here without owning dispatch.
  Stream<AgentWorkCompleted> get events => _events.stream;

  /// Publish a completion. Never throws — each seam is guarded so one failing
  /// sink can't sink the others or the caller's work.
  Future<void> emit(AgentWorkCompleted event) async {
    _events.add(event);

    // R3 — tell the source agent's live chat, best-effort.
    await _guard('inject', () => injectIntoActiveChat?.call(event));
    // R5 — feed notice, best-effort.
    await _guard('notify', () => notify?.call(event));

    // R2 — wake subscribers, unless we've hit the cause-chain cap.
    if (event.depth >= maxHops) {
      OpsLog.warn(
        'trigger',
        'hop cap $maxHops reached for ${event.refId} — skipping wakes',
      );
      return;
    }
    final wake = wakeAgent;
    if (wake == null) {
      OpsLog.info(
        'trigger',
        'no wake seam wired — ${event.refId} recorded, subscribers not fired',
      );
      return;
    }
    List<TriggerSubscription> matches;
    try {
      matches = await subscriptions.matching(event);
    } catch (e) {
      OpsLog.warn('trigger', 'subscription match failed: $e');
      return;
    }
    // Observability trail (konpi's "which surface?" — the R2 dispatch decision
    // lands in ~/.makemind-ops/boot.log): how many rules matched this event and
    // who is being woken. A woken agent's own output then appears in ITS kernel
    // conversation (inline `agents.ask`), not the feed or a new task.
    OpsLog.info(
      'trigger',
      'emit ${event.kind.name}(${event.refId}) src=${event.sourceAgentId} '
          'ws=${event.workspaceId} state=${event.state} '
          '→ ${matches.length} subscription(s) matched'
          '${matches.isEmpty ? '' : ' → waking '
              '${matches.map((s) => s.targetAgentId).join(', ')}'}',
    );
    for (final sub in matches) {
      await _guard(
        'wake ${sub.targetAgentId}',
        () => wake(sub.targetAgentId, sub.render(event), event),
      );
      // One-shot rules (e.g. a chat-driven "report this delegation back to me")
      // retire after firing so they don't linger and re-fire on later work.
      if (sub.once) {
        await _guard('unsubscribe ${sub.id}', () async {
          await subscriptions.unsubscribe(sub.id);
        });
      }
    }
  }

  Future<void> _guard(String what, Future<void>? Function() run) async {
    try {
      await run();
    } catch (e) {
      OpsLog.warn('trigger', '$what failed: $e');
    }
  }

  Future<void> dispose() async {
    await _events.close();
  }
}
