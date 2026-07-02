/// Workspace resolution for ops tool calls.
///
/// The "active workspace" is a UI dashboard lens, **not** an execution
/// selector. A single global mutable active (any concurrent actor can flip via
/// `workspace_switch`) makes multi-agent operation race: agent A touring
/// departments and agent B monitoring clobber each other's active, so a tool
/// call reads the wrong workspace. Execution must resolve a workspace that is
/// stable per caller, independent of what anyone else is viewing.
///
/// Resolution order ([resolveWorkspaceId]):
///   1. explicit `workspaceId` (or legacy `workspace`) arg — cross-department
///      staff target a specific department per call;
///   2. the caller's execution-scoped workspace ([WorkspaceExecutionContext]) —
///      an agent runs pinned to its own department, unaffected by another
///      actor switching the dashboard lens;
///   3. the global active workspace — UI/human fallback only, never the
///      primary execution source.
library;

import 'dart:async';

/// Resolve the workspace a tool call operates on. Pure — the three sources are
/// passed in so the ordering is deterministically testable. Returns `null`
/// only when no source yields a non-empty id (caller raises the
/// no-workspace error).
String? resolveWorkspaceId(
  Map<String, dynamic> args, {
  String? execWorkspaceId,
  String? activeWorkspaceId,
}) {
  final explicit = args['workspaceId'] ?? args['workspace'];
  if (explicit is String && explicit.isNotEmpty) return explicit;
  if (execWorkspaceId != null && execWorkspaceId.isNotEmpty) {
    return execWorkspaceId;
  }
  if (activeWorkspaceId != null && activeWorkspaceId.isNotEmpty) {
    return activeWorkspaceId;
  }
  return null;
}

/// Async-scoped "current execution workspace" — the department an agent is
/// running in. Established with [run] around an agent/behavior execution so
/// every tool call the agent makes *within that execution* (including LLM
/// tool-use that re-enters the tool boundary in-process) defaults to that
/// workspace instead of the global active. Concurrent executions each carry
/// their own zone value, so they never clobber one another.
class WorkspaceExecutionContext {
  WorkspaceExecutionContext._();

  static const Object _zoneKey = #opsExecWorkspaceId;

  /// The workspace pinned for the current execution, or `null` when the call
  /// is not inside a [run] scope (e.g. a human/UI-initiated tool call).
  static String? get current {
    final v = Zone.current[_zoneKey];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// Run [body] with [workspaceId] pinned as the execution workspace. Nested
  /// [run] calls shadow the outer value for their own subtree. A null/empty
  /// [workspaceId] runs [body] with no pin (transparent).
  static Future<T> run<T>(
    String? workspaceId,
    Future<T> Function() body,
  ) {
    if (workspaceId == null || workspaceId.isEmpty) return body();
    return runZoned(body, zoneValues: <Object, Object?>{_zoneKey: workspaceId});
  }
}
