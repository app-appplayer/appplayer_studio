import 'dart:async';
import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart';
import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart';

import '../infra/ws_paths.dart';
import '../util/atomic_write.dart';

/// See `SRS §2.10 FR-OPS-012` for the design specification.
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

  Task copyWith({TaskState? state, List<TaskRunRef>? runs}) => Task(
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
  );
}

typedef SkillDispatch =
    Future<Map<String, dynamic>> Function(
      String skillId,
      Map<String, dynamic> args,
    );

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
    if (t.skillIds.isEmpty) {
      throw StateError('Task $id has no skillIds');
    }
    final d = dispatch;
    if (d == null) {
      throw StateError('SkillDispatch not attached to TaskRegistry');
    }
    final runId = _uuid.v4();
    final startedAt = DateTime.now();
    final running = t.copyWith(
      state: TaskState.inProgress,
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
      final result = await d(t.skillIds.first, {
        ...t.inputs,
        'workspace': t.workspaceId,
        'actor': t.assigneeIds.firstOrNull,
      });
      final ref = TaskRunRef(
        runId: runId,
        startedAt: startedAt,
        endedAt: DateTime.now(),
        endState: TaskState.completed,
        summary: result.toString(),
      );
      await update(
        running.copyWith(state: TaskState.completed, runs: [...t.runs, ref]),
      );
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
      return ref;
    }
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
    );
  }

  String _toYaml(Task t) {
    final buf = StringBuffer();
    buf.writeln('id: ${t.id}');
    buf.writeln('kind: ${t.kind.name}');
    buf.writeln('title: ${t.title}');
    if (t.description != null) buf.writeln('description: ${t.description}');
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
    return buf.toString();
  }

  String _scalar(Object? v) {
    if (v == null) return 'null';
    if (v is String) return '"$v"';
    return v.toString();
  }
}
