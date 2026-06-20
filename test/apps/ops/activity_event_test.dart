/// Unit tests for `ActivityEvent` value class.
///
/// Boot-independent: pure immutable data model.
///
/// Scenarios:
///   ae1  default severity is info
///   ae2  optional fields default to null/empty
///   ae3  toJson contains required fields
///   ae4  toJson omits optional null fields
///   ae5  toJson includes optional fields when present
///   ae6  ActivityKind enum names are stable
///   ae7  ActivitySeverity enum names are stable
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/observability/activity_event.dart';

void main() {
  group('ActivityEvent', () {
    final ts = DateTime.utc(2026, 6, 1, 12, 0, 0);

    test('ae1 default severity is info', () {
      final e = ActivityEvent(
        ts: ts,
        kind: ActivityKind.agentAsk,
        actor: 'studio.manager',
        headline: 'Ask started',
      );
      expect(e.severity, ActivitySeverity.info);
    });

    test('ae2 optional fields default to null / empty', () {
      final e = ActivityEvent(
        ts: ts,
        kind: ActivityKind.info,
        actor: 'sys',
        headline: 'ping',
      );
      expect(e.workspaceId, isNull);
      expect(e.durationMs, isNull);
      expect(e.tokensIn, isNull);
      expect(e.tokensOut, isNull);
      expect(e.meta, isEmpty);
    });

    test('ae3 toJson contains ts / kind / actor / headline / severity', () {
      final e = ActivityEvent(
        ts: ts,
        kind: ActivityKind.toolDispatch,
        actor: 'agent_1',
        headline: 'Called bk.fact.get',
        severity: ActivitySeverity.warn,
      );
      final j = e.toJson();
      expect(j['ts'], ts.toIso8601String());
      expect(j['kind'], 'toolDispatch');
      expect(j['actor'], 'agent_1');
      expect(j['headline'], 'Called bk.fact.get');
      expect(j['severity'], 'warn');
    });

    test('ae4 toJson omits null optional fields', () {
      final e = ActivityEvent(
        ts: ts,
        kind: ActivityKind.info,
        actor: 'sys',
        headline: 'boot',
      );
      final j = e.toJson();
      expect(j.containsKey('workspaceId'), isFalse);
      expect(j.containsKey('durationMs'), isFalse);
      expect(j.containsKey('tokensIn'), isFalse);
      expect(j.containsKey('tokensOut'), isFalse);
      expect(j.containsKey('meta'), isFalse);
    });

    test('ae5 toJson includes optional fields when provided', () {
      final e = ActivityEvent(
        ts: ts,
        kind: ActivityKind.llmCall,
        actor: 'claude',
        headline: '100→50 tok',
        severity: ActivitySeverity.info,
        workspaceId: 'ws_1',
        durationMs: 320,
        tokensIn: 100,
        tokensOut: 50,
        meta: {'provider': 'claude', 'model': 'sonnet'},
      );
      final j = e.toJson();
      expect(j['workspaceId'], 'ws_1');
      expect(j['durationMs'], 320);
      expect(j['tokensIn'], 100);
      expect(j['tokensOut'], 50);
      expect((j['meta'] as Map)['provider'], 'claude');
    });

    test('ae6 ActivityKind enum names are stable', () {
      expect(ActivityKind.agentAsk.name, 'agentAsk');
      expect(ActivityKind.agentReply.name, 'agentReply');
      expect(ActivityKind.toolDispatch.name, 'toolDispatch');
      expect(ActivityKind.toolResult.name, 'toolResult');
      expect(ActivityKind.mcpInbound.name, 'mcpInbound');
      expect(ActivityKind.llmCall.name, 'llmCall');
      expect(ActivityKind.error.name, 'error');
      expect(ActivityKind.info.name, 'info');
    });

    test('ae7 ActivitySeverity enum names are stable', () {
      expect(ActivitySeverity.info.name, 'info');
      expect(ActivitySeverity.warn.name, 'warn');
      expect(ActivitySeverity.error.name, 'error');
    });
  });
}
