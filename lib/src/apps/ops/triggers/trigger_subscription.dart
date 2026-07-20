/// Persisted "when X completes, wake Y" rules — the R2 subscription store.
/// Generalises the process→process completion chain
/// (`ProcessRegistry._fireCompletionChain`) to agent/task completions waking an
/// agent. See `docs/makemind_ops/ops-agent-trigger-bus.md`.
library;

import 'dart:io';

import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart';

import '../infra/ws_paths.dart';
import '../util/atomic_write.dart';
import 'trigger_events.dart';

/// A rule: when a completion event matches (source / kind / workspace filters,
/// each optional = "any"), wake [targetAgentId] with a rendered request.
class TriggerSubscription {
  TriggerSubscription({
    required this.id,
    required this.workspaceId,
    required this.targetAgentId,
    this.sourceAgentId,
    this.kind,
    this.onState = 'completed',
    this.requestTemplate,
    this.once = false,
    required this.createdAt,
  });

  final String id;

  /// One-shot: the bus removes this subscription right after it fires the
  /// first matching wake. Used by chat-driven background delegation
  /// (`agent_ask(background)`) to wire a single "report back to the delegating
  /// coordinator when this lands" without leaving a standing rule behind.
  final bool once;

  /// The workspace this subscription is stored under (also the default match
  /// scope — a subscription only reacts to events in its own workspace).
  final String workspaceId;

  /// Who to wake when the rule matches.
  final String targetAgentId;

  /// Match filter — the completing agent. Null = any agent.
  final String? sourceAgentId;

  /// Match filter — the work kind. Null = any kind.
  final WorkKind? kind;

  /// Match filter — the completion state to react to (`completed` | `blocked` |
  /// `any`). Defaults to `completed` so a subscription doesn't fire on failures
  /// unless it opts in.
  final String onState;

  /// Template for the request handed to the target agent. Placeholders:
  /// `{summary}` `{sourceAgentId}` `{refId}` `{kind}` `{state}` `{artifactRef}`.
  /// Null → a default digest.
  final String? requestTemplate;

  final DateTime createdAt;

  /// True when [e] should fire this subscription. Workspace is matched exactly
  /// (a subscription reacts only within its own workspace); the rest are
  /// "any when null".
  bool matches(AgentWorkCompleted e) {
    if (e.workspaceId != workspaceId) return false;
    if (sourceAgentId != null && e.sourceAgentId != sourceAgentId) return false;
    if (kind != null && e.kind != kind) return false;
    if (onState != 'any' && e.state != onState) return false;
    // Never wake the source with its own completion (trivial self-loop).
    if (targetAgentId == e.sourceAgentId) return false;
    return true;
  }

  /// The request text handed to [targetAgentId], with the event's fields
  /// substituted into [requestTemplate] (or a default digest).
  String render(AgentWorkCompleted e) {
    final tpl = requestTemplate ??
        '${e.sourceAgentId} completed ${e.kind.name} (${e.refId}): '
            '{summary}';
    return tpl
        .replaceAll('{summary}', e.summary ?? '')
        .replaceAll('{sourceAgentId}', e.sourceAgentId)
        .replaceAll('{refId}', e.refId)
        .replaceAll('{kind}', e.kind.name)
        .replaceAll('{state}', e.state)
        .replaceAll('{artifactRef}', e.artifactRef ?? '');
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'targetAgentId': targetAgentId,
    if (sourceAgentId != null) 'sourceAgentId': sourceAgentId,
    if (kind != null) 'kind': kind!.name,
    'onState': onState,
    if (requestTemplate != null) 'requestTemplate': requestTemplate,
    if (once) 'once': true,
    'createdAt': createdAt.toIso8601String(),
  };
}

/// File-backed store for [TriggerSubscription]s, one YAML file per subscription
/// under `<workspace>/triggers/<id>.yaml` — the same persistence shape as
/// `TaskRegistry`.
class TriggerRegistry {
  TriggerRegistry({this.rootDir = './workspaces'});

  final String rootDir;

  final Map<String, Map<String, TriggerSubscription>> _byWorkspace = {};
  final Set<String> _loaded = {};
  final _uuid = const Uuid();

  Future<List<TriggerSubscription>> list({String? wsId}) async {
    if (wsId != null) {
      await _ensureLoaded(wsId);
      return _byWorkspace[wsId]?.values.toList() ?? <TriggerSubscription>[];
    }
    return _byWorkspace.values
        .expand((m) => m.values)
        .toList(growable: false);
  }

  /// Subscriptions whose filters match [e] — loads the event's workspace lazily.
  Future<List<TriggerSubscription>> matching(AgentWorkCompleted e) async {
    await _ensureLoaded(e.workspaceId);
    final bucket = _byWorkspace[e.workspaceId];
    if (bucket == null) return const [];
    return bucket.values.where((s) => s.matches(e)).toList(growable: false);
  }

  Future<TriggerSubscription> subscribe({
    required String workspaceId,
    required String targetAgentId,
    String? sourceAgentId,
    WorkKind? kind,
    String onState = 'completed',
    String? requestTemplate,
    bool once = false,
  }) async {
    final sub = TriggerSubscription(
      id: _uuid.v4(),
      workspaceId: workspaceId,
      targetAgentId: targetAgentId,
      sourceAgentId: sourceAgentId,
      kind: kind,
      onState: onState,
      requestTemplate: requestTemplate,
      once: once,
      createdAt: DateTime.now(),
    );
    _byWorkspace.putIfAbsent(workspaceId, () => {})[sub.id] = sub;
    await _persist(sub);
    return sub;
  }

  Future<bool> unsubscribe(String id) async {
    for (final ws in _byWorkspace.keys) {
      final removed = _byWorkspace[ws]?.remove(id);
      if (removed != null) {
        final f = File('${wsContentRoot(rootDir, ws)}/triggers/$id.yaml');
        if (await f.exists()) await f.delete();
        return true;
      }
    }
    return false;
  }

  // --- internals ---

  Future<void> _ensureLoaded(String wsId) async {
    if (_loaded.contains(wsId)) return;
    final dir = Directory('${wsContentRoot(rootDir, wsId)}/triggers');
    final bucket = _byWorkspace.putIfAbsent(wsId, () => {});
    if (await dir.exists()) {
      await for (final entry in dir.list()) {
        if (entry is! File) continue;
        if (!entry.path.endsWith('.yaml')) continue;
        try {
          final y = loadYaml(await entry.readAsString());
          if (y is YamlMap) {
            final s = _fromYaml(Map<String, dynamic>.from(y), wsId);
            bucket[s.id] = s;
          }
        } catch (e) {
          stderr.writeln('Trigger load failed: ${entry.path}: $e');
        }
      }
    }
    _loaded.add(wsId);
  }

  Future<void> _persist(TriggerSubscription s) async {
    if (rootDir.isEmpty) {
      throw StateError(
        'TriggerRegistry: workspacesRoot not bound — open an Ops project '
        'before creating triggers.',
      );
    }
    final f = File(
      '${wsContentRoot(rootDir, s.workspaceId)}/triggers/${s.id}.yaml',
    );
    await writeStringAtomic(f, _toYaml(s));
  }

  TriggerSubscription _fromYaml(Map<String, dynamic> y, String wsId) {
    final kindName = y['kind'] as String?;
    return TriggerSubscription(
      id: y['id'] as String,
      workspaceId: wsId,
      targetAgentId: y['targetAgentId'] as String? ?? '',
      sourceAgentId: y['sourceAgentId'] as String?,
      kind: kindName == null
          ? null
          : WorkKind.values.firstWhere(
              (k) => k.name == kindName,
              orElse: () => WorkKind.task,
            ),
      onState: y['onState'] as String? ?? 'completed',
      requestTemplate: y['requestTemplate'] as String?,
      once: y['once'] == true,
      createdAt:
          DateTime.tryParse(y['createdAt'] as String? ?? '') ?? DateTime.now(),
    );
  }

  String _toYaml(TriggerSubscription s) {
    final buf = StringBuffer();
    buf.writeln('id: ${s.id}');
    buf.writeln('targetAgentId: ${s.targetAgentId}');
    if (s.sourceAgentId != null) {
      buf.writeln('sourceAgentId: ${s.sourceAgentId}');
    }
    if (s.kind != null) buf.writeln('kind: ${s.kind!.name}');
    buf.writeln('onState: ${s.onState}');
    if (s.requestTemplate != null) {
      buf.writeln('requestTemplate: ${_scalar(s.requestTemplate!)}');
    }
    if (s.once) buf.writeln('once: true');
    buf.writeln('createdAt: ${s.createdAt.toIso8601String()}');
    return buf.toString();
  }

  String _scalar(String v) => '"${v.replaceAll('"', r'\"')}"';
}
