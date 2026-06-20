// Activity event model for the in-memory ActivityBus + Live Activity Feed.
//
// Defined in PRD §FM-OBSERVE-01. An event is structured: kind classifies
// the source (agent ask, tool dispatch, MCP inbound, fork transition,
// philosophy gate, error) and meta carries provider/agent/skill/tool ids
// the UI uses for filtering and headline rendering.

import 'package:meta/meta.dart';

/// Source classification for an [ActivityEvent].
///
/// Each kind has a stable enum name so consumers (Live Feed filter,
/// Diagnostic Export, JSON serialization) can switch on it without
/// magic strings.
enum ActivityKind {
  agentAsk,
  agentReply,
  toolDispatch,
  toolResult,
  mcpInbound,
  forkAssigned,
  forkEvolved,
  philosophyGate,
  llmCall,
  error,
  info,
}

/// Severity for filtering — Live Feed shows all by default, Status Bar
/// highlights warn/error.
enum ActivitySeverity { info, warn, error }

@immutable
class ActivityEvent {
  const ActivityEvent({
    required this.ts,
    required this.kind,
    required this.actor,
    required this.headline,
    this.severity = ActivitySeverity.info,
    this.workspaceId,
    this.durationMs,
    this.tokensIn,
    this.tokensOut,
    this.meta = const {},
  });

  final DateTime ts;
  final ActivityKind kind;

  /// Logical actor — agent id, `'system'`, MCP session id, etc.
  final String actor;

  /// Human-readable one-liner. Live Feed renders this directly.
  final String headline;

  final ActivitySeverity severity;
  final String? workspaceId;
  final int? durationMs;
  final int? tokensIn;
  final int? tokensOut;

  /// Extra structured details (provider, model, tool name, error code …).
  /// Kept loosely typed so emitters don't need to declare fields.
  final Map<String, Object?> meta;

  Map<String, Object?> toJson() => {
    'ts': ts.toIso8601String(),
    'kind': kind.name,
    'actor': actor,
    'headline': headline,
    'severity': severity.name,
    if (workspaceId != null) 'workspaceId': workspaceId,
    if (durationMs != null) 'durationMs': durationMs,
    if (tokensIn != null) 'tokensIn': tokensIn,
    if (tokensOut != null) 'tokensOut': tokensOut,
    if (meta.isNotEmpty) 'meta': meta,
  };
}
