/// Studio-side helper for accumulating agent successes.
///
/// Wraps two distinct FlowBrain mechanisms behind one façade so callers
/// don't have to know which is which:
///
///  1. **Auto-tracked** — `agents.ask` flow naturally mutates the
///     agent-owned 4-axis instance; `GrowthTracker` (FlowBrain core)
///     auto-emits `AgentForkEvolvedEvent`. We just listen and tally.
///
///  2. **Explicit** — `recordSuccess(...)` for moments the host wants
///     to stamp ground truth (user-confirmed patch, health-pass, build
///     pass). Goes through `FactFacade.writeFacts` directly (no
///     candidate pipeline — these are author-confirmed by definition).
///
/// Class names kept (`VibeGrowthRecorder`, `VibeSuccessRecord`) for
/// backwards-compat with existing host code; semantics are domain-agnostic.
library;

import 'dart:async' show StreamSubscription;

import 'package:brain_kernel/brain_kernel.dart' as fb;

class VibeSuccessRecord {
  const VibeSuccessRecord({
    required this.agentId,
    required this.intent,
    required this.toolSequence,
    required this.outcome,
    this.context,
  });

  final String agentId;
  final String intent;
  final List<String> toolSequence;
  final String outcome;
  final Map<String, dynamic>? context;
}

class VibeGrowthRecorder {
  VibeGrowthRecorder({required this.flowbrain});

  final fb.KernelApp flowbrain;

  int _autoTrackedCount = 0;
  String? _lastAutoEventId;
  DateTime? _lastAutoEventAt;
  StreamSubscription<dynamic>? _eventSub;

  int _explicitCount = 0;

  Map<String, dynamic> get stats => <String, dynamic>{
    'autoTrackedEvents': _autoTrackedCount,
    if (_lastAutoEventAt != null)
      'lastAutoEventAt': _lastAutoEventAt!.toIso8601String(),
    if (_lastAutoEventId != null) 'lastAutoEventId': _lastAutoEventId,
    'explicitRecords': _explicitCount,
  };

  Future<void> attach() async {
    if (_eventSub != null) return;
    // KernelApp instance present = booted.
    _eventSub = flowbrain.system.eventBus.stream.listen((event) {
      final type = event.runtimeType.toString();
      if (type == 'AgentForkEvolvedEvent') {
        _autoTrackedCount++;
        _lastAutoEventAt = DateTime.now().toUtc();
        try {
          final dyn = event as dynamic;
          _lastAutoEventId =
              '${dyn.agentId ?? ''}'
              ':${dyn.axis?.name ?? ''}'
              ':${dyn.forkedRef ?? ''}';
        } catch (_) {
          /* event shape might evolve — degrade silently */
        }
      }
    });
  }

  Future<void> detach() async {
    await _eventSub?.cancel();
    _eventSub = null;
  }

  Future<void> recordSuccess(VibeSuccessRecord record) async {
    _explicitCount++;
    final claimId = 'studio.success.${record.agentId}.$_explicitCount';
    final fact = fb.FactRecord(
      id: claimId,
      workspaceId: flowbrain.workspaceId,
      type: 'studio.success',
      entityId: 'agent:${record.agentId}',
      content: <String, dynamic>{
        'intent': record.intent,
        'toolSequence': record.toolSequence,
        'outcome': record.outcome,
        if (record.context != null) 'context': record.context,
      },
      confidence: 1.0,
      createdAt: DateTime.now().toUtc(),
    );
    await flowbrain.system.facts.writeFacts(<fb.FactRecord>[fact]);
  }
}
