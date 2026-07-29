/// The semantic completion signal that lets ops agents wake each other instead
/// of each running one-shot. Emitted when an agent finishes a unit of work —
/// a task run, a delegated route, an ask, or a process step — onto the
/// [OpsTriggerBus].
library;

/// The kind of work unit that produced a completion.
enum WorkKind { task, route, ask, step }

/// A completed unit of agent work. Carries just enough for a subscriber to
/// decide whether to wake (source / kind / workspace) and to render a
/// follow-up request (summary / artifactRef).
class AgentWorkCompleted {
  AgentWorkCompleted({
    required this.sourceAgentId,
    required this.workspaceId,
    required this.kind,
    required this.refId,
    required this.state,
    required this.at,
    this.summary,
    this.artifactRef,
    this.depth = 0,
  });

  /// The agent (member id or qualified agent id) that finished the work.
  final String sourceAgentId;
  final String workspaceId;
  final WorkKind kind;

  /// The producing work unit's id — runId / taskId / routeId / stepId.
  final String refId;

  /// `'completed'` on success, `'blocked'` on failure. Both are emitted so a
  /// subscriber can react to failures too (e.g. escalate a blocked run).
  final String state;

  final DateTime at;

  /// Human-readable outcome — the deliverable text or a short digest.
  final String? summary;

  /// Where the artifact lives, when the work produced one (e.g. an
  /// `html_report_export` path).
  final String? artifactRef;

  /// Cause-chain depth. A top-level completion is `0`; a completion produced
  /// by work that a trigger woke carries an incremented value. The bus stops
  /// firing R2 subscriptions past a cap so a mis-configured cycle cannot run
  /// away. (The default wake path — a bare `agents.ask` — is terminal and does
  /// not re-emit, so ordinary A→B chains never grow depth; the cap is a
  /// backstop for wake paths that route through emitting work.)
  final int depth;

  bool get isCompleted => state == 'completed';
  bool get isBlocked => state == 'blocked';

  AgentWorkCompleted withDepth(int d) => AgentWorkCompleted(
    sourceAgentId: sourceAgentId,
    workspaceId: workspaceId,
    kind: kind,
    refId: refId,
    state: state,
    at: at,
    summary: summary,
    artifactRef: artifactRef,
    depth: d,
  );

  Map<String, dynamic> toJson() => {
    'sourceAgentId': sourceAgentId,
    'workspaceId': workspaceId,
    'kind': kind.name,
    'refId': refId,
    'state': state,
    'at': at.toIso8601String(),
    if (summary != null) 'summary': summary,
    if (artifactRef != null) 'artifactRef': artifactRef,
    'depth': depth,
  };
}
