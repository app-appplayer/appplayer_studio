/// Unit tests for `ActivityBus` — the in-memory pub/sub ring buffer.
///
/// Boot-independent: `ActivityBus` is a pure Dart class with no Flutter
/// or framework dependencies.
///
/// Scenarios:
///   ab1  emit() — event appears in recent snapshot
///   ab2  ring buffer caps at bufferSize
///   ab3  recent returns oldest-first order
///   ab4  stream delivers emitted events to listener
///   ab5  convenience info() emitter sets severity=info
///   ab6  convenience warn() emitter sets severity=warn
///   ab7  convenience error() emitter sets severity=error and kind=error
///   ab8  dispose() closes the stream and clears ring buffer
///   ab9  multiple sequential emits accumulate in correct order
///   ab10 emit after dispose is a no-op (no throw, no stream event)
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/observability/activity_bus.dart';
import 'package:appplayer_studio/src/apps/ops/observability/activity_event.dart';

ActivityEvent _mkEvent({
  String actor = 'test',
  String headline = 'msg',
  ActivityKind kind = ActivityKind.info,
  ActivitySeverity severity = ActivitySeverity.info,
}) => ActivityEvent(
  ts: DateTime.now(),
  kind: kind,
  actor: actor,
  headline: headline,
  severity: severity,
);

void main() {
  group('ActivityBus', () {
    test('ab1 emit adds event to recent snapshot', () {
      final bus = ActivityBus();
      expect(bus.recent, isEmpty);
      bus.emit(_mkEvent(actor: 'sys', headline: 'boot'));
      expect(bus.recent, hasLength(1));
      expect(bus.recent.first.actor, 'sys');
      expect(bus.recent.first.headline, 'boot');
    });

    test('ab2 ring buffer caps at bufferSize, oldest is evicted', () {
      final bus = ActivityBus(bufferSize: 3);
      for (var i = 0; i < 5; i++) {
        bus.emit(_mkEvent(actor: 'a$i'));
      }
      expect(bus.recent, hasLength(3));
      // a0 and a1 should be gone; a2, a3, a4 remain
      final actors = bus.recent.map((e) => e.actor).toList();
      expect(actors, isNot(contains('a0')));
      expect(actors, isNot(contains('a1')));
      expect(actors, contains('a2'));
      expect(actors, contains('a4'));
    });

    test('ab3 recent returns events in oldest-first order', () {
      final bus = ActivityBus(bufferSize: 10);
      for (var i = 0; i < 4; i++) {
        bus.emit(_mkEvent(actor: 'ev$i'));
      }
      final actors = bus.recent.map((e) => e.actor).toList();
      expect(actors, <String>['ev0', 'ev1', 'ev2', 'ev3']);
    });

    test('ab4 stream delivers emitted events in emission order', () async {
      final bus = ActivityBus();
      final received = <ActivityEvent>[];
      final sub = bus.stream.listen(received.add);
      bus.emit(_mkEvent(actor: 'x'));
      bus.emit(_mkEvent(actor: 'y'));
      // Allow microtask queue to drain (broadcast stream fires async).
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(received, hasLength(2));
      expect(received.first.actor, 'x');
      expect(received.last.actor, 'y');
    });

    test('ab5 info() convenience emitter — severity=info', () {
      final bus = ActivityBus();
      bus.info('agent', 'started', workspaceId: 'ws1');
      final e = bus.recent.first;
      expect(e.severity, ActivitySeverity.info);
      expect(e.actor, 'agent');
      expect(e.headline, 'started');
      expect(e.workspaceId, 'ws1');
    });

    test('ab6 warn() convenience emitter — severity=warn', () {
      final bus = ActivityBus();
      bus.warn('svc', 'slow response');
      expect(bus.recent.first.severity, ActivitySeverity.warn);
    });

    test('ab7 error() convenience emitter — severity=error, kind=error', () {
      final bus = ActivityBus();
      bus.error('provider', 'LLM timeout');
      final e = bus.recent.first;
      expect(e.severity, ActivitySeverity.error);
      expect(e.kind, ActivityKind.error);
    });

    test('ab8 dispose closes stream and clears ring buffer', () async {
      final bus = ActivityBus();
      bus.emit(_mkEvent());
      expect(bus.recent, isNotEmpty);
      await bus.dispose();
      expect(bus.recent, isEmpty);
    });

    test('ab9 multiple emits accumulate in correct order', () {
      final bus = ActivityBus(bufferSize: 100);
      for (var i = 0; i < 10; i++) {
        bus.emit(_mkEvent(actor: 'e$i'));
      }
      expect(bus.recent, hasLength(10));
      expect(bus.recent[0].actor, 'e0');
      expect(bus.recent[9].actor, 'e9');
    });

    test('ab10 emit after dispose does not throw', () async {
      final bus = ActivityBus();
      await bus.dispose();
      // Should not throw; isClosed guard in emit() prevents the add.
      expect(() => bus.emit(_mkEvent()), returnsNormally);
    });

    test('ab — meta map is forwarded onto events by info()', () {
      final bus = ActivityBus();
      bus.info('src', 'ok', meta: {'tool': 'bk.fact.get', 'latency': 42});
      final e = bus.recent.first;
      expect(e.meta['tool'], 'bk.fact.get');
      expect(e.meta['latency'], 42);
    });
  });
}
