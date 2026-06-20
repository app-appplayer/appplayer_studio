import 'dart:async';
import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart';
import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart';

import '../infra/ws_paths.dart';
import '../util/atomic_write.dart';

/// See `SRS §2.10 FR-OPS-006` for the design specification.
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
  });
  final String stepId;
  final String assigneeId;
  final String skillId;
  final Map<String, dynamic> inputs;
  final String? channelThreadId;
}

class Process {
  Process({
    required this.id,
    required this.workspaceId,
    required this.title,
    required this.steps,
    required this.gates,
    required this.trigger,
    this.runs = const [],
  });

  final String id;
  final String workspaceId;
  final String title;
  final List<ProcessStep> steps;
  final List<ProcessGate> gates;
  final ProcessTrigger trigger;
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

  ProcessRun copyWith({
    String? currentStep,
    Map<String, dynamic>? outcomes,
    ProcessRunState? state,
    PendingApproval? pendingApproval,
  }) => ProcessRun(
    runId: runId,
    processId: processId,
    workspaceId: workspaceId,
    startedAt: startedAt,
    currentStep: currentStep ?? this.currentStep,
    outcomes: outcomes ?? this.outcomes,
    state: state ?? this.state,
    checkpointRef: checkpointRef,
    pendingApproval: pendingApproval ?? this.pendingApproval,
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

typedef SkillDispatch =
    Future<Map<String, dynamic>> Function(
      String skillId,
      Map<String, dynamic> args,
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
    final res = await knowledgeSystem.ops.runBehavior(
      _behaviorIdFor(p),
      runId: runId,
      input: initialInputs ?? const <String, dynamic>{},
    );
    return _runFromResult(p, (res['runId'] ?? runId).toString(), res);
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
    await _saveCheckpoint(run.copyWith(state: ProcessRunState.cancelled));
  }

  /// Approve a pending approval gate and continue via the behavior engine.
  /// Every approval gate is flagged `approved_<afterStep> = true`; the engine
  /// only advances the one it is currently suspended on, so the extra flags
  /// are inert.
  Future<ProcessRun> approve(String runId, {required String approverId}) async {
    final run = await _loadRun(runId);
    if (run == null) throw StateError('No checkpoint: $runId');
    if (run.state != ProcessRunState.waitingApproval) {
      throw StateError('Run $runId is not waiting for approval');
    }
    final p = await get(run.processId);
    if (p == null) {
      throw StateError('Process definition missing: ${run.processId}');
    }
    final patch = <String, dynamic>{};
    for (final g in p.gates) {
      if (g.kind == GateKind.approval) {
        patch['approved_${g.afterStep}'] = true;
      }
    }
    final res = await knowledgeSystem.ops.resumeBehavior(
      _behaviorIdFor(p),
      runId,
      statePatch: patch,
    );
    return _runFromResult(p, runId, res);
  }

  // --- behavior delegation helpers ---

  /// `<projectBundleId>.<processId>` — the exposed behavior id under which
  /// `process_save` mirrored this process into `project.mbd`. projectBundleId
  /// is `<projectName>.project` (project root basename + `.project`).
  String _behaviorIdFor(Process p) {
    final name = rootDir.split(Platform.pathSeparator).last;
    return '$name.project.${p.id}';
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
    final run = ProcessRun(
      runId: runId,
      processId: p.id,
      workspaceId: p.workspaceId,
      startedAt: DateTime.now(),
      currentStep: (res['currentStep'] ?? '').toString(),
      state: _stateFromBehavior(status),
    );
    await _saveCheckpoint(run);
    return run;
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
    buf.writeln('steps:');
    for (final s in p.steps) {
      buf.writeln('  - stepId: ${s.stepId}');
      buf.writeln('    assigneeId: ${s.assigneeId}');
      buf.writeln('    skillId: ${s.skillId}');
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
          stderr.writeln('Process load failed: ${entry.path}: $e');
        }
      }
    }
    _loaded.add(wsId);
  }

  Process _fromYaml(Map<String, dynamic> y, String wsId) {
    final steps = <ProcessStep>[];
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
          steps.add(
            ProcessStep(
              stepId: stepId,
              assigneeId: assigneeId,
              skillId: skillId,
              inputs:
                  (s['inputs'] as Map?)?.cast<String, dynamic>() ?? const {},
              channelThreadId: s['channelThreadId'] as String?,
            ),
          );
        }
      }
    }
    final gates = <ProcessGate>[];
    final rawGates = y['gates'];
    if (rawGates is List) {
      for (final g in rawGates) {
        if (g is Map) {
          gates.add(
            ProcessGate(
              afterStep: g['afterStep'] as String? ?? '*',
              kind: GateKind.values.firstWhere(
                (k) => k.name == (g['kind'] as String? ?? 'philosophy'),
                orElse: () => GateKind.philosophy,
              ),
              params:
                  (g['params'] as Map?)?.cast<String, dynamic>() ?? const {},
            ),
          );
        }
      }
    }
    return Process(
      id: y['id'] as String,
      workspaceId: wsId,
      title: (y['title'] as String?) ?? y['id'] as String,
      steps: steps,
      gates: gates,
      trigger: ProcessTrigger.values.firstWhere(
        (t) => t.name == (y['trigger'] as String? ?? 'manual'),
        orElse: () => ProcessTrigger.manual,
      ),
    );
  }
}
