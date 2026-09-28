import 'dart:async';
import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart';
import 'package:mcp_knowledge_ops/mcp_knowledge_ops.dart'
    as kops
    show KvStateStore;
import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart';

import '../infra/ws_paths.dart';
import '../observability/activity_bus.dart';
import '../observability/activity_event.dart';
import '../triggers/trigger_events.dart';
import '../util/atomic_write.dart';
import '../util/log.dart';

enum ProcessTrigger { manual, event, task }

enum GateKind { philosophy, quality, approval }

enum ProcessRunState { running, waitingApproval, blocked, completed, cancelled }

class ProcessGate {
  ProcessGate({
    required this.afterStep,
    required this.kind,
    this.params = const {},
  });
  final String afterStep;
  final GateKind kind;
  final Map<String, dynamic> params;
}

class ProcessStep {
  ProcessStep({
    required this.stepId,
    required this.assigneeId,
    required this.skillId,
    this.inputs = const {},
    this.channelThreadId,
    this.dependsOn = const [],
  });
  final String stepId;
  final String assigneeId;
  final String skillId;
  final Map<String, dynamic> inputs;
  final String? channelThreadId;

  /// Step ids this step depends on. Empty ⇒ the step depends on the
  /// textually-previous step (the default linear chain). Non-empty ⇒ an
  /// explicit DAG: steps that depend on the *same* predecessor (or on
  /// nothing / the same set) run in parallel — the behavior engine schedules
  /// by topological level, so independent branches execute concurrently. This
  /// is how a single process expresses parallel work (e.g. shoot / design /
  /// produce all `dependsOn: [build]`) rather than a forced sequence.
  final List<String> dependsOn;
}

class Process {
  Process({
    required this.id,
    required this.workspaceId,
    required this.title,
    required this.steps,
    required this.gates,
    required this.trigger,
    this.triggerSource,
    this.runs = const [],
  });

  final String id;
  final String workspaceId;
  final String title;
  final List<ProcessStep> steps;
  final List<ProcessGate> gates;
  final ProcessTrigger trigger;

  /// Event chaining (G-event): the id of the process whose completion
  /// auto-starts this one (set when `trigger: event`). A → B without manual
  /// re-start, so the org runs unattended. Cross-process; the step
  /// `dependsOn` chains within one process, this chains between processes.
  final String? triggerSource;
  final List<ProcessRun> runs;
}

class ProcessRun {
  ProcessRun({
    required this.runId,
    required this.processId,
    required this.workspaceId,
    required this.startedAt,
    required this.currentStep,
    this.outcomes = const {},
    required this.state,
    this.checkpointRef,
    this.pendingApproval,
    this.error,
  });
  final String runId;
  final String processId;
  final String workspaceId;
  final DateTime startedAt;
  final String currentStep;
  final Map<String, dynamic> outcomes;
  final ProcessRunState state;
  final String? checkpointRef;
  final PendingApproval? pendingApproval;

  /// Why the run stopped, when it stopped on a thrown error. A `blocked` run
  /// without it leaves the cause recoverable only by re-running synchronously.
  final String? error;

  ProcessRun copyWith({
    String? currentStep,
    Map<String, dynamic>? outcomes,
    ProcessRunState? state,
    PendingApproval? pendingApproval,
    bool clearPendingApproval = false,
    String? error,
  }) => ProcessRun(
    runId: runId,
    processId: processId,
    workspaceId: workspaceId,
    startedAt: startedAt,
    currentStep: currentStep ?? this.currentStep,
    outcomes: outcomes ?? this.outcomes,
    state: state ?? this.state,
    checkpointRef: checkpointRef,
    pendingApproval:
        clearPendingApproval ? null : (pendingApproval ?? this.pendingApproval),
    error: error ?? this.error,
  );

  Map<String, dynamic> toJson() => {
    'runId': runId,
    'processId': processId,
    'workspaceId': workspaceId,
    'startedAt': startedAt.toIso8601String(),
    'currentStep': currentStep,
    'outcomes': outcomes,
    'state': state.name,
    if (checkpointRef != null) 'checkpointRef': checkpointRef,
    if (pendingApproval != null) 'pendingApproval': pendingApproval!.toJson(),
    if (error != null) 'error': error,
  };

  static ProcessRun fromJson(Map<String, dynamic> j) => ProcessRun(
    runId: j['runId'] as String,
    processId: j['processId'] as String,
    workspaceId: j['workspaceId'] as String,
    startedAt: DateTime.parse(j['startedAt'] as String),
    currentStep: j['currentStep'] as String? ?? '',
    outcomes: (j['outcomes'] as Map?)?.cast<String, dynamic>() ?? const {},
    state: ProcessRunState.values.firstWhere(
      (s) => s.name == (j['state'] as String? ?? 'running'),
      orElse: () => ProcessRunState.running,
    ),
    checkpointRef: j['checkpointRef'] as String?,
    pendingApproval:
        j['pendingApproval'] is Map
            ? PendingApproval.fromJson(
              Map<String, dynamic>.from(j['pendingApproval'] as Map),
            )
            : null,
    error: j['error'] as String?,
  );
}

class PendingApproval {
  PendingApproval({
    required this.afterStep,
    required this.approverId,
    required this.requestedAt,
  });
  final String afterStep;
  final String approverId;
  final DateTime requestedAt;

  Map<String, dynamic> toJson() => {
    'afterStep': afterStep,
    'approverId': approverId,
    'requestedAt': requestedAt.toIso8601String(),
  };

  factory PendingApproval.fromJson(Map<String, dynamic> j) => PendingApproval(
    afterStep: j['afterStep'] as String,
    approverId: j['approverId'] as String,
    requestedAt: DateTime.parse(j['requestedAt'] as String),
  );
}

/// Raised when a principal other than the gate's designated approver tries
/// to approve (G3 hierarchical approval authorization).
class ApproverMismatch implements Exception {
  ApproverMismatch({
    required this.afterStep,
    required this.requiredApprover,
    required this.attemptedBy,
  });
  final String afterStep;
  final String requiredApprover;
  final String attemptedBy;

  @override
  String toString() =>
      'Not authorized: approval gate after "$afterStep" requires approver '
      '"$requiredApprover", but "$attemptedBy" attempted it.';
}

typedef SkillDispatch =
    Future<Map<String, dynamic>> Function(
      String skillId,
      Map<String, dynamic> args,
    );

/// True when a run suspended at [currentStep] waits for a person to do a
/// `human` / `manual` step — work, not a sign-off. Such a run carries no
/// pending approval: the tasks inbox lists it; the approvals inbox must not,
/// or it offers a gate that was already approved for approval again.
bool isHumanStepWait(Process p, String currentStep) => p.steps.any(
  (s) =>
      s.stepId == currentStep &&
      (s.skillId == 'human' || s.skillId == 'manual'),
);

class ProcessRegistry {
  ProcessRegistry({
    required this.kv,
    required this.knowledgeSystem,
    this.rootDir = './workspaces',
  });

  final KvStoragePortAdapter kv;
  final KnowledgeSystem knowledgeSystem;
  final String rootDir;
  SkillDispatch? dispatch;

  /// Injected after bootstrap — emits a completion event when a run finishes so
  /// the trigger bus can wake subscribers (R2) / relay it (R3), complementing
  /// the process→process [_fireCompletionChain]. Null → runs complete silently.
  void Function(AgentWorkCompleted event)? onWorkCompleted;

  /// Injected after bootstrap — the Live Activity feed's bus. Every run
  /// state transition (running / waitingApproval / blocked / completed /
  /// cancelled) emits so a running process is visible in real time (the
  /// waitingApproval transition is the `philosophyGate` signal). Null (stdio
  /// CLI, no UI) → silent. See [_emitRunActivity].
  ActivityBus? activityBus;

  /// Last activity state emitted per run so a re-saved checkpoint at the same
  /// state (e.g. a `running` re-persist) does not double-log the feed.
  final Map<String, ProcessRunState> _lastActivityState =
      <String, ProcessRunState>{};

  /// Resolves a workspace's org-ancestor chain (nearest parent first) for
  /// approval escalation. Host-wired to `WorkspaceRegistry.ancestors`. When
  /// the gate's designated approver is a workspace/org-unit id, any ancestor
  /// of it may approve on their behalf (escalation up the org tree). Null
  /// (unwired) ⇒ strict exact-match approval only.
  Future<List<String>> Function(String workspaceId)? ancestorsOf;

  /// Reads a raw value from the ORG-level KV — where the behavior engine
  /// persists each run's working state (step outputs). The scoped `kv` cannot
  /// see it: runs span workspaces, so the store is wired to `orgKv` on purpose
  /// (see `knowledge_init` behaviorStore). Injected at boot where `orgKv` is in
  /// scope; null-safe (run `outcomes` stay empty if left unwired).
  Future<String?> Function(String key)? readOrgKv;

  /// The project bundle id (`project.mbd` manifest id) behaviors are exposed
  /// under. Host-wired to `KnowledgeInit.sharedPoolBundleId`. The folder name
  /// is only the seed's starting value: a project copied or renamed to another
  /// folder keeps its manifest id, and deriving the id from the folder made
  /// every run of such a project "behavior not found". Null (unwired, unit
  /// tests) ⇒ the seed contract `<folder>.project`.
  String? Function()? projectBundleIdOf;

  final Map<String, Map<String, Process>> _byWorkspace = {};
  final Set<String> _loaded = {};
  final _uuid = const Uuid();

  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  void _notify() => _changes.add(null);

  Future<List<Process>> list({String? wsId}) async {
    if (wsId != null) await _ensureLoaded(wsId);
    if (wsId != null) {
      return _byWorkspace[wsId]?.values.toList() ?? const [];
    }
    return _byWorkspace.values.expand((m) => m.values).toList();
  }

  Future<Process?> get(String id) async {
    // Lazily load the active workspace so a direct get/start (before any
    // list() warmed the cache) still resolves the process.
    await _ensureLoaded(kv.workspaceId!);
    for (final ws in _byWorkspace.keys) {
      final p = _byWorkspace[ws]?[id];
      if (p != null) return p;
    }
    return null;
  }

  /// List all checkpointed [ProcessRun]s for [processId] in [workspaceId]
  /// (defaults to the current workspace). Reads from the KV
  /// `ws/<wsId>/process_runs/*` partition where [_saveCheckpoint] writes.
  Future<List<ProcessRun>> listRuns(
    String processId, {
    String? workspaceId,
  }) async {
    final keys = await kv.keys(prefix: 'ws/${kv.workspaceId!}/process_runs/');
    final runs = <ProcessRun>[];
    for (final k in keys) {
      final raw = await kv.get(k);
      if (raw is! Map) continue;
      try {
        final run = ProcessRun.fromJson(Map<String, dynamic>.from(raw));
        if (run.processId == processId &&
            (workspaceId == null || run.workspaceId == workspaceId)) {
          runs.add(run);
        }
      } catch (_) {
        // Skip malformed entries
      }
    }
    runs.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return runs;
  }

  Future<Process> create(Process spec) async {
    _byWorkspace.putIfAbsent(spec.workspaceId, () => {})[spec.id] = spec;
    await _persist(spec);
    _notify();
    return spec;
  }

  Future<Process> update(Process p) async {
    _byWorkspace.putIfAbsent(p.workspaceId, () => {})[p.id] = p;
    await _persist(p);
    _notify();
    return p;
  }

  Future<void> delete(String id, {String? workspaceId}) async {
    for (final ws in _byWorkspace.keys) {
      if (workspaceId != null && ws != workspaceId) continue;
      if (_byWorkspace[ws]?.remove(id) != null) {
        final f = File('${wsContentRoot(rootDir, ws)}/processes/$id.yaml');
        if (await f.exists()) await f.delete();
      }
    }
    _notify();
  }

  /// Read the raw YAML text for a process, returning null if missing.
  /// Counterpart to [saveFromYaml] — used by UI editors that want to show
  /// the exact on-disk content rather than a re-serialized view.
  Future<String?> readYaml(String workspaceId, String id) async {
    final f = File('${wsContentRoot(rootDir, workspaceId)}/processes/$id.yaml');
    if (!await f.exists()) return null;
    return f.readAsString();
  }

  /// Save a process from a raw YAML string (LLM authoring path).
  Future<Process> saveFromYaml(String yamlText, String workspaceId) async {
    final parsed = loadYaml(yamlText);
    if (parsed is! YamlMap) {
      throw StateError('process YAML must be a mapping');
    }
    final map = Map<String, dynamic>.from(parsed);
    if (map['id'] is! String || (map['id'] as String).isEmpty) {
      throw StateError('process YAML must contain a non-empty id');
    }
    final p = _fromYaml(map, workspaceId);
    _byWorkspace.putIfAbsent(workspaceId, () => {})[p.id] = p;
    final f = File(
      '${wsContentRoot(rootDir, workspaceId)}/processes/${p.id}.yaml',
    );
    await writeStringAtomic(f, yamlText);
    _notify();
    return p;
  }

  Future<ProcessRun> start(
    String id, {
    Map<String, dynamic>? initialInputs,
    bool background = false,
  }) async {
    final p = await get(id);
    if (p == null) throw StateError('Process not found: $id');
    final runId = _uuid.v4();
    // Delegate execution to the unified behavior engine — `process_save`
    // mirrored this process into project.mbd's behavior section, exposed as
    // `<projectBundleId>.<processId>`. The engine owns step dispatch, gates,
    // and durable suspend/resume; ProcessRegistry keeps only a thin run
    // record (runId → processId) for the UI. Called on the host `OpsFacade`
    // directly (the `bk.behavior.*` MCP tools live on the host endpoint, not
    // the ops inbound server `dispatch` reaches).
    Future<Map<String, dynamic>> drive() => knowledgeSystem.ops.runBehavior(
      _behaviorIdFor(p),
      runId: runId,
      input: initialInputs ?? const <String, dynamic>{},
    );
    if (background) {
      // A long process dispatches agent steps that each take a full LLM turn,
      // so a synchronous drive blocks the caller's transport for the whole run
      // (HTTP timeout) and lets an eager `process_approve` race a run that has
      // not suspended at its gate yet. Background mode persists a `running`
      // checkpoint, returns immediately, and drives off the request path — the
      // caller polls `process_get` / `process_runs` for the gate / completion.
      final running = ProcessRun(
        runId: runId,
        processId: p.id,
        workspaceId: p.workspaceId,
        startedAt: DateTime.now(),
        currentStep: '',
        state: ProcessRunState.running,
      );
      await _saveCheckpoint(running);
      unawaited(_driveInBackground(p, runId, drive));
      return running;
    }
    final res = await drive();
    return _runFromResult(p, (res['runId'] ?? runId).toString(), res);
  }

  /// Drive a behavior run to its next suspend / completion OFF the caller's
  /// request path (background mode for [start] / [approve]). A thrown error
  /// persists a `blocked` checkpoint carrying the error, so a poller sees the
  /// run stop and why, instead of it hanging on `running` forever; the
  /// synchronous path still surfaces the throw to its own caller. The prior
  /// checkpoint (start time, reached step) is kept.
  Future<void> _driveInBackground(
    Process p,
    String runId,
    Future<Map<String, dynamic>> Function() drive,
  ) async {
    try {
      final res = await drive();
      await _runFromResult(p, (res['runId'] ?? runId).toString(), res);
    } catch (e) {
      try {
        final prior = await _loadRun(runId);
        await _saveCheckpoint(
          (prior ??
                  ProcessRun(
                    runId: runId,
                    processId: p.id,
                    workspaceId: p.workspaceId,
                    startedAt: DateTime.now(),
                    currentStep: '',
                    state: ProcessRunState.blocked,
                  ))
              .copyWith(state: ProcessRunState.blocked, error: '$e'),
        );
      } catch (_) {
        // Best-effort — nothing else to do if even the checkpoint write fails.
      }
    }
  }

  Future<ProcessRun> resume(String runId) async {
    final run = await _loadRun(runId);
    if (run == null) throw StateError('No checkpoint for run: $runId');
    if (run.state == ProcessRunState.completed) return run;
    if (run.state == ProcessRunState.cancelled) return run;
    final p = await get(run.processId);
    if (p == null) {
      throw StateError('Process definition missing: ${run.processId}');
    }
    final res = await knowledgeSystem.ops.resumeBehavior(
      _behaviorIdFor(p),
      runId,
    );
    return _runFromResult(p, runId, res);
  }

  Future<void> cancel(String runId) async {
    final run = await _loadRun(runId);
    if (run == null) return;
    // Clear any parked pendingApproval — a cancelled run must not linger in
    // the Inbox as a waiting gate. (The Inbox already filters on
    // `state == waitingApproval`, but stale pendingApproval on a cancelled
    // checkpoint is misleading and re-cancel must converge it to clean.)
    await _saveCheckpoint(
      run.copyWith(
        state: ProcessRunState.cancelled,
        clearPendingApproval: true,
      ),
    );
  }

  /// Approve the gate the run is currently suspended on and continue via the
  /// behavior engine.
  ///
  /// Hierarchical approval (G3): the pending gate records its **designated
  /// approver** (`pendingApproval.approverId`, from the YAML gate's
  /// `params.approverId`). Only that principal may advance it — a different
  /// [approverId] is rejected with [ApproverMismatch]. An empty configured
  /// approver means an open gate (any approver proceeds). Only the currently
  /// pending gate is flagged, so a later gate suspends again and must be
  /// approved by its own designated approver (per-gate authorization).
  Future<ProcessRun> approve(
    String runId, {
    required String approverId,
    bool background = false,
  }) async {
    final run = await _loadRun(runId);
    if (run == null) throw StateError('No checkpoint: $runId');
    if (run.state != ProcessRunState.waitingApproval) {
      throw StateError('Run $runId is not waiting for approval');
    }
    final p = await get(run.processId);
    if (p == null) {
      throw StateError('Process definition missing: ${run.processId}');
    }
    final pending = run.pendingApproval;
    final requiredApprover = pending?.approverId ?? '';
    if (requiredApprover.isNotEmpty && approverId != requiredApprover) {
      // Escalation (G2+G3): a higher org unit — an ancestor of the designated
      // approver in the org tree — may approve on their behalf. If the
      // approver is a plain (non-workspace) id, its chain is empty and only
      // an exact match passes.
      final chain =
          ancestorsOf == null
              ? const <String>[]
              : await ancestorsOf!(requiredApprover);
      if (!chain.contains(approverId)) {
        throw ApproverMismatch(
          afterStep: pending?.afterStep ?? '',
          requiredApprover: requiredApprover,
          attemptedBy: approverId,
        );
      }
      // else: approved via escalation by an ancestor org unit.
    }
    final patch = <String, dynamic>{};
    if (pending != null) {
      patch['approved_${pending.afterStep}'] = true;
    } else {
      // No recorded pending gate — legacy fallback: flag every approval gate.
      for (final g in p.gates) {
        if (g.kind == GateKind.approval) {
          patch['approved_${g.afterStep}'] = true;
        }
      }
    }
    if (background) {
      // The approved step and everything up to the next gate may dispatch
      // agent turns; drive them off the request path (same rationale as
      // `start`). The run stays visible as `running` until it re-suspends /
      // completes — poll `process_get` / `process_runs`.
      unawaited(
        _driveInBackground(
          p,
          runId,
          () => knowledgeSystem.ops.resumeBehavior(
            _behaviorIdFor(p),
            runId,
            statePatch: patch,
          ),
        ),
      );
      return run.copyWith(state: ProcessRunState.running);
    }
    final res = await knowledgeSystem.ops.resumeBehavior(
      _behaviorIdFor(p),
      runId,
      statePatch: patch,
    );
    return _runFromResult(p, runId, res);
  }

  /// Mark a human-assigned step done and continue. A step authored with
  /// `skillId: human` (or `manual`) suspends the run until its assigned
  /// person submits their work here — the human-task counterpart to an
  /// approval gate. Only this run advances; other processes keep running.
  /// [result] is recorded under `<stepId>_result` and [by] under
  /// `<stepId>_by` so later steps / guards can read who did it and what.
  Future<ProcessRun> submitStep(
    String runId,
    String stepId, {
    String? by,
    Object? result,
  }) async {
    final run = await _loadRun(runId);
    if (run == null) throw StateError('No checkpoint: $runId');
    final p = await get(run.processId);
    if (p == null) {
      throw StateError('Process definition missing: ${run.processId}');
    }
    final res = await knowledgeSystem.ops.resumeBehavior(
      _behaviorIdFor(p),
      runId,
      statePatch: <String, dynamic>{
        'done_$stepId': true,
        if (by != null) '${stepId}_by': by,
        if (result != null) '${stepId}_result': result,
      },
    );
    return _runFromResult(p, runId, res);
  }

  // --- behavior delegation helpers ---

  /// `<projectBundleId>.<processId>` — the exposed behavior id under which
  /// `process_save` mirrored this process into `project.mbd`.
  String _behaviorIdFor(Process p) => '${_projectBundleId()}.${p.id}';

  /// The `project.mbd` manifest id (see [projectBundleIdOf]).
  String _projectBundleId() =>
      projectBundleIdOf?.call() ??
      '${rootDir.split(Platform.pathSeparator).last}.project';

  /// The behavior engine records each step's output into a durable working
  /// state (`BehaviorRunState.state`), but the facade result only surfaces
  /// status / waitingStepId — so a run's per-step outcomes are invisible to the
  /// ops layer unless read back from the store. This reads that state via the
  /// store's own public `load()` (ops owns the store + its key prefix — no
  /// package reach-in) so a run record can expose step outputs (`run.outcomes`)
  /// for output↔step correlation. Best-effort: empty when unwired or on any
  /// read/parse failure — never fails the run record.
  Future<Map<String, dynamic>> _loadRunOutcomes(String runId) async {
    final read = readOrgKv;
    if (read == null) return const <String, dynamic>{};
    try {
      final bundleId = _projectBundleId();
      final store = kops.KvStateStore(
        writeKv: (_, _) async {},
        readKv: read,
        removeKv: (_) async {},
        prefix: 'behavior/run/$bundleId/',
      );
      final run = await store.load(runId);
      return run?.state ?? const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  ProcessRunState _stateFromBehavior(String status) => switch (status) {
    'completed' => ProcessRunState.completed,
    'cancelled' => ProcessRunState.cancelled,
    'suspended' => ProcessRunState.waitingApproval,
    'waiting' => ProcessRunState.waitingApproval,
    'wait' => ProcessRunState.waitingApproval,
    'blocked' => ProcessRunState.blocked,
    _ => ProcessRunState.running,
  };

  Future<ProcessRun> _runFromResult(
    Process p,
    String runId,
    Map<String, dynamic> res,
  ) async {
    final status = (res['status'] ?? res['state'] ?? 'running').toString();
    final state = _stateFromBehavior(status);
    // The behavior engine reports the suspended node as `waitingStepId`; use
    // it as the current step so approval-gate matching and the human-task /
    // approval inboxes can resolve exactly which node a run is parked on.
    final cur = (res['waitingStepId'] ?? res['currentStep'] ?? '').toString();
    // Record which approval gate is pending so `process_approve` can default
    // its approverId from the run record (the gate's configured approver)
    // instead of failing with "no pendingApproval". Match the suspended gate
    // node (`gate_approval_<afterStep>`) when the engine reports it, else the
    // first approval gate (single-gate common case).
    PendingApproval? pending;
    if (state == ProcessRunState.waitingApproval && !isHumanStepWait(p, cur)) {
      final approvalGates =
          p.gates.where((g) => g.kind == GateKind.approval).toList();
      if (approvalGates.isNotEmpty) {
        final g = approvalGates.firstWhere(
          (g) => cur == 'gate_approval_${g.afterStep}' || cur == g.afterStep,
          orElse: () => approvalGates.first,
        );
        pending = PendingApproval(
          afterStep: g.afterStep,
          approverId: (g.params['approverId'] as String?) ?? '',
          requestedAt: DateTime.now(),
        );
      }
    }
    final run = ProcessRun(
      runId: runId,
      processId: p.id,
      workspaceId: p.workspaceId,
      startedAt: DateTime.now(),
      currentStep: cur,
      state: state,
      pendingApproval: pending,
      // Surface per-step outputs the behavior engine recorded, so a run
      // exposes what its agents actually produced (output↔step correlation)
      // instead of an empty `{}`.
      outcomes: await _loadRunOutcomes(runId),
    );
    await _saveCheckpoint(run);
    if (state == ProcessRunState.completed) {
      // G-event: this run reached the end — auto-start any process whose
      // `triggerSource` names it, so A → B chains without a manual re-start.
      unawaited(_fireCompletionChain(p.id, p.workspaceId));
      // Trigger bus (R1): surface the run completion so agent subscriptions
      // wake and the live chat can relay it. Best-effort — a bad listener must
      // not fail the run. A process is not a single agent, so `sourceAgentId`
      // is empty (subscriptions match it as "any source").
      final cb = onWorkCompleted;
      if (cb != null) {
        try {
          cb(
            AgentWorkCompleted(
              sourceAgentId: '',
              workspaceId: p.workspaceId,
              kind: WorkKind.step,
              refId: run.runId,
              state: 'completed',
              at: DateTime.now(),
              summary: 'Process "${p.title}" (${p.id}) completed',
            ),
          );
        } catch (_) {
          // Emission is best-effort; the run already persisted its outcome.
        }
      }
    }
    return run;
  }

  /// Start every process whose `triggerSource` is [completedProcessId]
  /// (event chaining). Fire-and-forget + best-effort — a failing chained
  /// start must not fail the completing run, and one bad target must not
  /// block the others. Cycles (A → B → A) are author error and are not
  /// guarded here.
  Future<void> _fireCompletionChain(
    String completedProcessId,
    String workspaceId,
  ) async {
    try {
      final procs = await list(wsId: workspaceId);
      for (final next in procs) {
        if (next.id == completedProcessId) continue;
        if (next.triggerSource != completedProcessId) continue;
        try {
          await start(next.id);
        } catch (_) {
          // Skip this target; keep chaining the rest.
        }
      }
    } catch (_) {
      // Chain resolution failed — the completing run still succeeds.
    }
  }

  Future<ProcessRun?> _loadRun(String runId) async {
    final raw = await kv.get('ws/${kv.workspaceId!}/process_runs/$runId');
    if (raw is! Map) return null;
    return ProcessRun.fromJson(Map<String, dynamic>.from(raw));
  }

  // --- internals ---

  // Step execution, gate evaluation, and durable suspend/resume are owned by
  // the unified behavior engine now (see start / resume / approve). The
  // former self-engine `_execute` / `_runGate` (+ `_GateVerdict`) was removed
  // with the delegation; `process_save` mirrors the process to the bundle's
  // behavior section that the engine runs.

  Future<void> _persist(Process p) async {
    final f = File(
      '${wsContentRoot(rootDir, p.workspaceId)}/processes/${p.id}.yaml',
    );
    await writeStringAtomic(f, _toYaml(p));
  }

  String _toYaml(Process p) {
    final buf = StringBuffer();
    buf.writeln('id: ${p.id}');
    buf.writeln('title: ${p.title}');
    buf.writeln('trigger: ${p.trigger.name}');
    if (p.triggerSource != null && p.triggerSource!.isNotEmpty) {
      buf.writeln('triggerSource: ${p.triggerSource}');
    }
    buf.writeln('steps:');
    for (final s in p.steps) {
      buf.writeln('  - stepId: ${s.stepId}');
      buf.writeln('    assigneeId: ${s.assigneeId}');
      buf.writeln('    skillId: ${s.skillId}');
      if (s.dependsOn.isNotEmpty) {
        buf.writeln('    dependsOn: [${s.dependsOn.join(', ')}]');
      }
      if (s.inputs.isNotEmpty) {
        buf.writeln('    inputs:');
        s.inputs.forEach((k, v) => buf.writeln('      $k: ${_scalar(v)}'));
      }
      if (s.channelThreadId != null) {
        buf.writeln('    channelThreadId: ${s.channelThreadId}');
      }
    }
    if (p.gates.isNotEmpty) {
      buf.writeln('gates:');
      for (final g in p.gates) {
        buf.writeln('  - afterStep: ${g.afterStep}');
        buf.writeln('    kind: ${g.kind.name}');
        if (g.params.isNotEmpty) {
          buf.writeln('    params:');
          g.params.forEach((k, v) => buf.writeln('      $k: ${_scalar(v)}'));
        }
      }
    }
    return buf.toString();
  }

  String _scalar(Object? v) {
    if (v == null) return 'null';
    if (v is String) return '"$v"';
    return v.toString();
  }

  Future<void> _saveCheckpoint(ProcessRun run) async {
    await kv.set(
      'ws/${kv.workspaceId!}/process_runs/${run.runId}',
      run.toJson(),
    );
    // A run's state changed (started / suspended / approved / submitted /
    // completed) — fire the changes stream so live views (the Inbox, the
    // Processes page) refresh without a manual reload.
    _notify();
    _emitRunActivity(run);
  }

  /// Publish a run's state transition to the Live Activity feed. De-duped per
  /// run so an idempotent checkpoint re-save is not logged twice. The
  /// waitingApproval transition carries the `philosophyGate` kind (an approval
  /// gate is the platform's charter/approval checkpoint).
  void _emitRunActivity(ProcessRun run) {
    final bus = activityBus;
    if (bus == null) return;
    if (_lastActivityState[run.runId] == run.state) return;
    _lastActivityState[run.runId] = run.state;
    final label = 'Process ${run.processId}';
    switch (run.state) {
      case ProcessRunState.running:
        bus.info(
          run.processId,
          '$label started',
          kind: ActivityKind.info,
          workspaceId: run.workspaceId,
          meta: {'runId': run.runId},
        );
      case ProcessRunState.waitingApproval:
        final who = run.pendingApproval?.approverId ?? '';
        bus.warn(
          run.processId,
          '$label awaiting approval${who.isEmpty ? '' : ' · $who'}',
          kind: ActivityKind.philosophyGate,
          workspaceId: run.workspaceId,
          meta: {'runId': run.runId, if (who.isNotEmpty) 'approver': who},
        );
      case ProcessRunState.blocked:
        bus.error(
          run.processId,
          run.error == null
              ? '$label blocked'
              : '$label blocked · ${run.error}',
          kind: ActivityKind.error,
          workspaceId: run.workspaceId,
          meta: {'runId': run.runId, if (run.error != null) 'error': run.error},
        );
      case ProcessRunState.completed:
        bus.info(
          run.processId,
          '$label completed',
          kind: ActivityKind.info,
          workspaceId: run.workspaceId,
          meta: {'runId': run.runId},
        );
      case ProcessRunState.cancelled:
        bus.info(
          run.processId,
          '$label cancelled',
          kind: ActivityKind.info,
          workspaceId: run.workspaceId,
          meta: {'runId': run.runId},
        );
    }
  }

  Future<void> _ensureLoaded(String wsId) async {
    if (_loaded.contains(wsId)) return;
    final dir = Directory('${wsContentRoot(rootDir, wsId)}/processes');
    final bucket = _byWorkspace.putIfAbsent(wsId, () => {});
    if (await dir.exists()) {
      await for (final entry in dir.list()) {
        if (entry is! File) continue;
        if (!entry.path.endsWith('.yaml')) continue;
        try {
          final y = loadYaml(await entry.readAsString());
          if (y is YamlMap) {
            final p = _fromYaml(Map<String, dynamic>.from(y), wsId);
            bucket[p.id] = p;
          }
        } catch (e) {
          // Recorded where a project's other boot findings are read — a file
          // that fails to load is missing from every process list, and stderr
          // alone left no trace of why.
          OpsLog.warn('process', 'process load failed: ${entry.path}: $e');
        }
      }
    }
    _loaded.add(wsId);
  }

  Process _fromYaml(Map<String, dynamic> y, String wsId) {
    final steps = <ProcessStep>[];
    // Approval gates expressed inline on a step (`approverId` / `approver`)
    // rather than in the separate `gates:` list — both forms must produce a
    // real approval gate so the behavior engine suspends. Without this, an
    // inline `approverId` was silently dropped and the run auto-completed
    // (no gate step → no `when: approved_*` wait).
    final inlineGates = <ProcessGate>[];
    final rawSteps = y['steps'];
    if (rawSteps is List) {
      for (final s in rawSteps) {
        if (s is Map) {
          // Validate required fields with a clear message instead of letting
          // a raw `as String` cast throw an opaque "Null is not a subtype of
          // String" on a malformed step.
          final stepId = s['stepId'];
          final assigneeId = s['assigneeId'];
          final skillId = s['skillId'];
          if (stepId is! String ||
              assigneeId is! String ||
              skillId is! String) {
            throw StateError(
              'process step requires string `stepId`, `assigneeId`, `skillId`'
              ' — got ${s.keys.toList()}',
            );
          }
          // dependsOn: accept a YAML list, a single string, or absent (⇒ []).
          final rawDep = s['dependsOn'];
          final dependsOn = <String>[];
          if (rawDep is List) {
            for (final d in rawDep) {
              if (d != null) dependsOn.add(d.toString());
            }
          } else if (rawDep is String && rawDep.isNotEmpty) {
            dependsOn.add(rawDep);
          }
          steps.add(
            ProcessStep(
              stepId: stepId,
              assigneeId: assigneeId,
              skillId: skillId,
              inputs:
                  (s['inputs'] as Map?)?.cast<String, dynamic>() ?? const {},
              channelThreadId: s['channelThreadId'] as String?,
              dependsOn: dependsOn,
            ),
          );
          // Accept the common inline-approval shapes an author (incl. the
          // chat manager) uses: top-level `approverId`/`approver`, or a
          // nested `approval:` block (`approval.approverId`, `approval: <id>`,
          // or `approval: true`). Any of them creates a real approval gate.
          String? inlineApprover;
          var inlineApproval = false;
          final topAv = s['approverId'] ?? s['approver'];
          if (topAv is String && topAv.isNotEmpty) {
            inlineApprover = topAv;
            inlineApproval = true;
          }
          final ap = s['approval'];
          if (ap is Map) {
            inlineApproval = true;
            final nested = ap['approverId'] ?? ap['approver'];
            if (nested is String && nested.isNotEmpty) inlineApprover = nested;
          } else if (ap is String && ap.isNotEmpty) {
            inlineApproval = true;
            inlineApprover = ap;
          } else if (ap == true) {
            inlineApproval = true;
          }
          if (inlineApproval) {
            inlineGates.add(
              ProcessGate(
                afterStep: stepId,
                kind: GateKind.approval,
                params: <String, dynamic>{
                  if (inlineApprover != null) 'approverId': inlineApprover,
                },
              ),
            );
          }
        }
      }
    }
    final gates = <ProcessGate>[...inlineGates];
    final rawGates = y['gates'];
    if (rawGates is List) {
      final stepIds = <String>{for (final s in steps) s.stepId};
      for (final g in rawGates) {
        // A gate the engine cannot place must fail the save. Filling a missing
        // `afterStep` / `kind` with defaults turned the entry into a philosophy
        // gate after `*`, which attaches to no step — the gate did nothing and
        // nobody was told.
        final afterStep = g is Map ? g['afterStep'] : null;
        final kindName = g is Map ? g['kind'] : null;
        GateKind? kind;
        for (final k in GateKind.values) {
          if (k.name == kindName) kind = k;
        }
        if (g is! Map ||
            afterStep is! String ||
            !stepIds.contains(afterStep) ||
            kind == null) {
          throw StateError(
            'process gate requires `afterStep` naming one of the steps '
            '(${stepIds.join(', ')}) and `kind` '
            '(${GateKind.values.map((k) => k.name).join(' | ')}), with an '
            'approver as `params: {approverId: …}` — got $g',
          );
        }
        gates.add(
          ProcessGate(
            afterStep: afterStep,
            kind: kind,
            params: (g['params'] as Map?)?.cast<String, dynamic>() ?? const {},
          ),
        );
      }
    }
    return Process(
      id: y['id'] as String,
      workspaceId: wsId,
      title: (y['title'] as String?) ?? y['id'] as String,
      steps: steps,
      gates: gates,
      triggerSource: (y['triggerSource'] as String?),
      trigger: ProcessTrigger.values.firstWhere(
        (t) => t.name == (y['trigger'] as String? ?? 'manual'),
        orElse: () => ProcessTrigger.manual,
      ),
    );
  }
}
