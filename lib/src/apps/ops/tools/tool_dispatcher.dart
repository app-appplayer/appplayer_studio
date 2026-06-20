import 'package:mcp_bundle/mcp_bundle.dart' as bundle;

import '../config/ops_error.dart';
import '../init/knowledge_init.dart';
import '../observability/activity_event.dart';
import '../observability/observability_module.dart';
import '../registries/member_registry.dart';

/// Converts loaded YAML Skills into MCP tool handlers and routes inbound
/// tool calls through workspace context → PhilosophyFacade check →
/// SkillExecutor.
class ToolDispatcher {
  ToolDispatcher({required this.init, this.observability});

  final KnowledgeInit init;
  final ObservabilityModule? observability;

  Future<Map<String, dynamic>> dispatch(
    String skillId,
    Map<String, dynamic> args,
  ) async {
    final sw = Stopwatch()..start();
    final workspaceId =
        (args['workspace'] as String?) ?? init.registries.workspace.activeId;
    if (workspaceId == null || workspaceId.isEmpty) {
      throw OpsError(code: 'E2001', message: 'No active workspace.');
    }

    final actor =
        (args['actor'] as String?) ?? await _defaultActor(workspaceId);
    // 3-layer resolution: agent overlay → workspace override → template.
    final def = await init.skillResolver.resolve(
      skillId,
      workspaceId: workspaceId,
      actorId: actor == 'default' ? null : actor,
    );
    if (def == null) {
      throw OpsError(code: 'E1006', message: 'Unknown skill: $skillId');
    }

    // Philosophy prohibition gate (optional — engine may be unavailable).
    try {
      if (init.system.philosophy.isAvailable) {
        final result = await init.system.philosophy.checkProhibitions(
          bundle.ProhibitionCheckRequest(
            proposedAction: skillId,
            context: {
              'actor': actor,
              'workspaceId': workspaceId,
              'inputs': args,
            },
          ),
        );
        if (result.hasHardViolation) {
          final reasons = result.checks
              .where((c) => c.violated)
              .map((c) => c.violationDetail ?? c.prohibitionId)
              .join('; ');
          throw OpsError(
            code: 'E3001',
            message: 'Philosophy hard prohibition: $reasons',
          );
        }
      }
    } on OpsError {
      rethrow;
    } on StateError {
      // Philosophy engine not wired — open by default.
    }

    final inputs =
        Map<String, dynamic>.from(args)
          ..remove('workspace')
          ..remove('actor');

    try {
      final out = await init.skillExecutor.run(
        def,
        inputs,
        actorId: actor,
        workspaceId: workspaceId,
      );
      sw.stop();
      _record(
        skillId,
        actor,
        workspaceId,
        sw.elapsedMilliseconds,
        error: false,
      );
      return out;
    } on OpsError {
      sw.stop();
      _record(skillId, actor, workspaceId, sw.elapsedMilliseconds, error: true);
      rethrow;
    } on ArgumentError catch (e) {
      sw.stop();
      _record(skillId, actor, workspaceId, sw.elapsedMilliseconds, error: true);
      throw OpsError(
        code: 'E1002',
        message: 'Invalid argument for skill $skillId',
        detail: e.message.toString(),
      );
    } on StateError catch (e) {
      sw.stop();
      _record(skillId, actor, workspaceId, sw.elapsedMilliseconds, error: true);
      throw OpsError(
        code: 'E1008',
        message: 'Runtime error in skill $skillId',
        detail: e.message,
      );
    } catch (e) {
      sw.stop();
      _record(skillId, actor, workspaceId, sw.elapsedMilliseconds, error: true);
      throw OpsError(
        code: 'E9999',
        message: 'Unexpected error in skill $skillId',
        detail: e.toString(),
      );
    }
  }

  void _record(
    String skillId,
    String actor,
    String workspaceId,
    int latencyMs, {
    required bool error,
  }) {
    final obs = observability;
    if (obs == null) return;
    obs.telemetry.recordToolDispatch(
      tool: skillId,
      latencyMs: latencyMs,
      error: error,
    );
    if (error) {
      obs.bus.error(
        actor,
        'Skill $skillId failed (${latencyMs}ms)',
        kind: ActivityKind.toolDispatch,
        workspaceId: workspaceId,
        meta: {'skill': skillId, 'latencyMs': latencyMs},
      );
    } else {
      obs.bus.info(
        actor,
        'Skill $skillId · ${latencyMs}ms',
        kind: ActivityKind.toolDispatch,
        workspaceId: workspaceId,
        meta: {'skill': skillId, 'latencyMs': latencyMs},
      );
    }
  }

  /// Pick an actor when the caller did not supply one. Prefers the first
  /// AI-agent member of the workspace so per-actor skill overlays
  /// (`workspaces/<ws>/members/<actor>/skills/...`) participate in the
  /// 3-layer resolution. Falls back to the sentinel `'default'` only when
  /// no agent member exists, in which case the resolver bypasses the agent
  /// overlay layer entirely.
  Future<String> _defaultActor(String workspaceId) async {
    try {
      final members = await init.registries.member.listForWorkspace(
        workspaceId,
      );
      for (final m in members) {
        if (m.kind == MemberKind.agent) return m.id;
      }
    } catch (_) {
      // Member registry unavailable — fall through to the sentinel.
    }
    return 'default';
  }
}
