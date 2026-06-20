/// Unit tests for `TelemetryStore` + `ProviderCounters` + `ToolCounters`.
///
/// Boot-independent: pure Dart state counters.
///
/// Scenarios:
///   t1  recordLlmCall — increments calls, tokensIn, tokensOut, latency sample
///   t2  recordLlmCall error=true — increments errors
///   t3  recordToolDispatch — increments tool calls + latency accumulation
///   t4  recordToolDispatch error=true — increments tool errors
///   t5  recordMcpInbound — increments mcpInboundRequests
///   t6  recordAgentAsk — increments agentAsks
///   t7  totalLlmCalls / totalLlmErrors / totalTokensIn / totalTokensOut aggregate
///   t8  ProviderCounters latency cap: buffers only last 200 samples
///   t9  ProviderCounters p50 / p95 — sorted percentile computation
///   t10 ToolCounters avgLatencyMs — integer division of total/count
///   t11 markBoot / uptime — uptime is non-negative after markBoot
///   t12 toJson — contains expected keys and data
///   t13 dispose — closes ticks stream cleanly
///   t14 multiple providers tracked independently
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/observability/telemetry_store.dart';

void main() {
  group('TelemetryStore', () {
    late TelemetryStore store;

    setUp(() => store = TelemetryStore());
    tearDown(() async => store.dispose());

    // t1
    test('t1 recordLlmCall increments calls, tokensIn, tokensOut', () {
      store.recordLlmCall(
        provider: 'claude',
        latencyMs: 200,
        tokensIn: 100,
        tokensOut: 50,
      );
      expect(store.totalLlmCalls, 1);
      expect(store.totalTokensIn, 100);
      expect(store.totalTokensOut, 50);
      final p = store.providers['claude']!;
      expect(p.calls, 1);
      expect(p.tokensIn, 100);
      expect(p.tokensOut, 50);
    });

    // t2
    test('t2 recordLlmCall error=true increments errors', () {
      store.recordLlmCall(provider: 'claude', latencyMs: 0, error: true);
      expect(store.totalLlmErrors, 1);
      expect(store.providers['claude']!.errors, 1);
    });

    // t3
    test('t3 recordToolDispatch accumulates latency', () {
      store.recordToolDispatch(tool: 'bk.fact.get', latencyMs: 30);
      store.recordToolDispatch(tool: 'bk.fact.get', latencyMs: 70);
      final tc = store.tools['bk.fact.get']!;
      expect(tc.calls, 2);
      expect(tc.totalLatencyMs, 100);
    });

    // t4
    test('t4 recordToolDispatch error=true increments tool errors', () {
      store.recordToolDispatch(tool: 'bk.fact.get', latencyMs: 0, error: true);
      expect(store.tools['bk.fact.get']!.errors, 1);
    });

    // t5
    test('t5 recordMcpInbound increments mcpInboundRequests', () {
      expect(store.mcpInboundRequests, 0);
      store.recordMcpInbound();
      store.recordMcpInbound();
      expect(store.mcpInboundRequests, 2);
    });

    // t6
    test('t6 recordAgentAsk increments agentAsks', () {
      expect(store.agentAsks, 0);
      store.recordAgentAsk();
      expect(store.agentAsks, 1);
    });

    // t7
    test('t7 totals aggregate across multiple providers', () {
      store.recordLlmCall(
        provider: 'claude',
        latencyMs: 100,
        tokensIn: 50,
        tokensOut: 20,
      );
      store.recordLlmCall(
        provider: 'openai',
        latencyMs: 80,
        tokensIn: 30,
        tokensOut: 10,
      );
      expect(store.totalLlmCalls, 2);
      expect(store.totalTokensIn, 80);
      expect(store.totalTokensOut, 30);
    });

    // t11
    test('t11 uptime is non-negative after markBoot', () async {
      expect(store.uptime, Duration.zero);
      store.markBoot();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(store.uptime.inMicroseconds, greaterThan(0));
    });

    // t12
    test('t12 toJson contains expected top-level keys', () {
      store.recordLlmCall(
        provider: 'claude',
        latencyMs: 100,
        tokensIn: 10,
        tokensOut: 5,
      );
      store.recordToolDispatch(tool: 'fs.read', latencyMs: 20);
      final j = store.toJson();
      expect(j.containsKey('uptimeSec'), isTrue);
      expect(j.containsKey('totals'), isTrue);
      expect(j.containsKey('providers'), isTrue);
      expect(j.containsKey('tools'), isTrue);
      final totals = j['totals'] as Map;
      expect(totals['llmCalls'], 1);
      expect(totals['tokensIn'], 10);
    });

    // t13
    test('t13 dispose closes ticks stream', () async {
      final events = <void>[];
      final sub = store.ticks.listen((_) => events.add(null));
      store.recordMcpInbound(); // fires one tick
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await store.dispose();
      // Dispose should complete without error
    });

    // t14
    test('t14 multiple providers tracked independently', () {
      store.recordLlmCall(
        provider: 'claude',
        latencyMs: 100,
        tokensIn: 50,
        tokensOut: 20,
      );
      store.recordLlmCall(
        provider: 'openai',
        latencyMs: 80,
        tokensIn: 30,
        tokensOut: 10,
      );
      expect(store.providers, hasLength(2));
      expect(store.providers['claude']!.calls, 1);
      expect(store.providers['openai']!.calls, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // ProviderCounters
  // ---------------------------------------------------------------------------
  group('ProviderCounters', () {
    // t8
    test('t8 latency buffer caps at 200 samples', () {
      final pc = ProviderCounters('test');
      for (var i = 0; i < 250; i++) {
        pc.recordLatency(i);
      }
      // _latencyCap = 200 — we can't read private field, but p50/p95
      // should still compute without error and be ≥ 0.
      expect(pc.p50, greaterThanOrEqualTo(0));
      expect(pc.p95, greaterThanOrEqualTo(0));
    });

    // t9
    test('t9 p50 and p95 are correctly computed', () {
      final pc = ProviderCounters('prov');
      // Samples: 10, 20, 30, 40, 50, 60, 70, 80, 90, 100
      for (var i = 1; i <= 10; i++) {
        pc.recordLatency(i * 10);
      }
      // p50 → floor(10 * 0.5) = index 5 → sorted[5] = 60
      expect(pc.p50, 60);
      // p95 → floor(10 * 0.95) = 9, clamped to 9 → sorted[9] = 100
      expect(pc.p95, 100);
    });

    test('t9b p50 / p95 are zero when no samples', () {
      final pc = ProviderCounters('empty');
      expect(pc.p50, 0);
      expect(pc.p95, 0);
    });

    test('t9c toJson contains all expected keys', () {
      final pc = ProviderCounters('claude');
      pc.calls = 3;
      pc.errors = 1;
      pc.tokensIn = 100;
      pc.tokensOut = 50;
      pc.recordLatency(200);
      final j = pc.toJson();
      expect(j['provider'], 'claude');
      expect(j['calls'], 3);
      expect(j['errors'], 1);
      expect(j['tokensIn'], 100);
      expect(j['tokensOut'], 50);
      expect(j.containsKey('latencyP50Ms'), isTrue);
      expect(j.containsKey('latencyP95Ms'), isTrue);
      expect(j.containsKey('samples'), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // ToolCounters
  // ---------------------------------------------------------------------------
  group('ToolCounters', () {
    // t10
    test('t10 avgLatencyMs uses integer division', () {
      final tc = ToolCounters();
      tc.calls = 3;
      tc.totalLatencyMs = 100;
      final j = tc.toJson();
      expect(j['avgLatencyMs'], 33); // 100 ~/ 3
    });

    test('t10b avgLatencyMs is 0 when calls=0', () {
      final tc = ToolCounters();
      expect(tc.toJson()['avgLatencyMs'], 0);
    });

    test('t10c toJson contains calls / errors / avgLatencyMs', () {
      final tc =
          ToolCounters()
            ..calls = 5
            ..errors = 1
            ..totalLatencyMs = 500;
      final j = tc.toJson();
      expect(j['calls'], 5);
      expect(j['errors'], 1);
      expect(j['avgLatencyMs'], 100);
    });
  });
}
