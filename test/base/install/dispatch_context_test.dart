/// `DispatchContext` unit tests. Verifies the 4 scoping rules
/// (master / no-session / cross-bundle full-name / default prefix),
/// the Zone-scoped session override of the singleton fallback, and
/// concurrent Zone fork isolation.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart';

DispatchSession _session(String bundleId, {bool master = false, int n = 1}) =>
    DispatchSession(
      sessionId: '$bundleId#$n',
      bundleId: bundleId,
      master: master,
    );

void main() {
  group('DispatchContext.scopeId', () {
    setUp(() => DispatchContext.instance.resetForTesting());
    tearDown(() => DispatchContext.instance.resetForTesting());

    test('no session — pass-through', () {
      expect(DispatchContext.instance.scopeId('foo'), 'foo');
    });

    test('foreground session — local id gets prefix', () {
      DispatchContext.instance.setForeground(session: _session('app_builder'));
      expect(DispatchContext.instance.scopeId('foo'), 'app_builder.foo');
    });

    test('foreground session — full-name pass-through (cross-bundle)', () {
      DispatchContext.instance.setForeground(session: _session('app_builder'));
      expect(DispatchContext.instance.scopeId('ops.audit'), 'ops.audit');
    });

    test('foreground master — pass-through', () {
      DispatchContext.instance.setForeground(master: true);
      expect(DispatchContext.instance.scopeId('foo'), 'foo');
    });

    test('Zone-scoped session wins over foreground', () async {
      DispatchContext.instance.setForeground(
        session: _session('foreground_bundle'),
      );
      final zoneSession = _session('zone_bundle');
      final result = await DispatchContext.instance.runScoped(
        zoneSession,
        () async => DispatchContext.instance.scopeId('foo'),
      );
      expect(result, 'zone_bundle.foo');
      // After the zone closes, foreground is back.
      expect(DispatchContext.instance.scopeId('foo'), 'foreground_bundle.foo');
    });

    test('Zone master overrides foreground bundle', () async {
      DispatchContext.instance.setForeground(
        session: _session('foreground_bundle'),
      );
      final result = await DispatchContext.instance.runAsMaster(
        () async => DispatchContext.instance.scopeId('foo'),
      );
      expect(result, 'foo');
    });

    test('concurrent Zone forks see distinct sessions', () async {
      final sa = _session('app_a', n: 1);
      final sb = _session('app_b', n: 1);
      final results = await Future.wait<String>(<Future<String>>[
        DispatchContext.instance.runScoped(sa, () async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return DispatchContext.instance.scopeId('foo');
        }),
        DispatchContext.instance.runScoped(
          sb,
          () async => DispatchContext.instance.scopeId('foo'),
        ),
      ]);
      expect(results, <String>['app_a.foo', 'app_b.foo']);
    });

    test('empty id — pass-through', () {
      DispatchContext.instance.setForeground(session: _session('x'));
      expect(DispatchContext.instance.scopeId(''), '');
    });

    test('scopeIds — batch helper', () {
      DispatchContext.instance.setForeground(session: _session('b'));
      expect(
        DispatchContext.instance.scopeIds(<String>['a', 'b.c', 'd']),
        <String>['b.a', 'b.c', 'b.d'],
      );
    });
  });

  group('DispatchContext.filterToOwn', () {
    setUp(() => DispatchContext.instance.resetForTesting());
    tearDown(() => DispatchContext.instance.resetForTesting());

    test('bundle context — keeps only entries with own prefix', () {
      DispatchContext.instance.setForeground(session: _session('app_a'));
      final all = <String>['app_a.foo', 'app_b.bar', 'app_a.baz', 'other'];
      final mine = DispatchContext.instance.filterToOwn(all, (e) => e);
      expect(mine, <String>['app_a.foo', 'app_a.baz']);
    });

    test('master — pass-through', () {
      DispatchContext.instance.setForeground(master: true);
      final all = <String>['app_a.foo', 'app_b.bar'];
      expect(DispatchContext.instance.filterToOwn(all, (e) => e), all);
    });

    test('no session — pass-through', () {
      final all = <String>['app_a.foo', 'app_b.bar'];
      expect(DispatchContext.instance.filterToOwn(all, (e) => e), all);
    });

    test('shouldFilterToOwn — bundle true, host/master false', () {
      DispatchContext.instance.setForeground(session: _session('x'));
      expect(DispatchContext.instance.shouldFilterToOwn, isTrue);
      DispatchContext.instance.setForeground(master: true);
      expect(DispatchContext.instance.shouldFilterToOwn, isFalse);
      DispatchContext.instance.setForeground(session: null);
      expect(DispatchContext.instance.shouldFilterToOwn, isFalse);
    });

    test('idOf selector — works on object entries', () {
      DispatchContext.instance.setForeground(session: _session('app_a'));
      final all = <Map<String, String>>[
        <String, String>{'id': 'app_a.tool1', 'name': 'A'},
        <String, String>{'id': 'app_b.tool2', 'name': 'B'},
        <String, String>{'id': 'app_a.tool3', 'name': 'C'},
      ];
      final mine = DispatchContext.instance.filterToOwn(all, (e) => e['id']!);
      expect(mine, hasLength(2));
      expect(mine.map((e) => e['name']), <String>['A', 'C']);
    });
  });
}
