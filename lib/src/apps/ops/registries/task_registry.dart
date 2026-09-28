import 'dart:async';
import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart';
import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart';

import '../infra/ws_paths.dart';
import '../triggers/trigger_events.dart';
import '../util/atomic_write.dart';

enum TaskKind { oneOff, recurring, sustained }

enum TaskState { pending, inProgress, blocked, completed, cancelled }

class TaskSchedule {
  TaskSchedule({required this.cron, this.timezone, this.nextRunAt});
  final String cron;
  final String? timezone;
  final DateTime? nextRunAt;
}

class TaskRunRef {
  TaskRunRef({
    required this.runId,
    required this.startedAt,
    this.endedAt,
    required this.endState,
    this.summary,
    this.errorCode,
  });
  final String runId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final TaskState endState;
  final String? summary;
  final String? errorCode;

  Map<String, dynamic> toJson() => {
    'runId': runId,
    'startedAt': startedAt.toIso8601String(),
    if (endedAt != null) 'endedAt': endedAt!.toIso8601String(),
    'endState': endState.name,
    if (summary != null) 'summary': summary,
    if (errorCode != null) 'errorCode': errorCode,
  };
}

class Task {
  Task({
    required this.id,
    required this.workspaceId,
    required this.kind,
    required this.title,
    this.description,
    required this.assigneeIds,
    required this.skillIds,
    this.inputs = const {},
    this.schedule,
    this.dueAt,
    this.state = TaskState.pending,
    this.runs = const [],
    required this.createdAt,
    this.lastFiredAt,
  });

  final String id;
  final String workspaceId;
  final TaskKind kind;
  final String title;
  final String? description;
  final List<String> assigneeIds;
  final List<String> skillIds;
  final Map<String, dynamic> inputs;
  final TaskSchedule? schedule;
  final DateTime? dueAt;
  final TaskState state;
  final List<TaskRunRef> runs;
  final DateTime createdAt;

  /// When this task last ran — persisted (unlike the in-memory [runs]) so the
  /// scheduler can catch up recurring fires missed while the app was closed.
  /// See `TaskScheduler` R4 catchup.
  final DateTime? lastFiredAt;

  Task copyWith({
    TaskState? state,
    List<TaskRunRef>? runs,
    DateTime? lastFiredAt,
  }) => Task(
    id: id,
    workspaceId: workspaceId,
    kind: kind,
    title: title,
    description: description,
    assigneeIds: assigneeIds,
    skillIds: skillIds,
    inputs: inputs,
    schedule: schedule,
    dueAt: dueAt,
    state: state ?? this.state,
    runs: runs ?? this.runs,
    createdAt: createdAt,
    lastFiredAt: lastFiredAt ?? this.lastFiredAt,
  );
}

typedef SkillDispatch =
    Future<Map<String, dynamic>> Function(
      String skillId,
      Map<String, dynamic> args,
    );

/// Runs the task's assignee AGENT on a request, returning its deliverable —
/// or null when the assignee is not a runnable agent (a person, unknown id,
/// or the agent subsystem is off), in which case [TaskRegistry.run] falls back
/// to headless skill dispatch. Injected at boot (resolves the bare member id
/// to its scoped kernel agent + calls the agent), so both manual `task_run`
/// and the recurring scheduler actually wake the assignee.
typedef AgentRun =
    Future<String?> Function(
      String assigneeId,
      String request, {
      String? workspaceId,
    });

class TaskRegistry {
  TaskRegistry({
    required this.kv,
    required this.knowledgeSystem,
    this.rootDir = './workspaces',
  });

  final String rootDir;

  final KvStoragePortAdapter kv;
  final KnowledgeSystem knowledgeSystem;

  /// Injected after bootstrap to allow running skills.
  SkillDispatch? dispatch;

  /// Injected after bootstrap — drives the assignee agent (assign + produce).
  /// Null / returns null → fall back to [dispatch] (headless skill run).
  AgentRun? agentRun;

  /// Injected after bootstrap — emits a completion event when a run finishes
  /// (success or blocked), so the trigger bus can wake subscribers / surface it
  /// into the assignee's live chat. Null → runs complete silently (legacy).
  void Function(AgentWorkCompleted event)? onWorkCompleted;

  final Map<String, Map<String, Task>> _byWorkspace = {};
  final Set<String> _loaded = {};
  final _uuid = const Uuid();

  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  void _notify() => _changes.add(null);

  Future<List<Task>> list({String? wsId, Set<TaskState>? states}) async {
    if (wsId != null) await _ensureLoaded(wsId);
    final all =
        wsId == null
            ? _byWorkspace.values.expand((m) => m.values).toList()
            : _byWorkspace[wsId]?.values.toList() ?? <Task>[];
    if (states == null) return all;
    return all.where((t) => states.contains(t.state)).toList();
  }

  Future<Task?> get(String id) async {
    for (final ws in _byWorkspace.keys) {
      final t = _byWorkspace[ws]?[id];
      if (t != null) return t;
    }
    return null;
  }

  Future<Task> create(Task spec) async {
    _byWorkspace.putIfAbsent(spec.workspaceId, () => {})[spec.id] = spec;
    await _persist(spec);
    _notify();
    return spec;
  }

  Future<Task> update(Task t) async {
    _byWorkspace.putIfAbsent(t.workspaceId, () => {})[t.id] = t;
    await _persist(t);
    _notify();
    return t;
  }

  Future<void> delete(String id) async {
    for (final ws in _byWorkspace.keys) {
      if (_byWorkspace[ws]?.remove(id) != null) {
        final f = File('${wsContentRoot(rootDir, ws)}/tasks/$id.yaml');
        if (await f.exists()) await f.delete();
      }
    }
    _notify();
  }

  Future<TaskRunRef> run(String id) async {
    final t = await get(id);
    if (t == null) throw StateError('Task not found: $id');
    final assignee = t.assigneeIds.isEmpty ? null : t.assigneeIds.first;
    // Two execution paths: drive the assignee AGENT, or run a skill. The agent
    // path is available only when an assignee + the `agentRun` seam are both
    // present. When it is NOT, the task must run via a skill — validate that
    // up front (config errors propagate as StateError, distinct from a runtime
    // failure which becomes a `blocked` run inside the try below).
    final canTryAgent = assignee != null && agentRun != null;
    if (!canTryAgent) {
      if (t.skillIds.isEmpty) {
        throw StateError('Task $id has no skillIds');
      }
      if (dispatch == null) {
        throw StateError('SkillDispatch not attached to TaskRegistry');
      }
    }
    final runId = _uuid.v4();
    final startedAt = DateTime.now();
    // Advance lastFiredAt on every run (manual or scheduled) — it feeds the
    // scheduler's catchup decision, and a manual run means "ran recently".
    final running = t.copyWith(
      state: TaskState.inProgress,
      lastFiredAt: startedAt,
      runs: [
        ...t.runs,
        TaskRunRef(
          runId: runId,
          startedAt: startedAt,
          endState: TaskState.inProgress,
        ),
      ],
    );
    await update(running);

    try {
      // Prefer driving the assignee AGENT (assign + produce): the member
      // actually performs the task and its history records the turn. Returns
      // null when the assignee is not a runnable agent → fall back to headless
      // skill dispatch (unchanged behaviour). Covers manual `task_run` AND the
      // recurring scheduler, since both call run().
      String? summary;
      if (canTryAgent) {
        // Pass the task's OWN workspace so a bare assignee (`lead`) resolves
        // WITHIN it — every division has a `lead`, so an unscoped resolve
        // returns the first match by scan order and could mis-deliver to a
        // same-named member in another department.
        summary = await agentRun!(
          assignee,
          _taskRequest(t),
          workspaceId: t.workspaceId,
        );
      }
      if (summary == null) {
        // Agent path unavailable / declined (person, unknown id, subsystem
        // off) → run the task's skill. Guaranteed present unless the agent
        // path was viable (validated above).
        final d = dispatch;
        if (d == null || t.skillIds.isEmpty) {
          throw StateError(
            'Task $id assignee is not a runnable agent and has no skill to run',
          );
        }
        final result = await d(t.skillIds.first, {
          ...t.inputs,
          'workspace': t.workspaceId,
          'actor': assignee,
        });
        summary = result.toString();
      }
      final ref = TaskRunRef(
        runId: runId,
        startedAt: startedAt,
        endedAt: DateTime.now(),
        endState: TaskState.completed,
        summary: summary,
      );
      await update(
        running.copyWith(state: TaskState.completed, runs: [...t.runs, ref]),
      );
      _emitCompleted(t, assignee, runId, 'completed', summary);
      return ref;
    } catch (e) {
      final ref = TaskRunRef(
        runId: runId,
        startedAt: startedAt,
        endedAt: DateTime.now(),
        endState: TaskState.blocked,
        errorCode: e.toString(),
      );
      await update(
        running.copyWith(state: TaskState.blocked, runs: [...t.runs, ref]),
      );
      _emitCompleted(t, assignee, runId, 'blocked', e.toString());
      return ref;
    }
  }

  /// Fire the R1 completion event (best-effort — a bad listener must not fail
  /// the run). `sourceAgentId` is the assignee that performed the work (empty
  /// when the run went through a headless skill with no agent assignee).
  void _emitCompleted(
    Task t,
    String? assignee,
    String runId,
    String state,
    String? summary,
  ) {
    final cb = onWorkCompleted;
    if (cb == null) return;
    try {
      cb(
        AgentWorkCompleted(
          sourceAgentId: assignee ?? '',
          workspaceId: t.workspaceId,
          kind: WorkKind.task,
          refId: runId,
          state: state,
          at: DateTime.now(),
          summary: summary,
        ),
      );
    } catch (_) {
      // Emission is best-effort; the run already persisted its outcome.
    }
  }

  /// Build the instruction handed to the assignee agent from the task's own
  /// fields (title / description / skills / inputs) — the "what to produce".
  String _taskRequest(Task t) {
    final b = StringBuffer(t.title);
    if ((t.description ?? '').isNotEmpty) b.write('\n\n${t.description}');
    if (t.skillIds.isNotEmpty) {
      b.write('\n\n(related skills: ${t.skillIds.join(', ')})');
    }
    if (t.inputs.isNotEmpty) b.write('\n\ninputs: ${t.inputs}');
    return b.toString();
  }

  Future<void> cancel(String id) async {
    final t = await get(id);
    if (t == null) return;
    await update(t.copyWith(state: TaskState.cancelled));
  }

  // --- internals ---

  Future<void> _ensureLoaded(String wsId) async {
    if (_loaded.contains(wsId)) return;
    final dir = Directory('${wsContentRoot(rootDir, wsId)}/tasks');
    final bucket = _byWorkspace.putIfAbsent(wsId, () => {});
    if (await dir.exists()) {
      await for (final entry in dir.list()) {
        if (entry is! File) continue;
        if (!entry.path.endsWith('.yaml')) continue;
        try {
          final y = loadYaml(await entry.readAsString());
          if (y is YamlMap) {
            final t = _fromYaml(Map<String, dynamic>.from(y), wsId);
            bucket[t.id] = t;
          }
        } catch (e) {
          stderr.writeln('Task load failed: ${entry.path}: $e');
        }
      }
    }
    _loaded.add(wsId);
  }

  Future<void> _persist(Task t) async {
    if (rootDir.isEmpty) {
      throw StateError(
        'TaskRegistry: workspacesRoot not bound — open an Ops project '
        'before creating tasks.',
      );
    }
    final f = File(
      '${wsContentRoot(rootDir, t.workspaceId)}/tasks/${t.id}.yaml',
    );
    await writeStringAtomic(f, _toYaml(t));
  }

  Task _fromYaml(Map<String, dynamic> y, String wsId) {
    TaskSchedule? sched;
    final rawSched = y['schedule'];
    if (rawSched is Map) {
      sched = TaskSchedule(
        cron: rawSched['cron'] as String? ?? '',
        timezone: rawSched['timezone'] as String?,
      );
    }
    return Task(
      id: y['id'] as String,
      workspaceId: wsId,
      kind: TaskKind.values.firstWhere(
        (k) => k.name == (y['kind'] as String? ?? 'oneOff'),
        orElse: () => TaskKind.oneOff,
      ),
      title: (y['title'] as String?) ?? y['id'] as String,
      description: y['description'] as String?,
      assigneeIds: (y['assigneeIds'] as List?)?.cast<String>() ?? const [],
      skillIds: (y['skillIds'] as List?)?.cast<String>() ?? const [],
      inputs:
          (y['inputs'] as Map?)?.cast<String, dynamic>().map(
            (k, v) =>
                MapEntry(k, v is YamlMap ? Map<String, dynamic>.from(v) : v),
          ) ??
          const {},
      schedule: sched,
      dueAt: y['dueAt'] is String ? DateTime.tryParse(y['dueAt']) : null,
      state: TaskState.values.firstWhere(
        (s) => s.name == (y['state'] as String? ?? 'pending'),
        orElse: () => TaskState.pending,
      ),
      createdAt:
          DateTime.tryParse(y['createdAt'] as String? ?? '') ?? DateTime.now(),
      lastFiredAt:
          y['lastFiredAt'] is String
              ? DateTime.tryParse(y['lastFiredAt'] as String)
              : null,
    );
  }

  String _toYaml(Task t) {
    final buf = StringBuffer();
    buf.writeln('id: ${t.id}');
    buf.writeln('kind: ${t.kind.name}');
    buf.writeln('title: ${_quoted(t.title)}');
    if (t.description != null) {
      buf.writeln('description: ${_quoted(t.description!)}');
    }
    buf.writeln('assigneeIds:');
    for (final a in t.assigneeIds) buf.writeln('  - $a');
    buf.writeln('skillIds:');
    for (final s in t.skillIds) buf.writeln('  - $s');
    if (t.inputs.isNotEmpty) {
      buf.writeln('inputs:');
      t.inputs.forEach((k, v) => buf.writeln('  $k: ${_scalar(v)}'));
    }
    if (t.schedule != null) {
      buf.writeln('schedule:');
      buf.writeln('  cron: "${t.schedule!.cron}"');
      if (t.schedule!.timezone != null) {
        buf.writeln('  timezone: ${t.schedule!.timezone}');
      }
    }
    if (t.dueAt != null) buf.writeln('dueAt: ${t.dueAt!.toIso8601String()}');
    buf.writeln('state: ${t.state.name}');
    if (t.lastFiredAt != null) {
      buf.writeln('lastFiredAt: ${t.lastFiredAt!.toIso8601String()}');
    }
    return buf.toString();
  }

  String _scalar(Object? v) {
    if (v == null) return 'null';
    if (v is String) return _quoted(v);
    return v.toString();
  }

  /// A YAML double-quoted scalar for [s]. Free text (a delegated message, a
  /// title) carries newlines, `: `, `#`, quotes and leading `- `; written bare
  /// it stops being one scalar and the task file no longer loads.
  String _quoted(String s) {
    final out = StringBuffer('"');
    for (final r in s.runes) {
      switch (r) {
        case 0x5C:
          out.write(r'\\');
        case 0x22:
          out.write(r'\"');
        case 0x0A:
          out.write(r'\n');
        case 0x0D:
          out.write(r'\r');
        case 0x09:
          out.write(r'\t');
        default:
          if (r < 0x20) {
            out.write('\\u${r.toRadixString(16).padLeft(4, '0')}');
          } else {
            out.writeCharCode(r);
          }
      }
    }
    out.write('"');
    return out.toString();
  }
}
